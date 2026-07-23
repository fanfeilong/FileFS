import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { FileHandle } from "./file-handle.js";
import { DirectoryHandle } from "./directory-handle.js";
import {
  BlockSize,
  BlockItemMaxCount,
  BlockHead,
  BlockNameMaxSize,
  BlockStopBlockIndex,
  BlockOffset,
  MagicNumber,
  SeekWhence,
  FileType,
  FileFsError,
} from "./types.js";
import {
  readUInt32,
  writeUInt32,
  readUInt16,
  writeUInt16,
  fixedNameToString,
  copyName,
  ensureNameFits,
  sliceByteBuffer,
  readExact,
  writeExact,
  normalizeWhence,
  createEntryObject,
} from "./util.js";

const DIRECTORY_ENTRY_SIZE = 25;
const DIRECTORY_BASE_OFFSET = BlockHead + DIRECTORY_ENTRY_SIZE * 2;

function fileFsError(message) {
  return new FileFsError(message);
}

function cloneEntry(entry) {
  return {
    isFile: entry.isFile,
    name: entry.name,
    startBlockIndex: entry.startBlockIndex >>> 0,
    stopBlockIndex: entry.stopBlockIndex >>> 0,
    fileOffset: entry.fileOffset >>> 0,
  };
}

export class FileSystem {
  constructor() {
    this._path = "";
    this._journalPath = "";
    this._fd = null;
    this._pwd = "";
    this._pwdBlockIndex = 0;
    this._tmp = {
      state: 0,
      pwd: "",
      pwdBlockIndex: 0,
      copyFd: null,
      addFd: null,
      copyPath: "",
      addPath: "",
      tempDir: "",
      copySize: 0,
      totalBlockSize: 0,
      unusedBlockHead: 0,
      newTotalBlockSize: 0,
      newUnusedBlockHead: 0,
    };
  }

  static mkfs(imagePath) {
    if (!imagePath) {
      throw fileFsError("FileFS image path is required.");
    }

    const fd = fs.openSync(imagePath, "w+");
    try {
      const superBlock = Buffer.alloc(BlockSize);
      MagicNumber.copy(superBlock, 0);
      writeUInt32(superBlock, 2, 4);
      writeExact(fs, fd, superBlock, 0);

      const rootBlock = Buffer.alloc(BlockSize);
      let k = BlockHead;

      rootBlock[k++] = 0;
      copyName(rootBlock, k, ".");
      k += BlockNameMaxSize;
      writeUInt32(rootBlock, 1, k);
      k += 4;
      writeUInt32(rootBlock, 1, k);
      k += 4;
      writeUInt16(rootBlock, DIRECTORY_BASE_OFFSET, k);
      k += 2;

      rootBlock[k++] = 0;
      copyName(rootBlock, k, "..");

      writeExact(fs, fd, rootBlock, BlockSize);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }

    const journalPath = `${imagePath}-j`;
    if (fs.existsSync(journalPath)) {
      fs.unlinkSync(journalPath);
    }
  }

  get isMounted() {
    return this._fd !== null;
  }

  mount(imagePath) {
    if (!imagePath) {
      throw fileFsError("FileFS image path is required.");
    }

    this.umount();

    const fd = fs.openSync(imagePath, "r+");
    try {
      const block = Buffer.alloc(BlockSize);
      if (!readExact(fs, fd, block, 0)) {
        throw fileFsError("Unable to read FileFS superblock.");
      }
      if (!block.subarray(0, 4).equals(MagicNumber)) {
        throw fileFsError("Invalid FileFS magic number.");
      }
      if (readUInt32(block, 4) < 2) {
        throw fileFsError("Invalid FileFS block count.");
      }

      if (!readExact(fs, fd, block, BlockSize)) {
        throw fileFsError("Unable to read FileFS root directory block.");
      }

      if (block[BlockHead] !== 0) {
        throw fileFsError("Invalid FileFS root '.' entry state.");
      }
      if (fixedNameToString(block, BlockHead + 1) !== ".") {
        throw fileFsError("Invalid FileFS root '.' entry.");
      }

      const dotDotOffset = BlockHead + DIRECTORY_ENTRY_SIZE;
      if (block[dotDotOffset] !== 0) {
        throw fileFsError("Invalid FileFS root '..' entry state.");
      }
      if (fixedNameToString(block, dotDotOffset + 1) !== "..") {
        throw fileFsError("Invalid FileFS root '..' entry.");
      }

      this._fd = fd;
      this._path = imagePath;
      this._journalPath = `${imagePath}-j`;
      this._pwd = "/";
      this._pwdBlockIndex = 1;
      this._recoverJournal();
    } catch (error) {
      fs.closeSync(fd);
      throw error;
    }
  }

  umount() {
    if (this._fd !== null) {
      fs.closeSync(this._fd);
      this._fd = null;
    }

    if (this._journalPath && fs.existsSync(this._journalPath)) {
      fs.unlinkSync(this._journalPath);
    }

    this._journalPath = "";
    this._path = "";
    this._stopTransaction();
    this._pwd = "";
    this._pwdBlockIndex = 0;
  }

  open(filePath, mode) {
    this._ensureMounted();
    if (!filePath) {
      throw fileFsError("File path is required.");
    }
    const byteMode = this._parseMode(mode);
    const { parentBlockIndex, lastName } = this._resolveParentPath(filePath);
    if (!lastName || lastName === "." || lastName === "..") {
      throw fileFsError(`Invalid file path '${filePath}'.`);
    }

    const handle =
      byteMode === 0 || byteMode === 3
        ? this._openRead(lastName, byteMode, parentBlockIndex)
        : byteMode === 1 || byteMode === 4
          ? this._openWrite(lastName, byteMode, parentBlockIndex)
          : this._openAppend(lastName, byteMode, parentBlockIndex);

    if (handle === null) {
      throw fileFsError(`Unable to open '${filePath}' in mode '${mode}'.`);
    }
    return handle;
  }

