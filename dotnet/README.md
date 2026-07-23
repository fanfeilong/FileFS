# FileFS .NET port

Pure C# / .NET port of FileFS, the single-image virtual filesystem used by the C, Go, Java, Rust, and Zig implementations in this repository.

## Target framework

- `net10.0`

## Layout

```text
dotnet/
├── FileFS.sln
├── FileFS/
│   ├── FileSystem.cs
│   ├── FileSystem.Mount.cs
│   ├── FileSystem.Txn.cs
│   ├── FileSystem.Block.cs
│   ├── FileSystem.PathOps.cs
│   ├── FileSystem.Open.cs
│   ├── FileSystem.IO.cs
│   ├── FileSystem.Dir.cs
│   ├── FileSystem.FileOps.cs
│   ├── FileHandle.cs
│   ├── DirectoryHandle.cs
│   ├── DirEntry.cs
│   ├── FileType.cs
│   ├── SeekWhence.cs
│   ├── FileFsException.cs
│   └── Internal/
│       ├── Types.cs
│       └── Util.cs
└── FileFS.Tests/
    └── FileSystemTests.cs
```

## Usage

```bash
cd dotnet
dotnet test
```

## API notes

- `FileSystem.Mkfs(path)` formats a new FileFS image.
- `Mount`/`Umount` work against the image file directly and use a journal at `path + "-j"`.
- `Getcwd()` matches the historical FileFS behavior and keeps a trailing slash for non-root directories, for example `/docs/`.
- `Open` accepts `r`, `w`, `a`, `r+`, `w+`, and `a+`.
- Directory iteration returns `DirEntry` instances with `Name` and `Type`.
- Transactions use the same copy/add staging model as the Go port and recover from a completed journal on mount.

## On-disk compatibility

This port preserves the shared FileFS image format:

- block size: `512`
- magic: `78 11 45 14`
- journal sidecar: `*-j`

It is a pure managed rewrite and does not use P/Invoke.
