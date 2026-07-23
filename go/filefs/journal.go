package filefs

import (
	"os"
)

// Journal recovery: apply pending <file>-j into the main image.
func (ffs *FileFS) j2ffs() {
	fpj, err := os.Open(ffs.Fnj)
	if err != nil {
		return
	}
	defer func() {
		_ = fpj.Close()
		_ = os.Remove(ffs.Fnj)
	}()

	var state [1]byte
	n, err := fpj.Read(state[:])
	if err != nil || n != 1 {
		return
	}
	if state[0] != 0xff {
		return
	}

	var indexBlock [4 + BlockSize]byte
	for {
		n, err = fpj.Read(indexBlock[:])
		if err != nil || n != 4+BlockSize {
			break
		}
		index := B4toU32(indexBlock[:4])
		pos := uint64(index) * BlockSize
		if ffsFsetpos(ffs.Fp, pos) != nil {
			break
		}
		wn, werr := ffs.Fp.Write(indexBlock[4 : 4+BlockSize])
		if werr != nil || wn != BlockSize {
			break
		}
	}
	ffsFflush(ffs.Fp)
}

// Begin starts a manual transaction (C: FileFS_begin).
