import { BlockSize } from "./types.js";

export class DirectoryHandle {
  constructor(owner, absolutePath = "/") {
    this._owner = owner;
    this.absolutePath = absolutePath;
    this.block = Buffer.alloc(BlockSize);
    this.searchIndex = 0;
    this.blockIndex = 0;
    this.stopBlockIndex = 0;
    this.offset = 0;
  }

  get isClosed() {
    return this._owner === null;
  }

  close() {
    if (this._owner === null) {
      return;
    }
    const owner = this._owner;
    this._owner = null;
    owner.closeDir(this);
  }
}
