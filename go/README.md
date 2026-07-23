# FileFS (Go)

Pure-Go port of FileFS (see [c/](../c/) for the original C implementation): a virtual filesystem stored in a single file.

## Layout

```
go/
  filefs/              # library (API equivalent to FileFS.h)
    types.go           # constants, File/Dir/FileFS structs
    util.go            # endian helpers, file seek/sync wrappers
    mount.go           # Create/Destroy/Mkfs/Mount/Umount/IsMount
    fopen.go           # Fopen
    fopen_helpers.go   # open helpers for r/w/a modes
    readwrite.go       # Fread/Fwrite/Fclose
    seek.go            # Fseek/Ftell/Rewind
    exist.go           # FileExist/DirExist/stat
    remove.go          # Remove
    rename.go          # Rename (+ doRename)
    move.go            # Move
    copy.go            # Copy
    pwd.go             # Chdir/Getcwd
    mkdir.go           # Mkdir
    rmdir.go           # Rmdir
    readdir.go         # Opendir/Readdir/Closedir
    txn.go             # Begin/Commit/Rollback
    block.go           # block alloc/read/write/remove/path lookup
    journal.go         # journal recovery (fn-j)
  cmd/demo/            # interactive shell (equivalent to main.c)
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
