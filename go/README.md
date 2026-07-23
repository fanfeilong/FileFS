# FileFS (Go)

Pure-Go port of [FileFS](../README.md): a virtual filesystem stored in a single file.

## Layout

```
go/
  filefs/     # library (API equivalent to FileFS.h)
  cmd/demo/   # interactive shell (equivalent to main.c)
  go.mod
```

## Build

```bash
cd go
go build -o demo ./cmd/demo
```

## Run

```bash
./demo
```

Example session:

```
$>mkfs test.ffs
$>mount test.ffs
$>mkdir foo
$>echo hello.txt hello world
$>ls
$>cat hello.txt
$>q
```

## API

Package `filefs` mirrors the C API:

| C | Go |
|---|---|
| `FileFS_create` / `destroy` | `Create` / `(*FileFS).Destroy` |
| `FileFS_mkfs` / `mount` / `umount` | `Mkfs` / `Mount` / `Umount` |
| `FileFS_fopen` / `fread` / `fwrite` | `Fopen` / `Fread` / `Fwrite` |
| `FileFS_mkdir` / `rmdir` / `chdir` | `Mkdir` / `Rmdir` / `Chdir` |
| `FileFS_begin` / `commit` / `rollback` | `Begin` / `Commit` / `Rollback` |

On-disk format is compatible with the C implementation (512-byte blocks, magic `78 11 45 14`).
