# Rust FileFS

Idiomatic Rust port of FileFS: a tiny virtual filesystem stored inside a single image file.

## Status

- Same on-disk basics as the C / C++ / Go / Zig variants
  - 512-byte blocks
  - magic `78 11 45 14`
  - journal file at `image-path + "-j"`
- Safe Rust only
- Zero dependencies beyond `std`
- Integration tests cover the basic lifecycle, directory ops, file IO, copy/rename/remove, directory iteration, and transactions

## Design

The public API follows Rust ownership and error-handling idioms rather than exposing C-style integer codes:

- `FileSystem` owns the mounted image and unmounts on `Drop`
- `File` and `Dir` are lightweight handles with explicit `close()` methods that are also idempotent under `Drop`
- operations return `Result<T, filefs::Error>`
- directory iteration uses `Iterator<Item = DirEntry>`
- file seeking uses `std::io::SeekFrom`

## Example

```rust
use filefs::{FileSystem, SeekFrom};

fn demo() -> filefs::Result<()> {
    FileSystem::mkfs("demo.ffs")?;

    let mut fs = FileSystem::new();
    fs.mount("demo.ffs")?;

    fs.create_dir("docs")?;
    fs.chdir("docs")?;

    let mut file = fs.open("note.txt", "w+")?;
    fs.write(&mut file, b"hello filefs")?;
    fs.seek(&mut file, SeekFrom::Start(0))?;

    let mut buf = [0u8; 32];
    let n = fs.read(&mut file, &mut buf)?;
    assert_eq!(&buf[..n], b"hello filefs");

    fs.begin()?;
    let mut txn = fs.open("/txn.txt", "w")?;
    fs.write(&mut txn, b"x")?;
    fs.commit()?;

    Ok(())
}
```

## Layout

```text
rust/
├── Cargo.toml
├── README.md
├── src/
│   ├── lib.rs
│   ├── error.rs
│   ├── types.rs
│   ├── util.rs
│   ├── mount.rs
│   ├── block.rs
│   ├── txn.rs
│   ├── journal.rs
│   ├── fopen.rs
│   ├── fopen_helpers.rs
│   ├── readwrite.rs
│   ├── seek.rs
│   ├── exist.rs
│   ├── remove.rs
│   ├── rename.rs
│   ├── move_ops.rs
│   ├── copy.rs
│   ├── pwd.rs
│   ├── mkdir.rs
│   ├── rmdir.rs
│   └── readdir.rs
└── tests/
    └── integration.rs
```

## Development

```bash
cd rust
cargo test
```
