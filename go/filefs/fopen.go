package filefs

func (ffs *FileFS) doFopenR(lastname string, mode uint8, blockHeadIndex uint32) *File {
	var block [BlockSize]byte
	var b4 [4]byte
	var b2 [2]byte

	if !ffs.readblock(blockHeadIndex, block[:]) {
		return nil
	}
	copy(b4[:], block[12+1+14+4:12+1+14+8])
	stopBlockindex := B4toU32(b4[:])
	copy(b2[:], block[12+1+14+4+4:12+1+14+4+6])
	offset := B2toU16(b2[:])

	found := false
	var dirBlockindex uint32
	var dirOffset uint16
	index := blockHeadIndex
	var s [BlockNameMaxSize + 1]byte

	for {
		k := BlockHead
		for i := 0; i < BlockItemMaxCount; i++ {
			state := block[k]
			k++
			copy(s[:BlockNameMaxSize], block[k:k+BlockNameMaxSize])
			k += BlockNameMaxSize
			if cstrFromFixed(s[:]) != lastname {
				k += 10
				if index == stopBlockindex && k+1 >= int(offset) {
					return nil
				}
				continue
			}
			dirFile := state & 0x01
			if dirFile == 0 {
				return nil
			}
			dirBlockindex = index
			dirOffset = uint16(k + 10)
			found = true
			break
		}
		if found {
			break
		}
		copy(b4[:], block[4:8])
		index = B4toU32(b4[:])
		if index == 0 {
			return nil
		}
		if !ffs.readblock(index, block[:]) {
			return nil
		}
	}

	ff := &File{}
	ff.Mode = mode
	ff.DirBlockindex = dirBlockindex
	ff.DirOffset = dirOffset

	copy(b4[:], block[dirOffset-10:dirOffset-6])
	ff.FileStartBlockindex = B4toU32(b4[:])
	copy(b4[:], block[dirOffset-6:dirOffset-2])
	ff.FileStopBlockindex = B4toU32(b4[:])
	copy(b2[:], block[dirOffset-2:dirOffset])
	ff.FileOffset = B2toU16(b2[:])

	ff.PosBlockindex = ff.FileStartBlockindex
	ff.PosOffset = BlockHead
	ff.Pos = 0
	return ff
}

func (ffs *FileFS) doFopenCreatefileitem(lastname string,
	orgStartBlockindex, orgStopBlockindex uint32, orgOffset uint16,
	dirBlock []byte, dirBlockindex *uint32, dirOffset *uint16) bool {

	var b4 [4]byte
	var b2 [2]byte
	var ba [2]BlockArray
	var blockStart, blockStop []byte
	var blockStartIndex, blockStopIndex uint32

	if !ffs.readblock(orgStartBlockindex, ba[0].Block[:]) {
		return false
	}
	ba[0].Blockindex = orgStartBlockindex
	ba[0].Active = 1
	blockStart = ba[0].Block[:]
	blockStartIndex = ba[0].Blockindex

	if orgStopBlockindex == orgStartBlockindex {
		blockStop = blockStart
		blockStopIndex = blockStartIndex
	} else {
		if !ffs.readblock(orgStopBlockindex, ba[1].Block[:]) {
			return false
		}
		ba[1].Blockindex = orgStopBlockindex
		ba[1].Active = 1
		blockStop = ba[1].Block[:]
		blockStopIndex = ba[1].Blockindex
	}

	if ffs.Tmp.State == 0 {
		ffs.tmpstart(1)
	}

	if orgOffset < BlockSize {
		k := int(orgOffset)
		blockStop[k] = 1
		k++
		for i := 0; i < BlockNameMaxSize; i++ {
			blockStop[k+i] = 0
		}
		copy(blockStop[k:k+len(lastname)], lastname)
		k += BlockNameMaxSize
		k += 4
		k += 4
		k += 2
		newOffset := uint16(k)
		U16toB2(newOffset, b2[:])
		copy(blockStart[BlockOffset:], b2[:])

		for i := 0; i < 2; i++ {
			if ba[i].Active != 0 {
				if !ffs.writeblock(ba[i].Blockindex, ba[i].Block[:]) {
					if ffs.Tmp.State == 1 {
						ffs.tmpstop()
					}
					return false
				}
			}
		}
		if ffs.Tmp.State == 1 {
			if !ffs.Commit() {
				return false
			}
		}
		copy(dirBlock, blockStop)
		*dirBlockindex = blockStopIndex
		*dirOffset = newOffset
		return true
	}

	blockindex2 := ffs.genblockindex()
	if blockindex2 == 0 {
		if ffs.Tmp.State == 1 {
			ffs.tmpstop()
		}
		return false
	}
	var block2 [BlockSize]byte
	k := 8
	U32toB4(orgStopBlockindex, b4[:])
	copy(block2[k:], b4[:])
	k += 4
	block2[k] = 1
	k++
	for i := 0; i < BlockNameMaxSize; i++ {
		block2[k+i] = 0
	}
	copy(block2[k:k+len(lastname)], lastname)
	k += BlockNameMaxSize
	k += 4
	k += 4
	k += 2
	newOffset := uint16(k)
	U16toB2(newOffset, b2[:])
	copy(blockStart[BlockOffset:], b2[:])
	U32toB4(blockindex2, b4[:])
	copy(blockStart[BlockStopBlockindex:], b4[:])
	copy(blockStop[4:], b4[:])

	for i := 0; i < 2; i++ {
		if ba[i].Active != 0 {
			if !ffs.writeblock(ba[i].Blockindex, ba[i].Block[:]) {
				if ffs.Tmp.State == 1 {
					ffs.tmpstop()
				}
				return false
			}
		}
	}
	if ffs.Tmp.State == 1 {
		if !ffs.Commit() {
			return false
		}
	}
	copy(dirBlock, block2[:])
	*dirBlockindex = blockindex2
	*dirOffset = newOffset
	return true
}

