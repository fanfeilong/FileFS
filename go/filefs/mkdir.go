package filefs

// doMkdir creates a directory entry and its . / .. block.
func (ffs *FileFS) doMkdir(lastname string, startBlockindex uint32, startBlock []byte,
	curBlockindex uint32, curBlock []byte,
	stopBlockindex uint32, offset uint16) int {

	if ffs.Tmp.State == 0 {
		ffs.tmpstart(1)
	}

	var b4 [4]byte
	var b2 [2]byte
	var name [BlockNameMaxSize + 1]byte
	var newBlock [BlockSize]byte
	var block2 [BlockSize]byte

	if offset < BlockSize {
		newBlockindex := ffs.genblockindex()
		if newBlockindex == 0 {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 1
		}
		for i := range newBlock {
			newBlock[i] = 0
		}
		k := BlockHead
		newBlock[k] = 0
		k++
		name[0] = '.'
		copy(newBlock[k:], name[:1])
		k += BlockNameMaxSize
		U32toB4(newBlockindex, b4[:])
		copy(newBlock[k:], b4[:])
		k += 4
		copy(newBlock[k:], b4[:])
		k += 4
		ls := uint16(4 + 4 + 4 + 25 + 25)
		U16toB2(ls, b2[:])
		copy(newBlock[k:], b2[:])
		k += 2

		newBlock[k] = 0
		k++
		name[1] = '.'
		copy(newBlock[k:], name[:2])
		k += BlockNameMaxSize
		U32toB4(startBlockindex, b4[:])
		copy(newBlock[k:], b4[:])
		k += 4
		k += 4
		k += 2
		if !ffs.writeblock(newBlockindex, newBlock[:]) {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 1
		}

		k = int(offset)
		curBlock[k] = 0
		k++
		for i := 0; i < BlockNameMaxSize; i++ {
			curBlock[k+i] = 0
		}
		copy(curBlock[k:k+len(lastname)], lastname)
		k += BlockNameMaxSize
		U32toB4(newBlockindex, b4[:])
		copy(curBlock[k:], b4[:])
		k += 4
		k += 4
		k += 2
		newOffset := uint16(k)
		U16toB2(newOffset, b2[:])

		if curBlockindex == startBlockindex {
			copy(curBlock[BlockOffset:], b2[:])
			if !ffs.writeblock(curBlockindex, curBlock) {
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
		} else {
			if !ffs.writeblock(curBlockindex, curBlock) {
				if ffs.Tmp.State == 1 {
					ffs.tmpstop()
				}
				return 1
			}
			copy(startBlock[BlockOffset:], b2[:])
			if !ffs.writeblock(startBlockindex, startBlock) {
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
		}
		return 0
	}

	newBlockindex := ffs.genblockindex()
	if newBlockindex == 0 {
		if ffs.Tmp.State == 1 {
			ffs.tmpstop()
		}
		return 1
	}
	blockindex2 := ffs.genblockindex()
	if blockindex2 == 0 {
		if ffs.Tmp.State == 1 {
			ffs.tmpstop()
		}
		return 1
	}
	for i := range block2 {
		block2[i] = 0
	}
	k := 8
	U32toB4(curBlockindex, b4[:])
	copy(block2[k:], b4[:])
	k += 4
	block2[k] = 0
	k++
	for i := 0; i < BlockNameMaxSize; i++ {
		block2[k+i] = 0
	}
	copy(block2[k:k+len(lastname)], lastname)
	k += BlockNameMaxSize
	U32toB4(newBlockindex, b4[:])
	copy(block2[k:], b4[:])
	k += 4
	k += 4
	k += 2
	newOffset := uint16(k)

	if !ffs.writeblock(blockindex2, block2[:]) {
		if ffs.Tmp.State == 1 {
			ffs.tmpstop()
		}
		return 1
	}

	for i := range newBlock {
		newBlock[i] = 0
	}
	k = BlockHead
	newBlock[k] = 0
	k++
	for i := range name {
		name[i] = 0
	}
	name[0] = '.'
	copy(newBlock[k:], name[:1])
	k += BlockNameMaxSize
	U32toB4(newBlockindex, b4[:])
	copy(newBlock[k:], b4[:])
	k += 4
	copy(newBlock[k:], b4[:])
	k += 4
	ls := uint16(4 + 4 + 4 + 25 + 25)
	U16toB2(ls, b2[:])
	copy(newBlock[k:], b2[:])
	k += 2

	newBlock[k] = 0
	k++
	name[1] = '.'
	copy(newBlock[k:], name[:2])
	k += BlockNameMaxSize
	U32toB4(startBlockindex, b4[:])
	copy(newBlock[k:], b4[:])
	k += 4
	k += 4
	k += 2
	if !ffs.writeblock(newBlockindex, newBlock[:]) {
		if ffs.Tmp.State == 1 {
			ffs.tmpstop()
		}
		return 1
	}

	U16toB2(newOffset, b2[:])
	U32toB4(blockindex2, b4[:])
	copy(curBlock[4:], b4[:])

	if curBlockindex == startBlockindex {
		copy(curBlock[BlockStopBlockindex:], b4[:])
		copy(curBlock[BlockOffset:], b2[:])
		if !ffs.writeblock(curBlockindex, curBlock) {
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
	} else {
		if !ffs.writeblock(curBlockindex, curBlock) {
			if ffs.Tmp.State == 1 {
				ffs.tmpstop()
			}
			return 1
		}
		copy(startBlock[BlockStopBlockindex:], b4[:])
		copy(startBlock[BlockOffset:], b2[:])
		if !ffs.writeblock(startBlockindex, startBlock) {
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
	}
	_ = stopBlockindex
	return 0
}

// Mkdir creates a directory. return: 0-ok,1-gen err,2-name>limit,3-path existed,4-exist same name file
func (ffs *FileFS) Mkdir(pathname string) int {
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
			index := ffs.findPathBlockindex(blockindex, string(s[:slen]))
			if index < 1 {
				if i == lenN-1 {
					break
				}
				return 1
			}
			blockindex = index
			slen = 0
			continue
		}
		s[slen] = pathname[i]
		slen++
		if slen > BlockNameMaxSize {
			return 2
		}
	}
	if slen == 0 {
		return 3
	}
	lastname := string(s[:slen])
	if len(lastname) > BlockNameMaxSize {
		return 2
	}

	var startBlock, block [BlockSize]byte
	var b4 [4]byte
	var b2 [2]byte
	if !ffs.readblock(blockindex, block[:]) {
		return 1
	}
	copy(startBlock[:], block[:])
	startBlockindex := blockindex

	copy(b4[:], block[12+1+14+4:12+1+14+8])
	stopBlockindex := B4toU32(b4[:])
	copy(b2[:], block[12+1+14+4+4:12+1+14+4+6])
	offset := B2toU16(b2[:])

	flag := false
	index := startBlockindex
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
					flag = true
					break
				}
				continue
			}
			dirFile := state & 0x01
			if dirFile == 0 {
				return 3
			}
			return 4
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

	return ffs.doMkdir(lastname, startBlockindex, startBlock[:], index, block[:], stopBlockindex, offset)
}

// Rmdir removes an empty directory. return: 0-ok,1-gen err,2-sub dir not empty,3-path not existed,4-name>limit
