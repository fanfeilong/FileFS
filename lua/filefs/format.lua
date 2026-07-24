-- FileFS on-disk format helpers (512-byte blocks, magic 78 11 45 14).

local Format = {}

Format.BLOCK_SIZE = 512
Format.BLOCK_ITEM_MAX_COUNT = 20
Format.BLOCK_HEAD = 12
Format.BLOCK_NAME_MAX_SIZE = 14
Format.ENTRY_SIZE = 25
Format.ROOT_BLOCKINDEX = 1
Format.DATA_PER_BLOCK = Format.BLOCK_SIZE - Format.BLOCK_HEAD
Format.MAGIC = { 0x78, 0x11, 0x45, 0x14 }

local function empty_block()
  local b = {}
  for i = 1, Format.BLOCK_SIZE do
    b[i] = 0
  end
  return b
end

local function write_u32_le(bytes, offset0, value)
  -- offset0 is 0-based
  local i = offset0 + 1
  local v = value & 0xFFFFFFFF
  bytes[i] = v & 0xFF
  bytes[i + 1] = (v >> 8) & 0xFF
  bytes[i + 2] = (v >> 16) & 0xFF
  bytes[i + 3] = (v >> 24) & 0xFF
end

local function read_u32_le(bytes, offset0)
  local i = offset0 + 1
  return bytes[i]
    | (bytes[i + 1] << 8)
    | (bytes[i + 2] << 16)
    | (bytes[i + 3] << 24)
end

local function write_u16_le(bytes, offset0, value)
  local i = offset0 + 1
  local v = value & 0xFFFF
  bytes[i] = v & 0xFF
  bytes[i + 1] = (v >> 8) & 0xFF
end

local function read_u16_le(bytes, offset0)
  local i = offset0 + 1
  return bytes[i] | (bytes[i + 1] << 8)
end