func (ffs *FileFS) doFopenCleanfilecontent(dirBlock []byte, dirBlockindex uint32, dirOffset uint16) bool {
	var b4 [4]byte
	copy(b4[:], dirBlock[dirOffset-10:dirOffset-6])
	fileStart := B4toU32(b4[:])
	copy(b4[:], dirBlock[dirOffset-6:dirOffset-2])
	fileStop := B4toU32(b4[:])
	if fileStart == 0 {
		return true
	}

	if ffs.Tmp.State == 0 {
		ffs.tmpstart(1)
	}

	var fileBlockStop [BlockSize]byte
	if !ffs.readblock(fileStop, fileBlockStop[:]) {
		if ffs.Tmp.State == 1 {
			ffs.tmpstop()
		}
		return false
	}
	U32toB4(ffs.Tmp.NewUnusedBlockhead, b4[:])
	copy(fileBlockStop[4:], b4[:])
	ffs.Tmp.NewUnusedBlockhead = fileStart

	for i := 0; i < 10; i++ {
		dirBlock[int(dirOffset)-10+i] = 0
	}

	if !ffs.writeblock(dirBlockindex, dirBlock) {
		if ffs.Tmp.State == 1 {
			ffs.tmpstop()
		}
		return false
	}
	if !ffs.writeblock(fileStop, fileBlockStop[:]) {
		if ffs.Tmp.State == 1 {
			ffs.tmpstop()
		}
		return false
	}
	if ffs.Tmp.State == 1 {
		if !ffs.Commit() {
			return false
		}
	}
	return true
}

func (ffs *FileFS) doFopenW(lastname string, mode uint8, blockHeadIndex uint32) *File {
	var block [BlockSize]byte
	var b4 [4]byte
	var b2 [2]byte

	if !ffs.readblock(blockHeadIndex, block[:]) {
		return nil
	}
	copy(b4[:], block[12+1+14+4:12+1+14+8])
	stopBlockindex := B4toU32(b4[:])
	copy(b2[:], block[12+1+14+4+4:12+1+14+4+6])
	offset := B2toU16(b2[:])

	found := false
	dirExists := false
	var dirBlockindex uint32
	var dirOffset uint16
	index := blockHeadIndex
	var s [BlockNameMaxSize + 1]byte

	for {
		k := BlockHead
		for i := 0; i < BlockItemMaxCount; i++ {
			state := block[k]
			k++
			copy(s[:BlockNameMaxSize], block[k:k+BlockNameMaxSize])
			k += BlockNameMaxSize
			if cstrFromFixed(s[:]) != lastname {
				k += 10
				if index == stopBlockindex && k+1 >= int(offset) {
					found = true
					break
				}
				continue
			}
			dirFile := state & 0x01
			if dirFile == 0 {
				return nil
			}
			dirBlockindex = index
			dirOffset = uint16(k + 10)
			dirExists = true
			found = true
			break
		}
		if found {
			break
		}
		copy(b4[:], block[4:8])
		index = B4toU32(b4[:])
		if index == 0 {
			return nil
		}
		if !ffs.readblock(index, block[:]) {
			return nil
		}
	}

	if !dirExists {
		if !ffs.doFopenCreatefileitem(lastname, blockHeadIndex, stopBlockindex, offset,
			block[:], &dirBlockindex, &dirOffset) {
			return nil
		}
	} else {
		if !ffs.doFopenCleanfilecontent(block[:], dirBlockindex, dirOffset) {
			return nil
		}
	}

	ff := &File{}
	ff.Mode = mode
	ff.DirBlockindex = dirBlockindex
	ff.DirOffset = dirOffset
	ff.FileStartBlockindex = 0
	ff.FileStopBlockindex = 0
	ff.FileOffset = 0
	ff.PosBlockindex = 0
	ff.PosOffset = 0
	ff.Pos = 0
	return ff
}

