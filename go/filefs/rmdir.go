package filefs

// Rmdir removes an empty directory (C: FileFS_rmdir).
// return: 0-ok,1-gen err,2-sub dir not empty,3-path not existed,4-name>limit(14byte)
func (ffs *FileFS) Rmdir(pathname string) int {
	if pathname == "" || ffs == nil || ffs.Fp == nil {
		return 1
	}
	lenN := len(pathname)
	var blockindex uint32
	var start int
	if pathname[0] == '/' {
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
	for i := start; i < lenN; i++ {
		if pathname[i] == '/' {
			if slen == 0 {
				continue
			}
			if i == lenN-1 {
				break
			}
			index := ffs.findPathBlockindex(blockindex, string(s[:slen]))
			if index < 1 {
				return 3
			}
			blockindex = index
			slen = 0
			continue
		}
		s[slen] = pathname[i]
		slen++
		if slen > BlockNameMaxSize {
			return 4
		}
	}
	if slen > BlockNameMaxSize {
		return 4
	}
	lastname := string(s[:slen])
	if lastname == "." || lastname == ".." {
		return 1
	}

	var ba [4]BlockArray
	baUsed := 0
	var blockHead, blockLast, blockItem, blockPrev []byte
	var blockItemIndex, blockLastIndex, blockPrevIndex, blockHeadIndex uint32

	var block [BlockSize]byte
	var b4 [4]byte
	var b2 [2]byte

	if !ffs.readblock(blockindex, block[:]) {
		return 1
	}
	copy(ba[0].Block[:], block[:])
	ba[0].Blockindex = blockindex
	ba[0].Active = 1
	blockHead = ba[0].Block[:]
	blockHeadIndex = blockindex
	baUsed = 1

	copy(b4[:], blockHead[12+1+14+4:12+1+14+8])
	stopBlockindex := B4toU32(b4[:])
	copy(b2[:], blockHead[12+1+14+4+4:12+1+14+4+6])
	offset := B2toU16(b2[:])

	if stopBlockindex == blockHeadIndex {
		blockLast = blockHead
		blockLastIndex = blockHeadIndex
	} else {
		if !ffs.readblock(stopBlockindex, ba[1].Block[:]) {
			return 1
		}
		ba[1].Blockindex = stopBlockindex
		ba[1].Active = 1
		blockLast = ba[1].Block[:]
		blockLastIndex = stopBlockindex
		baUsed++
	}

	var subdirblockindex uint32
	var subdirblock [BlockSize]byte
	var itemOffset uint16
	flag := false
	index := blockHeadIndex
	for {
		k := BlockHead
		for i := 0; i < BlockItemMaxCount; i++ {
			state := block[k]
			k++
			copy(s[:BlockNameMaxSize], block[k:k+BlockNameMaxSize])
			k += BlockNameMaxSize
			if cstrFromFixed(s[:BlockNameMaxSize+1]) != lastname {
				k += 10
				if index == stopBlockindex && k+1 >= int(offset) {
					return 3
				}
				continue
			}
			dirFile := state & 0x01
			if dirFile == 1 {
				return 3
			}
			copy(b4[:], block[k:k+4])
			subdirblockindex = B4toU32(b4[:])
			if !ffs.readblock(subdirblockindex, subdirblock[:]) {
				return 1
			}
			copy(b4[:], subdirblock[BlockStartBlockindex:BlockStartBlockindex+4])
			subdirStart := B4toU32(b4[:])
			copy(b4[:], subdirblock[BlockStopBlockindex:BlockStopBlockindex+4])
			subdirStop := B4toU32(b4[:])
			copy(b2[:], subdirblock[BlockOffset:BlockOffset+2])
			subdirOffset := B2toU16(b2[:])
			if subdirStop != subdirStart {
				return 2
			}
			if subdirOffset > 62 {
				return 2
			}

			itemOffset = uint16(k + 10)
			u := false
			for j := 0; j < baUsed; j++ {
				if ba[j].Blockindex == index {
					blockItem = ba[j].Block[:]
					blockItemIndex = index
					u = true
					break
				}
			}
			if !u {
				copy(ba[baUsed].Block[:], block[:])
				ba[baUsed].Blockindex = index
				ba[baUsed].Active = 1
				blockItem = ba[baUsed].Block[:]
				blockItemIndex = index
				baUsed++
			}
			flag = true
			break
		}
		if flag {
			break
		}
		copy(b4[:], block[4:8])
		index = B4toU32(b4[:])
		if index == 0 {
			return 1
		}
		if !ffs.readblock(index, block[:]) {
			return 1
		}
	}

	if ffs.Tmp.State == 0 {
		ffs.tmpstart(1)
	}
	ffs.removeblock(subdirblockindex)

	if blockItemIndex != stopBlockindex || itemOffset != offset {
		copy(blockItem[itemOffset-25:itemOffset], blockLast[offset-25:offset])
	}
	offset -= 25
	U16toB2(offset, b2[:])
	copy(blockHead[BlockOffset:], b2[:])

	if offset < 25 {
		copy(b4[:], blockLast[8:12])
		blockPrevIndex = B4toU32(b4[:])
		ffs.removeblock(blockLastIndex)
		k := -1
		for i := 0; i < baUsed; i++ {
			if ba[i].Blockindex == blockLastIndex {
				ba[i].Active = 0
				k = i
				break
			}
		}
		if k < 0 {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 1
		}
		u := false
		for i := 0; i < baUsed; i++ {
			if ba[i].Blockindex == blockPrevIndex {
				blockPrev = ba[i].Block[:]
				u = true
				break
			}
		}
		if !u {
			if !ffs.readblock(blockPrevIndex, block[:]) {
				if ffs.Tmp.State == 1 {
					ffs.tmpstop()
				}
				return 1
			}
			copy(ba[k].Block[:], block[:])
			ba[k].Blockindex = blockPrevIndex
			ba[k].Active = 1
			blockPrev = ba[k].Block[:]
		}
		for i := 0; i < 4; i++ {
			blockPrev[4+i] = 0
		}
		U32toB4(blockPrevIndex, b4[:])
		copy(blockHead[BlockStopBlockindex:], b4[:])
		offset = BlockSize
		U16toB2(offset, b2[:])
		copy(blockHead[BlockOffset:], b2[:])
	}

	for i := 0; i < baUsed; i++ {
		if ba[i].Active == 0 {
			continue
		}
		if !ffs.writeblock(ba[i].Blockindex, ba[i].Block[:]) {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 1
		}
	}
	if ffs.Tmp.State == 1 {
		if !ffs.Commit() {
			return 1
		}
	}
	return 0
}

// Opendir opens a directory for reading.
// Returns (dir, absolutePath); dir is nil on failure (C: FileFS_opendir absolute_path out-param).
