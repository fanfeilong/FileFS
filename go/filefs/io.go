package filefs

// Fread reads up to size*nmemb bytes into ptr (C: FileFS_fread).
// Returns number of elements successfully read (with size=1, byte count).
func (ffs *FileFS) Fread(ptr []byte, size, nmemb int, stream *File) int {
	if ffs == nil || ffs.Fp == nil || stream == nil {
		return 0
	}
	if stream.Mode == 1 || stream.Mode == 2 {
		return 0
	}
	if stream.PosBlockindex == 0 {
		return 0
	}

	wannasize := size * nmemb
	k := 0
	var block [BlockSize]byte
	blockindex := stream.PosBlockindex
	var b4 [4]byte

	for {
		if !ffs.readblock(blockindex, block[:]) {
			return 0
		}
		copy(b4[:], block[4:8])
		nextindex := B4toU32(b4[:])

		if stream.PosOffset == BlockSize {
			stream.PosBlockindex = blockindex
			stream.PosOffset = BlockHead
		}

		if blockindex == stream.FileStopBlockindex {
			n := int(stream.FileOffset) - int(stream.PosOffset)
			if n <= 0 {
				return k
			}
			if wannasize-k < n {
				n = wannasize - k
			}
			copy(ptr[k:k+n], block[stream.PosOffset:int(stream.PosOffset)+n])
			k += n
			stream.PosBlockindex = blockindex
			stream.PosOffset += uint16(n)
			stream.Pos += uint64(n)
			return k
		}

		n := BlockSize - int(stream.PosOffset)
		if n <= 0 {
			return k
		}
		if wannasize-k < n {
			n = wannasize - k
		}
		copy(ptr[k:k+n], block[stream.PosOffset:int(stream.PosOffset)+n])
		k += n
		stream.PosBlockindex = blockindex
		stream.PosOffset += uint16(n)
		stream.Pos += uint64(n)
		if k >= wannasize {
			return k
		}

		blockindex = nextindex
		if nextindex == 0 {
			return k
		}
	}
}

