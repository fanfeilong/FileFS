package filefs



// doRename moves/renames a directory entry between parent blocks.
func (ffs *FileFS) doRename(oldLastname string, oldBlockindex uint32, oldTypeDir uint8,
	newLastname string, newBlockindex uint32, newTypeDir uint8) int {

	var b4 [4]byte
	var b2 [2]byte
	var s [BlockNameMaxSize + 2]byte

	var oldBa [4]BlockArray
	oldBaUsed := 0
	var oldBlockHead, oldBlockLast, oldBlockItem, oldBlockPrev []byte
	var oldBlockItemIndex, oldBlockLastIndex, oldBlockPrevIndex, oldBlockHeadIndex uint32

	var oldBlock [BlockSize]byte
	if !ffs.readblock(oldBlockindex, oldBlock[:]) {
		return 1
	}
	copy(oldBa[0].Block[:], oldBlock[:])
	oldBa[0].Blockindex = oldBlockindex
	oldBa[0].Active = 1
	oldBlockHead = oldBa[0].Block[:]
	oldBlockHeadIndex = oldBlockindex
	oldBaUsed = 1

	copy(b4[:], oldBlockHead[12+1+14+4:12+1+14+8])
	oldStopBlockindex := B4toU32(b4[:])
	copy(b2[:], oldBlockHead[12+1+14+4+4:12+1+14+4+6])
	oldOffset := B2toU16(b2[:])

	if oldStopBlockindex == oldBlockHeadIndex {
		oldBlockLast = oldBlockHead
		oldBlockLastIndex = oldBlockHeadIndex
	} else {
		if !ffs.readblock(oldStopBlockindex, oldBa[1].Block[:]) {
			return 1
		}
		oldBa[1].Blockindex = oldStopBlockindex
		oldBa[1].Active = 1
		oldBlockLast = oldBa[1].Block[:]
		oldBlockLastIndex = oldStopBlockindex
		oldBaUsed++
	}

	var oldItemOffset uint16
	var oldDirFile uint8
	flag := false
	index := oldBlockHeadIndex
	for {
		k := BlockHead
		for i := 0; i < BlockItemMaxCount; i++ {
			state := oldBlock[k]
			k++
			copy(s[:BlockNameMaxSize], oldBlock[k:k+BlockNameMaxSize])
			k += BlockNameMaxSize
			if cstrFromFixed(s[:BlockNameMaxSize+1]) != oldLastname {
				k += 10
				if index == oldStopBlockindex && k+1 >= int(oldOffset) {
					return 4
				}
				continue
			}
			oldDirFile = state & 0x01
			if oldTypeDir == 1 && oldDirFile == 1 {
				return 2
			}
			if newTypeDir == 1 && oldDirFile == 1 {
				return 6
			}
			oldItemOffset = uint16(k + 10)

			u := false
			for j := 0; j < oldBaUsed; j++ {
				if oldBa[j].Blockindex == index {
					oldBlockItem = oldBa[j].Block[:]
					oldBlockItemIndex = index
					u = true
					break
				}
			}
			if !u {
				copy(oldBa[oldBaUsed].Block[:], oldBlock[:])
				oldBa[oldBaUsed].Blockindex = index
				oldBa[oldBaUsed].Active = 1
				oldBlockItem = oldBa[oldBaUsed].Block[:]
				oldBlockItemIndex = index
				oldBaUsed++
			}
			flag = true
			break
		}
		if flag {
			break
		}
		copy(b4[:], oldBlock[4:8])
		index = B4toU32(b4[:])
		if index == 0 {
			return 1
		}
		if !ffs.readblock(index, oldBlock[:]) {
			return 1
		}
	}

	var newBa [2]BlockArray
	newBaUsed := 0
	var newBlockHead, newBlockLast []byte
	var newBlockHeadIndex, newBlockLastIndex uint32

	var newBlock [BlockSize]byte
	if !ffs.readblock(newBlockindex, newBlock[:]) {
		return 1
	}
	copy(newBa[0].Block[:], newBlock[:])
	newBa[0].Blockindex = newBlockindex
	newBa[0].Active = 1
	newBlockHead = newBa[0].Block[:]
	newBlockHeadIndex = newBlockindex
	newBaUsed = 1

	copy(b4[:], newBlockHead[12+1+14+4:12+1+14+8])
	newStopBlockindex := B4toU32(b4[:])
	copy(b2[:], newBlockHead[12+1+14+4+4:12+1+14+4+6])
	newOffset := B2toU16(b2[:])

	if newStopBlockindex == newBlockHeadIndex {
		newBlockLast = newBlockHead
		newBlockLastIndex = newBlockHeadIndex
	} else {
		if !ffs.readblock(newStopBlockindex, newBa[1].Block[:]) {
			return 1
		}
		newBa[1].Blockindex = newStopBlockindex
		newBa[1].Active = 1
		newBlockLast = newBa[1].Block[:]
		newBlockLastIndex = newStopBlockindex
		newBaUsed++
	}

	flag = false
	index = newBlockHeadIndex
	for {
		k := BlockHead
		for i := 0; i < BlockItemMaxCount; i++ {
			k++
			copy(s[:BlockNameMaxSize], newBlock[k:k+BlockNameMaxSize])
			k += BlockNameMaxSize
			if cstrFromFixed(s[:BlockNameMaxSize+1]) != newLastname {
				k += 10
				if index == newStopBlockindex && k+1 >= int(newOffset) {
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
		copy(b4[:], newBlock[4:8])
		index = B4toU32(b4[:])
		if index == 0 {
			return 1
		}
		if !ffs.readblock(index, newBlock[:]) {
			return 1
		}
	}

	if oldBlockHeadIndex == newBlockHeadIndex {
		nameBytes := make([]byte, BlockNameMaxSize)
		copy(nameBytes, newLastname)
		copy(oldBlockItem[oldItemOffset-10-14:oldItemOffset-10], nameBytes)
		if ffs.Tmp.State == 0 {
			ffs.tmpstart(1)
		}
		if !ffs.writeblock(oldBlockItemIndex, oldBlockItem) {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 1
		}
		if ffs.Tmp.State == 1 {
			if !ffs.Commit() {
				return 1
			}
		}
		return 0
	}

	if ffs.Tmp.State == 0 {
		ffs.tmpstart(1)
	}

	if oldDirFile == 0 {
		copy(b4[:], oldBlockItem[oldItemOffset-10:oldItemOffset-6])
		pathBlockindex := B4toU32(b4[:])
		var pathBlock [BlockSize]byte
		if !ffs.readblock(pathBlockindex, pathBlock[:]) {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 1
		}
		U32toB4(newBlockHeadIndex, b4[:])
		copy(pathBlock[BlockHead+25+1+14:], b4[:])
		if !ffs.writeblock(pathBlockindex, pathBlock[:]) {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 1
		}
	}

	var block2 [BlockSize]byte
	var blockindex2 uint32

	if newOffset < BlockSize {
		copy(newBlockLast[newOffset:newOffset+25], oldBlockItem[oldItemOffset-25:oldItemOffset])
		newOffset += 25
		U16toB2(newOffset, b2[:])
		copy(newBlockHead[BlockOffset:], b2[:])
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
		U32toB4(newBlockLastIndex, b4[:])
		copy(block2[8:], b4[:])
		copy(block2[BlockHead:BlockHead+25], oldBlockItem[oldItemOffset-25:oldItemOffset])
		if !ffs.writeblock(blockindex2, block2[:]) {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 1
		}
		U32toB4(blockindex2, b4[:])
		copy(newBlockLast[4:], b4[:])
		newOffset = BlockHead + 25
		U16toB2(newOffset, b2[:])
		copy(newBlockHead[BlockOffset:], b2[:])
		copy(newBlockHead[BlockStopBlockindex:], b4[:])
	}
	for i := 0; i < newBaUsed; i++ {
		if newBa[i].Active == 0 {
			continue
		}
		if !ffs.writeblock(newBa[i].Blockindex, newBa[i].Block[:]) {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 1
		}
	}

	if oldBlockItemIndex != oldStopBlockindex || oldItemOffset != oldOffset {
		copy(oldBlockItem[oldItemOffset-25:oldItemOffset], oldBlockLast[oldOffset-25:oldOffset])
	}
	oldOffset -= 25
	U16toB2(oldOffset, b2[:])
	copy(oldBlockHead[BlockOffset:], b2[:])

	if oldOffset < 25 {
		copy(b4[:], oldBlockLast[8:12])
		oldBlockPrevIndex = B4toU32(b4[:])
		ffs.removeblock(oldBlockLastIndex)
		k := -1
		for i := 0; i < oldBaUsed; i++ {
			if oldBa[i].Blockindex == oldBlockLastIndex {
				oldBa[i].Active = 0
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
		for i := 0; i < oldBaUsed; i++ {
			if oldBa[i].Blockindex == oldBlockPrevIndex {
				oldBlockPrev = oldBa[i].Block[:]
				u = true
				break
			}
		}
		if !u {
			if !ffs.readblock(oldBlockPrevIndex, oldBlock[:]) {
				if ffs.Tmp.State == 1 {
					ffs.tmpstop()
				}
				return 1
			}
			copy(oldBa[k].Block[:], oldBlock[:])
			oldBa[k].Blockindex = oldBlockPrevIndex
			oldBa[k].Active = 1
			oldBlockPrev = oldBa[k].Block[:]
		}
		for i := 0; i < 4; i++ {
			oldBlockPrev[4+i] = 0
		}
		U32toB4(oldBlockPrevIndex, b4[:])
		copy(oldBlockHead[BlockStopBlockindex:], b4[:])
		oldOffset = BlockSize
		U16toB2(oldOffset, b2[:])
		copy(oldBlockHead[BlockOffset:], b2[:])
	}

	for i := 0; i < oldBaUsed; i++ {
		if oldBa[i].Active == 0 {
			continue
		}
		if !ffs.writeblock(oldBa[i].Blockindex, oldBa[i].Block[:]) {
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

// Rename renames a file or directory.
// return: 0:ok,1-err,2-old name format err,3-new name format err,4-old name not exist,5-new name exist,6-old new format not match
func (ffs *FileFS) Rename(oldName, newName string) int {
	if ffs == nil || ffs.Fp == nil || oldName == "" || newName == "" {
		return 1
	}

	lenN := len(oldName)
	var blockindex uint32
	var start int
	if oldName[0] == '/' {
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
		if oldName[i] == '/' {
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
		s[slen] = oldName[i]
		slen++
		if slen > BlockNameMaxSize {
			return 2
		}
	}
	if slen > BlockNameMaxSize {
		return 2
	}
	oldLastname := string(s[:slen])
	if oldLastname == "." || oldLastname == ".." {
		return 2
	}
	oldBlockindex := blockindex
	var oldTypeDir uint8
	if oldName[lenN-1] == '/' {
		oldTypeDir = 1
	}

	lenN = len(newName)
	if newName[0] == '/' {
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
		if newName[i] == '/' {
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
		s[slen] = newName[i]
		slen++
		if slen > BlockNameMaxSize {
			return 3
		}
	}
	if slen > BlockNameMaxSize {
		return 3
	}
	newLastname := string(s[:slen])
	if newLastname == "." || newLastname == ".." {
		return 3
	}
	newBlockindex := blockindex
	var newTypeDir uint8
	if newName[lenN-1] == '/' {
		newTypeDir = 1
	}

	return ffs.doRename(oldLastname, oldBlockindex, oldTypeDir, newLastname, newBlockindex, newTypeDir)
}