  read(file, buffer, offset = 0, length = undefined) {
    this._ensureMounted();
    this._ensureOpenFileHandle(file);
    if (file.mode === 1 || file.mode === 2) {
      throw fileFsError("File handle is not readable.");
    }

    const target = sliceByteBuffer(buffer, offset, length);
    if (target.length === 0 || file.posBlockIndex === 0) {
      return 0;
    }

    let totalRead = 0;
    let blockIndex = file.posBlockIndex;
    const block = Buffer.alloc(BlockSize);

    while (totalRead < target.length) {
      if (!this._readBlock(blockIndex, block)) {
        return totalRead;
      }

      const nextIndex = readUInt32(block, 4);
      if (file.posOffset === BlockSize) {
        if (nextIndex === 0) {
          return totalRead;
        }
        blockIndex = nextIndex;
        file.posBlockIndex = blockIndex;
        file.posOffset = BlockHead;
        continue;
      }

      if (blockIndex === file.fileStopBlockIndex) {
        const remainingInFile = file.fileOffset - file.posOffset;
        if (remainingInFile <= 0) {
          return totalRead;
        }
        const count = Math.min(target.length - totalRead, remainingInFile);
        block.copy(target, totalRead, file.posOffset, file.posOffset + count);
        totalRead += count;
        file.posOffset += count;
        file.pos += count;
        file.posBlockIndex = blockIndex;
        return totalRead;
      }

      const remainingInBlock = BlockSize - file.posOffset;
      if (remainingInBlock <= 0) {
        return totalRead;
      }

      const count = Math.min(target.length - totalRead, remainingInBlock);
      block.copy(target, totalRead, file.posOffset, file.posOffset + count);
      totalRead += count;
      file.posOffset += count;
      file.pos += count;
      file.posBlockIndex = blockIndex;

      if (file.posOffset === BlockSize && nextIndex !== 0) {
        blockIndex = nextIndex;
      }
    }

    return totalRead;
  }

  write(file, buffer, offset = 0, length = undefined) {
    this._ensureMounted();
    this._ensureOpenFileHandle(file);
    if (file.mode === 0) {
      throw fileFsError("File handle is not writable.");
    }

    const source = sliceByteBuffer(buffer, offset, length);
    if (source.length === 0) {
      return 0;
    }

    return this._withTransaction(() => {
      let written = 0;
      let nextBlockIndex = 0;
      let posBlock = Buffer.alloc(BlockSize);
      const dirBlock = Buffer.alloc(BlockSize);

      if (file.posBlockIndex === 0) {
        const newBlockIndex = this._genBlockIndex();
        if (newBlockIndex === 0) {
          throw fileFsError("Unable to allocate a FileFS data block.");
        }
        if (!this._writeBlock(newBlockIndex, posBlock)) {
          throw fileFsError("Unable to initialize a FileFS data block.");
        }
        if (!this._readBlock(file.dirBlockIndex, dirBlock)) {
          throw fileFsError("Unable to read FileFS directory entry.");
        }

        writeUInt32(dirBlock, newBlockIndex, file.dirOffset - 10);
        writeUInt32(dirBlock, newBlockIndex, file.dirOffset - 6);
        writeUInt16(dirBlock, BlockHead, file.dirOffset - 2);

        file.fileStartBlockIndex = newBlockIndex;
        file.fileStopBlockIndex = newBlockIndex;
        file.fileOffset = 0;
        file.posBlockIndex = newBlockIndex;
        file.posOffset = BlockHead;
        file.pos = 0;

        if (!this._writeBlock(file.dirBlockIndex, dirBlock)) {
          throw fileFsError("Unable to update FileFS directory entry.");
        }
      } else {
        if (!this._readBlock(file.posBlockIndex, posBlock)) {
          throw fileFsError("Unable to read FileFS data block.");
        }
        nextBlockIndex = readUInt32(posBlock, 4);
      }

      while (written < source.length) {
        let extendedWithNewBlock = false;

        if (file.posOffset === BlockSize) {
          if (nextBlockIndex === 0) {
            const newBlockIndex = this._genBlockIndex();
            if (newBlockIndex === 0) {
              throw fileFsError("Unable to allocate FileFS data block.");
            }

            const newBlock = Buffer.alloc(BlockSize);
            writeUInt32(newBlock, file.posBlockIndex, 8);
            writeUInt32(posBlock, newBlockIndex, 4);

            if (!this._writeBlock(file.posBlockIndex, posBlock)) {
              throw fileFsError("Unable to link FileFS data block.");
            }

            file.posBlockIndex = newBlockIndex;
            file.posOffset = BlockHead;
            posBlock = newBlock;
            nextBlockIndex = 0;
            extendedWithNewBlock = true;
          } else {
            const currentIndex = nextBlockIndex;
            if (!this._readBlock(currentIndex, posBlock)) {
              throw fileFsError("Unable to read next FileFS data block.");
            }
            nextBlockIndex = readUInt32(posBlock, 4);
            file.posBlockIndex = currentIndex;
            file.posOffset = BlockHead;
          }
        }

        const available = BlockSize - file.posOffset;
        const count = Math.min(source.length - written, available);
        source.copy(posBlock, file.posOffset, written, written + count);
        written += count;

        if (!this._writeBlock(file.posBlockIndex, posBlock)) {
          throw fileFsError("Unable to write FileFS data block.");
        }

        file.posOffset += count;
        file.pos += count;

        const extended =
          extendedWithNewBlock ||
          file.fileStopBlockIndex === 0 ||
          (file.posBlockIndex === file.fileStopBlockIndex &&
            file.posOffset > file.fileOffset);

        if (extended) {
          if (!this._readBlock(file.dirBlockIndex, dirBlock)) {
            throw fileFsError("Unable to refresh FileFS directory entry.");
          }
          file.fileStopBlockIndex = file.posBlockIndex;
          file.fileOffset = file.posOffset;
          writeUInt32(dirBlock, file.posBlockIndex, file.dirOffset - 6);
          writeUInt16(dirBlock, file.posOffset, file.dirOffset - 2);
          if (!this._writeBlock(file.dirBlockIndex, dirBlock)) {
            throw fileFsError("Unable to persist FileFS directory entry.");
          }
        }
      }

      return written;
    });
  }

  close(file) {
    if (!(file instanceof FileHandle)) {
      return;
    }
  }

  seek(file, offset, whence) {
    this._ensureMounted();
    this._ensureOpenFileHandle(file);
    if (file.posBlockIndex === 0 || file.fileStartBlockIndex === 0) {
      return false;
    }

    const length = this._getFileLength(
      file.fileStartBlockIndex,
      file.fileStopBlockIndex,
      file.fileOffset,
    );

    let target;
    switch (normalizeWhence(whence)) {
      case SeekWhence.Set:
        if (offset < 0) {
          return false;
        }
        target = offset;
        break;
      case SeekWhence.Cur:
        target = file.pos + offset;
        break;
      case SeekWhence.End:
        if (offset > 0) {
          return false;
        }
        target = length + offset;
        break;
      default:
        return false;
    }

    if (target < 0) {
      target = 0;
    } else if (target > length) {
      target = length;
    }

    let blockIndex = file.fileStartBlockIndex;
    let blockOffset = BlockHead;
    if (target === 0) {
      file.posBlockIndex = blockIndex;
      file.posOffset = blockOffset;
      file.pos = 0;
      return true;
    }

    let remaining = target;
    const block = Buffer.alloc(BlockSize);
    while (true) {
      const blockSize =
        blockIndex === file.fileStopBlockIndex ? file.fileOffset : BlockSize;
      const available = blockSize - blockOffset;
      if (remaining <= available) {
        file.posBlockIndex = blockIndex;
        file.posOffset = blockOffset + remaining;
        file.pos = target;
        return true;
      }

      remaining -= available;
      if (blockIndex === file.fileStopBlockIndex) {
        file.posBlockIndex = blockIndex;
        file.posOffset = file.fileOffset;
        file.pos = length;
        return true;
      }

      if (!this._readBlock(blockIndex, block)) {
        return false;
      }
      blockIndex = readUInt32(block, 4);
      if (blockIndex === 0) {
        file.posBlockIndex = file.fileStopBlockIndex;
        file.posOffset = file.fileOffset;
        file.pos = length;
        return true;
      }
      blockOffset = BlockHead;
    }
  }

