package filefs


// Move relocates an entry into another directory (C: FileFS_move).

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
