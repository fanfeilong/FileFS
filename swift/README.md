# FileFS Swift

Pure Swift port of the FileFS single-image virtual filesystem.

## Features

- 512-byte block format compatible with the Go, Rust, and C ports
- Root image magic `78 11 45 14`
- Copy-on-write transaction staging with `begin`, `commit`, and `rollback`
- Journal recovery from `image-path + "-j"`
- Idiomatic Swift API built on `throws` and `FileFSError`

## Package layout

```text
swift/
  Package.swift
  Sources/FileFS/
  Tests/FileFSTests/
```

## Usage

```swift
import FileFS

try FileSystem.mkfs(at: "/tmp/demo.ffs")

let fs = FileSystem()
try fs.mount(at: "/tmp/demo.ffs")

try fs.mkdir("docs")
try fs.chdir("docs")

let handle = try fs.open("note.txt", mode: "w")
_ = try fs.write(handle, from: Array("hello".utf8))
fs.close(handle)
```

## Notes

- Directory names and file names are limited to 14 UTF-8 bytes.
- `getcwd()` mirrors the original ports and keeps a trailing slash for non-root directories.
- The implementation favors on-disk compatibility over host filesystem convenience.

## Test

```bash
cd /workspace/swift
swift test
```
