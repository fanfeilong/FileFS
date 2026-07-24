import { readFile } from "node:fs/promises";

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

let wasmRuntime = null;

function asBytes(value) {
  if (value instanceof Uint8Array) {
    return value;
  }
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  }
  if (value instanceof ArrayBuffer) {
    return new Uint8Array(value);
  }
  return textEncoder.encode(String(value));
}

async function readWasmSource(source) {
  const url = source instanceof URL ? source : new URL(String(source), import.meta.url);
  if (url.protocol === "http:" || url.protocol === "https:") {
    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(`Unable to fetch ${url.href}: ${response.status} ${response.statusText}`);
    }
    return new Uint8Array(await response.arrayBuffer());
  }
  return readFile(url);
}

async function instantiateRuntime(options = {}) {
  const source = options.source ?? new URL("../zig-out/bin/filefs.wasm", import.meta.url);
  const bytes = await readWasmSource(source);
  const { instance } = await WebAssembly.instantiate(bytes, {});
  return {
    exports: instance.exports,
  };
}

function requireRuntime() {
  if (!wasmRuntime) {
    throw new Error("Call FileSystem.load() before constructing a FileSystem.");
  }
  return wasmRuntime;
}

function copyWasmBytes(exports, ptr, len) {
  if (!ptr || !len) {
    return new Uint8Array(0);
  }
  return Uint8Array.from(new Uint8Array(exports.memory.buffer, ptr, len));
}

function readWasmText(exports, ptr, len) {
  if (!ptr || !len) {
    return "";
  }
  return textDecoder.decode(new Uint8Array(exports.memory.buffer, ptr, len));
}

function readLastError(exports) {
  return readWasmText(exports, exports.filefs_last_error_ptr(), exports.filefs_last_error_len());
}

function readResultBytes(exports) {
  return copyWasmBytes(exports, exports.filefs_result_ptr(), exports.filefs_result_len());
}

function readResultText(exports) {
  return textDecoder.decode(readResultBytes(exports));
}

function allocBytes(exports, bytes) {
  if (bytes.length === 0) {
    return { ptr: 0, len: 0 };
  }
  const ptr = exports.filefs_alloc(bytes.length);
  if (!ptr) {
    throw new Error(readLastError(exports) || "Unable to allocate Wasm memory.");
  }
  new Uint8Array(exports.memory.buffer).set(bytes, ptr);
  return { ptr, len: bytes.length };
}

function freeBytes(exports, allocation) {
  if (allocation.ptr && allocation.len) {
    exports.filefs_free(allocation.ptr, allocation.len);
  }
}

function parseDirListing(text) {
  return text
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const [typeCode, name = ""] = line.split("\t");
      const type =
        typeCode === "0" ? "file" : typeCode === "1" ? "dir" : "root";
      return { type, name };
    });
}

export class FileSystem {
  static async load(options = {}) {
    if (!wasmRuntime) {
      wasmRuntime = await instantiateRuntime(options);
    }
    return this;
  }

  #exports;
  #handle;

