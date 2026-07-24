///|
let block_size : Int = 512

///|
let block_item_max_count : Int = 20

///|
let block_head : Int = 12

///|
let block_name_max_size : Int = 14

///|
let entry_size : Int = 25

///|
let root_blockindex : Int = 1

///|
let data_per_block : Int = 500 // block_size - block_head

///|
let magic0 : Byte = b'\x78'

///|
let magic1 : Byte = b'\x11'

///|
let magic2 : Byte = b'\x45'

///|
let magic3 : Byte = b'\x14'

///|
fn empty_block() -> Array[Byte] {
  Array::make(block_size, b'\x00')
}

///|
fn write_u32_le(bytes : Array[Byte], offset : Int, value : Int) -> Unit {
  bytes[offset] = (value & 0xFF).to_byte()
  bytes[offset + 1] = ((value >> 8) & 0xFF).to_byte()
  bytes[offset + 2] = ((value >> 16) & 0xFF).to_byte()
  bytes[offset + 3] = ((value >> 24) & 0xFF).to_byte()
}

///|
fn read_u32_le(bytes : Array[Byte], offset : Int) -> Int {
  (bytes[offset].to_int() & 0xFF) |
  ((bytes[offset + 1].to_int() & 0xFF) << 8) |
  ((bytes[offset + 2].to_int() & 0xFF) << 16) |
  ((bytes[offset + 3].to_int() & 0xFF) << 24)
}

///|
fn read_u32_le_bytes(bytes : Bytes, offset : Int) -> Int {
  (bytes[offset].to_int() & 0xFF) |
  ((bytes[offset + 1].to_int() & 0xFF) << 8) |
  ((bytes[offset + 2].to_int() & 0xFF) << 16) |
  ((bytes[offset + 3].to_int() & 0xFF) << 24)
}

///|
fn write_u16_le(bytes : Array[Byte], offset : Int, value : Int) -> Unit {
  bytes[offset] = (value & 0xFF).to_byte()
  bytes[offset + 1] = ((value >> 8) & 0xFF).to_byte()
}

///|
fn read_u16_le(bytes : Array[Byte], offset : Int) -> Int {
  (bytes[offset].to_int() & 0xFF) | ((bytes[offset + 1].to_int() & 0xFF) << 8)
}

///|
fn write_fixed_name(
  bytes : Array[Byte],
  offset : Int,
  name : String,
) -> Unit raise {
  if name.length() > block_name_max_size {
    raise FileFsError("name exceeds 14 bytes: \{name}")
  }
  for i = 0; i < block_name_max_size; i = i + 1 {
    bytes[offset + i] = b'\x00'
  }
  // FileFS names are ASCII octets, not UTF-16 code units.
  let mut i = 0
  name
  .iter()
  .each(fn(ch) {
    bytes[offset + i] = ch.to_int().to_byte()
    i = i + 1
  })
}

///|
fn read_fixed_name(bytes : Array[Byte], offset : Int) -> String {
  let mut end = offset
  let stop = offset + block_name_max_size
  while end < stop && bytes[end] != b'\x00' {
    end = end + 1
  }
  let chars = Array::new(capacity=end - offset)
  for i = offset; i < end; i = i + 1 {
    chars.push(Char::from_int(bytes[i].to_int()))
  }
  String::from_array(chars[:])
}

///|
fn read_entry(bytes : Array[Byte], offset : Int) -> WireEntry {
  let is_file = (bytes[offset].to_int() & 0x01) == 1
  let name = read_fixed_name(bytes, offset + 1)
  let start = read_u32_le(bytes, offset + 1 + block_name_max_size)
  let stop = read_u32_le(bytes, offset + 1 + block_name_max_size + 4)
  let entry_offset = read_u16_le(bytes, offset + 1 + block_name_max_size + 8)
  { is_file, name, start, stop, offset: entry_offset }
}

///|
fn ceil_div(numerator : Int, denominator : Int) -> Int {
  (numerator + denominator - 1) / denominator
}

