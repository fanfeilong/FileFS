package filefs

import (
	"os"
)

// Create allocates a new FileFS instance (C: FileFS_create).
func Create() *FileFS {
	return &FileFS{}
}

// Destroy umounts and releases the FileFS instance (C: FileFS_destroy).
func (ffs *FileFS) Destroy() {
	if ffs == nil {
		return
	}
	ffs.Umount()
}

// Mkfs formats a new FileFS image file (C: FileFS_mkfs).
func Mkfs(filename string) bool {
	fp, err := os.Create(filename)
	if err != nil {
		return false
	}

	var block [BlockSize]byte
	var b4 [4]byte
	var b2 [2]byte

	// block[0]
	k := 0
	copy(block[k:], magicNumber[:])
	k += 4
	n := uint32(2)
	U32toB4(n, b4[:])
	copy(block[k:], b4[:])
	k += 4

	if wn, err := fp.Write(block[:]); err != nil || wn != BlockSize {
		_ = fp.Close()
		return false
	}

	// block[1], root directory
	for i := range block {
		block[i] = 0
	}
	k = 0
	k += 4 // tmpindex
	k += 4 // next
	k += 4 // prev

	var state byte
	var name [BlockNameMaxSize + 1]byte

	// .
	state = 0
	block[k] = state
	k++
	name[0] = '.'
	copy(block[k:], name[:1])
	k += BlockNameMaxSize
	n = 1
	U32toB4(n, b4[:])
	copy(block[k:], b4[:])
	k += 4
	copy(block[k:], b4[:])
	k += 4
	offset := uint16(4 + 4 + 4 + 25 + 25)
	U16toB2(offset, b2[:])
	copy(block[k:], b2[:])
	k += 2

	// ..
	state = 0
	block[k] = state
	k++
	name[1] = '.'
	copy(block[k:], name[:2])
	k += BlockNameMaxSize
	k += 4
	k += 4
	k += 2

	if wn, err := fp.Write(block[:]); err != nil || wn != BlockSize {
		_ = fp.Close()
		return false
	}

	ffsFflush(fp)
	_ = fp.Close()

	fnj := filename + "-j"
	_ = os.Remove(fnj)
	return true
}

// Mount opens an existing FileFS image (C: FileFS_mount).
func (ffs *FileFS) Mount(filename string) bool {
	if ffs == nil {
		return false
	}

	fp, err := os.OpenFile(filename, os.O_RDWR, 0)
	if err != nil {
		return false
	}

	var block [BlockSize]byte
	if n, err := fp.Read(block[:]); err != nil || n != BlockSize {
		_ = fp.Close()
		return false
	}

	k := 0
	var mn [4]byte
	copy(mn[:], block[k:k+4])
	k += 4
	if mn != magicNumber {
		_ = fp.Close()
		return false
	}
	var b4 [4]byte
	copy(b4[:], block[k:k+4])
	k += 4
	bs := B4toU32(b4[:])
	if bs < 2 {
		_ = fp.Close()
		return false
	}

	if n, err := fp.Read(block[:]); err != nil || n != BlockSize {
		_ = fp.Close()
		return false
	}

	var state byte
	var name [BlockNameMaxSize + 1]byte
	k = 0
	k += 4
	k += 4
	k += 4

	state = block[k]
	k++
	if state != 0 {
		_ = fp.Close()
		return false
	}
	copy(name[:BlockNameMaxSize], block[k:k+BlockNameMaxSize])
	k += BlockNameMaxSize
	if cstrFromFixed(name[:]) != "." {
		_ = fp.Close()
		return false
	}
	k += 4
	k += 4
	k += 2

	state = block[k]
	k++
	if state != 0 {
		_ = fp.Close()
		return false
	}
	copy(name[:BlockNameMaxSize], block[k:k+BlockNameMaxSize])
	k += BlockNameMaxSize
	if cstrFromFixed(name[:]) != ".." {
		_ = fp.Close()
		return false
	}

	if ffs.Fp != nil {
		_ = ffs.Fp.Close()
		ffs.Fp = nil
	}
	ffs.Fn = ""
	ffs.Fnj = ""

	ffs.Fp = fp
	ffs.Fn = filename
	ffs.Fnj = filename + "-j"
	ffs.Pwd = "/"
	ffs.PwdBlockindex = 1

	ffs.j2ffs()
	return true
}

// Umount closes the mounted filesystem (C: FileFS_umount).
func (ffs *FileFS) Umount() {
	if ffs == nil {
		return
	}
	if ffs.Fp != nil {
		_ = ffs.Fp.Close()
		ffs.Fp = nil
	}
	ffs.Fn = ""
	if ffs.Fnj != "" {
		_ = os.Remove(ffs.Fnj)
		ffs.Fnj = ""
	}
	if ffs.Tmp.FpCp != nil {
		_ = ffs.Tmp.FpCp.Close()
		if ffs.Tmp.CpPath != "" {
			_ = os.Remove(ffs.Tmp.CpPath)
		}
		ffs.Tmp.FpCp = nil
		ffs.Tmp.CpPath = ""
	}
	if ffs.Tmp.FpAdd != nil {
		_ = ffs.Tmp.FpAdd.Close()
		if ffs.Tmp.AddPath != "" {
			_ = os.Remove(ffs.Tmp.AddPath)
		}
		ffs.Tmp.FpAdd = nil
		ffs.Tmp.AddPath = ""
	}
	ffs.Tmp.Pwd = ""
	ffs.Pwd = ""
	ffs.PwdBlockindex = 0
	ffs.PwdTmp = ""
}

// IsMount reports whether a filesystem image is mounted (C: FileFS_ismount).
func (ffs *FileFS) IsMount() bool {
	if ffs == nil {
		return false
	}
	return ffs.Fp != nil
}