  tell(file) {
    this._ensureMounted();
    this._ensureOpenFileHandle(file);
    return file.pos;
  }

  rewind(file) {
    this.seek(file, 0, SeekWhence.Set);
  }

  fileExists(filePath) {
    this._ensureMounted();
    return this._stat(filePath) === 1;
  }

  dirExists(dirPath) {
    this._ensureMounted();
    return this._stat(dirPath) === 2;
  }

  removeFile(filePath) {
    this._ensureMounted();
    if (!filePath) {
      throw fileFsError("File path is required.");
    }
    if (filePath.endsWith("/")) {
      throw fileFsError(`Unable to remove file '${filePath}' (code 5).`);
    }

    const { parentBlockIndex, lastName } = this._resolveParentPath(filePath);
    if (!lastName || lastName === "." || lastName === "..") {
      throw fileFsError(`Unable to remove file '${filePath}' (code 5).`);
    }

    const info = this._readDirectoryEntries(parentBlockIndex);
    const index = info.entries.findIndex((entry) => entry.name === lastName);
    if (index < 0 || !info.entries[index].isFile) {
      throw fileFsError(`Unable to remove file '${filePath}' (code 2).`);
    }

    this._withTransaction(() => {
      const entry = info.entries[index];
      if (entry.startBlockIndex > 0) {
        this._freeChain(entry.startBlockIndex, entry.stopBlockIndex);
      }
      info.entries.splice(index, 1);
      this._rewriteDirectory(parentBlockIndex, info.entries, info.chainIndices);
    });
  }

  rename(fromPath, toPath) {
    this._ensureMounted();
    if (!fromPath || !toPath) {
      throw fileFsError("Source and destination paths are required.");
    }

    const from = this._resolveParentPath(fromPath);
    const to = this._resolveParentPath(toPath);
    if (!from.lastName || from.lastName === "." || from.lastName === "..") {
      throw fileFsError(`Unable to rename '${fromPath}' to '${toPath}' (code 2).`);
    }
    if (!to.lastName || to.lastName === "." || to.lastName === "..") {
      throw fileFsError(`Unable to rename '${fromPath}' to '${toPath}' (code 3).`);
    }

    const fromInfo = this._readDirectoryEntries(from.parentBlockIndex);
    const fromIndex = fromInfo.entries.findIndex((entry) => entry.name === from.lastName);
    if (fromIndex < 0) {
      throw fileFsError(`Unable to rename '${fromPath}' to '${toPath}' (code 4).`);
    }

    const fromEntry = fromInfo.entries[fromIndex];
    if (from.trailingSlash && fromEntry.isFile) {
      throw fileFsError(`Unable to rename '${fromPath}' to '${toPath}' (code 2).`);
    }
    if (to.trailingSlash && fromEntry.isFile) {
      throw fileFsError(`Unable to rename '${fromPath}' to '${toPath}' (code 6).`);
    }

    if (
      from.parentBlockIndex === to.parentBlockIndex &&
      from.lastName === to.lastName &&
      from.trailingSlash === to.trailingSlash
    ) {
      return;
    }

    const toInfo =
      from.parentBlockIndex === to.parentBlockIndex
        ? fromInfo
        : this._readDirectoryEntries(to.parentBlockIndex);
    const destinationExists = toInfo.entries.some((entry) => entry.name === to.lastName);
    if (destinationExists) {
      throw fileFsError(`Unable to rename '${fromPath}' to '${toPath}' (code 5).`);
    }

    this._withTransaction(() => {
      const movedEntry = cloneEntry(fromEntry);
      movedEntry.name = to.lastName;

      if (from.parentBlockIndex === to.parentBlockIndex) {
        fromInfo.entries[fromIndex] = movedEntry;
        this._rewriteDirectory(from.parentBlockIndex, fromInfo.entries, fromInfo.chainIndices);
      } else {
        fromInfo.entries.splice(fromIndex, 1);
        toInfo.entries.push(movedEntry);
        this._rewriteDirectory(from.parentBlockIndex, fromInfo.entries, fromInfo.chainIndices);
        this._rewriteDirectory(to.parentBlockIndex, toInfo.entries, toInfo.chainIndices);

        if (!movedEntry.isFile) {
          const childInfo = this._readDirectoryEntries(movedEntry.startBlockIndex);
          childInfo.entries[1].startBlockIndex = to.parentBlockIndex;
          this._rewriteDirectory(
            movedEntry.startBlockIndex,
            childInfo.entries,
            childInfo.chainIndices,
          );
        }
      }
    });
  }

  move(fromPath, toDirPath) {
    this._ensureMounted();
    if (!fromPath || !toDirPath) {
      throw fileFsError("Source path and destination directory are required.");
    }

    const from = this._resolveParentPath(fromPath);
    const fromInfo = this._readDirectoryEntries(from.parentBlockIndex);
    const fromIndex = fromInfo.entries.findIndex((entry) => entry.name === from.lastName);
    if (fromIndex < 0) {
      throw fileFsError(`Unable to move '${fromPath}' into '${toDirPath}' (code 4).`);
    }

    const fromEntry = fromInfo.entries[fromIndex];
    if (from.trailingSlash && fromEntry.isFile) {
      throw fileFsError(`Unable to move '${fromPath}' into '${toDirPath}' (code 2).`);
    }

    const destination = this._resolveDirectoryPath(toDirPath);
    const toInfo =
      destination.blockIndex === from.parentBlockIndex
        ? fromInfo
        : this._readDirectoryEntries(destination.blockIndex);
    if (toInfo.entries.some((entry) => entry.name === from.lastName)) {
      throw fileFsError(`Unable to move '${fromPath}' into '${toDirPath}' (code 5).`);
    }

    this._withTransaction(() => {
      const movedEntry = cloneEntry(fromEntry);
      fromInfo.entries.splice(fromIndex, 1);
      toInfo.entries.push(movedEntry);
      this._rewriteDirectory(from.parentBlockIndex, fromInfo.entries, fromInfo.chainIndices);
      this._rewriteDirectory(destination.blockIndex, toInfo.entries, toInfo.chainIndices);

      if (!movedEntry.isFile) {
        const childInfo = this._readDirectoryEntries(movedEntry.startBlockIndex);
        childInfo.entries[1].startBlockIndex = destination.blockIndex;
        this._rewriteDirectory(
          movedEntry.startBlockIndex,
          childInfo.entries,
          childInfo.chainIndices,
        );
      }
    });
  }

