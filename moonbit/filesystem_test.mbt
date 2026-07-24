///|
fn remove_quiet(path : String) -> Unit {
  if @fs.path_exists(path) {
    @fs.remove_file(path) catch {
      _ => ()
    }
  }
}

///|
fn with_fixture(
  name : String,
  body : (FileSystem, String) -> Unit raise,
) -> Unit raise {
  let path = "tmp-filefs-moonbit-\{name}.ffs"
  let journal = path + "-j"
  remove_quiet(path)
  remove_quiet(journal)
  @filefs.mkfs(path)
  let fsys = @filefs.FileSystem::new()
  fsys.mount(path)
  defer {
    fsys.umount()
    remove_quiet(path)
    remove_quiet(journal)
  }
  body(fsys, path)
}

///|
fn ascii_bytes(text : String) -> Array[Byte] {
  let out = Array::new(capacity=text.length())
  text.iter().each(fn(ch) { out.push(ch.to_int().to_byte()) })
  out
}

///|
test "mkfs_mount_and_getcwd" {
  with_fixture("lifecycle", (fsys, _path) => {
    assert_true(fsys.is_mounted())
    assert_eq(fsys.getcwd(), "/")
  })
}

///|
test "mkdir_and_chdir" {
  with_fixture("mkdir", (fsys, _path) => {
    fsys.mkdir("docs")
    fsys.chdir("docs")
    assert_eq(fsys.getcwd(), "/docs/")
  })
}

///|
test "open_write_read_roundtrip" {
  with_fixture("roundtrip", (fsys, _path) => {
    fsys.mkdir("docs")
    fsys.chdir("docs")
    let out = fsys.open("note.txt", "w")
    let payload = ascii_bytes("hello filefs")
    assert_eq(fsys.write(out, payload), payload.length())
    fsys.close(out)
    let input = fsys.open("note.txt", "r")
    assert_true(fsys.seek(input, 0, @filefs.SeekWhence::End))
    assert_eq(fsys.tell(input), payload.length())
    fsys.rewind(input)
    let buffer = Array::make(64, b'\x00')
    let count = fsys.read(input, buffer)
    fsys.close(input)
    let chars = Array::new(capacity=count)
    for i = 0; i < count; i = i + 1 {
      chars.push(Char::from_int(buffer[i].to_int()))
    }
    assert_eq(String::from_array(chars[:]), "hello filefs")
  })
}

///|
test "copy_rename_and_remove" {
  with_fixture("copy", (fsys, _path) => {
    let out = fsys.open("orig.txt", "w")
    let payload = ascii_bytes("copy me")
    assert_eq(fsys.write(out, payload), payload.length())
    fsys.close(out)
    fsys.copy_file("orig.txt", "copy.txt")
    fsys.rename("copy.txt", "renamed.txt")
    assert_true(fsys.file_exists("renamed.txt"))
    fsys.remove_file("renamed.txt")
    assert_false(fsys.file_exists("renamed.txt"))
  })
}

///|
test "open_dir_lists_docs" {
  with_fixture("readdir", (fsys, _path) => {
    fsys.mkdir("docs")
    let dir = fsys.open_dir("/")
    assert_eq(dir.absolute_path(), "/")
    let mut found_docs = false
    while true {
      match fsys.read_dir(dir) {
        None => break
        Some(entry) =>
          if entry.name == "docs" && entry.file_type() == @filefs.FileType::Dir {
            found_docs = true
          }
      }
    }
    fsys.close_dir(dir)
    assert_true(found_docs)
  })
}

///|
test "begin_commit_creates_file" {
  with_fixture("txn", (fsys, _path) => {
    assert_true(fsys.begin())
    let out = fsys.open("txn.txt", "w")
    assert_eq(fsys.write(out, [b'x']), 1)
    fsys.close(out)
    assert_true(fsys.commit())
    assert_true(fsys.file_exists("txn.txt"))
  })
}