local function write_fixed_name(bytes, offset0, name)
  assert(#name <= Format.BLOCK_NAME_MAX_SIZE, "name exceeds 14 bytes: " .. name)
  for i = 0, Format.BLOCK_NAME_MAX_SIZE - 1 do
    bytes[offset0 + 1 + i] = 0
  end
  for i = 1, #name do
    bytes[offset0 + i] = string.byte(name, i)
  end
end

local function read_fixed_name(bytes, offset0)
  local chars = {}
  for i = 0, Format.BLOCK_NAME_MAX_SIZE - 1 do
    local b = bytes[offset0 + 1 + i]
    if b == 0 then
      break
    end
    chars[#chars + 1] = string.char(b)
  end
  return table.concat(chars)
end

local function read_entry(bytes, offset0)
  return {
    is_file = (bytes[offset0 + 1] & 0x01) == 1,
    name = read_fixed_name(bytes, offset0 + 1),
    start = read_u32_le(bytes, offset0 + 1 + Format.BLOCK_NAME_MAX_SIZE),
    stop = read_u32_le(bytes, offset0 + 1 + Format.BLOCK_NAME_MAX_SIZE + 4),
    offset = read_u16_le(bytes, offset0 + 1 + Format.BLOCK_NAME_MAX_SIZE + 8),
  }
end

local function ceil_div(a, b)
  return math.floor((a + b - 1) / b)
end

function Format.new_dir(name, parent)
  return {
    kind = "dir",
    name = name,
    parent = parent,
    children = {}, -- ordered array of {name=, node=} plus map by name
    child_map = {},
  }
end

function Format.new_file(name, parent, data)
  return {
    kind = "file",
    name = name,
    parent = parent,
    data = data or {},
  }
end

function Format.dir_set_child(dir, name, node)
  if dir.child_map[name] then
    for i, entry in ipairs(dir.children) do
      if entry.name == name then
        dir.children[i] = { name = name, node = node }
        break
      end
    end
  else
    dir.children[#dir.children + 1] = { name = name, node = node }
  end
  dir.child_map[name] = node
  node.name = name
  node.parent = dir
end

function Format.dir_remove_child(dir, name)
  local node = dir.child_map[name]
  if not node then
    return nil
  end
  dir.child_map[name] = nil
  for i, entry in ipairs(dir.children) do
    if entry.name == name then
      table.remove(dir.children, i)
      break
    end
  end
  return node
end

function Format.dir_get_child(dir, name)
  return dir.child_map[name]
end

local function copy_bytes(src)
  local dst = {}
  for i = 1, #src do
    dst[i] = src[i]
  end
  return dst
end

function Format.deep_copy_tree(root, cwd)
  local map = {}

  local function copy_dir(source, parent)
    local copy = Format.new_dir(source.name, parent)
    map[source] = copy
    for _, entry in ipairs(source.children) do
      local child = entry.node
      if child.kind == "dir" then
        Format.dir_set_child(copy, entry.name, copy_dir(child, copy))
      else
        Format.dir_set_child(copy, entry.name, Format.new_file(entry.name, copy, copy_bytes(child.data)))
      end
    end
    return copy
  end

  local root_copy = copy_dir(root, nil)
  return {
    root = root_copy,
    cwd = map[cwd] or root_copy,
  }
end

function Format.build_absolute_path(dir)
  if dir.parent == nil then
    return "/"
  end
  local parts = {}
  local current = dir
  while current and current.parent do
    table.insert(parts, 1, current.name)
    current = current.parent
  end
  return "/" .. table.concat(parts, "/") .. "/"
end

function Format.list_directory_entries(dir)
  local FileType = require("filefs.types").FileType
  local entries = {}
  local dot_type = dir.parent == nil and FileType.ROOT or FileType.DIR
  entries[#entries + 1] = { type = dot_type, name = "." }
  entries[#entries + 1] = { type = dot_type, name = ".." }
  for _, entry in ipairs(dir.children) do
    local typ = entry.node.kind == "dir" and FileType.DIR or FileType.FILE
    entries[#entries + 1] = { type = typ, name = entry.name }
  end
  return entries
end

function Format.serialize_tree(root)
  local addresses = {} -- node -> address

  local function assign(node, next_index)
    if node.kind == "dir" then
      local entry_count = 2 + #node.children
      local block_count = ceil_div(entry_count, Format.BLOCK_ITEM_MAX_COUNT)
      local start = next_index
      local stop = start + block_count - 1
      local remainder = entry_count % Format.BLOCK_ITEM_MAX_COUNT
      local offset = remainder == 0 and Format.BLOCK_SIZE
        or (Format.BLOCK_HEAD + remainder * Format.ENTRY_SIZE)
      addresses[node] = {
        start = start,
        stop = stop,
        offset = offset,
        block_count = block_count,
      }
      local cursor = stop + 1
      for _, entry in ipairs(node.children) do
        cursor = assign(entry.node, cursor)
      end
      return cursor
    end

    if #node.data == 0 then
      addresses[node] = { start = 0, stop = 0, offset = 0, block_count = 0 }
      return next_index
    end

    local block_count = ceil_div(#node.data, Format.DATA_PER_BLOCK)
    local start = next_index
    local stop = start + block_count - 1
    local remainder = #node.data % Format.DATA_PER_BLOCK
    local offset = remainder == 0 and Format.BLOCK_SIZE
      or (Format.BLOCK_HEAD + remainder)
    addresses[node] = {
      start = start,
      stop = stop,
      offset = offset,
      block_count = block_count,
    }
    return stop + 1
  end

  local total_blocks = assign(root, Format.ROOT_BLOCKINDEX)
  local blocks = {}
  for i = 0, total_blocks - 1 do
    blocks[i] = empty_block()
  end

  blocks[0][1] = Format.MAGIC[1]
  blocks[0][2] = Format.MAGIC[2]
  blocks[0][3] = Format.MAGIC[3]
  blocks[0][4] = Format.MAGIC[4]
  write_u32_le(blocks[0], 4, total_blocks)
  write_u32_le(blocks[0], 8, 0)

  local function serialize_file(file)
    local address = addresses[file]
    if address.start == 0 then
      return
    end
    local source_offset = 0
    for block_index = address.start, address.stop do
      local block = blocks[block_index]
      local next = block_index < address.stop and (block_index + 1) or 0
      local prev = block_index > address.start and (block_index - 1) or 0
      write_u32_le(block, 4, next)
      write_u32_le(block, 8, prev)
      local end_exclusive = math.min(source_offset + Format.DATA_PER_BLOCK, #file.data)
      for i = source_offset + 1, end_exclusive do
        block[Format.BLOCK_HEAD + (i - source_offset)] = file.data[i]
      end
      source_offset = end_exclusive
    end
  end

  local function serialize_dir(dir)
    local address = addresses[dir]
    local entries = {}
    entries[#entries + 1] = {
      is_file = false,
      name = ".",
      start = address.start,
      stop = address.stop,
      offset = address.offset,
    }
    local parent_start = 0
    if dir.parent then
      parent_start = addresses[dir.parent].start
    end
    entries[#entries + 1] = {
      is_file = false,
      name = "..",
      start = parent_start,
      stop = 0,
      offset = 0,
    }
    for _, child_entry in ipairs(dir.children) do
      local child = child_entry.node
      local child_address = addresses[child]
      entries[#entries + 1] = {
        is_file = child.kind == "file",
        name = child.name,
        start = child_address.start,
        stop = child_address.stop,
        offset = child_address.offset,
      }
    end

    for block_offset = 0, address.block_count - 1 do
      local block_index = address.start + block_offset
      local block = blocks[block_index]
      local next = block_index < address.stop and (block_index + 1) or 0
      local prev = block_index > address.start and (block_index - 1) or 0
      write_u32_le(block, 4, next)
      write_u32_le(block, 8, prev)
      local from = block_offset * Format.BLOCK_ITEM_MAX_COUNT
      local to = math.min(#entries, from + Format.BLOCK_ITEM_MAX_COUNT)
      local position = Format.BLOCK_HEAD
      for entry_index = from + 1, to do
        local entry = entries[entry_index]
        block[position + 1] = entry.is_file and 1 or 0
        position = position + 1
        write_fixed_name(block, position, entry.name)
        position = position + Format.BLOCK_NAME_MAX_SIZE
        write_u32_le(block, position, entry.start)
        position = position + 4
        write_u32_le(block, position, entry.stop)
        position = position + 4
        write_u16_le(block, position, entry.offset)
        position = position + 2
      end
    end

    for _, child_entry in ipairs(dir.children) do
      local child = child_entry.node
      if child.kind == "dir" then
        serialize_dir(child)
      else
        serialize_file(child)
      end
    end
  end

  serialize_dir(root)
  return blocks
end

function Format.parse_tree(blocks)
  assert(#blocks >= 1 or blocks[1] ~= nil or blocks[0] ~= nil, "image must contain blocks")
  -- blocks is 0-indexed sparse array; length via highest index is awkward — use total from header
  local visited = {}

  local function read_block(index)
    local block = blocks[index]
    assert(block, "missing block " .. tostring(index))
    return block
  end

  local function parse_file(start, stop, offset)
    if start == 0 and stop == 0 and offset == 0 then
      return {}
    end
    assert(start > 0 and stop >= start, "invalid file block range")
    assert(offset >= Format.BLOCK_HEAD and offset <= Format.BLOCK_SIZE, "invalid file offset")
    local out = {}
    local current = start
    while true do
      local block = read_block(current)
      local limit = current == stop and offset or Format.BLOCK_SIZE
      assert(limit >= Format.BLOCK_HEAD and limit <= Format.BLOCK_SIZE, "invalid block limit")
      for i = Format.BLOCK_HEAD, limit - 1 do
        out[#out + 1] = block[i + 1]
      end
      if current == stop then
        break
      end
      current = read_u32_le(block, 4)
      assert(current ~= 0, "unterminated file block chain")
    end
    return out
  end

  local function parse_dir(index, name, parent)
    assert(not visited[index], "directory cycle at block " .. tostring(index))
    visited[index] = true
    local first_block = read_block(index)
    local dot = read_entry(first_block, Format.BLOCK_HEAD)
    assert(not dot.is_file and dot.name == ".", "invalid directory header at block " .. tostring(index))
    local dir = Format.new_dir(name, parent)
    local entries = {}
    local current = index
    while true do
      local block = read_block(current)
      local limit = current == dot.stop and dot.offset or Format.BLOCK_SIZE
      assert(limit >= Format.BLOCK_HEAD and limit <= Format.BLOCK_SIZE, "invalid directory offset")
      local position = Format.BLOCK_HEAD
      while position + Format.ENTRY_SIZE <= limit do
        entries[#entries + 1] = read_entry(block, position)
        position = position + Format.ENTRY_SIZE
      end
      if current == dot.stop then
        break
      end
      current = read_u32_le(block, 4)
      assert(current ~= 0, "unterminated directory chain")
    end
    assert(#entries >= 2, "directory missing dot entries")
    assert(entries[2].name == "..", "directory missing parent entry")
    for i = 3, #entries do
      local entry = entries[i]
      assert(entry.name ~= "", "empty child entry")
      local child
      if entry.is_file then
        child = Format.new_file(entry.name, dir, parse_file(entry.start, entry.stop, entry.offset))
      else
        child = parse_dir(entry.start, entry.name, dir)
      end
      Format.dir_set_child(dir, entry.name, child)
    end
    return dir
  end

  return parse_dir(Format.ROOT_BLOCKINDEX, "", nil)
end

function Format.blocks_to_string(blocks)
  -- blocks is 0-indexed; find max index
  local max_index = -1
  for i, _ in pairs(blocks) do
    if type(i) == "number" and i > max_index then
      max_index = i
    end
  end
  local parts = {}
  for i = 0, max_index do
    local block = blocks[i]
    local chars = {}
    for j = 1, Format.BLOCK_SIZE do
      chars[j] = string.char(block[j])
    end
    parts[#parts + 1] = table.concat(chars)
  end
  return table.concat(parts)
end

function Format.string_to_blocks(data)
  assert(#data % Format.BLOCK_SIZE == 0, "image size is not a multiple of 512")
  local total = #data // Format.BLOCK_SIZE
  local blocks = {}
  for i = 0, total - 1 do
    local block = empty_block()
    local base = i * Format.BLOCK_SIZE
    for j = 1, Format.BLOCK_SIZE do
      block[j] = string.byte(data, base + j)
    end
    blocks[i] = block
  end
  return blocks
end

function Format.read_u32_le_str(data, offset0)
  local i = offset0 + 1
  local b1, b2, b3, b4 = string.byte(data, i, i + 3)
  return b1 | (b2 << 8) | (b3 << 16) | (b4 << 24)
end

Format.write_u32_le = write_u32_le
Format.read_u32_le = read_u32_le
Format.write_u16_le = write_u16_le
Format.read_u16_le = read_u16_le
Format.read_fixed_name = read_fixed_name
Format.write_fixed_name = write_fixed_name
Format.empty_block = empty_block
Format.copy_bytes = copy_bytes

return Format
