# filefs (Lua)

Pure [Lua](https://www.lua.org/) 5.4 port of FileFS.

Uses the same on-disk format as the other host ports:

- 512-byte blocks
- magic number `78 11 45 14`
- copy-on-write journal stored beside the image as `<image>-j`

No third-party Lua rocks are required — only the standard library (`io` / `os`).

## Verify

```bash
cd lua
lua5.4 tests/run_tests.lua
# or, if `lua` points at 5.4+:
lua tests/run_tests.lua
```

## API sketch

```lua
local filefs = require("filefs")
local FileSystem = filefs.FileSystem

FileSystem.mkfs("demo.ffs")
local fsys = FileSystem.new()
fsys:mount("demo.ffs")
fsys:mkdir("docs")
fsys:chdir("docs")

local file = fsys:open("note.txt", "w")
fsys:write(file, FileSystem.bytes_from_string("hello"))
fsys:close(file)
```

Set `package.path` so it can see this directory (the test runner does this for you):

```lua
package.path = "./?.lua;./?/init.lua;" .. package.path
```

### Exports

- `FileSystem` / `mkfs` / `new`
- `FileType` / `SeekWhence` / `FileFsError`
- `FileSystem.bytes_from_string` / `FileSystem.string_from_bytes` helpers

## Notes

- Tree mutations happen in memory; persistence rewrites the image via the journal (same approach as the Kotlin / MoonBit ports).
- File I/O buffers are Lua arrays of byte values (`0–255`).
