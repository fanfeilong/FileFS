# FileFS

FileFS: Implement a virtual file system within a single file.

## Layout

```
.
├── c/          # C implementation (original)
├── cpp/        # Pure C++20 port
├── go/         # Pure-Go port
├── java/       # Pure Java 21 port
├── python/     # Python package (CPython bindings to c/)
├── rust/       # Pure-Rust port
├── zig/        # Pure-Zig port
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

## C++

```bash
cmake -S cpp -B cpp/build -DCMAKE_BUILD_TYPE=Release
cmake --build cpp/build -j
ctest --test-dir cpp/build --output-on-failure
```

See [cpp/README.md](cpp/README.md).

## Go

```bash
cd go
go build -o demo ./cmd/demo
./demo
```

See [go/README.md](go/README.md).

## Java

```bash
mvn -f java/pom.xml test
```

See [java/README.md](java/README.md).

## Python

```bash
cd python
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
python -m unittest discover -s tests -v
```

See [python/README.md](python/README.md).

## Rust

```bash
cd rust
cargo test
```

See [rust/README.md](rust/README.md).

## Zig

```bash
cd zig
zig build test
```

See [zig/README.md](zig/README.md).

C / C++ / Go / Java / Python / Rust / Zig share the same on-disk format (512-byte blocks, magic `78 11 45 14`).
