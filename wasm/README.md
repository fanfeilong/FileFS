# FileFS Wasm

WebAssembly exposure of FileFS for Node/browser-style consumers using an in-memory image instead of host files.

## What is different here

- The FileFS image lives in Wasm linear memory as a growable byte buffer.
- `mkfs()` initializes that image in memory; `mount()` validates and activates it.
- Transactions use an in-memory snapshot of the image and working directory at `begin()` instead of the host-side `-j` journal file used by the native ports.
- JS talks to Wasm through a small exported C-style ABI and presents a `FileSystem`-like wrapper in `js/filefs.mjs`.

## Layout

- `src/store.zig` - memory-backed FileFS image, block allocation, directory and file operations, snapshot transactions
- `src/root.zig` - exported Wasm ABI, handle table, result/error buffers
- `js/filefs.mjs` - ESM loader and wrapper API
- `test/filefs.test.mjs` - Node tests

## Build and test

```bash
cd wasm
/usr/local/bin/zig build
npm test
```

## Example

```js
import { FileSystem } from "./js/filefs.mjs";

await FileSystem.load();

const fs = new FileSystem();
fs.mkfs();
fs.mount();
fs.mkdir("docs");
fs.chdir("docs");
fs.writeFile("note.txt", "hello wasm");

console.log(fs.readFile("note.txt"));
console.log(fs.getImage().length);

fs.destroy();
```

## Exported ABI

The Zig module exports a small handle-based ABI:

- `filefs_create()` / `filefs_destroy()`
- `filefs_mkfs()` / `filefs_mount()`
- `filefs_getcwd()`
- `filefs_mkdir()` / `filefs_chdir()`
- `filefs_write_file()` / `filefs_read_file()`
- `filefs_copy_file()` / `filefs_rename()` / `filefs_remove_file()`
- `filefs_list_dir()`
- `filefs_begin()` / `filefs_commit()` / `filefs_rollback()`
- `filefs_image_ptr()` / `filefs_image_len()`

String and byte arguments are copied into Wasm linear memory through `filefs_alloc()` / `filefs_free()`, while result payloads and the last error string are exposed through dedicated result/error buffers.
