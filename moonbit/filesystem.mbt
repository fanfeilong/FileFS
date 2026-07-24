///|
pub struct FileSystem {
  priv mut image_path : String?
  priv mut journal_path : String?
  priv mut mounted : Bool
  priv mut committed_root : DirNode?
  priv mut committed_cwd : DirNode?
  priv mut committed_cwd_path : String
  priv mut transaction : TransactionState?
  priv file_handles : Array[FileHandle]
  priv dir_handles : Array[DirectoryHandle]
}

///|
pub fn FileSystem::new() -> FileSystem {
  {
    image_path: None,
    journal_path: None,
    mounted: false,
    committed_root: None,
    committed_cwd: None,
    committed_cwd_path: "",
    transaction: None,
    file_handles: [],
    dir_handles: [],
  }
}

///|
pub fn FileSystem::is_mounted(self : FileSystem) -> Bool {
  self.mounted
}

///|
fn journal_path_for(path : String) -> String {
  path + "-j"
}

///|
pub fn mkfs(path : String) -> Unit raise {
  let image = serialize_tree(new_dir("", None))
  @fs.write_bytes_to_file(path, concat_blocks(image))
  let journal = journal_path_for(path)
  if @fs.path_exists(journal) {
    @fs.remove_file(journal) catch {
      _ => ()
    }
  }
}

///|
pub fn FileSystem::mount(self : FileSystem, path : String) -> Unit raise {
  if !@fs.path_exists(path) {
    raise FileFsError("mount failed: \{path} does not exist")
  }
  let raw = @fs.read_file_to_bytes(path)
  let blocks = split_image_bytes(raw)
  validate_header(blocks)
  validate_root(blocks)
  self.umount()
  self.image_path = Some(path)
  self.journal_path = Some(journal_path_for(path))
  self.mounted = true
  self.apply_journal(None)
  let root = self.read_tree_from_disk()
  self.committed_root = Some(root)
  self.committed_cwd = Some(root)
  self.committed_cwd_path = "/"
  self.transaction = None
}

///|
pub fn FileSystem::umount(self : FileSystem) -> Unit {
  self.close_all_handles()
  self.mounted = false
  self.image_path = None
  self.transaction = None
  self.committed_root = None
  self.committed_cwd = None
  self.committed_cwd_path = ""
  match self.journal_path {
    Some(path) =>
      if @fs.path_exists(path) {
        @fs.remove_file(path) catch {
          _ => ()
        }
      }
    None => ()
  }
  self.journal_path = None
}

///|
pub fn FileSystem::open(
  self : FileSystem,
  path : String,
  mode : String,
) -> FileHandle raise {
  self.require_mounted()
  let leaf = self.resolve_leaf(path)
  let existing = leaf.parent.children.get(leaf.name)
  let node = match mode {
    "r" | "r+" =>
      match existing {
        Some(Regular(file)) => file
        _ => raise FileFsError("open failed: \{path}")
      }
    "w" | "w+" => {
      let file_node = match existing {
        None => {
          let created = new_file(leaf.name, Some(leaf.parent))
          leaf.parent.children.set(leaf.name, Regular(created))
          created
        }
        Some(Regular(file)) => {
          file.data = []
          file
        }
        _ => raise FileFsError("open failed: \{path}")
      }
      self.persist_if_auto()
      file_node
    }
    "a" | "a+" => {
      let file_node = match existing {
        None => {
          let created = new_file(leaf.name, Some(leaf.parent))
          leaf.parent.children.set(leaf.name, Regular(created))
          created
        }
        Some(Regular(file)) => file
        _ => raise FileFsError("open failed: \{path}")
      }
      self.persist_if_auto()
      file_node
    }
    _ => raise FileFsError("unsupported mode: \{mode}")
  }
  let position = if mode.has_prefix("a") { node.data.length() } else { 0 }
  let handle = { node, mode, position, open_: true }
  self.file_handles.push(handle)
  handle
}