  constructor() {
    const runtime = requireRuntime();
    this.#exports = runtime.exports;
    this.#handle = this.#exports.filefs_create();
    if (!this.#handle) {
      throw new Error(readLastError(this.#exports) || "Unable to create FileFS handle.");
    }
  }

  destroy() {
    if (this.#handle) {
      this.#exports.filefs_destroy(this.#handle);
      this.#handle = 0;
    }
  }

  #ensureHandle() {
    if (!this.#handle) {
      throw new Error("FileSystem handle has been destroyed.");
    }
  }

  #callBoolean(operation, fn) {
    this.#ensureHandle();
    const ok = fn();
    if (!ok) {
      const reason = readLastError(this.#exports);
      throw new Error(reason ? `${operation} failed: ${reason}` : `${operation} failed.`);
    }
  }

  #withBytes(value, callback) {
    const bytes = asBytes(value);
    const allocation = allocBytes(this.#exports, bytes);
    try {
      return callback(allocation.ptr, allocation.len);
    } finally {
      freeBytes(this.#exports, allocation);
    }
  }

  #withTwoByteSlices(first, second, callback) {
    const firstAllocation = allocBytes(this.#exports, asBytes(first));
    const secondAllocation = allocBytes(this.#exports, asBytes(second));
    try {
      return callback(firstAllocation, secondAllocation);
    } finally {
      freeBytes(this.#exports, secondAllocation);
      freeBytes(this.#exports, firstAllocation);
    }
  }

  mkfs() {
    this.#callBoolean("mkfs", () => this.#exports.filefs_mkfs(this.#handle));
    return this;
  }

  mount() {
    this.#callBoolean("mount", () => this.#exports.filefs_mount(this.#handle));
    return this;
  }

  getcwd() {
    this.#callBoolean("getcwd", () => this.#exports.filefs_getcwd(this.#handle));
    return readResultText(this.#exports);
  }

  mkdir(path) {
    this.#withBytes(path, (ptr, len) => {
      this.#callBoolean("mkdir", () => this.#exports.filefs_mkdir(this.#handle, ptr, len));
    });
    return this;
  }

  chdir(path = "") {
    this.#withBytes(path, (ptr, len) => {
      this.#callBoolean("chdir", () => this.#exports.filefs_chdir(this.#handle, ptr, len));
    });
    return this;
  }

  writeFile(path, data) {
    this.#withTwoByteSlices(path, data, (pathAllocation, dataAllocation) => {
      this.#callBoolean("writeFile", () =>
        this.#exports.filefs_write_file(
          this.#handle,
          pathAllocation.ptr,
          pathAllocation.len,
          dataAllocation.ptr,
          dataAllocation.len,
        ),
      );
    });
    return this;
  }

  readFile(path, options = {}) {
    this.#withBytes(path, (ptr, len) => {
      this.#callBoolean("readFile", () => this.#exports.filefs_read_file(this.#handle, ptr, len));
    });
    const bytes = readResultBytes(this.#exports);
    if (options.encoding === null) {
      return bytes;
    }
    return textDecoder.decode(bytes);
  }

  copyFile(fromPath, toPath) {
    this.#withTwoByteSlices(fromPath, toPath, (fromAllocation, toAllocation) => {
      this.#callBoolean("copyFile", () =>
        this.#exports.filefs_copy_file(
          this.#handle,
          fromAllocation.ptr,
          fromAllocation.len,
          toAllocation.ptr,
          toAllocation.len,
        ),
      );
    });
    return this;
  }

  rename(fromPath, toPath) {
    this.#withTwoByteSlices(fromPath, toPath, (fromAllocation, toAllocation) => {
      this.#callBoolean("rename", () =>
        this.#exports.filefs_rename(
          this.#handle,
          fromAllocation.ptr,
          fromAllocation.len,
          toAllocation.ptr,
          toAllocation.len,
        ),
      );
    });
    return this;
  }

  removeFile(path) {
    this.#withBytes(path, (ptr, len) => {
      this.#callBoolean("removeFile", () =>
        this.#exports.filefs_remove_file(this.#handle, ptr, len),
      );
    });
    return this;
  }

  listDir(path = "") {
    this.#withBytes(path, (ptr, len) => {
      this.#callBoolean("listDir", () => this.#exports.filefs_list_dir(this.#handle, ptr, len));
    });
    return parseDirListing(readResultText(this.#exports));
  }

  begin() {
    this.#callBoolean("begin", () => this.#exports.filefs_begin(this.#handle));
    return this;
  }

  commit() {
    this.#callBoolean("commit", () => this.#exports.filefs_commit(this.#handle));
    return this;
  }

  rollback() {
    this.#callBoolean("rollback", () => this.#exports.filefs_rollback(this.#handle));
    return this;
  }

  getImage() {
    this.#ensureHandle();
    return copyWasmBytes(
      this.#exports,
      this.#exports.filefs_image_ptr(this.#handle),
      this.#exports.filefs_image_len(this.#handle),
    );
  }
}
