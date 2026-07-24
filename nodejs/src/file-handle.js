export class FileHandle {
  constructor(owner) {
    this._owner = owner;
    this.mode = 0;
    this.dirBlockIndex = 0;
    this.dirOffset = 0;
    this.fileStartBlockIndex = 0;
    this.fileStopBlockIndex = 0;
    this.fileOffset = 0;
    this.posBlockIndex = 0;
    this.posOffset = 0;
    this.pos = 0;
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
    owner.close(this);
  }
}