///|
pub fn FileSystem::read(
  self : FileSystem,
  file : FileHandle,
  buffer : Array[Byte],
  offset? : Int = 0,
  length? : Int = -1,
) -> Int raise {
  self.require_mounted()
  let len = if length < 0 { buffer.length() - offset } else { length }
  if !file.open_ || offset < 0 || len <= 0 || offset + len > buffer.length() {
    return 0
  }
  if file.mode == "w" || file.mode == "a" {
    return 0
  }
  let remaining = file.node.data.length() - file.position
  if remaining <= 0 {
    return 0
  }
  let count = if len < remaining { len } else { remaining }
  for i = 0; i < count; i = i + 1 {
    buffer[offset + i] = file.node.data[file.position + i]
  }
  file.position = file.position + count
  count
}

///|
pub fn FileSystem::write(
  self : FileSystem,
  file : FileHandle,
  buffer : Array[Byte],
  offset? : Int = 0,
  length? : Int = -1,
) -> Int raise {
  self.require_mounted()
  let len = if length < 0 { buffer.length() - offset } else { length }
  if !file.open_ || offset < 0 || len <= 0 || offset + len > buffer.length() {
    return 0
  }
  if file.mode == "r" {
    return 0
  }
  let end_position = file.position + len
  let current = file.node.data
  let new_size = if current.length() > end_position {
    current.length()
  } else {
    end_position
  }
  let updated = Array::make(new_size, b'\x00')
  current.blit_to(updated, len=current.length())
  for i = 0; i < len; i = i + 1 {
    updated[file.position + i] = buffer[offset + i]
  }
  file.node.data = updated
  file.position = end_position
  self.persist_if_auto()
  len
}

///|
pub fn FileSystem::close(_self : FileSystem, file : FileHandle) -> Unit {
  file.close()
}

///|
pub fn FileSystem::seek(
  self : FileSystem,
  file : FileHandle,
  offset : Int,
  whence : SeekWhence,
) -> Bool raise {
  self.require_mounted()
  if !file.open_ {
    return false
  }
  let size = file.node.data.length()
  let target = match whence {
    Set => offset
    Cur => file.position + offset
    End => size + offset
  }
  let clamped = if target < 0 {
    0
  } else if target > size {
    size
  } else {
    target
  }
  file.position = clamped
  true
}

///|
pub fn FileSystem::tell(self : FileSystem, file : FileHandle) -> Int raise {
  self.require_mounted()
  if file.open_ {
    file.position
  } else {
    0
  }
}

///|
pub fn FileSystem::rewind(self : FileSystem, file : FileHandle) -> Unit raise {
  ignore(self.seek(file, 0, SeekWhence::Set))
}

///|
pub fn FileSystem::file_exists(self : FileSystem, path : String) -> Bool raise {
  match self.resolve_node_or_null(path) {
    Some(Regular(_)) => true
    _ => false
  }
}

///|
pub fn FileSystem::dir_exists(self : FileSystem, path : String) -> Bool raise {
  match self.resolve_node_or_null(path) {
    Some(Directory(_)) => true
    _ => false
  }
}

///|
pub fn FileSystem::remove_file(self : FileSystem, path : String) -> Unit raise {
  let leaf = self.resolve_leaf(path)
  match leaf.parent.children.get(leaf.name) {
    Some(Regular(_)) => {
      leaf.parent.children.remove(leaf.name)
      self.persist_if_auto()
    }
    _ => raise FileFsError("removeFile failed path=\{path}")
  }
}

///|
pub fn FileSystem::rename(
  self : FileSystem,
  from : String,
  to : String,
) -> Unit raise {
  self.move_or_rename(from, to)
}

