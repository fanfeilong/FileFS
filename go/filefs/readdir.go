package filefs

// Opendir opens a directory for iteration (C: FileFS_opendir).
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
