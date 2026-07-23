package filefs

// Low-level block allocation and read/write against the journaled store.
func (ffs *FileFS) genblockindex() uint32 {
	var block [BlockSize]byte

	if ffs.Tmp.NewUnusedBlockhead > 0 {
		blockindex := ffs.Tmp.NewUnusedBlockhead
		if !ffs.readblock(blockindex, block[:]) {
			return 0
		}
		ffs.Tmp.NewUnusedBlockhead = B4toU32(block[4:8])
		return blockindex
	}

	blockindex := ffs.Tmp.NewTotalBlocksize
	addindex := blockindex - ffs.Tmp.TotalBlocksize
	pos := uint64(addindex) * uint64(4+BlockSize)
	if ffsFsetpos(ffs.Tmp.FpAdd, pos) != nil {
		return 0
	}
	var b4 [4]byte
	U32toB4(blockindex, b4[:])
	if n, err := ffs.Tmp.FpAdd.Write(b4[:]); err != nil || n != 4 {
		return 0
	}
	if n, err := ffs.Tmp.FpAdd.Write(block[:]); err != nil || n != BlockSize {
		return 0
	}
	ffs.Tmp.NewTotalBlocksize++
	return blockindex
}

func (ffs *FileFS) readblock(blockindex uint32, block []byte) bool {
	pos := uint64(blockindex) * BlockSize
	if ffsFsetpos(ffs.Fp, pos) != nil {
		return false
	}
	var buf [4]byte
	n, err := ffs.Fp.Read(buf[:])
	if err != nil || n != 4 {
		if ffs.Tmp.State == 0 {
			return false
		}
		if blockindex < ffs.Tmp.TotalBlocksize {
			return false
		}
		addindex := blockindex - ffs.Tmp.TotalBlocksize
		pos = uint64(addindex)*uint64(BlockSize+4) + 4
		if ffsFsetpos(ffs.Tmp.FpAdd, pos) != nil {
			return false
		}
		n, err = ffs.Tmp.FpAdd.Read(block[:BlockSize])
		return err == nil && n == BlockSize
	}

	if ffs.Tmp.State == 0 {
		copy(block[:4], buf[:])
		n, err = ffs.Fp.Read(block[4:BlockSize])
		return err == nil && n == BlockSize-4
	}

	var b4 [4]byte
	copy(b4[:], buf[:])
	cpindex := B4toU32(b4[:])
	pos = uint64(cpindex) * uint64(BlockSize+4)
	if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
		return false
	}
	n, err = ffs.Tmp.FpCp.Read(b4[:])
	if err != nil || n != 4 {
		copy(block[:4], buf[:])
		n, err = ffs.Fp.Read(block[4:BlockSize])
		return err == nil && n == BlockSize-4
	}
	orgindex := B4toU32(b4[:])
	if orgindex != blockindex {
		copy(block[:4], buf[:])
		n, err = ffs.Fp.Read(block[4:BlockSize])
		return err == nil && n == BlockSize-4
	}
	n, err = ffs.Tmp.FpCp.Read(block[:BlockSize])
	return err == nil && n == BlockSize
}

func (ffs *FileFS) writeblock(blockindex uint32, block []byte) bool {
	if ffs.Tmp.State == 0 {
		return false
	}

	pos := uint64(blockindex) * BlockSize
	if ffsFsetpos(ffs.Fp, pos) != nil {
		return false
	}
	var buf [4]byte
	n, err := ffs.Fp.Read(buf[:])
	if err != nil || n != 4 {
		if blockindex < ffs.Tmp.TotalBlocksize {
			return false
		}
		addindex := blockindex - ffs.Tmp.TotalBlocksize
		pos = uint64(addindex)*uint64(BlockSize+4) + 4
		if ffsFsetpos(ffs.Tmp.FpAdd, pos) != nil {
			return false
		}
		n, err = ffs.Tmp.FpAdd.Write(block[:BlockSize])
		return err == nil && n == BlockSize
	}

	var b4 [4]byte
	copy(b4[:], buf[:])
	cpindex := B4toU32(b4[:])
	pos = uint64(cpindex) * uint64(BlockSize+4)
	if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
		return false
	}
	n, err = ffs.Tmp.FpCp.Read(b4[:])
	if err != nil || n != 4 {
		cpindex = uint32(ffs.Tmp.CpSize)
		pos = uint64(cpindex) * uint64(BlockSize+4)
		if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
			return false
		}
		U32toB4(blockindex, b4[:])
		if n, err = ffs.Tmp.FpCp.Write(b4[:]); err != nil || n != 4 {
			return false
		}
		if n, err = ffs.Tmp.FpCp.Write(block[:BlockSize]); err != nil || n != BlockSize {
			return false
		}
		pos = uint64(blockindex) * BlockSize
		if ffsFsetpos(ffs.Fp, pos) != nil {
			return false
		}
		U32toB4(cpindex, b4[:])
		if n, err = ffs.Fp.Write(b4[:]); err != nil || n != 4 {
			return false
		}
		ffs.Tmp.CpSize++
		return true
	}
	orgindex := B4toU32(b4[:])
	if orgindex != blockindex {
		cpindex = uint32(ffs.Tmp.CpSize)
		pos = uint64(cpindex) * uint64(BlockSize+4)
		if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
			return false
		}
		U32toB4(blockindex, b4[:])
		if n, err = ffs.Tmp.FpCp.Write(b4[:]); err != nil || n != 4 {
			return false
		}
		if n, err = ffs.Tmp.FpCp.Write(block[:BlockSize]); err != nil || n != BlockSize {
			return false
		}
		pos = uint64(blockindex) * BlockSize
		if ffsFsetpos(ffs.Fp, pos) != nil {
			return false
		}
		U32toB4(cpindex, b4[:])
		if n, err = ffs.Fp.Write(b4[:]); err != nil || n != 4 {
			return false
		}
		ffs.Tmp.CpSize++
		return true
	}

	pos = uint64(cpindex)*uint64(BlockSize+4) + 4
	if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
		return false
	}
	n, err = ffs.Tmp.FpCp.Write(block[:BlockSize])
	return err == nil && n == BlockSize
}