///|
pub fn FileSystem::copy_file(
  self : FileSystem,
  from : String,
  to : String,
) -> Unit raise {
  let source = match self.resolve_node_or_null(from) {
    Some(Regular(file)) => file
    _ => raise FileFsError("copyFile failed from=\{from}")
  }
  let leaf = self.resolve_leaf(to)
  if leaf.parent.children.contains(leaf.name) {
    raise FileFsError("copyFile failed to=\{to}")
  }
  let data_copy = Array::make(source.data.length(), b'\x00')
  source.data.blit_to(data_copy, len=source.data.length())
  leaf.parent.children.set(
    leaf.name,
    Regular(new_file(leaf.name, Some(leaf.parent), data=data_copy)),
  )
  self.persist_if_auto()
}

///|
pub fn FileSystem::chdir(self : FileSystem, path : String) -> Unit raise {
  let dir = match self.resolve_node_or_null(path) {
    Some(Directory(node)) => node
    _ => raise FileFsError("chdir failed: \{path}")
  }
  match self.transaction {
    None => {
      self.committed_cwd = Some(dir)
      self.committed_cwd_path = build_absolute_path(dir)
    }
    Some(tx) => {
      tx.cwd = dir
      tx.cwd_path = build_absolute_path(dir)
    }
  }
}

///|
pub fn FileSystem::getcwd(self : FileSystem) -> String {
  match self.transaction {
    Some(tx) => tx.cwd_path
    None => self.committed_cwd_path
  }
}

///|
pub fn FileSystem::mkdir(self : FileSystem, path : String) -> Unit raise {
  let leaf = self.resolve_leaf(path)
  if leaf.parent.children.contains(leaf.name) {
    raise FileFsError("mkdir failed path=\{path}")
  }
  leaf.parent.children.set(
    leaf.name,
    Directory(new_dir(leaf.name, Some(leaf.parent))),
  )
  self.persist_if_auto()
}

///|
pub fn FileSystem::rmdir(self : FileSystem, path : String) -> Unit raise {
  let leaf = self.resolve_leaf(path)
  let dir = match leaf.parent.children.get(leaf.name) {
    Some(Directory(node)) => node
    _ => raise FileFsError("rmdir failed path=\{path}")
  }
  if dir.children.length() != 0 {
    raise FileFsError("rmdir failed path=\{path}")
  }
  if dir.parent is None || self.is_same_or_ancestor(dir, self.current_cwd()) {
    raise FileFsError("rmdir failed path=\{path}")
  }
  leaf.parent.children.remove(leaf.name)
  self.persist_if_auto()
}

///|
pub fn FileSystem::open_dir(
  self : FileSystem,
  path : String,
) -> DirectoryHandle raise {
  self.require_mounted()
  let dir = match self.resolve_node_or_null(path) {
    Some(Directory(node)) => node
    _ => raise FileFsError("openDir failed: \{path}")
  }
  let handle = {
    entries: list_directory_entries(dir),
    index: 0,
    open_: true,
    path: build_absolute_path(dir),
  }
  self.dir_handles.push(handle)
  handle
}

///|
pub fn FileSystem::read_dir(
  self : FileSystem,
  dir : DirectoryHandle,
) -> DirEntry? raise {
  self.require_mounted()
  if !dir.open_ || dir.index >= dir.entries.length() {
    return None
  }
  let entry = dir.entries[dir.index]
  dir.index = dir.index + 1
  Some(entry)
}

///|
pub fn FileSystem::close_dir(_self : FileSystem, dir : DirectoryHandle) -> Unit {
  dir.close()
}

///|
pub fn FileSystem::begin(self : FileSystem) -> Bool {
  if !self.mounted {
    return false
  }
  self.rollback()
  match (self.committed_root, self.committed_cwd) {
    (Some(root), Some(cwd)) => {
      let copy = deep_copy_tree(root, cwd)
      self.transaction = Some({
        root: copy.root,
        cwd: copy.cwd,
        cwd_path: build_absolute_path(copy.cwd),
      })
      true
    }
    _ => false
  }
}

///|
pub fn FileSystem::commit(self : FileSystem) -> Bool {
  if !self.mounted {
    return true
  }
  match self.transaction {
    None => true
    Some(tx) =>
      try {
        self.persist_tree(tx.root)
        self.committed_root = Some(tx.root)
        self.committed_cwd = Some(tx.cwd)
        self.committed_cwd_path = tx.cwd_path
        self.transaction = None
        true
      } catch {
        _ => false
      }
  }
}