// Fwrite writes size*nmemb bytes from ptr (C: FileFS_fwrite).
func (ffs *FileFS) Fwrite(ptr []byte, size, nmemb int, stream *File) int {
	if ffs == nil || ffs.Fp == nil || stream == nil {
		return 0
	}
	if stream.Mode == 0 {
		return 0
	}

	wannasize := size * nmemb
	if wannasize <= 0 {
		return 0
	}
	cut := 0
	var newBlock [BlockSize]byte
	var posBlock [BlockSize]byte
	var dirBlock [BlockSize]byte
	var b4 [4]byte
	var b2 [2]byte
	var nextBlockindex uint32

	if ffs.Tmp.State == 0 {
		ffs.tmpstart(1)
	}

	if stream.PosBlockindex == 0 {
		newBlockindex := ffs.genblockindex()
		if newBlockindex == 0 {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 0
		}
		for i := range posBlock {
			posBlock[i] = 0
		}
		if !ffs.writeblock(newBlockindex, posBlock[:]) {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 0
		}
		if !ffs.readblock(stream.DirBlockindex, dirBlock[:]) {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 0
		}
		U32toB4(newBlockindex, b4[:])
		copy(dirBlock[stream.DirOffset-10:], b4[:])
		copy(dirBlock[stream.DirOffset-6:], b4[:])
		off := uint16(BlockHead)
		U16toB2(off, b2[:])
		copy(dirBlock[stream.DirOffset-2:], b2[:])
		stream.FileStartBlockindex = newBlockindex
		stream.FileStopBlockindex = newBlockindex
		stream.FileOffset = 0
		stream.PosBlockindex = newBlockindex
		stream.PosOffset = BlockHead
		stream.Pos = 0
		if !ffs.writeblock(stream.DirBlockindex, dirBlock[:]) {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 0
		}
		nextBlockindex = 0
	} else {
		if !ffs.readblock(stream.PosBlockindex, posBlock[:]) {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 0
		}
		copy(b4[:], posBlock[4:8])
		nextBlockindex = B4toU32(b4[:])
	}

	for {
		if stream.PosOffset == BlockSize {
			if nextBlockindex == 0 {
				newBlockindex := ffs.genblockindex()
				if newBlockindex == 0 {
					if ffs.Tmp.State == 1 {
						ffs.tmpstop()
					}
					return 0
				}
				for i := range newBlock {
					newBlock[i] = 0
				}
				U32toB4(stream.PosBlockindex, b4[:])
				copy(newBlock[8:], b4[:])
				U32toB4(newBlockindex, b4[:])
				copy(posBlock[4:], b4[:])
				if !ffs.writeblock(stream.PosBlockindex, posBlock[:]) {
					if ffs.Tmp.State == 1 {
						ffs.tmpstop()
					}
					return 0
				}
				stream.PosBlockindex = newBlockindex
				stream.PosOffset = BlockHead
				copy(posBlock[:], newBlock[:])
				nextBlockindex = 0
			} else {
				if !ffs.readblock(nextBlockindex, posBlock[:]) {
					if ffs.Tmp.State == 1 {
						ffs.tmpstop()
					}
					return 0
				}
				copy(b4[:], posBlock[4:8])
				nextBlockindex = B4toU32(b4[:])
				stream.PosBlockindex = nextBlockindex
				stream.PosOffset = BlockHead
			}
		}

		avail := BlockSize - int(stream.PosOffset)
		if wannasize-cut <= avail {
			n := wannasize - cut
			copy(posBlock[stream.PosOffset:int(stream.PosOffset)+n], ptr[cut:cut+n])
			cut += n
			if !ffs.writeblock(stream.PosBlockindex, posBlock[:]) {
				if ffs.Tmp.State == 1 {
					ffs.tmpstop()
				}
				return 0
			}
			stream.PosOffset += uint16(n)
			stream.Pos += uint64(n)

			flag := false
			if stream.PosBlockindex > stream.FileStopBlockindex {
				flag = true
			} else if stream.PosBlockindex == stream.FileStopBlockindex && stream.PosOffset > stream.FileOffset {
				flag = true
			}
			if flag {
				if !ffs.readblock(stream.DirBlockindex, dirBlock[:]) {
					if ffs.Tmp.State == 1 {
						ffs.tmpstop()
					}
					return 0
				}
				stream.FileStopBlockindex = stream.PosBlockindex
				stream.FileOffset = stream.PosOffset
				U32toB4(stream.PosBlockindex, b4[:])
				copy(dirBlock[stream.DirOffset-6:], b4[:])
				U16toB2(stream.PosOffset, b2[:])
				copy(dirBlock[stream.DirOffset-2:], b2[:])
				if !ffs.writeblock(stream.DirBlockindex, dirBlock[:]) {
					if ffs.Tmp.State == 1 {
						ffs.tmpstop()
					}
					return 0
				}
				stream.FileStopBlockindex = stream.PosBlockindex
				stream.FileOffset = stream.PosOffset
			}
			if ffs.Tmp.State == 1 {
				if !ffs.Commit() {
					return 0
				}
			}
			return wannasize
		}

		n := avail
		copy(posBlock[stream.PosOffset:int(stream.PosOffset)+n], ptr[cut:cut+n])
		cut += n
		if !ffs.writeblock(stream.PosBlockindex, posBlock[:]) {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 0
		}
		stream.PosOffset += uint16(n)
		stream.Pos += uint64(n)

		if wannasize-cut == 0 {
			flag := false
			if stream.PosBlockindex > stream.FileStopBlockindex {
				flag = true
			} else if stream.PosBlockindex == stream.FileStopBlockindex && stream.PosOffset > stream.FileOffset {
				flag = true
			}
			if flag {
				if !ffs.readblock(stream.DirBlockindex, dirBlock[:]) {
					if ffs.Tmp.State == 1 {
						ffs.tmpstop()
					}
					return 0
				}
				stream.FileStopBlockindex = stream.PosBlockindex
				stream.FileOffset = stream.PosOffset
				U32toB4(stream.PosBlockindex, b4[:])
				copy(dirBlock[stream.DirOffset-6:], b4[:])
				U16toB2(stream.PosOffset, b2[:])
				copy(dirBlock[stream.DirOffset-2:], b2[:])
				if !ffs.writeblock(stream.DirBlockindex, dirBlock[:]) {
					if ffs.Tmp.State == 1 {
						ffs.tmpstop()
					}
					return 0
				}
				stream.FileStopBlockindex = stream.PosBlockindex
				stream.FileOffset = stream.PosOffset
			}
			if ffs.Tmp.State == 1 {
				if !ffs.Commit() {
					return 0
				}
			}
			return wannasize
		}
	}
}

// Fclose closes a virtual file handle (C: FileFS_fclose).
func (ffs *FileFS) Fclose(stream *File) {
	if ffs == nil || ffs.Fp == nil || stream == nil {
		return
	}
	// Go GC collects; no explicit free needed.
}

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
