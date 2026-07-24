local Format = require("filefs.format")
local Types = require("filefs.types")

local FileType = Types.FileType
local SeekWhence = Types.SeekWhence
local FileFsError = Types.FileFsError

local FileSystem = {}
FileSystem.__index = FileSystem

local function err(message)
  error(FileFsError(message), 2)
end

local function bytes_from_string(s)
  local out = {}
  for i = 1, #s do
    out[i] = string.byte(s, i)
  end
  return out
end

local function string_from_bytes(bytes, offset, length)
  offset = offset or 1
  length = length or (#bytes - offset + 1)
  local chars = {}
  for i = 0, length - 1 do
    chars[i + 1] = string.char(bytes[offset + i] or 0)
  end
  return table.concat(chars)
end

local function journal_path_for(path)
  return path .. "-j"
end

local function path_exists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function remove_file(path)
  os.remove(path)
end

local function write_file(path, data)
  local f, open_err = io.open(path, "wb")
  if not f then
    err("write failed: " .. tostring(open_err))
  end
  f:write(data)
  f:flush()
  f:close()
end

local function read_file(path)
  local f, open_err = io.open(path, "rb")
  if not f then
    err("read failed: " .. tostring(open_err))
  end
  local data = f:read("*a")
  f:close()
  return data
end

local function validate_header(blocks)
  local block0 = blocks[0]
  if not block0 then
    err("invalid FileFS magic")
  end
  for i = 1, 4 do
    if block0[i] ~= Format.MAGIC[i] then
      err("invalid FileFS magic")
    end
  end
  if Format.read_u32_le(block0, 4) < 2 then
    err("invalid FileFS block count")
  end
end

local function validate_root(blocks)
  local block1 = blocks[1]
  if not block1 then
    err("invalid root directory")
  end
  if block1[Format.BLOCK_HEAD + 1] ~= 0 then
    err("invalid root directory")
  end
  if Format.read_fixed_name(block1, Format.BLOCK_HEAD + 1) ~= "." then
    err("invalid root directory")
  end
  local dot_dot_offset = Format.BLOCK_HEAD + Format.ENTRY_SIZE
  if block1[dot_dot_offset + 1] ~= 0 then
    err("invalid root parent entry")
  end
  if Format.read_fixed_name(block1, dot_dot_offset + 1) ~= ".." then
    err("invalid root parent entry")
  end
end

function FileSystem.mkfs(path)
  local image = Format.serialize_tree(Format.new_dir("", nil))
  write_file(path, Format.blocks_to_string(image))
  local journal = journal_path_for(path)
  if path_exists(journal) then
    remove_file(journal)
  end
end

function FileSystem.new()
  return setmetatable({
    image_path = nil,
    journal_path = nil,
    mounted = false,
    committed_root = nil,
    committed_cwd = nil,
    committed_cwd_path = "",
    transaction = nil,
    file_handles = {},
    dir_handles = {},
  }, FileSystem)
end

function FileSystem:is_mounted()
  return self.mounted
end

function FileSystem:umount()
  self:_close_all_handles()
  self.mounted = false
  self.image_path = nil
  self.transaction = nil
  self.committed_root = nil
  self.committed_cwd = nil
  self.committed_cwd_path = ""
  if self.journal_path and path_exists(self.journal_path) then
    remove_file(self.journal_path)
  end
  self.journal_path = nil
end

function FileSystem:mount(path)
  if not path_exists(path) then
    err("mount failed: " .. path .. " does not exist")
  end
  local raw = read_file(path)
  local blocks = Format.string_to_blocks(raw)
  validate_header(blocks)
  validate_root(blocks)
  self:umount()
  self.image_path = path
  self.journal_path = journal_path_for(path)
  self.mounted = true
  self:_apply_journal(nil)
  local root = self:_read_tree_from_disk()
  self.committed_root = root
  self.committed_cwd = root
  self.committed_cwd_path = "/"
  self.transaction = nil
end

function FileSystem:_require_mounted()
  if not self.mounted then
    err("filesystem is not mounted")
  end
end

function FileSystem:_current_root()
  if self.transaction then
    return self.transaction.root
  end
  return self.committed_root
end

function FileSystem:_current_cwd()
  if self.transaction then
    return self.transaction.cwd
  end
  return self.committed_cwd
end

function FileSystem:_close_all_handles()
  for _, handle in ipairs(self.file_handles) do
    handle.is_open = false
  end
  for _, handle in ipairs(self.dir_handles) do
    handle.is_open = false
  end
  self.file_handles = {}
  self.dir_handles = {}
end

local function parse_path(path)
  if path == nil or path == "" then
    err("path is required")
  end
  local absolute = path:sub(1, 1) == "/"
  local parts = {}
  for part in string.gmatch(path, "[^/]+") do
    parts[#parts + 1] = part
  end
  return { absolute = absolute, parts = parts }
end

function FileSystem:_validate_leaf_name(name)
  if name == "." or name == ".." or name == "" then
    err("invalid leaf name: " .. tostring(name))
  end
  for i = 1, #name do
    local code = string.byte(name, i)
    if code < 0x20 or code > 0x7E then
      err("name must be ASCII: " .. name)
    end
  end
  if #name > Format.BLOCK_NAME_MAX_SIZE then
    err("name exceeds 14 bytes: " .. name)
  end
end

function FileSystem:_resolve_node_or_null(path)
  self:_require_mounted()
  if path == "" then
    return nil
  end
  local parsed = parse_path(path)
  local current = parsed.absolute and self:_current_root() or self:_current_cwd()
  if #parsed.parts == 0 then
    return current
  end
  for index, part in ipairs(parsed.parts) do
    if part == "." then
      -- stay
    elseif part == ".." then
      current = current.parent or current
    else
      local child = Format.dir_get_child(current, part)
      if not child then
        return nil
      end
      if index < #parsed.parts then
        if child.kind ~= "dir" then
          return nil
        end
        current = child
      else
        return child
      end
    end
  end
  return current
end

function FileSystem:_resolve_leaf(path)
  self:_require_mounted()
  local parsed = parse_path(path)
  if #parsed.parts == 0 then
    err("invalid path: " .. path)
  end
  local leaf_name = parsed.parts[#parsed.parts]
  self:_validate_leaf_name(leaf_name)
  local current = parsed.absolute and self:_current_root() or self:_current_cwd()
  for i = 1, #parsed.parts - 1 do
    local part = parsed.parts[i]
    if part == "." then
      -- stay
    elseif part == ".." then
      current = current.parent or current
    else
      local child = Format.dir_get_child(current, part)
      if not child or child.kind ~= "dir" then
        err("path not found: " .. path)
      end
      current = child
    end
  end
  return { parent = current, name = leaf_name }
end

function FileSystem:_is_same_or_ancestor(candidate, dir)
  local current = dir
  while current do
    if current == candidate then
      return true
    end
    current = current.parent
  end
  return false
end

function FileSystem:_refresh_working_directory_path()
  if self.transaction then
    self.transaction.cwd_path = Format.build_absolute_path(self.transaction.cwd)
  elseif self.committed_cwd then
    self.committed_cwd_path = Format.build_absolute_path(self.committed_cwd)
  end
end

function FileSystem:_write_journal(image_blocks)
  local target = self.journal_path
  if not target then
    err("journal path unavailable")
  end
  local max_index = -1
  for i, _ in pairs(image_blocks) do
    if type(i) == "number" and i > max_index then
      max_index = i
    end
  end
  local parts = { string.char(0xFF) }
  for index = 0, max_index do
    local index_bytes = Format.empty_block() -- reuse helper for 4 bytes
    local ib = { 0, 0, 0, 0 }
    Format.write_u32_le(ib, 0, index)
    parts[#parts + 1] = string.char(ib[1], ib[2], ib[3], ib[4])
    local block = image_blocks[index]
    local chars = {}
    for j = 1, Format.BLOCK_SIZE do
      chars[j] = string.char(block[j])
    end
    parts[#parts + 1] = table.concat(chars)
  end
  write_file(target, table.concat(parts))
end

function FileSystem:_apply_journal(expected_blocks)
  local target = self.journal_path
  if not target or not path_exists(target) then
    return
  end
  local image_path = self.image_path
  if not image_path then
    err("filesystem is not mounted")
  end
  local journal = read_file(target)
  if #journal == 0 or string.byte(journal, 1) ~= 0xFF then
    remove_file(target)
    return
  end
  local image = path_exists(image_path) and read_file(image_path) or ""
  local image_bytes = bytes_from_string(image)
  local max_index = -1
  local cursor = 1 -- 0-based after flag byte; journal[1] is flag
  local record = 4 + Format.BLOCK_SIZE
  -- cursor as 0-based offset into journal string
  local pos = 1 -- 1-based index after flag
  while pos + record - 1 <= #journal do
    local index = Format.read_u32_le_str(journal, pos - 1)
    local needed = (index + 1) * Format.BLOCK_SIZE
    while #image_bytes < needed do
      image_bytes[#image_bytes + 1] = 0
    end
    for j = 0, Format.BLOCK_SIZE - 1 do
      image_bytes[index * Format.BLOCK_SIZE + j + 1] = string.byte(journal, pos + 4 + j)
    end
    if index > max_index then
      max_index = index
    end
    pos = pos + record
  end
  local block_count = expected_blocks or (max_index + 1)
  local final_size = block_count * Format.BLOCK_SIZE
  if #image_bytes > final_size then
    for i = #image_bytes, final_size + 1, -1 do
      image_bytes[i] = nil
    end
  else
    while #image_bytes < final_size do
      image_bytes[#image_bytes + 1] = 0
    end
  end
  write_file(image_path, string_from_bytes(image_bytes))
  remove_file(target)
end

function FileSystem:_persist_tree(root)
  local image = Format.serialize_tree(root)
  self:_write_journal(image)
  local max_index = -1
  for i, _ in pairs(image) do
    if type(i) == "number" and i > max_index then
      max_index = i
    end
  end
  self:_apply_journal(max_index + 1)
end

function FileSystem:_persist_if_auto()
  if self.transaction then
    self:_refresh_working_directory_path()
    return
  end
  if not self.committed_root then
    err("persist failed: missing root")
  end
  self:_persist_tree(self.committed_root)
end

function FileSystem:_read_tree_from_disk()
  if not self.image_path then
    err("filesystem is not mounted")
  end
  local raw = read_file(self.image_path)
  return Format.parse_tree(Format.string_to_blocks(raw))
end

function FileSystem:open(path, mode)
  self:_require_mounted()
  local leaf = self:_resolve_leaf(path)
  local existing = Format.dir_get_child(leaf.parent, leaf.name)
  local node
  if mode == "r" or mode == "r+" then
    if not existing or existing.kind ~= "file" then
      err("open failed: " .. path)
    end
    node = existing
  elseif mode == "w" or mode == "w+" then
    if existing == nil then
      node = Format.new_file(leaf.name, leaf.parent)
      Format.dir_set_child(leaf.parent, leaf.name, node)
    elseif existing.kind == "file" then
      existing.data = {}
      node = existing
    else
      err("open failed: " .. path)
    end
    self:_persist_if_auto()
  elseif mode == "a" or mode == "a+" then
    if existing == nil then
      node = Format.new_file(leaf.name, leaf.parent)
      Format.dir_set_child(leaf.parent, leaf.name, node)
    elseif existing.kind == "file" then
      node = existing
    else
      err("open failed: " .. path)
    end
    self:_persist_if_auto()
  else
    err("unsupported mode: " .. tostring(mode))
  end
  local position = (mode:sub(1, 1) == "a") and #node.data or 0
  local handle = {
    node = node,
    mode = mode,
    position = position,
    is_open = true,
    close = function(self_handle)
      self_handle.is_open = false
    end,
  }
  self.file_handles[#self.file_handles + 1] = handle
  return handle
end

function FileSystem:read(file, buffer, offset, length)
  self:_require_mounted()
  offset = offset or 1
  length = length or (#buffer - offset + 1)
  if not file.is_open or offset < 1 or length <= 0 or offset + length - 1 > #buffer then
    return 0
  end
  if file.mode == "w" or file.mode == "a" then
    return 0
  end
  local remaining = #file.node.data - file.position
  if remaining <= 0 then
    return 0
  end
  local count = math.min(length, remaining)
  for i = 0, count - 1 do
    buffer[offset + i] = file.node.data[file.position + i + 1]
  end
  file.position = file.position + count
  return count
end

function FileSystem:write(file, buffer, offset, length)
  self:_require_mounted()
  offset = offset or 1
  length = length or (#buffer - offset + 1)
  if not file.is_open or offset < 1 or length <= 0 or offset + length - 1 > #buffer then
    return 0
  end
  if file.mode == "r" then
    return 0
  end
  local end_position = file.position + length
  local current = file.node.data
  local new_size = math.max(#current, end_position)
  local updated = {}
  for i = 1, new_size do
    updated[i] = current[i] or 0
  end
  for i = 0, length - 1 do
    updated[file.position + i + 1] = buffer[offset + i]
  end
  file.node.data = updated
  file.position = end_position
  self:_persist_if_auto()
  return length
end

function FileSystem:close(file)
  file:close()
end

function FileSystem:seek(file, offset, whence)
  self:_require_mounted()
  if not file.is_open then
    return false
  end
  local size = #file.node.data
  local target
  if whence == SeekWhence.SET then
    target = offset
  elseif whence == SeekWhence.CUR then
    target = file.position + offset
  elseif whence == SeekWhence.END then
    target = size + offset
  else
    return false
  end
  if target < 0 then
    target = 0
  elseif target > size then
    target = size
  end
  file.position = target
  return true
end

function FileSystem:tell(file)
  self:_require_mounted()
  return file.is_open and file.position or 0
end

function FileSystem:rewind(file)
  self:seek(file, 0, SeekWhence.SET)
end

function FileSystem:file_exists(path)
  local node = self:_resolve_node_or_null(path)
  return node ~= nil and node.kind == "file"
end

function FileSystem:dir_exists(path)
  local node = self:_resolve_node_or_null(path)
  return node ~= nil and node.kind == "dir"
end

function FileSystem:remove_file(path)
  local leaf = self:_resolve_leaf(path)
  local node = Format.dir_get_child(leaf.parent, leaf.name)
  if not node or node.kind ~= "file" then
    err("removeFile failed path=" .. path)
  end
  Format.dir_remove_child(leaf.parent, leaf.name)
  self:_persist_if_auto()
end

function FileSystem:rename(from, to)
  self:_move_or_rename(from, to)
end

function FileSystem:copy_file(from, to)
  local source = self:_resolve_node_or_null(from)
  if not source or source.kind ~= "file" then
    err("copyFile failed from=" .. from)
  end
  local leaf = self:_resolve_leaf(to)
  if Format.dir_get_child(leaf.parent, leaf.name) then
    err("copyFile failed to=" .. to)
  end
  Format.dir_set_child(
    leaf.parent,
    leaf.name,
    Format.new_file(leaf.name, leaf.parent, Format.copy_bytes(source.data))
  )
  self:_persist_if_auto()
end

function FileSystem:chdir(path)
  local node = self:_resolve_node_or_null(path)
  if not node or node.kind ~= "dir" then
    err("chdir failed: " .. path)
  end
  if self.transaction then
    self.transaction.cwd = node
    self.transaction.cwd_path = Format.build_absolute_path(node)
  else
    self.committed_cwd = node
    self.committed_cwd_path = Format.build_absolute_path(node)
  end
end

function FileSystem:getcwd()
  if self.transaction then
    return self.transaction.cwd_path
  end
  return self.committed_cwd_path
end

function FileSystem:mkdir(path)
  local leaf = self:_resolve_leaf(path)
  if Format.dir_get_child(leaf.parent, leaf.name) then
    err("mkdir failed path=" .. path)
  end
  Format.dir_set_child(leaf.parent, leaf.name, Format.new_dir(leaf.name, leaf.parent))
  self:_persist_if_auto()
end

function FileSystem:rmdir(path)
  local leaf = self:_resolve_leaf(path)
  local dir = Format.dir_get_child(leaf.parent, leaf.name)
  if not dir or dir.kind ~= "dir" then
    err("rmdir failed path=" .. path)
  end
  if #dir.children ~= 0 then
    err("rmdir failed path=" .. path)
  end
  if dir.parent == nil or self:_is_same_or_ancestor(dir, self:_current_cwd()) then
    err("rmdir failed path=" .. path)
  end
  Format.dir_remove_child(leaf.parent, leaf.name)
  self:_persist_if_auto()
end

function FileSystem:open_dir(path)
  self:_require_mounted()
  local dir = self:_resolve_node_or_null(path)
  if not dir or dir.kind ~= "dir" then
    err("openDir failed: " .. path)
  end
  local handle = {
    entries = Format.list_directory_entries(dir),
    index = 1,
    is_open = true,
    path = Format.build_absolute_path(dir),
    absolute_path = function(self_handle)
      return self_handle.path
    end,
    close = function(self_handle)
      self_handle.is_open = false
    end,
  }
  self.dir_handles[#self.dir_handles + 1] = handle
  return handle
end

function FileSystem:read_dir(dir)
  self:_require_mounted()
  if not dir.is_open or dir.index > #dir.entries then
    return nil
  end
  local entry = dir.entries[dir.index]
  dir.index = dir.index + 1
  return entry
end

function FileSystem:close_dir(dir)
  dir:close()
end

function FileSystem:begin()
  if not self.mounted then
    return false
  end
  self:rollback()
  if not self.committed_root or not self.committed_cwd then
    return false
  end
  local copy = Format.deep_copy_tree(self.committed_root, self.committed_cwd)
  self.transaction = {
    root = copy.root,
    cwd = copy.cwd,
    cwd_path = Format.build_absolute_path(copy.cwd),
  }
  return true
end

function FileSystem:commit()
  if not self.mounted then
    return true
  end
  local tx = self.transaction
  if not tx then
    return true
  end
  local ok, result = pcall(function()
    self:_persist_tree(tx.root)
  end)
  if not ok then
    return false
  end
  self.committed_root = tx.root
  self.committed_cwd = tx.cwd
  self.committed_cwd_path = tx.cwd_path
  self.transaction = nil
  return true
end

function FileSystem:rollback()
  if not self.mounted then
    return
  end
  self:_close_all_handles()
  self.transaction = nil
  if self.journal_path and path_exists(self.journal_path) then
    remove_file(self.journal_path)
  end
end

function FileSystem:_move_or_rename(from, to)
  local source_leaf = self:_resolve_leaf(from)
  local source_node = Format.dir_get_child(source_leaf.parent, source_leaf.name)
  if not source_node then
    err("rename failed from=" .. from)
  end
  local destination_leaf = self:_resolve_leaf(to)
  self:_move_node(source_node, destination_leaf.parent, destination_leaf.name)
end

function FileSystem:_move_node(node, new_parent, new_name)
  self:_validate_leaf_name(new_name)
  if Format.dir_get_child(new_parent, new_name) then
    err("target already exists: " .. new_name)
  end
  local old_parent = node.parent
  if not old_parent then
    err("cannot move root directory")
  end
  if node.kind == "dir" and self:_is_same_or_ancestor(node, new_parent) then
    err("cannot move directory into itself")
  end
  Format.dir_remove_child(old_parent, node.name)
  Format.dir_set_child(new_parent, new_name, node)
  self:_refresh_working_directory_path()
  self:_persist_if_auto()
end

FileSystem.FileType = FileType
FileSystem.SeekWhence = SeekWhence
FileSystem.FileFsError = FileFsError
FileSystem.bytes_from_string = bytes_from_string
FileSystem.string_from_bytes = string_from_bytes

return FileSystem