///|
fn new_dir(name : String, parent : DirNode?) -> DirNode {
  { name, parent, children: Map([]) }
}

///|
fn new_file(
  name : String,
  parent : DirNode?,
  data? : Array[Byte] = [],
) -> FileNode {
  { name, parent, data }
}

///|
fn deep_copy_tree(root : DirNode, cwd : DirNode) -> TreeCopy {
  let pairs : Array[(DirNode, DirNode)] = []

  fn find_copy(source : DirNode) -> DirNode? {
    for pair in pairs {
      if physical_equal(pair.0, source) {
        return Some(pair.1)
      }
    }
    None
  }

  fn copy_dir(source : DirNode, parent : DirNode?) -> DirNode {
    let copy = new_dir(source.name, parent)
    pairs.push((source, copy))
    source.children.each(fn(name, child) {
      match child {
        Directory(dir) =>
          copy.children.set(name, Directory(copy_dir(dir, Some(copy))))
        Regular(file) => {
          let data_copy = Array::make(file.data.length(), b'\x00')
          file.data.blit_to(data_copy, len=file.data.length())
          copy.children.set(
            name,
            Regular(new_file(name, Some(copy), data=data_copy)),
          )
        }
      }
    })
    copy
  }

  let root_copy = copy_dir(root, None)
  let cwd_copy = match find_copy(cwd) {
    Some(dir) => dir
    None => root_copy
  }
  { root: root_copy, cwd: cwd_copy }
}

///|
fn build_absolute_path(dir : DirNode) -> String {
  match dir.parent {
    None => "/"
    Some(_) => {
      let parts : Array[String] = []
      let mut current : DirNode? = Some(dir)
      while true {
        match current {
          None => break
          Some(node) =>
            match node.parent {
              None => break
              Some(_) => {
                parts.push(node.name)
                current = node.parent
              }
            }
        }
      }
      let builder = StringBuilder::new()
      builder.write_char('/')
      let mut i = parts.length() - 1
      while i >= 0 {
        builder.write_string(parts[i])
        builder.write_char('/')
        i = i - 1
      }
      builder.to_string()
    }
  }
}

///|
fn list_directory_entries(dir : DirNode) -> Array[DirEntry] {
  let entries : Array[DirEntry] = []
  let dot_type = match dir.parent {
    None => FileType::Root
    Some(_) => FileType::Dir
  }
  entries.push({ type_: dot_type, name: "." })
  entries.push({ type_: dot_type, name: ".." })
  dir.children.each(fn(_name, child) {
    match child {
      Directory(node) => entries.push({ type_: FileType::Dir, name: node.name })
      Regular(node) => entries.push({ type_: FileType::File, name: node.name })
    }
  })
  entries
}

