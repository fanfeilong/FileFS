# FileFS Java Port

Pure Java rewrite of FileFS that matches the shared on-disk image format used by the C, Go, C++, Rust, and Zig implementations.

## Build and test

```bash
mvn -f java/pom.xml test
```

## Layout

```text
java/
├── pom.xml
├── README.md
└── src
    ├── main/java/com/filefs
    │   ├── DirectoryHandle.java
    │   ├── DirEntry.java
    │   ├── FileFsException.java
    │   ├── FileHandle.java
    │   ├── FileSystem.java
    │   ├── FileType.java
    │   ├── SeekWhence.java
    │   ├── Types.java
    │   └── Util.java
    └── test/java/com/filefs
        └── FileSystemTest.java
```

## API notes

- `FileSystem.mkfs(Path)` formats a new image.
- `mount(Path)` / `umount()` manage the mounted image and journal recovery.
- `open(path, mode)` supports `r`, `w`, `a`, `r+`, `w+`, and `a+`.
- `read`, `write`, `seek`, `tell`, and `rewind` operate on `FileHandle`.
- `mkdir`, `rmdir`, `rename`, `move`, `copyFile`, `removeFile`, `chdir`, `getcwd`, `openDir`, and `readDir` mirror the core filesystem operations.
- `begin`, `commit`, and `rollback` expose the journal-backed transaction flow.
- `getcwd()` matches the historical FileFS behavior and keeps a trailing slash for non-root directories, for example `/docs/`.

## Format compatibility

- block size: `512`
- magic: `78 11 45 14`
- journal path: `<image>-j`
- directory entry size: `25` bytes

The implementation ports the journaled block allocation and directory/file mutation logic from `go/filefs`.
