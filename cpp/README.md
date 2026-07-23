# FileFS C++20 Port

This directory contains a pure C++20 implementation of FileFS, matching the on-disk format and core semantics of the C and Go ports.

## Highlights

- Pure C++20 rewrite in the `filefs::` namespace
- STL-style public API with move-only `File` and `Directory` handles
- 512-byte block format compatible with the other ports
- Transaction and journal behavior matching the Go implementation
- Self-contained test runner with no external test dependency

## Layout

```text
cpp/
├── CMakeLists.txt
├── README.md
├── include/filefs/filefs.hpp
├── src/
│   ├── block.cpp
│   ├── copy.cpp
│   ├── exist.cpp
│   ├── fopen.cpp
│   ├── fopen_helpers.cpp
│   ├── journal.cpp
│   ├── mkdir.cpp
│   ├── mount.cpp
│   ├── move.cpp
│   ├── pwd.cpp
│   ├── readwrite.cpp
│   ├── readdir.cpp
│   ├── remove.cpp
│   ├── rename.cpp
│   ├── rmdir.cpp
│   ├── seek.cpp
│   ├── txn.cpp
│   ├── types.hpp
│   ├── util.cpp
│   └── util.hpp
└── tests/
    └── test_filefs.cpp
```

## Build

```bash
cmake -S cpp -B cpp/build -DCMAKE_BUILD_TYPE=Release
cmake --build cpp/build -j
ctest --test-dir cpp/build --output-on-failure
```

`CMakeLists.txt` prefers `/usr/bin/g++` automatically on environments where the default `/usr/bin/c++` does not have a working standard library link setup.

## Public API

The public header is `include/filefs/filefs.hpp`. The main entry point is `filefs::FileSystem`.

Example:

```cpp
#include "filefs/filefs.hpp"

filefs::FileSystem fs;
filefs::FileSystem::mkfs("demo.ffs");
fs.mount("demo.ffs");
fs.mkdir("docs");

auto file = fs.fopen("/docs/note.txt", "w");
if (file) {
  const std::string text = "hello";
  fs.fwrite(*file, std::as_bytes(std::span(text.data(), text.size())));
  fs.fclose(*file);
}
```

## Notes

- `fread`/`fwrite` provide span overloads plus `void*`/`size`/`nmemb` overloads for C-style parity.
- Mutating operations preserve the original return-code conventions from `c/FileFS.h`.
- `File` and `Directory` destructors mark handles closed, while explicit `fclose` and `closedir` remain available for parity.