///|
fn serialize_tree(root : DirNode) -> Array[Array[Byte]] raise {
  let addresses : Array[(FsNode, NodeAddress)] = []

  fn remember(node : FsNode, address : NodeAddress) -> Unit {
    addresses.push((node, address))
  }

  fn lookup(node : FsNode) -> NodeAddress raise {
    for pair in addresses {
      match (pair.0, node) {
        (Directory(a), Directory(b)) =>
          if physical_equal(a, b) {
            return pair.1
          }
        (Regular(a), Regular(b)) => if physical_equal(a, b) { return pair.1 }
        _ => ()
      }
    }
    raise FileFsError("missing address for node")
  }

  fn assign(node : FsNode, next_index : Int) -> Int raise {
    match node {
      Directory(dir) => {
        let entry_count = 2 + dir.children.length()
        let block_count = ceil_div(entry_count, block_item_max_count)
        let start = next_index
        let stop = start + block_count - 1
        let remainder = entry_count % block_item_max_count
        let offset = if remainder == 0 {
          block_size
        } else {
          block_head + remainder * entry_size
        }
        remember(Directory(dir), { start, stop, offset, block_count })
        let mut cursor = stop + 1
        dir.children.each(fn(_name, child) { cursor = assign(child, cursor) })
        cursor
      }
      Regular(file) =>
        if file.data.length() == 0 {
          remember(Regular(file), {
            start: 0,
            stop: 0,
            offset: 0,
            block_count: 0,
          })
          next_index
        } else {
          let block_count = ceil_div(file.data.length(), data_per_block)
          let start = next_index
          let stop = start + block_count - 1
          let remainder = file.data.length() % data_per_block
          let offset = if remainder == 0 {
            block_size
          } else {
            block_head + remainder
          }
          remember(Regular(file), { start, stop, offset, block_count })
          stop + 1
        }
    }
  }

  let total_blocks = assign(Directory(root), root_blockindex)
  let blocks = Array::make(total_blocks, empty_block())
  for i = 0; i < total_blocks; i = i + 1 {
    blocks[i] = empty_block()
  }

  blocks[0][0] = magic0
  blocks[0][1] = magic1
  blocks[0][2] = magic2
  blocks[0][3] = magic3
  write_u32_le(blocks[0], 4, total_blocks)
  write_u32_le(blocks[0], 8, 0)

  fn serialize_file(file : FileNode) -> Unit raise {
    let address = lookup(Regular(file))
    if address.start == 0 {
      return
    }
    let mut source_offset = 0
    for block_index = address.start
        block_index <= address.stop
        block_index = block_index + 1 {
      let block = blocks[block_index]
      let next = if block_index < address.stop { block_index + 1 } else { 0 }
      let prev = if block_index > address.start { block_index - 1 } else { 0 }
      write_u32_le(block, 4, next)
      write_u32_le(block, 8, prev)
      let end_exclusive = @cmp.minimum(
        source_offset + data_per_block,
        file.data.length(),
      )
      for i = source_offset; i < end_exclusive; i = i + 1 {
        block[block_head + (i - source_offset)] = file.data[i]
      }
      source_offset = end_exclusive
    }
  }

  fn serialize_dir(dir : DirNode) -> Unit raise {
    let address = lookup(Directory(dir))
    let entries : Array[WireEntry] = []
    entries.push({
      is_file: false,
      name: ".",
      start: address.start,
      stop: address.stop,
      offset: address.offset,
    })
    let parent_start = match dir.parent {
      None => 0
      Some(parent) => lookup(Directory(parent)).start
    }
    entries.push({
      is_file: false,
      name: "..",
      start: parent_start,
      stop: 0,
      offset: 0,
    })
    dir.children.each(fn(_name, child) {
      let child_address = lookup(child)
      match child {
        Regular(file) =>
          entries.push({
            is_file: true,
            name: file.name,
            start: child_address.start,
            stop: child_address.stop,
            offset: child_address.offset,
          })
        Directory(child_dir) =>
          entries.push({
            is_file: false,
            name: child_dir.name,
            start: child_address.start,
            stop: child_address.stop,
            offset: child_address.offset,
          })
      }
    })

    for block_offset = 0
        block_offset < address.block_count
        block_offset = block_offset + 1 {
      let block_index = address.start + block_offset
      let block = blocks[block_index]
      let next = if block_index < address.stop { block_index + 1 } else { 0 }
      let prev = if block_index > address.start { block_index - 1 } else { 0 }
      write_u32_le(block, 4, next)
      write_u32_le(block, 8, prev)
      let from = block_offset * block_item_max_count
      let to = @cmp.minimum(entries.length(), from + block_item_max_count)
      let mut position = block_head
      for entry_index = from; entry_index < to; entry_index = entry_index + 1 {
        let entry = entries[entry_index]
        block[position] = if entry.is_file { b'\x01' } else { b'\x00' }
        position = position + 1
        write_fixed_name(block, position, entry.name)
        position = position + block_name_max_size
        write_u32_le(block, position, entry.start)
        position = position + 4
        write_u32_le(block, position, entry.stop)
        position = position + 4
        write_u16_le(block, position, entry.offset)
        position = position + 2
      }
    }

    dir.children.each(fn(_name, child) {
      match child {
        Directory(child_dir) => serialize_dir(child_dir)
        Regular(file) => serialize_file(file)
      }
    })
  }

  serialize_dir(root)
  blocks
}