///|
pub fn FileSystem::rollback(self : FileSystem) -> Unit {
  if !self.mounted {
    return
  }
  self.close_all_handles()
  self.transaction = None
  match self.journal_path {
    Some(path) =>
      if @fs.path_exists(path) {
        @fs.remove_file(path) catch {
          _ => ()
        }
      }
    None => ()
  }
}

///|
fn FileSystem::move_or_rename(
  self : FileSystem,
  from : String,
  to : String,
) -> Unit raise {
  let source_leaf = self.resolve_leaf(from)
  let source_node = match source_leaf.parent.children.get(source_leaf.name) {
    Some(node) => node
    None => raise FileFsError("rename failed from=\{from}")
  }
  let destination_leaf = self.resolve_leaf(to)
  self.move_node(source_node, destination_leaf.parent, destination_leaf.name)
}

///|
fn FileSystem::move_node(
  self : FileSystem,
  node : FsNode,
  new_parent : DirNode,
  new_name : String,
) -> Unit raise {
  self.validate_leaf_name(new_name)
  if new_parent.children.contains(new_name) {
    raise FileFsError("target already exists: \{new_name}")
  }
  let old_parent = match node {
    Directory(dir) =>
      match dir.parent {
        Some(parent) => parent
        None => raise FileFsError("cannot move root directory")
      }
    Regular(file) =>
      match file.parent {
        Some(parent) => parent
        None => raise FileFsError("cannot move root directory")
      }
  }
  match node {
    Directory(dir) =>
      if self.is_same_or_ancestor(dir, new_parent) {
        raise FileFsError("cannot move directory into itself")
      }
    Regular(_) => ()
  }
  let old_name = match node {
    Directory(dir) => dir.name
    Regular(file) => file.name
  }
  old_parent.children.remove(old_name)
  match node {
    Directory(dir) => {
      dir.name = new_name
      dir.parent = Some(new_parent)
      new_parent.children.set(new_name, Directory(dir))
    }
    Regular(file) => {
      file.name = new_name
      file.parent = Some(new_parent)
      new_parent.children.set(new_name, Regular(file))
    }
  }
  self.refresh_working_directory_path()
  self.persist_if_auto()
}

///|
fn FileSystem::is_same_or_ancestor(
  _self : FileSystem,
  candidate : DirNode,
  dir : DirNode,
) -> Bool {
  let mut current : DirNode? = Some(dir)
  while true {
    match current {
      None => return false
      Some(node) => {
        if physical_equal(node, candidate) {
          return true
        }
        current = node.parent
      }
    }
  }
  false
}

///|
fn FileSystem::refresh_working_directory_path(self : FileSystem) -> Unit {
  match self.transaction {
    None =>
      match self.committed_cwd {
        Some(cwd) => self.committed_cwd_path = build_absolute_path(cwd)
        None => ()
      }
    Some(tx) => tx.cwd_path = build_absolute_path(tx.cwd)
  }
}

///|
fn FileSystem::persist_if_auto(self : FileSystem) -> Unit raise {
  match self.transaction {
    None =>
      match self.committed_root {
        Some(root) => self.persist_tree(root)
        None => raise FileFsError("persist failed: missing root")
      }
    Some(_) => self.refresh_working_directory_path()
  }
}

///|
fn FileSystem::persist_tree(self : FileSystem, root : DirNode) -> Unit raise {
  let image = serialize_tree(root)
  self.write_journal(image)
  self.apply_journal(Some(image.length()))
}

