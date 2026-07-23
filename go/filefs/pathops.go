package filefs

// return: 0:not exist, 1:is file, 2:is dir
func (ffs *FileFS) stat(name string) uint8 {
	if name == "" || ffs == nil || ffs.Fp == nil {
		return 0
	}

	var block [BlockSize]byte
	lenN := len(name)
	var blockindex uint32
	var start int
	if name[0] == '/' {
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
		if name[i] == '/' {
			if slen == 0 {
				continue
			}
			index := ffs.findPathBlockindex(blockindex, string(s[:slen]))
			if index < 1 {
				return 0
			}
			blockindex = index
			slen = 0
			continue
		}
		s[slen] = name[i]
		slen++
		if slen > BlockNameMaxSize {
			return 0
		}
	}
	if slen == 0 {
		return 2
	}
	lastname := string(s[:slen])

	var b4 [4]byte
	var b2 [2]byte
	if !ffs.readblock(blockindex, block[:]) {
		return 0
	}
	copy(b4[:], block[12+1+14+4:12+1+14+8])
	stopBlockindex := B4toU32(b4[:])
	copy(b2[:], block[12+1+14+4+4:12+1+14+4+6])
	offset := B2toU16(b2[:])

	index := blockindex
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
					return 0
				}
				continue
			}
			dirFile := state & 0x01
			if dirFile == 0 {
				return 2
			}
			return 1
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

// FileExist reports whether a file exists (C: FileFS_file_exist).
func (ffs *FileFS) FileExist(filename string) bool {
	return ffs.stat(filename) == 1
}

// DirExist reports whether a directory exists (C: FileFS_dir_exist).
func (ffs *FileFS) DirExist(pathname string) bool {
	return ffs.stat(pathname) == 2
}

// Remove deletes a file. Return: 0-ok,1-gen err,2-file not exist,3-dir not existed,4-name>limit,5-name format err
func (ffs *FileFS) Remove(filename string) int {
	if ffs == nil || ffs.Fp == nil || filename == "" {
		return 1
	}
	lenFn := len(filename)
	if filename[lenFn-1] == '/' {
		return 5
	}
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
			index := ffs.findPathBlockindex(blockindex, string(s[:slen]))
			if index < 1 {
				return 3
			}
			blockindex = index
			slen = 0
			continue
		}
		s[slen] = filename[i]
		slen++
		if slen > BlockNameMaxSize {
			return 4
		}
	}
	if slen == 0 {
		return 2
	}
	lastname := string(s[:slen])
	if lastname == "." || lastname == ".." {
		return 5
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

	var fileStart, fileStop uint32
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
					return 2
				}
				continue
			}
			dirFile := state & 0x01
			if dirFile == 0 {
				return 2
			}
			copy(b4[:], block[k:k+4])
			fileStart = B4toU32(b4[:])
			copy(b4[:], block[k+4:k+8])
			fileStop = B4toU32(b4[:])
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

	if fileStart > 0 {
		var fileBlockStop [BlockSize]byte
		if !ffs.readblock(fileStop, fileBlockStop[:]) {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 1
		}
		U32toB4(ffs.Tmp.NewUnusedBlockhead, b4[:])
		copy(fileBlockStop[4:], b4[:])
		ffs.Tmp.NewUnusedBlockhead = fileStart
		if !ffs.writeblock(fileStop, fileBlockStop[:]) {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 1
		}
	}

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

// Move moves a file or directory into toPath (keeps basename).
func (ffs *FileFS) Move(fromName, toPath string) int {
	if ffs == nil || ffs.Fp == nil || fromName == "" || toPath == "" {
		return 1
	}

	lenN := len(fromName)
	var blockindex uint32
	var start int
	if fromName[0] == '/' {
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
		if fromName[i] == '/' {
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
		s[slen] = fromName[i]
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
	var fromTypeDir uint8
	if fromName[lenN-1] == '/' {
		fromTypeDir = 1
	}

	lenN = len(toPath)
	if toPath[0] == '/' {
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
		if toPath[i] == '/' {
			if slen == 0 {
				continue
			}
			index := ffs.findPathBlockindex(blockindex, string(s[:slen]))
			if index < 1 {
				return 3
			}
			blockindex = index
			slen = 0
			continue
		}
		s[slen] = toPath[i]
		slen++
		if slen > BlockNameMaxSize {
			return 3
		}
	}
	if slen > 0 {
		if slen > BlockNameMaxSize {
			return 3
		}
		index := ffs.findPathBlockindex(blockindex, string(s[:slen]))
		if index < 1 {
			return 3
		}
		blockindex = index
	}

	return ffs.doRename(fromLastname, fromBlockindex, fromTypeDir, fromLastname, blockindex, fromTypeDir)
}

// Copy copies a file. return: 0:ok,1-err,2-from name format err,3-to path format err,4-from name not exist,5-to file exist
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