func (ffs *FileFS) doFopenA(lastname string, mode uint8, blockHeadIndex uint32) *File {
	var block [BlockSize]byte
	var b4 [4]byte
	var b2 [2]byte

	if !ffs.readblock(blockHeadIndex, block[:]) {
		return nil
	}
	copy(b4[:], block[12+1+14+4:12+1+14+8])
	stopBlockindex := B4toU32(b4[:])
	copy(b2[:], block[12+1+14+4+4:12+1+14+4+6])
	offset := B2toU16(b2[:])

	found := false
	dirExists := false
	var dirBlockindex uint32
	var dirOffset uint16
	index := blockHeadIndex
	var s [BlockNameMaxSize + 1]byte

	for {
		k := BlockHead
		for i := 0; i < BlockItemMaxCount; i++ {
			state := block[k]
			k++
			copy(s[:BlockNameMaxSize], block[k:k+BlockNameMaxSize])
			k += BlockNameMaxSize
			if cstrFromFixed(s[:]) != lastname {
				k += 10
				if index == stopBlockindex && k+1 >= int(offset) {
					found = true
					break
				}
				continue
			}
			dirFile := state & 0x01
			if dirFile == 0 {
				return nil
			}
			dirBlockindex = index
			dirOffset = uint16(k + 10)
			dirExists = true
			found = true
			break
		}
		if found {
			break
		}
		copy(b4[:], block[4:8])
		index = B4toU32(b4[:])
		if index == 0 {
			return nil
		}
		if !ffs.readblock(index, block[:]) {
			return nil
		}
	}

	if !dirExists {
		if !ffs.doFopenCreatefileitem(lastname, blockHeadIndex, stopBlockindex, offset,
			block[:], &dirBlockindex, &dirOffset) {
			return nil
		}
		ff := &File{}
		ff.Mode = mode
		ff.DirBlockindex = dirBlockindex
		ff.DirOffset = dirOffset
		ff.FileStartBlockindex = 0
		ff.FileStopBlockindex = 0
		ff.FileOffset = 0
		ff.PosBlockindex = 0
		ff.PosOffset = 0
		ff.Pos = 0
		return ff
	}

	copy(b4[:], block[dirOffset-10:dirOffset-6])
	fileStart := B4toU32(b4[:])
	copy(b4[:], block[dirOffset-6:dirOffset-2])
	fileStop := B4toU32(b4[:])
	copy(b2[:], block[dirOffset-2:dirOffset])
	fileOffset := B2toU16(b2[:])

	var pos uint64
	index = fileStart
	for {
		if index == fileStop {
			pos += uint64(fileOffset - BlockHead)
			break
		}
		if !ffs.readblock(index, block[:]) {
			return nil
		}
		pos += BlockSize - BlockHead
		copy(b4[:], block[4:8])
		index = B4toU32(b4[:])
	}

	ff := &File{}
	ff.Mode = mode
	ff.DirBlockindex = dirBlockindex
	ff.DirOffset = dirOffset
	ff.FileStartBlockindex = fileStart
	ff.FileStopBlockindex = fileStop
	ff.FileOffset = fileOffset
	ff.PosBlockindex = fileStop
	ff.PosOffset = fileOffset
	ff.Pos = pos
	return ff
}

// Fopen opens a virtual file (C: FileFS_fopen).
func (ffs *FileFS) Fopen(filename, mode string) *File {
	if ffs == nil || ffs.Fp == nil {
		return nil
	}
	if filename == "" || mode == "" {
		return nil
	}

	var bmode uint8
	switch mode {
	case "r":
		bmode = 0
	case "w":
		bmode = 1
	case "a":
		bmode = 2
	case "r+":
		bmode = 3
	case "w+":
		bmode = 4
	case "a+":
		bmode = 5
	default:
		return nil
	}

	lenFn := len(filename)
	var blockindex uint32
	var start int
	if filename[0] == '/' {
		blockindex = 1
		start = 1
	} else {
		if ffs.Tmp.State == 0 {
			blockindex = ffs.PwdBlockindex
		} else {
			blockindex = ffs.Tmp.PwdBlockindex
		}
		start = 0
	}

	var s [BlockNameMaxSize + 2]byte
	slen := 0
	for i := start; i < lenFn; i++ {
		if filename[i] == '/' {
			if slen == 0 {
				continue
			}
			name := string(s[:slen])
			index := ffs.findPathBlockindex(blockindex, name)
			if index < 1 {
				return nil
			}
			blockindex = index
			slen = 0
			continue
		}
		s[slen] = filename[i]
		slen++
		if slen > BlockNameMaxSize {
			return nil
		}
	}
	if slen == 0 {
		return nil
	}
	lastname := string(s[:slen])
	if lastname == "." || lastname == ".." {
		return nil
	}

	switch bmode {
	case 0, 3:
		return ffs.doFopenR(lastname, bmode, blockindex)
	case 1, 4:
		return ffs.doFopenW(lastname, bmode, blockindex)
	case 2, 5:
		return ffs.doFopenA(lastname, bmode, blockindex)
	}
	return nil
}
