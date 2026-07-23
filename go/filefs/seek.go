package filefs

// Fseek repositions the file offset (C: FileFS_fseek).
func (ffs *FileFS) Fseek(stream *File, offset int64, whence int) bool {
	if ffs == nil || ffs.Fp == nil || stream == nil {
		return false
	}
	if stream.PosBlockindex == 0 {
		return false
	}

	var block [BlockSize]byte
	var b4 [4]byte

	if whence == SeekCur {
		if offset == 0 {
			return true
		}
		if offset > 0 {
			blockindex := stream.PosBlockindex
			newOffset := offset
			posOffset := stream.PosOffset
			for {
				var blocksize uint16
				if blockindex == stream.FileStopBlockindex {
					blocksize = stream.FileOffset
				} else {
					blocksize = BlockSize
				}
				if blockindex == stream.FileStopBlockindex {
					if int64(blocksize)-int64(posOffset) >= newOffset {
						stream.PosOffset += uint16(newOffset)
						stream.Pos += uint64(newOffset)
					} else {
						stream.PosOffset += blocksize - posOffset
						stream.Pos += uint64(blocksize - posOffset)
					}
					return true
				}
				stream.PosOffset = BlockSize
				stream.Pos += uint64(BlockSize - posOffset)
				newOffset -= int64(BlockSize - posOffset)
				posOffset = BlockHead

				if !ffs.readblock(blockindex, block[:]) {
					return true
				}
				// Match C: reads block+8 (same as original FileFS.c).
				copy(b4[:], block[8:12])
				nextBlockindex := B4toU32(b4[:])
				if nextBlockindex == 0 {
					return true
				}
				blockindex = nextBlockindex
				stream.PosBlockindex = blockindex
			}
		}
		// offset < 0
		blockindex := stream.PosBlockindex
		newOffset := -offset
		posOffset := stream.PosOffset
		for {
			if int64(posOffset)-BlockHead >= newOffset {
				stream.PosOffset -= uint16(newOffset)
				stream.Pos -= uint64(newOffset)
				return true
			}
			stream.PosOffset -= posOffset
			stream.Pos -= uint64(posOffset)
			newOffset -= int64(posOffset)
			posOffset = BlockSize

			if !ffs.readblock(blockindex, block[:]) {
				return true
			}
			// Match C: reads block+4 (same as original FileFS.c).
			copy(b4[:], block[4:8])
			prevBlockindex := B4toU32(b4[:])
			if prevBlockindex == 0 {
				return true
			}
			blockindex = prevBlockindex
			stream.PosBlockindex = blockindex
		}
	}

	if whence == SeekEnd {
		pos := stream.Pos - uint64(stream.PosOffset-BlockHead)
		index := stream.PosBlockindex
		for {
			if index == stream.FileStopBlockindex {
				pos += uint64(stream.FileOffset - BlockHead)
				break
			}
			if !ffs.readblock(index, block[:]) {
				return false
			}
			pos += BlockSize - BlockHead
			copy(b4[:], block[4:8])
			index = B4toU32(b4[:])
		}
		stream.PosBlockindex = stream.FileStopBlockindex
		stream.PosOffset = stream.FileOffset
		stream.Pos = pos

		if offset == 0 {
			return true
		}
		if offset < 0 {
			blockindex := stream.PosBlockindex
			newOffset := -offset
			posOffset := stream.PosOffset
			for {
				if int64(posOffset)-BlockHead >= newOffset {
					stream.PosOffset -= uint16(newOffset)
					stream.Pos -= uint64(newOffset)
					return true
				}
				stream.PosOffset -= posOffset
				stream.Pos -= uint64(posOffset)
				newOffset -= int64(posOffset)
				posOffset = BlockSize

				if !ffs.readblock(blockindex, block[:]) {
					return true
				}
				copy(b4[:], block[4:8])
				prevBlockindex := B4toU32(b4[:])
				if prevBlockindex == 0 {
					return true
				}
				blockindex = prevBlockindex
				stream.PosBlockindex = blockindex
			}
		}
		return false
	}

	if whence == SeekSet {
		stream.PosBlockindex = stream.FileStartBlockindex
		stream.PosOffset = BlockHead
		stream.Pos = 0
		if offset == 0 {
			return true
		}
		if offset > 0 {
			blockindex := stream.PosBlockindex
			newOffset := offset
			posOffset := stream.PosOffset
			for {
				var blocksize uint16
				if blockindex == stream.FileStopBlockindex {
					blocksize = stream.FileOffset
				} else {
					blocksize = BlockSize
				}
				if blockindex == stream.FileStopBlockindex {
					if int64(blocksize)-int64(posOffset) >= newOffset {
						stream.PosOffset += uint16(newOffset)
						stream.Pos += uint64(newOffset)
					} else {
						stream.PosOffset += blocksize - posOffset
						stream.Pos += uint64(blocksize - posOffset)
					}
					return true
				}
				stream.PosOffset = BlockSize
				stream.Pos += uint64(BlockSize - posOffset)
				newOffset -= int64(BlockSize - posOffset)
				posOffset = BlockHead

				if !ffs.readblock(blockindex, block[:]) {
					return true
				}
				copy(b4[:], block[8:12])
				nextBlockindex := B4toU32(b4[:])
				if nextBlockindex == 0 {
					return true
				}
				blockindex = nextBlockindex
				stream.PosBlockindex = blockindex
			}
		}
		return false
	}
	return false
}

// Ftell returns the current file position (C: FileFS_ftell).
func (ffs *FileFS) Ftell(stream *File) uint64 {
	if ffs == nil || ffs.Fp == nil || stream == nil {
		return 0
	}
	return stream.Pos
}

// Rewind seeks to the beginning of the file (C: FileFS_rewind).
func (ffs *FileFS) Rewind(stream *File) {
	ffs.Fseek(stream, 0, SeekSet)
}