  copyFile(fromPath, toPath) {
    this._ensureMounted();
    if (!this.fileExists(fromPath)) {
      throw fileFsError(`Source file '${fromPath}' does not exist.`);
    }
    if (this._stat(toPath) !== 0) {
      throw fileFsError(`Destination '${toPath}' already exists.`);
    }

    const source = this.open(fromPath, "r");
    try {
      const destination = this.open(toPath, "w");
      try {
        const buffer = Buffer.alloc(4096);
        while (true) {
          const bytesRead = this.read(source, buffer);
          if (bytesRead === 0) {
            break;
          }
          this.write(destination, buffer, 0, bytesRead);
        }
      } finally {
        destination.close();
      }
    } finally {
      source.close();
    }
  }

  chdir(dirPath = "") {
    this._ensureMounted();
    const resolved = this._resolveDirectoryPath(dirPath);
    if (this._tmp.state === 0) {
      this._pwd = resolved.absolutePath;
      this._pwdBlockIndex = resolved.blockIndex;
    } else {
      this._tmp.pwd = resolved.absolutePath;
      this._tmp.pwdBlockIndex = resolved.blockIndex;
    }
  }

  getcwd() {
    this._ensureMounted();
    return this._currentPwd();
  }

  mkdir(dirPath) {
    this._ensureMounted();
    if (!dirPath) {
      throw fileFsError("Directory path is required.");
    }

    const { parentBlockIndex, lastName } = this._resolveParentPath(dirPath);
    if (!lastName) {
      throw fileFsError(`Unable to create directory '${dirPath}' (code 3).`);
    }

    const parentInfo = this._readDirectoryEntries(parentBlockIndex);
    const existing = parentInfo.entries.find((entry) => entry.name === lastName);
    if (existing) {
      throw fileFsError(
        `Unable to create directory '${dirPath}' (code ${existing.isFile ? 4 : 3}).`,
      );
    }

    this._withTransaction(() => {
      const childBlockIndex = this._genBlockIndex();
      if (childBlockIndex === 0) {
        throw fileFsError(`Unable to create directory '${dirPath}' (code 1).`);
      }

      const childEntries = [
        {
          isFile: false,
          name: ".",
          startBlockIndex: childBlockIndex,
          stopBlockIndex: childBlockIndex,
          fileOffset: DIRECTORY_BASE_OFFSET,
        },
        {
          isFile: false,
          name: "..",
          startBlockIndex: parentBlockIndex,
          stopBlockIndex: 0,
          fileOffset: 0,
        },
      ];

      this._rewriteDirectory(childBlockIndex, childEntries, [childBlockIndex]);
      parentInfo.entries.push({
        isFile: false,
        name: lastName,
        startBlockIndex: childBlockIndex,
        stopBlockIndex: 0,
        fileOffset: 0,
      });
      this._rewriteDirectory(parentBlockIndex, parentInfo.entries, parentInfo.chainIndices);
    });
  }

  rmdir(dirPath) {
    this._ensureMounted();
    if (!dirPath) {
      throw fileFsError("Directory path is required.");
    }

    const { parentBlockIndex, lastName } = this._resolveParentPath(dirPath);
    if (!lastName || lastName === "." || lastName === "..") {
      throw fileFsError(`Unable to remove directory '${dirPath}' (code 1).`);
    }

    const parentInfo = this._readDirectoryEntries(parentBlockIndex);
    const index = parentInfo.entries.findIndex((entry) => entry.name === lastName);
    if (index < 0 || parentInfo.entries[index].isFile) {
      throw fileFsError(`Unable to remove directory '${dirPath}' (code 3).`);
    }

    const entry = parentInfo.entries[index];
    const childInfo = this._readDirectoryEntries(entry.startBlockIndex);
    if (childInfo.entries.length > 2) {
      throw fileFsError(`Unable to remove directory '${dirPath}' (code 2).`);
    }

    this._withTransaction(() => {
      this._freeBlockList(childInfo.chainIndices);
      parentInfo.entries.splice(index, 1);
      this._rewriteDirectory(parentBlockIndex, parentInfo.entries, parentInfo.chainIndices);
    });
  }

  openDir(dirPath = "") {
    this._ensureMounted();
    const resolved = this._resolveDirectoryPath(dirPath);
    const handle = new DirectoryHandle(this, resolved.absolutePath);
    handle.blockIndex = resolved.blockIndex;
    handle.searchIndex = 0;
    if (!this._readBlock(resolved.blockIndex, handle.block)) {
      throw fileFsError(`Unable to open directory '${dirPath}'.`);
    }
    handle.stopBlockIndex = readUInt32(handle.block, BlockStopBlockIndex);
    handle.offset = readUInt16(handle.block, BlockOffset);
    return handle;
  }

  readDir(dir) {
    this._ensureMounted();
    if (!(dir instanceof DirectoryHandle) || dir.isClosed) {
      throw fileFsError("Directory handle is closed.");
    }

    let block = dir.block;
    let k = BlockHead + dir.searchIndex * DIRECTORY_ENTRY_SIZE;
    if (dir.blockIndex === dir.stopBlockIndex && k + 1 >= dir.offset) {
      return null;
    }

    while (true) {
      if (dir.searchIndex >= BlockItemMaxCount) {
        const nextIndex = readUInt32(block, 4);
        if (nextIndex === 0 || !this._readBlock(nextIndex, dir.block)) {
          return null;
        }
        block = dir.block;
        dir.searchIndex = 0;
        dir.blockIndex = nextIndex;
        k = BlockHead;
        continue;
      }

      const state = block[k++];
      let type = (state & 0x01) === 0x01 ? FileType.File : FileType.Directory;
      const name = fixedNameToString(block, k);
      k += BlockNameMaxSize;
      if (name === ".") {
        if (readUInt32(block, k) === 1) {
          type = FileType.Root;
        }
      } else if (name === "..") {
        if (readUInt32(block, k) === 0) {
          type = FileType.Root;
        }
      }
      k += 10;
      dir.searchIndex += 1;
      return createEntryObject(name, type);
    }
  }

  closeDir(dir) {
    if (!(dir instanceof DirectoryHandle)) {
      return;
    }
  }

  begin() {
    this._ensureMounted();
    if (this._tmp.copyFd !== null) {
      this.rollback();
    }
    if (!this._startTransaction(2)) {
      throw fileFsError("Unable to start FileFS transaction.");
    }
    return true;
  }

