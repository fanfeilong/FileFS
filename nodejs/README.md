# filefs (Node.js)

Pure JavaScript ESM port of FileFS for Node.js 18+.

The Node port uses the same on-disk format as the C, Go, Java, .NET, Rust, and Zig ports:

- 512-byte blocks
- magic number `78 11 45 14`
- copy-on-write journal stored beside the image as `<image>-j`

## Install / use locally

```bash
cd nodejs
npm test
```

## API

```js
import { FileSystem, SeekWhence, FileType } from "filefs";

FileSystem.mkfs("demo.ffs");

const fsys = new FileSystem();
fsys.mount("demo.ffs");

fsys.mkdir("docs");
fsys.chdir("docs");

const file = fsys.open("note.txt", "w");
fsys.write(file, Buffer.from("hello"));
fsys.close(file);

const reader = fsys.open("note.txt", "r");
const buffer = Buffer.alloc(16);
const read = fsys.read(reader, buffer);
fsys.close(reader);

console.log(buffer.subarray(0, read).toString("utf8"));
console.log(fsys.getcwd()); // /docs/
```

### Exports

- `FileSystem`
- `FileHandle`
- `DirectoryHandle`
- `SeekWhence`
- `FileType`
- `FileFsError`

### Notes

- File I/O is synchronous to keep the implementation close to the reference ports.
- Paths follow FileFS semantics, including trailing `/` in `getcwd()` for non-root directories.
- Directory iteration returns `{ name, nameLength, type }`.
