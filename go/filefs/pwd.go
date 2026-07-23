package filefs

// Working-directory helpers (chdir / getcwd).
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