  commit() {
    this._ensureMounted();
    if (this._tmp.copyFd === null || this._tmp.addFd === null) {
      return true;
    }

    const journalFd = fs.openSync(this._journalPath, "w+");
    try {
      writeExact(fs, journalFd, Buffer.from([0]), null);

      if (
        this._tmp.totalBlockSize !== this._tmp.newTotalBlockSize ||
        this._tmp.unusedBlockHead !== this._tmp.newUnusedBlockHead
      ) {
        const entry = Buffer.alloc(4 + BlockSize);
        MagicNumber.copy(entry, 4);
        writeUInt32(entry, this._tmp.newTotalBlockSize, 8);
        writeUInt32(entry, this._tmp.newUnusedBlockHead, 12);
        writeExact(fs, journalFd, entry, null);
      }

      this._copyJournalEntries(this._tmp.copyFd, journalFd);
      this._copyJournalEntries(this._tmp.addFd, journalFd);

      writeExact(fs, journalFd, Buffer.from([0xff]), 0);
      fs.fsyncSync(journalFd);
    } finally {
      fs.closeSync(journalFd);
    }

    const replayFd = fs.openSync(this._journalPath, "r");
    try {
      const signal = Buffer.alloc(1);
      if (!readExact(fs, replayFd, signal, 0)) {
        throw fileFsError("Unable to read FileFS journal state.");
      }

      const entry = Buffer.alloc(4 + BlockSize);
      let position = 1;
      while (readExact(fs, replayFd, entry, position)) {
        const blockIndex = readUInt32(entry, 0);
        writeExact(fs, this._fd, entry.subarray(4), blockIndex * BlockSize);
        position += entry.length;
      }
    } finally {
      fs.closeSync(replayFd);
    }

    fs.fsyncSync(this._fd);
    if (fs.existsSync(this._journalPath)) {
      fs.unlinkSync(this._journalPath);
    }

    this._pwd = this._tmp.pwd;
    this._pwdBlockIndex = this._tmp.pwdBlockIndex;
    this._stopTransaction();
    return true;
  }

  rollback() {
    if (!this.isMounted) {
      return;
    }
    if (this._journalPath && fs.existsSync(this._journalPath)) {
      fs.unlinkSync(this._journalPath);
    }
    if (this._tmp.copyFd === null) {
      return;
    }
    this._stopTransaction();
  }

  _ensureMounted() {
    if (!this.isMounted) {
      throw fileFsError("FileFS image is not mounted.");
    }
  }

  _ensureOpenFileHandle(file) {
    if (!(file instanceof FileHandle) || file.isClosed) {
      throw fileFsError("File handle is closed.");
    }
  }

  _currentPwd() {
    return this._tmp.state === 0 ? this._pwd : this._tmp.pwd;
  }

  _currentPwdBlockIndex() {
    return this._tmp.state === 0 ? this._pwdBlockIndex : this._tmp.pwdBlockIndex;
  }

  _parseMode(mode) {
    switch (mode) {
      case "r":
        return 0;
      case "w":
        return 1;
      case "a":
        return 2;
      case "r+":
        return 3;
      case "w+":
        return 4;
      case "a+":
        return 5;
      default:
        throw fileFsError(`Unsupported mode '${String(mode)}'.`);
    }
  }

  _splitSegments(input) {
    const value = input ?? "";
    return {
      absolute: value.startsWith("/"),
      trailingSlash: value.length > 0 && value.endsWith("/"),
      segments: value.split("/").filter((segment) => segment.length > 0),
    };
  }

  _appendPathSegment(basePath, segment) {
    if (segment === ".") {
      return basePath;
    }
    if (segment === "..") {
      if (basePath === "/") {
        return "/";
      }
      let trimmed = basePath.endsWith("/") ? basePath.slice(0, -1) : basePath;
      const slash = trimmed.lastIndexOf("/");
      if (slash <= 0) {
        return "/";
      }
      trimmed = trimmed.slice(0, slash);
      return trimmed ? `${trimmed}/` : "/";
    }
    return basePath === "/" ? `/${segment}/` : `${basePath}${segment}/`;
  }

  _resolveDirectoryPath(dirPath = "") {
    const { absolute, segments } = this._splitSegments(dirPath);
    let blockIndex = absolute ? 1 : this._currentPwdBlockIndex();
    let absolutePath = absolute ? "/" : this._currentPwd();

    for (const segment of segments) {
      ensureNameFits(segment);
      const nextIndex = this._findPathBlockIndex(blockIndex, segment);
      if (nextIndex < 1) {
        throw fileFsError(`Directory '${dirPath}' does not exist.`);
      }
      blockIndex = nextIndex;
      absolutePath = this._appendPathSegment(absolutePath, segment);
    }

    return { blockIndex, absolutePath };
  }

  _resolveParentPath(targetPath) {
    if (!targetPath) {
      throw fileFsError("Path is required.");
    }
    const parts = this._splitSegments(targetPath);
    let blockIndex = parts.absolute ? 1 : this._currentPwdBlockIndex();

    if (parts.segments.length === 0) {
      return {
        parentBlockIndex: blockIndex,
        lastName: "",
        trailingSlash: parts.trailingSlash,
      };
    }

    for (const segment of parts.segments.slice(0, -1)) {
      ensureNameFits(segment);
      const nextIndex = this._findPathBlockIndex(blockIndex, segment);
      if (nextIndex < 1) {
        throw fileFsError(`Path '${targetPath}' does not exist.`);
      }
      blockIndex = nextIndex;
    }

    const lastName = parts.segments[parts.segments.length - 1];
    ensureNameFits(lastName);
    return {
      parentBlockIndex: blockIndex,
      lastName,
      trailingSlash: parts.trailingSlash,
    };
  }

  _stat(targetPath) {
    if (!targetPath) {
      return 0;
    }
    const parts = this._splitSegments(targetPath);
    let blockIndex = parts.absolute ? 1 : this._currentPwdBlockIndex();

    if (parts.segments.length === 0) {
      return 2;
    }

    for (const segment of parts.segments.slice(0, -1)) {
      if (Buffer.byteLength(segment, "utf8") > BlockNameMaxSize) {
        return 0;
      }
      blockIndex = this._findPathBlockIndex(blockIndex, segment);
      if (blockIndex < 1) {
        return 0;
      }
    }

    const lastName = parts.segments[parts.segments.length - 1];
    if (Buffer.byteLength(lastName, "utf8") > BlockNameMaxSize) {
      return 0;
    }
    const entry = this._findDirectoryEntry(blockIndex, lastName);
    if (!entry) {
      return 0;
    }
    return entry.isFile ? 1 : 2;
  }

