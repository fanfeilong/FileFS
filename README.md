# FileFS

FileFS: Implement a virtual file system within a single file.

## Layout

```
.
├── c/          # C implementation (original)
├── go/         # Pure-Go port
├── python/     # Python package (CPython bindings to c/)
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

## Python

```bash
cd python
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
python -m unittest discover -s tests -v
```

See [python/README.md](python/README.md).

C / Go / Python share the same on-disk format (512-byte blocks, magic `78 11 45 14`).
