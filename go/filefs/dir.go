package filefs

func (ffs *FileFS) initPwdtmp(s string) bool {
	ffs.PwdTmp = s
	return true
}

func (ffs *FileFS) addToPwdtmp(pathsize int, s string) bool {
	if s == "." {
		return true
	}
	pwd := ffs.PwdTmp
	lenP := len(pwd)

	if s == ".." {
		for i := 1; i < lenP; i++ {
			if pwd[lenP-i-1] == '/' {
				ffs.PwdTmp = pwd[:lenP-i]
				return true
			}
		}
		return false
	}

	ffs.PwdTmp = pwd + s + "/"
	_ = pathsize
	return true
}

// Chdir changes the current working directory (C: FileFS_chdir).
func (ffs *FileFS) Chdir(pathname string) bool {
	if ffs == nil || ffs.Fp == nil {
		return false
	}
	lenN := len(pathname)
	var blockindex uint32
	var start int
	if lenN > 0 && pathname[0] == '/' {
		blockindex = 1
		start = 1
		if !ffs.initPwdtmp("/") {
			return false
		}
	} else {
		if ffs.Tmp.State == 0 {
			blockindex = ffs.PwdBlockindex
			if !ffs.initPwdtmp(ffs.Pwd) {
				return false
			}
		} else {
			blockindex = ffs.Tmp.PwdBlockindex
			if !ffs.initPwdtmp(ffs.Tmp.Pwd) {
				return false
			}
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
				return false
			}
			blockindex = index
			if !ffs.addToPwdtmp(lenN, string(s[:slen])) {
				return false
			}
			slen = 0
			continue
		}
		s[slen] = pathname[i]
		slen++
		if slen > BlockNameMaxSize {
			return false
		}
	}
	if slen > 0 {
		index := ffs.findPathBlockindex(blockindex, string(s[:slen]))
		if index < 1 {
			return false
		}
		blockindex = index
		if !ffs.addToPwdtmp(lenN, string(s[:slen])) {
			return false
		}
	}

	if ffs.Tmp.State == 0 {
		ffs.Pwd = ffs.PwdTmp
		ffs.PwdBlockindex = blockindex
	} else {
		ffs.Tmp.Pwd = ffs.PwdTmp
		ffs.Tmp.PwdBlockindex = blockindex
	}
	return true
}

// Getcwd returns the current working directory (C: FileFS_getcwd).
func (ffs *FileFS) Getcwd() string {
	if ffs == nil {
		return ""
	}
	if ffs.Tmp.State == 0 {
		return ffs.Pwd
	}
	return ffs.Tmp.Pwd
}

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
func (ffs *FileFS) Opendir(path string) (*Dir, string) {
	if ffs == nil || ffs.Fp == nil {
		return nil, ""
	}
	dir := &Dir{}
	lenN := len(path)
	var blockindex uint32
	var start int
	if lenN > 0 && path[0] == '/' {
		blockindex = 1
		start = 1
		if !ffs.initPwdtmp("/") {
			return nil, ""
		}
	} else {
		if ffs.Tmp.State == 0 {
			blockindex = ffs.PwdBlockindex
			if !ffs.initPwdtmp(ffs.Pwd) {
				return nil, ""
			}
		} else {
			blockindex = ffs.Tmp.PwdBlockindex
			if !ffs.initPwdtmp(ffs.Tmp.Pwd) {
				return nil, ""
			}
		}
		start = 0
	}

	var s [BlockNameMaxSize + 2]byte
	slen := 0
	for i := start; i < lenN; i++ {
		if path[i] == '/' {
			if slen == 0 {
				continue
			}
			comp := string(s[:slen])
			index := ffs.findPathBlockindex(blockindex, comp)
			if index < 1 {
				return nil, ""
			}
			blockindex = index
			slen = 0
			if !ffs.addToPwdtmp(lenN, comp) {
				return nil, ""
			}
			continue
		}
		s[slen] = path[i]
		slen++
		if slen > BlockNameMaxSize {
			return nil, ""
		}
	}
	if slen > 0 {
		index := ffs.findPathBlockindex(blockindex, string(s[:slen]))
		if index < 1 {
			return nil, ""
		}
		blockindex = index
		if !ffs.addToPwdtmp(lenN, string(s[:slen])) {
			return nil, ""
		}
	}

	if !ffs.readblock(blockindex, dir.Block[:]) {
		return nil, ""
	}
	var b4 [4]byte
	var b2 [2]byte
	copy(b4[:], dir.Block[12+1+14+4:12+1+14+8])
	dir.StopBlockindex = B4toU32(b4[:])
	copy(b2[:], dir.Block[12+1+14+4+4:12+1+14+4+6])
	dir.Offset = B2toU16(b2[:])
	dir.Blockindex = blockindex
	dir.Searchindex = 0
	return dir, ffs.PwdTmp
}

// Readdir reads the next directory entry (C: FileFS_readdir).
func (ffs *FileFS) Readdir(dir *Dir) *Dirent {
	if ffs == nil || ffs.Fp == nil || dir == nil {
		return nil
	}

	block := dir.Block[:]
	k := BlockHead + dir.Searchindex*25
	if dir.Blockindex == dir.StopBlockindex && k+1 >= int(dir.Offset) {
		return nil
	}
	var b4 [4]byte
	for {
		if dir.Searchindex >= BlockItemMaxCount {
			nextindex := B4toU32(block[4:8])
			if nextindex == 0 {
				return nil
			}
			if !ffs.readblock(nextindex, dir.Block[:]) {
				return nil
			}
			block = dir.Block[:]
			dir.Searchindex = 0
			dir.Blockindex = nextindex
			k = BlockHead + dir.Searchindex*25
			continue
		}

		state := block[k]
		k++
		dirFile := state & 0x01
		if dirFile == 1 {
			dir.Dirp.DType = DTFile
		} else {
			dir.Dirp.DType = DTDir
		}

		for i := range dir.Dirp.DName {
			dir.Dirp.DName[i] = 0
		}
		copy(dir.Dirp.DName[:BlockNameMaxSize], block[k:k+BlockNameMaxSize])
		k += BlockNameMaxSize
		name := cstrFromFixed(dir.Dirp.DName[:])
		dir.Dirp.DNamlen = len(name)
		if name == "." {
			copy(b4[:], block[k:k+4])
			dirblockindex := B4toU32(b4[:])
			if dirblockindex == 1 {
				dir.Dirp.DType = DTRoot
			}
		} else if name == ".." {
			copy(b4[:], block[k:k+4])
			dirblockindex := B4toU32(b4[:])
			if dirblockindex == 0 {
				dir.Dirp.DType = DTRoot
			}
		}
		k += 10
		dir.Searchindex++
		return &dir.Dirp
	}
}

// Closedir closes a directory handle (C: FileFS_closedir).
func (ffs *FileFS) Closedir(dir *Dir) {
	_ = ffs
	_ = dir
}