  _openRead(lastName, mode, parentBlockIndex) {
    const location = this._findDirectoryEntryLocation(parentBlockIndex, lastName);
    if (!location || !location.entry.isFile) {
      return null;
    }

    const handle = new FileHandle(this);
    handle.mode = mode;
    handle.dirBlockIndex = location.blockIndex;
    handle.dirOffset = location.itemEndOffset;
    handle.fileStartBlockIndex = location.entry.startBlockIndex;
    handle.fileStopBlockIndex = location.entry.stopBlockIndex;
    handle.fileOffset = location.entry.fileOffset;
    handle.posBlockIndex = location.entry.startBlockIndex;
    handle.posOffset = BlockHead;
    handle.pos = 0;
    return handle;
  }

  _openWrite(lastName, mode, parentBlockIndex) {
    const handle = this._withTransaction(() => {
      const info = this._readDirectoryEntries(parentBlockIndex);
      const index = info.entries.findIndex((entry) => entry.name === lastName);

      if (index >= 0) {
        if (!info.entries[index].isFile) {
          throw fileFsError(`'${lastName}' is a directory.`);
        }
        const entry = info.entries[index];
        if (entry.startBlockIndex > 0) {
          this._freeChain(entry.startBlockIndex, entry.stopBlockIndex);
        }
        entry.startBlockIndex = 0;
        entry.stopBlockIndex = 0;
        entry.fileOffset = 0;
      } else {
        info.entries.push({
          isFile: true,
          name: lastName,
          startBlockIndex: 0,
          stopBlockIndex: 0,
          fileOffset: 0,
        });
      }

      this._rewriteDirectory(parentBlockIndex, info.entries, info.chainIndices);
      const location = this._findDirectoryEntryLocation(parentBlockIndex, lastName);
      if (!location) {
        throw fileFsError(`Unable to create '${lastName}'.`);
      }

      const file = new FileHandle(this);
      file.mode = mode;
      file.dirBlockIndex = location.blockIndex;
      file.dirOffset = location.itemEndOffset;
      return file;
    });

    return handle;
  }

  _openAppend(lastName, mode, parentBlockIndex) {
    const handle = this._withTransaction(() => {
      const info = this._readDirectoryEntries(parentBlockIndex);
      let entry = info.entries.find((item) => item.name === lastName);
      if (!entry) {
        entry = {
          isFile: true,
          name: lastName,
          startBlockIndex: 0,
          stopBlockIndex: 0,
          fileOffset: 0,
        };
        info.entries.push(entry);
        this._rewriteDirectory(parentBlockIndex, info.entries, info.chainIndices);
      } else if (!entry.isFile) {
        throw fileFsError(`'${lastName}' is a directory.`);
      }

      const location = this._findDirectoryEntryLocation(parentBlockIndex, lastName);
      if (!location) {
        throw fileFsError(`Unable to open '${lastName}' for append.`);
      }

      const file = new FileHandle(this);
      file.mode = mode;
      file.dirBlockIndex = location.blockIndex;
      file.dirOffset = location.itemEndOffset;
      file.fileStartBlockIndex = location.entry.startBlockIndex;
      file.fileStopBlockIndex = location.entry.stopBlockIndex;
      file.fileOffset = location.entry.fileOffset;
      file.posBlockIndex = location.entry.stopBlockIndex;
      file.posOffset = location.entry.fileOffset;
      file.pos = this._getFileLength(
        location.entry.startBlockIndex,
        location.entry.stopBlockIndex,
        location.entry.fileOffset,
      );
      return file;
    });

    return handle;
  }

  _findPathBlockIndex(blockIndex, name) {
    const entry = this._findDirectoryEntry(blockIndex, name);
    if (!entry || entry.isFile) {
      return 0;
    }
    return entry.startBlockIndex;
  }

  _findDirectoryEntry(blockIndex, name) {
    const location = this._findDirectoryEntryLocation(blockIndex, name);
    return location ? location.entry : null;
  }

  _findDirectoryEntryLocation(blockIndex, name) {
    const block = Buffer.alloc(BlockSize);
    if (!this._readBlock(blockIndex, block)) {
      return null;
    }

    const stopBlockIndex = readUInt32(block, BlockStopBlockIndex);
    const offset = readUInt16(block, BlockOffset);
    let index = blockIndex;
    while (true) {
      let k = BlockHead;
      for (let i = 0; i < BlockItemMaxCount; i += 1) {
        const state = block[k++];
        const entryName = fixedNameToString(block, k);
        k += BlockNameMaxSize;
        if (entryName !== name) {
          k += 10;
          if (index === stopBlockIndex && k + 1 >= offset) {
            return null;
          }
          continue;
        }

        return {
          blockIndex: index,
          itemEndOffset: k + 10,
          entry: {
            isFile: (state & 0x01) === 0x01,
            name: entryName,
            startBlockIndex: readUInt32(block, k),
            stopBlockIndex: readUInt32(block, k + 4),
            fileOffset: readUInt16(block, k + 8),
          },
        };
      }

      index = readUInt32(block, 4);
      if (index === 0 || !this._readBlock(index, block)) {
        return null;
      }
    }
  }

  _readDirectoryEntries(headBlockIndex) {
    const head = Buffer.alloc(BlockSize);
    if (!this._readBlock(headBlockIndex, head)) {
      throw fileFsError(`Unable to read directory block ${headBlockIndex}.`);
    }

    const stopBlockIndex = readUInt32(head, BlockStopBlockIndex);
    const offset = readUInt16(head, BlockOffset);
    const entries = [];
    const chainIndices = [];
    let block = Buffer.from(head);
    let index = headBlockIndex;

    while (true) {
      chainIndices.push(index);
      let k = BlockHead;
      while (k + 1 < BlockSize) {
        if (index === stopBlockIndex && k + 1 >= offset) {
          return { entries, chainIndices, stopBlockIndex, offset };
        }
        entries.push({
          isFile: (block[k] & 0x01) === 0x01,
          name: fixedNameToString(block, k + 1),
          startBlockIndex: readUInt32(block, k + 1 + BlockNameMaxSize),
          stopBlockIndex: readUInt32(block, k + 1 + BlockNameMaxSize + 4),
          fileOffset: readUInt16(block, k + 1 + BlockNameMaxSize + 8),
        });
        k += DIRECTORY_ENTRY_SIZE;
      }

      if (index === stopBlockIndex) {
        return { entries, chainIndices, stopBlockIndex, offset };
      }

      const nextIndex = readUInt32(block, 4);
      if (nextIndex === 0) {
        return { entries, chainIndices, stopBlockIndex, offset };
      }
      block = Buffer.alloc(BlockSize);
      if (!this._readBlock(nextIndex, block)) {
        throw fileFsError(`Unable to read directory block ${nextIndex}.`);
      }
      index = nextIndex;
    }
  }