///|
fn parse_tree(blocks : Array[Array[Byte]]) -> DirNode raise {
  if blocks.length() < 2 {
    raise FileFsError("image must contain at least two blocks")
  }
  let visited : Map[Int, Bool] = Map([])

  fn read_block(index : Int) -> Array[Byte] raise {
    match blocks.get(index) {
      Some(block) => block
      None => raise FileFsError("missing block \{index}")
    }
  }

  fn parse_file(start : Int, stop : Int, offset : Int) -> Array[Byte] raise {
    if start == 0 && stop == 0 && offset == 0 {
      return []
    }
    if !(start > 0 && stop >= start) {
      raise FileFsError("invalid file block range")
    }
    if !(offset >= block_head && offset <= block_size) {
      raise FileFsError("invalid file offset")
    }
    let out : Array[Byte] = []
    let mut current = start
    while true {
      let block = read_block(current)
      let limit = if current == stop { offset } else { block_size }
      if !(limit >= block_head && limit <= block_size) {
        raise FileFsError("invalid block limit")
      }
      for i = block_head; i < limit; i = i + 1 {
        out.push(block[i])
      }
      if current == stop {
        break
      }
      current = read_u32_le(block, 4)
      if current == 0 {
        raise FileFsError("unterminated file block chain")
      }
    }
    out
  }

  fn parse_dir(index : Int, name : String, parent : DirNode?) -> DirNode raise {
    if visited.contains(index) {
      raise FileFsError("directory cycle at block \{index}")
    }
    visited.set(index, true)
    let first_block = read_block(index)
    let dot = read_entry(first_block, block_head)
    if dot.is_file || dot.name != "." {
      raise FileFsError("invalid directory header at block \{index}")
    }
    let dir = new_dir(name, parent)
    let entries : Array[WireEntry] = []
    let mut current = index
    while true {
      let block = read_block(current)
      let limit = if current == dot.stop { dot.offset } else { block_size }
      if !(limit >= block_head && limit <= block_size) {
        raise FileFsError("invalid directory offset")
      }
      let mut position = block_head
      while position + entry_size <= limit {
        entries.push(read_entry(block, position))
        position = position + entry_size
      }
      if current == dot.stop {
        break
      }
      current = read_u32_le(block, 4)
      if current == 0 {
        raise FileFsError("unterminated directory chain")
      }
    }
    if entries.length() < 2 {
      raise FileFsError("directory missing dot entries")
    }
    if entries[1].name != ".." {
      raise FileFsError("directory missing parent entry")
    }
    for i = 2; i < entries.length(); i = i + 1 {
      let entry = entries[i]
      if entry.name.length() == 0 {
        raise FileFsError("empty child entry")
      }
      let child = if entry.is_file {
        Regular(
          new_file(
            entry.name,
            Some(dir),
            data=parse_file(entry.start, entry.stop, entry.offset),
          ),
        )
      } else {
        Directory(parse_dir(entry.start, entry.name, Some(dir)))
      }
      dir.children.set(entry.name, child)
    }
    dir
  }

  parse_dir(root_blockindex, "", None)
}

///|
fn concat_blocks(blocks : Array[Array[Byte]]) -> Bytes {
  let out = @buffer.Buffer::Buffer(size_hint=blocks.length() * block_size)
  for block in blocks {
    out.write_bytes(Bytes::from_array(block[:]))
  }
  out.to_bytes()
}

///|
fn split_image_bytes(image : Bytes) -> Array[Array[Byte]] raise {
  if image.length() % block_size != 0 {
    raise FileFsError("image size is not a multiple of 512")
  }
  let total = image.length() / block_size
  let blocks = Array::make(total, empty_block())
  for i = 0; i < total; i = i + 1 {
    let block = empty_block()
    for j = 0; j < block_size; j = j + 1 {
      block[j] = image[i * block_size + j]
    }
    blocks[i] = block
  }
  blocks
}
