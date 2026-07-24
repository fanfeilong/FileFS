# FileFS

FileFS: Implement a virtual file system within a single file.

## Layout

```
.
├── c/          # C implementation (original)
├── cpp/        # Pure C++20 port
├── dotnet/     # Pure C# / .NET port
├── go/         # Pure-Go port
├── java/       # Pure Java 21 port
├── kotlin/     # Pure Kotlin/JVM port
├── lua/        # Pure Lua 5.4 port
├── moonbit/    # Pure MoonBit port
├── nodejs/     # Pure JavaScript ESM port
├── python/     # Python package (CPython bindings to c/)
├── rust/       # Pure-Rust port
├── swift/      # Pure Swift port
├── wasm/       # WebAssembly (Zig) + JS glue (in-memory image)
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

## .NET

```bash
cd dotnet
dotnet test
```

See [dotnet/README.md](dotnet/README.md).

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

## Kotlin

```bash
cd kotlin
./build.sh
```

See [kotlin/README.md](kotlin/README.md).

## Lua

```bash
cd lua
lua5.4 tests/run_tests.lua
```

See [lua/README.md](lua/README.md).

## MoonBit

```bash
cd moonbit
moon test
```

See [moonbit/README.md](moonbit/README.md).

## Node.js

```bash
cd nodejs
npm test
```

See [nodejs/README.md](nodejs/README.md).

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

## Swift

```bash
cd swift
swift test
```

See [swift/README.md](swift/README.md).

## WebAssembly

```bash
cd wasm
zig build
npm test
```

In-memory FileFS image for browser/Node via Zig `wasm32-freestanding` + JS glue.  
See [wasm/README.md](wasm/README.md).

## Zig

```bash
cd zig
zig build test
```

See [zig/README.md](zig/README.md).

Host language ports share the same on-disk format (512-byte blocks, magic `78 11 45 14`).  
The Wasm port uses the same block layout in an in-memory image suitable for browsers.
