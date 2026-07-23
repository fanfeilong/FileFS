import {
  BlockNameMaxSize,
  SeekWhence,
  FileFsError,
} from "./types.js";

export function readUInt32(buffer, offset = 0) {
  return (
    (buffer[offset] & 0xff) |
    ((buffer[offset + 1] & 0xff) << 8) |
    ((buffer[offset + 2] & 0xff) << 16) |
    ((buffer[offset + 3] & 0xff) << 24)
  ) >>> 0;
}

export function writeUInt32(buffer, value, offset = 0) {
  const v = value >>> 0;
  buffer[offset] = v & 0xff;
  buffer[offset + 1] = (v >>> 8) & 0xff;
  buffer[offset + 2] = (v >>> 16) & 0xff;
  buffer[offset + 3] = (v >>> 24) & 0xff;
}

export function readUInt16(buffer, offset = 0) {
  return ((buffer[offset] & 0xff) | ((buffer[offset + 1] & 0xff) << 8)) >>> 0;
}

export function writeUInt16(buffer, value, offset = 0) {
  const v = value & 0xffff;
  buffer[offset] = v & 0xff;
  buffer[offset + 1] = (v >>> 8) & 0xff;
}

export function fixedNameToString(buffer, offset = 0, length = BlockNameMaxSize) {
  let end = offset;
  const limit = offset + length;
  while (end < limit && buffer[end] !== 0) {
    end += 1;
  }
  return Buffer.from(buffer.subarray(offset, end)).toString("utf8");
}

export function copyName(buffer, offset, name, length = BlockNameMaxSize) {
  buffer.fill(0, offset, offset + length);
  Buffer.from(name, "utf8").copy(buffer, offset, 0, length);
}

export function ensureNameFits(name, context = "path segment") {
  if (Buffer.byteLength(name, "utf8") > BlockNameMaxSize) {
    throw new FileFsError(`${context} exceeds ${BlockNameMaxSize} bytes.`);
  }
}

export function asByteBuffer(bufferLike) {
  if (Buffer.isBuffer(bufferLike)) {
    return bufferLike;
  }
  if (bufferLike instanceof Uint8Array) {
    return Buffer.from(
      bufferLike.buffer,
      bufferLike.byteOffset,
      bufferLike.byteLength,
    );
  }
  throw new TypeError("Expected Buffer or Uint8Array.");
}

export function sliceByteBuffer(bufferLike, offset = 0, length = undefined) {
  const buffer = asByteBuffer(bufferLike);
  const end = length === undefined ? buffer.length : offset + length;
  if (offset < 0 || end < offset || end > buffer.length) {
    throw new RangeError("Buffer offset/length is out of range.");
  }
  return buffer.subarray(offset, end);
}

export function readExact(fsModule, fd, buffer, position) {
  let total = 0;
  while (total < buffer.length) {
    const bytesRead = fsModule.readSync(
      fd,
      buffer,
      total,
      buffer.length - total,
      position === null ? null : position + total,
    );
    if (bytesRead === 0) {
      return false;
    }
    total += bytesRead;
  }
  return true;
}

export function writeExact(fsModule, fd, buffer, position) {
  let total = 0;
  while (total < buffer.length) {
    const bytesWritten = fsModule.writeSync(
      fd,
      buffer,
      total,
      buffer.length - total,
      position === null ? null : position + total,
    );
    total += bytesWritten;
  }
}

export function normalizeWhence(whence) {
  if (whence === "set") {
    return SeekWhence.Set;
  }
  if (whence === "cur") {
    return SeekWhence.Cur;
  }
  if (whence === "end") {
    return SeekWhence.End;
  }
  if (whence === 0 || whence === 1 || whence === 2) {
    return whence;
  }
  throw new FileFsError(`Unsupported seek whence '${String(whence)}'.`);
}

export function createEntryObject(name, type) {
  return {
    name,
    nameLength: Buffer.byteLength(name, "utf8"),
    type,
  };
}
