# FileFS

FileFS: Implement a virtual file system within a single file.

## Layout

```
.
├── c/          # C implementation (original)
├── go/         # Pure-Go port
├── LICENSE
└── README.md
```

## C

```bash
cd c
make
./demo
```

See [c/README.md](c/README.md).

## Go

```bash
cd go
go build -o demo ./cmd/demo
./demo
```

See [go/README.md](go/README.md).

Both implementations share the same on-disk format (512-byte blocks, magic `78 11 45 14`).
