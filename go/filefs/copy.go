package filefs

// Copy duplicates a file (C: FileFS_copy).
// return: 0:ok,1-err,2-from name format err,3-to path format err,4-from name not exist,5-to file exist
func (ffs *FileFS) Copy(fromFilename, toFilename string) int {
	if ffs == nil || ffs.Fp == nil || fromFilename == "" || toFilename == "" {
		return 1
	}

	lenN := len(fromFilename)
	if fromFilename[lenN-1] == '/' {
		return 2
	}
	var blockindex uint32
	var start int
	if fromFilename[0] == '/' {
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
		if fromFilename[i] == '/' {
			if slen == 0 {
				continue
			}
			if i == lenN-1 {
				break
			}
			index := ffs.findPathBlockindex(blockindex, string(s[:slen]))
			if index < 1 {
				return 2
			}
			blockindex = index
			slen = 0
			continue
		}
		s[slen] = fromFilename[i]
		slen++
		if slen > BlockNameMaxSize {
			return 2
		}
	}
	if slen > BlockNameMaxSize {
		return 2
	}
	fromLastname := string(s[:slen])
	if fromLastname == "." || fromLastname == ".." {
		return 2
	}
	fromBlockindex := blockindex

	lenN = len(toFilename)
	if toFilename[lenN-1] == '/' {
		return 3
	}
	if toFilename[0] == '/' {
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
	slen = 0
	for i := start; i < lenN; i++ {
		if toFilename[i] == '/' {
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
		s[slen] = toFilename[i]
		slen++
		if slen > BlockNameMaxSize {
			return 3
		}
	}
	if slen > BlockNameMaxSize {
		return 3
	}
	toLastname := string(s[:slen])
	if toLastname == "." || toLastname == ".." {
		return 3
	}
	toBlockindex := blockindex

	var b4 [4]byte
	var b2 [2]byte
	var fromBlock [BlockSize]byte
	if !ffs.readblock(fromBlockindex, fromBlock[:]) {
		return 1
	}
	copy(b4[:], fromBlock[12+1+14+4:12+1+14+8])
	fromStopBlockindex := B4toU32(b4[:])
	copy(b2[:], fromBlock[12+1+14+4+4:12+1+14+4+6])
	fromOffset := B2toU16(b2[:])

	var fromFileStart, fromFileStop uint32
	var fromFileOffset uint16
	flag := false
	index := fromBlockindex
	for {
		k := BlockHead
		for i := 0; i < BlockItemMaxCount; i++ {
			state := fromBlock[k]
			k++
			copy(s[:BlockNameMaxSize], fromBlock[k:k+BlockNameMaxSize])
			k += BlockNameMaxSize
			if cstrFromFixed(s[:BlockNameMaxSize+1]) != fromLastname {
				k += 10
				if index == fromStopBlockindex && k+1 >= int(fromOffset) {
					return 4
				}
				continue
			}
			dirFile := state & 0x01
			if dirFile != 1 {
				return 2
			}
			copy(b4[:], fromBlock[k:k+4])
			k += 4
			fromFileStart = B4toU32(b4[:])
			copy(b4[:], fromBlock[k:k+4])
			k += 4
			fromFileStop = B4toU32(b4[:])
			copy(b2[:], fromBlock[k:k+2])
			fromFileOffset = B2toU16(b2[:])
			flag = true
			break
		}
		if flag {
			break
		}
		copy(b4[:], fromBlock[4:8])
		index = B4toU32(b4[:])
		if index == 0 {
			return 1
		}
		if !ffs.readblock(index, fromBlock[:]) {
			return 1
		}
	}

	var toBa [2]BlockArray
	toBaUsed := 0
	var toBlockHead, toBlockLast []byte
	var toBlockHeadIndex, toBlockLastIndex uint32

	var toBlock [BlockSize]byte
	if !ffs.readblock(toBlockindex, toBlock[:]) {
		return 1
	}
	copy(toBa[0].Block[:], toBlock[:])
	toBa[0].Blockindex = toBlockindex
	toBa[0].Active = 1
	toBlockHead = toBa[0].Block[:]
	toBlockHeadIndex = toBlockindex
	toBaUsed = 1

	copy(b4[:], toBlockHead[12+1+14+4:12+1+14+8])
	toStopBlockindex := B4toU32(b4[:])
	copy(b2[:], toBlockHead[12+1+14+4+4:12+1+14+4+6])
	toOffset := B2toU16(b2[:])

	if toStopBlockindex == toBlockHeadIndex {
		toBlockLast = toBlockHead
		toBlockLastIndex = toBlockHeadIndex
	} else {
		if !ffs.readblock(toStopBlockindex, toBa[1].Block[:]) {
			return 1
		}
		toBa[1].Blockindex = toStopBlockindex
		toBa[1].Active = 1
		toBlockLast = toBa[1].Block[:]
		toBlockLastIndex = toStopBlockindex
		toBaUsed++
	}

	flag = false
	index = toBlockHeadIndex
	for {
		k := BlockHead
		for i := 0; i < BlockItemMaxCount; i++ {
			k++
			copy(s[:BlockNameMaxSize], toBlock[k:k+BlockNameMaxSize])
			k += BlockNameMaxSize
			if cstrFromFixed(s[:BlockNameMaxSize+1]) != toLastname {
				k += 10
				if index == toStopBlockindex && k+1 >= int(toOffset) {
					flag = true
					break
				}
				continue
			}
			return 5
		}
		if flag {
			break
		}
		copy(b4[:], toBlock[4:8])
		index = B4toU32(b4[:])
		if index == 0 {
			return 1
		}
		if !ffs.readblock(index, toBlock[:]) {
			return 1
		}
	}

	if ffs.Tmp.State == 0 {
		ffs.tmpstart(1)
	}

	var block2 [BlockSize]byte
	var blockindex2 uint32
	var newToOffset uint16

	if toOffset < BlockSize {
		for i := 0; i < 25; i++ {
			toBlockLast[int(toOffset)+i] = 0
		}
		toBlockLast[toOffset] = 1
		copy(toBlockLast[toOffset+1:int(toOffset)+1+len(toLastname)], toLastname)
		newToOffset = toOffset + 25
		U16toB2(newToOffset, b2[:])
		copy(toBlockHead[BlockOffset:], b2[:])
	} else {
		blockindex2 = ffs.genblockindex()
		if blockindex2 == 0 {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 1
		}
		for i := range block2 {
			block2[i] = 0
		}
		U32toB4(toBlockLastIndex, b4[:])
		copy(block2[8:], b4[:])
		block2[BlockHead] = 1
		copy(block2[BlockHead+1:BlockHead+1+len(toLastname)], toLastname)
		U32toB4(blockindex2, b4[:])
		copy(toBlockLast[4:], b4[:])
		newToOffset = BlockHead + 25
		U16toB2(newToOffset, b2[:])
		copy(toBlockHead[BlockOffset:], b2[:])
		copy(toBlockHead[BlockStopBlockindex:], b4[:])
	}

	var toFileStart, toFileStop uint32
	var toFileOffset uint16

	if fromFileStart > 0 {
		toFileOffset = fromFileOffset
		fromIndex := fromFileStart
		if !ffs.readblock(fromIndex, fromBlock[:]) {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 1
		}
		copy(b4[:], fromBlock[4:8])
		fromNextIndex := B4toU32(b4[:])

		newBlockindex := ffs.genblockindex()
		if newBlockindex == 0 {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 1
		}
		toFileStart = newBlockindex
		toFileStop = newBlockindex

		prevIndex := uint32(0)
		var newBlock [BlockSize]byte
		for {
			copy(newBlock[:], fromBlock[:])
			U32toB4(prevIndex, b4[:])
			copy(newBlock[8:], b4[:])

			if fromIndex == fromFileStop {
				toFileStop = newBlockindex
				if !ffs.writeblock(newBlockindex, newBlock[:]) {
					if ffs.Tmp.State == 1 {
						ffs.tmpstop()
					}
					return 1
				}
				break
			}

			prevIndex = newBlockindex
			newBlockindex = ffs.genblockindex()
			U32toB4(newBlockindex, b4[:])
			copy(newBlock[4:], b4[:])
			if !ffs.writeblock(prevIndex, newBlock[:]) {
				if ffs.Tmp.State == 1 {
					ffs.tmpstop()
				}
				return 1
			}

			fromIndex = fromNextIndex
			if !ffs.readblock(fromIndex, fromBlock[:]) {
				if ffs.Tmp.State == 1 {
					ffs.tmpstop()
				}
				return 1
			}
			copy(b4[:], fromBlock[4:8])
			fromNextIndex = B4toU32(b4[:])
		}
	}

	if toOffset < BlockSize {
		U32toB4(toFileStart, b4[:])
		copy(toBlockLast[toOffset+25-10:], b4[:])
		U32toB4(toFileStop, b4[:])
		copy(toBlockLast[toOffset+25-6:], b4[:])
		U16toB2(toFileOffset, b2[:])
		copy(toBlockLast[toOffset+25-2:], b2[:])
	} else {
		U32toB4(toFileStart, b4[:])
		copy(block2[BlockHead+25-10:], b4[:])
		U32toB4(toFileStop, b4[:])
		copy(block2[BlockHead+25-6:], b4[:])
		U16toB2(toFileOffset, b2[:])
		copy(block2[BlockHead+25-2:], b2[:])
		if !ffs.writeblock(blockindex2, block2[:]) {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 1
		}
	}

	for i := 0; i < toBaUsed; i++ {
		if toBa[i].Active == 0 {
			continue
		}
		if !ffs.writeblock(toBa[i].Blockindex, toBa[i].Block[:]) {
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
