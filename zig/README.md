# Zig FileFS

Pure-Zig port of FileFS using Zig 0.16.0.

## Layout

- `src/root.zig` - public API re-exports and tests
- `src/types.zig` - constants and core structs
- `src/*.zig` - feature-split implementation mirroring the Go port

## Build and test

```bash
cd zig
zig build test   # requires Zig >= 0.16.0
```

## Notes

- Block size: 512 bytes
- Magic: `78 11 45 14`
- Journal file: `<image>-j`
- API semantics follow the Go port in `../go/filefs/`
