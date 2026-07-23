package filefs

import (
	"os"
)

// Transaction helpers and Begin/Commit/Rollback API.
func (ffs *FileFS) tmpstart(state uint8) bool {
	if state == 0 {
		return false
	}
	if ffs.Tmp.State != 0 {
		ffs.tmpstop()
	}

	var block [12]byte
	ffsRewind(ffs.Fp)
	n, err := ffs.Fp.Read(block[:])
	if err != nil || n != 12 {
		return false
	}
	ffs.Tmp.TotalBlocksize = B4toU32(block[4:8])
	ffs.Tmp.UnusedBlockhead = B4toU32(block[8:12])
	ffs.Tmp.NewTotalBlocksize = ffs.Tmp.TotalBlocksize
	ffs.Tmp.NewUnusedBlockhead = ffs.Tmp.UnusedBlockhead

	fpCp, err := os.CreateTemp("", "filefs-cp-*")
	if err != nil {
		return false
	}
	ffs.Tmp.FpCp = fpCp
	ffs.Tmp.CpPath = fpCp.Name()

	fpAdd, err := os.CreateTemp("", "filefs-add-*")
	if err != nil {
		_ = ffs.Tmp.FpCp.Close()
		_ = os.Remove(ffs.Tmp.CpPath)
		ffs.Tmp.FpCp = nil
		ffs.Tmp.CpPath = ""
		return false
	}
	ffs.Tmp.FpAdd = fpAdd
	ffs.Tmp.AddPath = fpAdd.Name()

	ffs.Tmp.Pwd = ffs.Pwd
	ffs.Tmp.PwdBlockindex = ffs.PwdBlockindex

	ffs.Tmp.CpSize = 0
	ffs.Tmp.State = state
	return true
}

func (ffs *FileFS) tmpstop() {
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
	ffs.Tmp.CpSize = 0
	ffs.Tmp.State = 0
}

func (ffs *FileFS) Begin() bool {
	if ffs == nil {
		return false
	}
	if ffs.Fp == nil {
		return false
	}
	if ffs.Tmp.FpCp != nil {
		ffs.Rollback()
	}
	return ffs.tmpstart(2)
}

// Rollback aborts the current transaction (C: FileFS_rollback).
func (ffs *FileFS) Rollback() {
	if ffs == nil {
		return
	}
	if ffs.Fp == nil {
		return
	}
	_ = os.Remove(ffs.Fnj)
	if ffs.Tmp.FpCp == nil {
		return
	}
	ffs.tmpstop()
}

// Commit commits the current transaction (C: FileFS_commit).
func (ffs *FileFS) Commit() bool {
	if ffs == nil {
		return true
	}
	if ffs.Fp == nil {
		return true
	}
	if ffs.Tmp.FpCp == nil {
		return true
	}

	{
		fp, err := os.Create(ffs.Fnj)
		if err != nil {
			ffs.tmpstop()
			return false
		}

		signal := []byte{0}
		if n, err := fp.Write(signal); err != nil || n != 1 {
			_ = fp.Close()
			ffs.tmpstop()
			return false
		}

		var b4 [4]byte
		var block [BlockSize + 4]byte

		if ffs.Tmp.TotalBlocksize != ffs.Tmp.NewTotalBlocksize ||
			ffs.Tmp.UnusedBlockhead != ffs.Tmp.NewUnusedBlockhead {
			for i := range b4 {
				b4[i] = 0
			}
			_, _ = fp.Write(b4[:])

			for i := range block[:BlockSize] {
				block[i] = 0
			}
			k := 0
			copy(block[k:], magicNumber[:])
			k += 4
			U32toB4(ffs.Tmp.NewTotalBlocksize, b4[:])
			copy(block[k:], b4[:])
			k += 4
			U32toB4(ffs.Tmp.NewUnusedBlockhead, b4[:])
			copy(block[k:], b4[:])
			_, _ = fp.Write(block[:BlockSize])
		}

		ffsRewind(ffs.Tmp.FpCp)
		for {
			n, err := ffs.Tmp.FpCp.Read(block[:])
			if err != nil || n != BlockSize+4 {
				break
			}
			if wn, werr := fp.Write(block[:]); werr != nil || wn != BlockSize+4 {
				_ = fp.Close()
				ffs.tmpstop()
				return false
			}
		}

		ffsRewind(ffs.Tmp.FpAdd)
		for {
			n, err := ffs.Tmp.FpAdd.Read(block[:])
			if err != nil || n != BlockSize+4 {
				break
			}
			if wn, werr := fp.Write(block[:]); werr != nil || wn != BlockSize+4 {
				_ = fp.Close()
				ffs.tmpstop()
				return false
			}
		}

		ffsRewind(fp)
		signal[0] = 0xff
		if n, err := fp.Write(signal); err != nil || n != 1 {
			_ = fp.Close()
			ffs.tmpstop()
			return false
		}
		ffsFflush(fp)
		_ = fp.Close()

		fp, err = os.Open(ffs.Fnj)
		if err != nil {
			ffs.tmpstop()
			return false
		}

		if n, err := fp.Read(signal); err != nil || n != 1 {
			_ = fp.Close()
			ffs.tmpstop()
			return false
		}
		for {
			n, err := fp.Read(block[:])
			if err != nil || n != BlockSize+4 {
				break
			}
			blockindex := B4toU32(block[:4])
			pos := uint64(blockindex) * BlockSize
			if ffsFsetpos(ffs.Fp, pos) != nil {
				_ = fp.Close()
				ffs.tmpstop()
				return false
			}
			if wn, werr := ffs.Fp.Write(block[4 : 4+BlockSize]); werr != nil || wn != BlockSize {
				_ = fp.Close()
				ffs.tmpstop()
				return false
			}
		}
		_ = fp.Close()

		ffsFflush(ffs.Fp)
		_ = os.Remove(ffs.Fnj)
	}

	ffs.Pwd = ffs.Tmp.Pwd
	ffs.PwdBlockindex = ffs.Tmp.PwdBlockindex

	ffs.tmpstop()
	return true
}
