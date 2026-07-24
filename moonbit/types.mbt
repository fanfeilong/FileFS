///|
pub(all) enum FileType {
  File
  Dir
  Root
} derive(Eq, Debug)

///|
pub(all) enum SeekWhence {
  Set
  Cur
  End
} derive(Eq, Debug)

///|
pub(all) struct DirEntry {
  type_ : FileType
  name : String
} derive(Eq, Debug)

///|
pub fn DirEntry::file_type(self : DirEntry) -> FileType {
  self.type_
}

///|
pub fn DirEntry::name_length(self : DirEntry) -> Int {
  self.name.length()
}

///|
pub(all) suberror FileFsError {
  FileFsError(String)
} derive(Debug)

///|
priv enum FsNode {
  Directory(DirNode)
  Regular(FileNode)
}

///|
priv struct DirNode {
  mut name : String
  mut parent : DirNode?
  children : Map[String, FsNode]
}

///|
priv struct FileNode {
  mut name : String
  mut parent : DirNode?
  mut data : Array[Byte]
}

///|
pub struct FileHandle {
  priv node : FileNode
  priv mode : String
  priv mut position : Int
  priv mut open_ : Bool
}

///|
pub fn FileHandle::is_open(self : FileHandle) -> Bool {
  self.open_
}

///|
pub fn FileHandle::close(self : FileHandle) -> Unit {
  self.open_ = false
}

///|
pub struct DirectoryHandle {
  priv entries : Array[DirEntry]
  priv mut index : Int
  priv mut open_ : Bool
  priv path : String
}

///|
pub fn DirectoryHandle::is_open(self : DirectoryHandle) -> Bool {
  self.open_
}

///|
pub fn DirectoryHandle::absolute_path(self : DirectoryHandle) -> String {
  self.path
}

///|
pub fn DirectoryHandle::close(self : DirectoryHandle) -> Unit {
  self.open_ = false
}

///|
priv struct NodeAddress {
  start : Int
  stop : Int
  offset : Int
  block_count : Int
}

///|
priv struct WireEntry {
  is_file : Bool
  name : String
  start : Int
  stop : Int
  offset : Int
}

///|
priv struct TreeCopy {
  root : DirNode
  cwd : DirNode
}

///|
priv struct TransactionState {
  root : DirNode
  mut cwd : DirNode
  mut cwd_path : String
}

///|
priv struct ResolvedLeaf {
  parent : DirNode
  name : String
}

///|
priv struct ParsedPath {
  absolute : Bool
  parts : Array[String]
}
