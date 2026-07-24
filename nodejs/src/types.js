export const BlockSize = 512;
export const BlockItemMaxCount = 20;
export const BlockHead = 12;
export const BlockNameMaxSize = 14;
export const BlockStartBlockIndex = 27;
export const BlockStopBlockIndex = 31;
export const BlockOffset = 35;

export const MagicNumber = Buffer.from([0x78, 0x11, 0x45, 0x14]);

export const SeekWhence = Object.freeze({
  Set: 0,
  Cur: 1,
  End: 2,
});

export const FileType = Object.freeze({
  File: 0,
  Directory: 1,
  Root: 2,
});

export class FileFsError extends Error {
  constructor(message) {
    super(message);
    this.name = "FileFsError";
  }
}