  _rewriteDirectory(headBlockIndex, entries, existingChainIndices = null) {
    const cloned = entries.map(cloneEntry);
    if (cloned.length < 2 || cloned[0].name !== "." || cloned[1].name !== "..") {
      throw fileFsError("Directory entries must begin with '.' and '..'.");
    }

    let chainIndices = existingChainIndices ? [...existingChainIndices] : null;
    if (!chainIndices) {
      chainIndices = this._readDirectoryEntries(headBlockIndex).chainIndices;
    }

    const requiredBlocks = Math.max(1, Math.ceil(cloned.length / BlockItemMaxCount));
    while (chainIndices.length < requiredBlocks) {
      const newBlockIndex = this._genBlockIndex();
      if (newBlockIndex === 0) {
        throw fileFsError("Unable to allocate directory block.");
      }
      chainIndices.push(newBlockIndex);
    }

    const extraBlocks = chainIndices.slice(requiredBlocks);
    chainIndices = chainIndices.slice(0, requiredBlocks);
    if (extraBlocks.length > 0) {
      this._freeBlockList(extraBlocks);
    }

    const stopBlockIndex = chainIndices[chainIndices.length - 1];
    const entriesInLastBlock = cloned.length % BlockItemMaxCount;
    const finalOffset =
      entriesInLastBlock === 0 ? BlockSize : BlockHead + entriesInLastBlock * DIRECTORY_ENTRY_SIZE;

    cloned[0].isFile = false;
    cloned[0].name = ".";
    cloned[0].startBlockIndex = headBlockIndex;
    cloned[0].stopBlockIndex = stopBlockIndex;
    cloned[0].fileOffset = finalOffset;
    cloned[1].isFile = false;
    cloned[1].name = "..";

    for (let blockSlot = 0; blockSlot < chainIndices.length; blockSlot += 1) {
      const blockIndex = chainIndices[blockSlot];
      const block = Buffer.alloc(BlockSize);
      const nextIndex = chainIndices[blockSlot + 1] ?? 0;
      const prevIndex = chainIndices[blockSlot - 1] ?? 0;
      writeUInt32(block, nextIndex, 4);
      writeUInt32(block, prevIndex, 8);

      const start = blockSlot * BlockItemMaxCount;
      const end = Math.min(start + BlockItemMaxCount, cloned.length);
      let k = BlockHead;
      for (let i = start; i < end; i += 1) {
        const entry = cloned[i];
        block[k++] = entry.isFile ? 1 : 0;
        copyName(block, k, entry.name);
        k += BlockNameMaxSize;
        writeUInt32(block, entry.startBlockIndex, k);
        k += 4;
        writeUInt32(block, entry.stopBlockIndex, k);
        k += 4;
        writeUInt16(block, entry.fileOffset, k);
        k += 2;
      }

      if (!this._writeBlock(blockIndex, block)) {
        throw fileFsError(`Unable to write directory block ${blockIndex}.`);
      }
    }
  }

  _getFileLength(startBlockIndex, stopBlockIndex, fileOffset) {
    if (startBlockIndex === 0) {
      return 0;
    }

    const block = Buffer.alloc(BlockSize);
    let length = 0;
    let index = startBlockIndex;
    while (index !== 0) {
      if (index === stopBlockIndex) {
        length += fileOffset - BlockHead;
        break;
      }
      length += BlockSize - BlockHead;
      if (!this._readBlock(index, block)) {
        break;
      }
      index = readUInt32(block, 4);
    }
    return length;
  }

  _getChainIndices(startBlockIndex, stopBlockIndex = null) {
    if (startBlockIndex === 0) {
      return [];
    }

    const block = Buffer.alloc(BlockSize);
    const indices = [];
    let index = startBlockIndex;
    while (index !== 0) {
      indices.push(index);
      if (!this._readBlock(index, block)) {
        break;
      }
      if (stopBlockIndex !== null && index === stopBlockIndex) {
        break;
      }
      index = readUInt32(block, 4);
    }
    return indices;
  }

  _freeChain(startBlockIndex, stopBlockIndex) {
    this._freeBlockList(this._getChainIndices(startBlockIndex, stopBlockIndex));
  }

  _freeBlockList(blockIndices) {
    for (const blockIndex of blockIndices) {
      this._removeBlock(blockIndex);
    }
  }

  _withTransaction(work) {
    const autoCommit = this._tmp.state === 0;
    if (autoCommit && !this._startTransaction(1)) {
      throw fileFsError("Unable to start FileFS transaction.");
    }
    try {
      const result = work();
      if (autoCommit) {
        this.commit();
      }
      return result;
    } catch (error) {
      if (autoCommit) {
        this._stopTransaction();
      }
      throw error;
    }
  }

