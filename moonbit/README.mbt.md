# filefs (MoonBit)

Pure [MoonBit](https://www.moonbitlang.com/) port of FileFS.

Uses the same on-disk format as the other host ports:

- 512-byte blocks
- magic number `78 11 45 14`
- copy-on-write journal stored beside the image as `<image>-j`

Host I/O goes through `moonbitlang/x/fs` (wasm-gc / js / native).

## Verify

```bash
# Install toolchain: https://www.moonbitlang.com/download/
cd moonbit
moon install   # or moon update, then moon check
moon test
```

## API sketch

```moonbit nocheck
@filefs.mkfs("demo.ffs")
let fsys = @filefs.FileSystem::new()
fsys.mount("demo.ffs")
fsys.mkdir("docs")
fsys.chdir("docs")
let file = fsys.open("note.txt", "w")
ignore(fsys.write(file, Bytes::of_string("hello").to_array()))
fsys.close(file)
```

### Public surface

- `mkfs`
- `FileSystem` (`mount`, `umount`, open/read/write/seek, mkdir/chdir, copy/rename, begin/commit/rollback, …)
- `FileHandle` / `DirectoryHandle` / `DirEntry`
- `FileType` / `SeekWhence`
- `FileFsError`

## Notes

- Tree mutations happen in memory; persistence rewrites the image via the journal, matching the Kotlin port’s approach.
- Default preferred target is `wasm-gc` so `moon test` exercises the wasm FS backend bundled with `moonbitlang/x`.
