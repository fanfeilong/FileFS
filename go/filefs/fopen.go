package filefs

// Fopen opens a virtual file with fopen-like modes (C: FileFS_fopen).
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