  _startTransaction(state) {
    if (state === 0) {
      return false;
    }
    if (this._tmp.state !== 0) {
      this._stopTransaction();
    }

    const header = Buffer.alloc(12);
    if (!readExact(fs, this._fd, header, 0)) {
      return false;
    }

    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "filefs-"));
    const copyPath = path.join(tempDir, "copy.bin");
    const addPath = path.join(tempDir, "add.bin");

    this._tmp = {
      state,
      pwd: this._pwd,
      pwdBlockIndex: this._pwdBlockIndex,
      copyFd: fs.openSync(copyPath, "w+"),
      addFd: fs.openSync(addPath, "w+"),
      copyPath,
      addPath,
      tempDir,
      copySize: 0,
      totalBlockSize: readUInt32(header, 4),
      unusedBlockHead: readUInt32(header, 8),
      newTotalBlockSize: readUInt32(header, 4),
      newUnusedBlockHead: readUInt32(header, 8),
    };
    return true;
  }

  _stopTransaction() {
    const { copyFd, addFd, copyPath, addPath, tempDir } = this._tmp;
    if (copyFd !== null) {
      fs.closeSync(copyFd);
    }
    if (addFd !== null) {
      fs.closeSync(addFd);
    }
    if (copyPath && fs.existsSync(copyPath)) {
      fs.unlinkSync(copyPath);
    }
    if (addPath && fs.existsSync(addPath)) {
      fs.unlinkSync(addPath);
    }
    if (tempDir && fs.existsSync(tempDir)) {
      fs.rmdirSync(tempDir);
    }

    this._tmp = {
      state: 0,
      pwd: "",
      pwdBlockIndex: 0,
      copyFd: null,
      addFd: null,
      copyPath: "",
      addPath: "",
      tempDir: "",
      copySize: 0,
      totalBlockSize: 0,
      unusedBlockHead: 0,
      newTotalBlockSize: 0,
      newUnusedBlockHead: 0,
    };
  }

  _recoverJournal() {
    if (!this._journalPath || !fs.existsSync(this._journalPath)) {
      return;
    }

    const journalFd = fs.openSync(this._journalPath, "r");
    try {
      const signal = Buffer.alloc(1);
      if (!readExact(fs, journalFd, signal, 0) || signal[0] !== 0xff) {
        return;
      }

      const entry = Buffer.alloc(4 + BlockSize);
      let position = 1;
      while (readExact(fs, journalFd, entry, position)) {
        const blockIndex = readUInt32(entry, 0);
        writeExact(fs, this._fd, entry.subarray(4), blockIndex * BlockSize);
        position += entry.length;
      }
      fs.fsyncSync(this._fd);
    } finally {
      fs.closeSync(journalFd);
      fs.unlinkSync(this._journalPath);
    }
  }

  _copyJournalEntries(fromFd, toFd) {
    const entry = Buffer.alloc(4 + BlockSize);
    let position = 0;
    while (readExact(fs, fromFd, entry, position)) {
      writeExact(fs, toFd, entry, null);
      position += entry.length;
    }
  }

  _genBlockIndex() {
    const block = Buffer.alloc(BlockSize);
    if (this._tmp.newUnusedBlockHead > 0) {
      const blockIndex = this._tmp.newUnusedBlockHead;
      if (!this._readBlock(blockIndex, block)) {
        return 0;
      }
      this._tmp.newUnusedBlockHead = readUInt32(block, 4);
      return blockIndex;
    }

    const blockIndex = this._tmp.newTotalBlockSize;
    const addIndex = blockIndex - this._tmp.totalBlockSize;
    const entry = Buffer.alloc(4 + BlockSize);
    writeUInt32(entry, blockIndex, 0);
    writeExact(fs, this._tmp.addFd, entry, addIndex * entry.length);
    this._tmp.newTotalBlockSize += 1;
    return blockIndex;
  }

  _readBlock(blockIndex, block) {
    const position = blockIndex * BlockSize;
    const head = Buffer.alloc(4);
    if (!readExact(fs, this._fd, head, position)) {
      if (
        this._tmp.state === 0 ||
        blockIndex < this._tmp.totalBlockSize ||
        this._tmp.addFd === null
      ) {
        return false;
      }

      const addIndex = blockIndex - this._tmp.totalBlockSize;
      return readExact(fs, this._tmp.addFd, block, addIndex * (4 + BlockSize) + 4);
    }

    if (this._tmp.state === 0 || this._tmp.copyFd === null) {
      head.copy(block, 0);
      return readExact(fs, this._fd, block.subarray(4), position + 4);
    }

    const cpIndex = readUInt32(head, 0);
    const copyPosition = cpIndex * (4 + BlockSize);
    const originalIndex = Buffer.alloc(4);
    if (!readExact(fs, this._tmp.copyFd, originalIndex, copyPosition)) {
      head.copy(block, 0);
      return readExact(fs, this._fd, block.subarray(4), position + 4);
    }
    if (readUInt32(originalIndex, 0) !== blockIndex) {
      head.copy(block, 0);
      return readExact(fs, this._fd, block.subarray(4), position + 4);
    }
    return readExact(fs, this._tmp.copyFd, block, copyPosition + 4);
  }

  _writeBlock(blockIndex, block) {
    if (this._tmp.state === 0 || this._tmp.copyFd === null || this._tmp.addFd === null) {
      return false;
    }

    const position = blockIndex * BlockSize;
    const head = Buffer.alloc(4);
    if (!readExact(fs, this._fd, head, position)) {
      if (blockIndex < this._tmp.totalBlockSize) {
        return false;
      }
      const addIndex = blockIndex - this._tmp.totalBlockSize;
      writeExact(fs, this._tmp.addFd, block, addIndex * (4 + BlockSize) + 4);
      return true;
    }

    let cpIndex = readUInt32(head, 0);
    const copyPosition = cpIndex * (4 + BlockSize);
    const copyIndex = Buffer.alloc(4);
    if (
      !readExact(fs, this._tmp.copyFd, copyIndex, copyPosition) ||
      readUInt32(copyIndex, 0) !== blockIndex
    ) {
      cpIndex = this._tmp.copySize;
      const newPosition = cpIndex * (4 + BlockSize);
      writeUInt32(copyIndex, blockIndex, 0);
      writeExact(fs, this._tmp.copyFd, copyIndex, newPosition);
      writeExact(fs, this._tmp.copyFd, block, newPosition + 4);

      writeUInt32(copyIndex, cpIndex, 0);
      writeExact(fs, this._fd, copyIndex, position);
      this._tmp.copySize += 1;
      return true;
    }

    writeExact(fs, this._tmp.copyFd, block, copyPosition + 4);
    return true;
  }

  _removeBlock(blockIndex) {
    if (this._tmp.state === 0 || this._tmp.copyFd === null || this._tmp.addFd === null) {
      return false;
    }

    const position = blockIndex * BlockSize;
    const head = Buffer.alloc(4);
    if (!readExact(fs, this._fd, head, position)) {
      if (blockIndex < this._tmp.totalBlockSize) {
        return false;
      }
      const addIndex = blockIndex - this._tmp.totalBlockSize;
      const nextFree = Buffer.alloc(4);
      writeUInt32(nextFree, this._tmp.newUnusedBlockHead, 0);
      writeExact(fs, this._tmp.addFd, nextFree, addIndex * (4 + BlockSize) + 8);
      this._tmp.newUnusedBlockHead = blockIndex;
      return true;
    }

    let cpIndex = readUInt32(head, 0);
    const copyPosition = cpIndex * (4 + BlockSize);
    const copyIndex = Buffer.alloc(4);
    if (
      !readExact(fs, this._tmp.copyFd, copyIndex, copyPosition) ||
      readUInt32(copyIndex, 0) !== blockIndex
    ) {
      cpIndex = this._tmp.copySize;
      const newPosition = cpIndex * (4 + BlockSize);
      const freeBlock = Buffer.alloc(BlockSize);
      writeUInt32(freeBlock, this._tmp.newUnusedBlockHead, 4);

      writeUInt32(copyIndex, blockIndex, 0);
      writeExact(fs, this._tmp.copyFd, copyIndex, newPosition);
      writeExact(fs, this._tmp.copyFd, freeBlock, newPosition + 4);

      writeUInt32(copyIndex, cpIndex, 0);
      writeExact(fs, this._fd, copyIndex, position);
      this._tmp.copySize += 1;
      this._tmp.newUnusedBlockHead = blockIndex;
      return true;
    }

    const nextFree = Buffer.alloc(4);
    writeUInt32(nextFree, this._tmp.newUnusedBlockHead, 0);
    writeExact(fs, this._tmp.copyFd, nextFree, copyPosition + 8);
    this._tmp.newUnusedBlockHead = blockIndex;
    return true;
  }
}