///|
fn FileSystem::write_journal(
  self : FileSystem,
  image : Array[Array[Byte]],
) -> Unit raise {
  let target = match self.journal_path {
    Some(path) => path
    None => raise FileFsError("journal path unavailable")
  }
  let out = @buffer.Buffer::Buffer(
    size_hint=1 + image.length() * (4 + block_size),
  )
  out.write_byte(b'\xFF')
  for index = 0; index < image.length(); index = index + 1 {
    let index_bytes = Array::make(4, b'\x00')
    write_u32_le(index_bytes, 0, index)
    out.write_bytes(Bytes::from_array(index_bytes[:]))
    out.write_bytes(Bytes::from_array(image[index][:]))
  }
  @fs.write_bytes_to_file(target, out.to_bytes())
}

///|
fn FileSystem::apply_journal(
  self : FileSystem,
  expected_blocks : Int?,
) -> Unit raise {
  let target = match self.journal_path {
    Some(path) => path
    None => return
  }
  if !@fs.path_exists(target) {
    return
  }
  let image_path = match self.image_path {
    Some(path) => path
    None => raise FileFsError("filesystem is not mounted")
  }
  let journal = @fs.read_file_to_bytes(target)
  if journal.length() == 0 || journal[0] != b'\xFF' {
    @fs.remove_file(target) catch {
      _ => ()
    }
    return
  }
  let mut image = if @fs.path_exists(image_path) {
    @fs.read_file_to_bytes(image_path).to_array()
  } else {
    []
  }
  let mut max_index = -1
  let mut cursor = 1
  let record = 4 + block_size
  while cursor + record <= journal.length() {
    let index = read_u32_le_bytes(journal, cursor)
    let needed = (index + 1) * block_size
    if image.length() < needed {
      let grown = Array::make(needed, b'\x00')
      image.blit_to(grown, len=image.length())
      image = grown
    }
    for j = 0; j < block_size; j = j + 1 {
      image[index * block_size + j] = journal[cursor + 4 + j]
    }
    if index > max_index {
      max_index = index
    }
    cursor = cursor + record
  }
  let block_count = match expected_blocks {
    Some(count) => count
    None => max_index + 1
  }
  if block_count >= 0 {
    let final_size = block_count * block_size
    if image.length() > final_size {
      let trimmed = Array::make(final_size, b'\x00')
      image.blit_to(trimmed, len=final_size)
      image = trimmed
    } else if image.length() < final_size {
      let grown = Array::make(final_size, b'\x00')
      image.blit_to(grown, len=image.length())
      image = grown
    }
  }
  @fs.write_bytes_to_file(image_path, Bytes::from_array(image[:]))
  @fs.remove_file(target) catch {
    _ => ()
  }
}

///|
fn FileSystem::read_tree_from_disk(self : FileSystem) -> DirNode raise {
  let path = match self.image_path {
    Some(p) => p
    None => raise FileFsError("filesystem is not mounted")
  }
  let raw = @fs.read_file_to_bytes(path)
  parse_tree(split_image_bytes(raw))
}

///|
fn validate_header(blocks : Array[Array[Byte]]) -> Unit raise {
  if blocks.length() == 0 {
    raise FileFsError("invalid FileFS magic")
  }
  let block0 = blocks[0]
  if !(block0[0] == magic0 &&
    block0[1] == magic1 &&
    block0[2] == magic2 &&
    block0[3] == magic3) {
    raise FileFsError("invalid FileFS magic")
  }
  if read_u32_le(block0, 4) < 2 {
    raise FileFsError("invalid FileFS block count")
  }
}

///|
fn validate_root(blocks : Array[Array[Byte]]) -> Unit raise {
  if blocks.length() < 2 {
    raise FileFsError("invalid root directory")
  }
  let block1 = blocks[1]
  if block1[block_head] != b'\x00' {
    raise FileFsError("invalid root directory")
  }
  if read_fixed_name(block1, block_head + 1) != "." {
    raise FileFsError("invalid root directory")
  }
  let dot_dot_offset = block_head + entry_size
  if block1[dot_dot_offset] != b'\x00' {
    raise FileFsError("invalid root parent entry")
  }
  if read_fixed_name(block1, dot_dot_offset + 1) != ".." {
    raise FileFsError("invalid root parent entry")
  }
}