func (ffs *FileFS) removeblock(blockindex uint32) bool {
	if ffs.Tmp.State == 0 {
		return false
	}

	pos := uint64(blockindex) * BlockSize
	if ffsFsetpos(ffs.Fp, pos) != nil {
		return false
	}
	var buf [4]byte
	n, err := ffs.Fp.Read(buf[:])
	if err != nil || n != 4 {
		if blockindex < ffs.Tmp.TotalBlocksize {
			return false
		}
		addindex := blockindex - ffs.Tmp.TotalBlocksize
		pos = uint64(addindex)*uint64(BlockSize+4) + 4 + 4
		if ffsFsetpos(ffs.Tmp.FpAdd, pos) != nil {
			return false
		}
		var b4 [4]byte
		U32toB4(ffs.Tmp.NewUnusedBlockhead, b4[:])
		if n, err = ffs.Tmp.FpAdd.Write(b4[:]); err != nil || n != 4 {
			return false
		}
		ffs.Tmp.NewUnusedBlockhead = blockindex
		return true
	}

	var b4 [4]byte
	copy(b4[:], buf[:])
	cpindex := B4toU32(b4[:])
	pos = uint64(cpindex) * uint64(BlockSize+4)
	if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
		return false
	}
	n, err = ffs.Tmp.FpCp.Read(b4[:])
	if err != nil || n != 4 {
		cpindex = uint32(ffs.Tmp.CpSize)
		pos = uint64(cpindex) * uint64(BlockSize+4)
		if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
			return false
		}
		U32toB4(blockindex, b4[:])
		if n, err = ffs.Tmp.FpCp.Write(b4[:]); err != nil || n != 4 {
			return false
		}
		var block [BlockSize]byte
		U32toB4(ffs.Tmp.NewUnusedBlockhead, b4[:])
		copy(block[:4], b4[:])
		pos += 8
		if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
			return false
		}
		if n, err = ffs.Tmp.FpCp.Write(block[:]); err != nil || n != BlockSize {
			return false
		}
		pos = uint64(blockindex) * BlockSize
		if ffsFsetpos(ffs.Fp, pos) != nil {
			return false
		}
		U32toB4(cpindex, b4[:])
		if n, err = ffs.Fp.Write(b4[:]); err != nil || n != 4 {
			return false
		}
		ffs.Tmp.CpSize++
		ffs.Tmp.NewUnusedBlockhead = blockindex
		return true
	}
	orgindex := B4toU32(b4[:])
	if orgindex != blockindex {
		cpindex = uint32(ffs.Tmp.CpSize)
		pos = uint64(cpindex) * uint64(BlockSize+4)
		if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
			return false
		}
		U32toB4(blockindex, b4[:])
		if n, err = ffs.Tmp.FpCp.Write(b4[:]); err != nil || n != 4 {
			return false
		}
		var block [BlockSize]byte
		U32toB4(ffs.Tmp.NewUnusedBlockhead, b4[:])
		copy(block[:4], b4[:])
		pos += 8
		if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
			return false
		}
		if n, err = ffs.Tmp.FpCp.Write(block[:]); err != nil || n != BlockSize {
			return false
		}
		pos = uint64(blockindex) * BlockSize
		if ffsFsetpos(ffs.Fp, pos) != nil {
			return false
		}
		U32toB4(cpindex, b4[:])
		if n, err = ffs.Fp.Write(b4[:]); err != nil || n != 4 {
			return false
		}
		ffs.Tmp.CpSize++
		ffs.Tmp.NewUnusedBlockhead = blockindex
		return true
	}
	pos += 8
	if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
		return false
	}
	U32toB4(ffs.Tmp.NewUnusedBlockhead, b4[:])
	if n, err = ffs.Tmp.FpCp.Write(b4[:]); err != nil || n != 4 {
		return false
	}
	ffs.Tmp.NewUnusedBlockhead = blockindex
	return true
}

func (ffs *FileFS) findPathBlockindex(blockindex uint32, pathname string) uint32 {
	var block [BlockSize]byte
	index := blockindex
	var b4 [4]byte
	var b2 [2]byte
	var s [BlockNameMaxSize + 1]byte

	if !ffs.readblock(index, block[:]) {
		return 0
	}
	copy(b4[:], block[12+1+14+4:12+1+14+4+4])
	stopBlockindex := B4toU32(b4[:])
	copy(b2[:], block[12+1+14+4+4:12+1+14+4+4+2])
	offset := B2toU16(b2[:])

	for {
		k := BlockHead
		for i := 0; i < BlockItemMaxCount; i++ {
			state := block[k]
			k++
			dirFile := state & 0x01
			if dirFile == 1 {
				k += 24
				if index == stopBlockindex && k+1 >= int(offset) {
					return 0
				}
				continue
			}
			copy(s[:BlockNameMaxSize], block[k:k+BlockNameMaxSize])
			k += BlockNameMaxSize
			if cstrFromFixed(s[:]) != pathname {
				k += 10
				if index == stopBlockindex && k+1 >= int(offset) {
					return 0
				}
				continue
			}
			copy(b4[:], block[k:k+4])
			return B4toU32(b4[:])
		}

		copy(b4[:], block[4:8])
		index = B4toU32(b4[:])
		if index == 0 {
			return 0
		}
		if !ffs.readblock(index, block[:]) {
			return 0
		}
	}
}

