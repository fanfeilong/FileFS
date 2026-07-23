package filefs

// stat returns 0:not exist, 1:is file, 2:is dir.
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