///|
fn FileSystem::resolve_node_or_null(
  self : FileSystem,
  path : String,
) -> FsNode? raise {
  self.require_mounted()
  if path.length() == 0 {
    return None
  }
  let parsed = parse_path(path)
  let mut current = if parsed.absolute {
    self.current_root()
  } else {
    self.current_cwd()
  }
  if parsed.parts.length() == 0 {
    return Some(Directory(current))
  }
  for index = 0; index < parsed.parts.length(); index = index + 1 {
    let part = parsed.parts[index]
    match part {
      "." => ()
      ".." =>
        match current.parent {
          Some(parent) => current = parent
          None => ()
        }
      _ =>
        match current.children.get(part) {
          None => return None
          Some(child) =>
            if index < parsed.parts.length() - 1 {
              match child {
                Directory(dir) => current = dir
                Regular(_) => return None
              }
            } else {
              return Some(child)
            }
        }
    }
  }
  Some(Directory(current))
}

///|
fn FileSystem::resolve_leaf(
  self : FileSystem,
  path : String,
) -> ResolvedLeaf raise {
  self.require_mounted()
  let parsed = parse_path(path)
  if parsed.parts.length() == 0 {
    raise FileFsError("invalid path: \{path}")
  }
  let leaf_name = parsed.parts[parsed.parts.length() - 1]
  self.validate_leaf_name(leaf_name)
  let mut current = if parsed.absolute {
    self.current_root()
  } else {
    self.current_cwd()
  }
  for i = 0; i < parsed.parts.length() - 1; i = i + 1 {
    let part = parsed.parts[i]
    current = match part {
      "." => current
      ".." =>
        match current.parent {
          Some(parent) => parent
          None => current
        }
      _ =>
        match current.children.get(part) {
          Some(Directory(dir)) => dir
          _ => raise FileFsError("path not found: \{path}")
        }
    }
  }
  { parent: current, name: leaf_name }
}

///|
fn FileSystem::validate_leaf_name(
  self : FileSystem,
  name : String,
) -> Unit raise {
  if name == "." || name == ".." || name.length() == 0 {
    raise FileFsError("invalid leaf name: \{name}")
  }
  if !name.all(fn(ch) {
      let code = ch.to_int()
      code >= 0x20 && code <= 0x7E
    }) {
    raise FileFsError("name must be ASCII: \{name}")
  }
  if name.length() > block_name_max_size {
    raise FileFsError("name exceeds 14 bytes: \{name}")
  }
}

///|
fn FileSystem::current_root(self : FileSystem) -> DirNode raise {
  match self.transaction {
    Some(tx) => tx.root
    None =>
      match self.committed_root {
        Some(root) => root
        None => raise FileFsError("filesystem is not mounted")
      }
  }
}

///|
fn FileSystem::current_cwd(self : FileSystem) -> DirNode raise {
  match self.transaction {
    Some(tx) => tx.cwd
    None =>
      match self.committed_cwd {
        Some(cwd) => cwd
        None => raise FileFsError("filesystem is not mounted")
      }
  }
}

///|
fn FileSystem::require_mounted(self : FileSystem) -> Unit raise {
  if !self.mounted {
    raise FileFsError("filesystem is not mounted")
  }
}

///|
fn FileSystem::close_all_handles(self : FileSystem) -> Unit {
  for handle in self.file_handles {
    handle.close()
  }
  for handle in self.dir_handles {
    handle.close()
  }
  self.file_handles.clear()
  self.dir_handles.clear()
}

///|
fn parse_path(path : String) -> ParsedPath raise {
  if path.length() == 0 {
    raise FileFsError("path is required")
  }
  let absolute = path.has_prefix("/")
  let parts : Array[String] = []
  path
  .split("/")
  .each(fn(part) {
    let text = part.to_owned()
    if text.length() != 0 {
      parts.push(text)
    }
  })
  { absolute, parts }
}
