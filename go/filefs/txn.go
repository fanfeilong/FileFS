package filefs

import (
	"os"
)

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

func (ffs *FileFS) genblockindex() uint32 {
	var block [BlockSize]byte

	if ffs.Tmp.NewUnusedBlockhead > 0 {
		blockindex := ffs.Tmp.NewUnusedBlockhead
		if !ffs.readblock(blockindex, block[:]) {
			return 0
		}
		ffs.Tmp.NewUnusedBlockhead = B4toU32(block[4:8])
		return blockindex
	}

	blockindex := ffs.Tmp.NewTotalBlocksize
	addindex := blockindex - ffs.Tmp.TotalBlocksize
	pos := uint64(addindex) * uint64(4+BlockSize)
	if ffsFsetpos(ffs.Tmp.FpAdd, pos) != nil {
		return 0
	}
	var b4 [4]byte
	U32toB4(blockindex, b4[:])
	if n, err := ffs.Tmp.FpAdd.Write(b4[:]); err != nil || n != 4 {
		return 0
	}
	if n, err := ffs.Tmp.FpAdd.Write(block[:]); err != nil || n != BlockSize {
		return 0
	}
	ffs.Tmp.NewTotalBlocksize++
	return blockindex
}

func (ffs *FileFS) readblock(blockindex uint32, block []byte) bool {
	pos := uint64(blockindex) * BlockSize
	if ffsFsetpos(ffs.Fp, pos) != nil {
		return false
	}
	var buf [4]byte
	n, err := ffs.Fp.Read(buf[:])
	if err != nil || n != 4 {
		if ffs.Tmp.State == 0 {
			return false
		}
		if blockindex < ffs.Tmp.TotalBlocksize {
			return false
		}
		addindex := blockindex - ffs.Tmp.TotalBlocksize
		pos = uint64(addindex)*uint64(BlockSize+4) + 4
		if ffsFsetpos(ffs.Tmp.FpAdd, pos) != nil {
			return false
		}
		n, err = ffs.Tmp.FpAdd.Read(block[:BlockSize])
		return err == nil && n == BlockSize
	}

	if ffs.Tmp.State == 0 {
		copy(block[:4], buf[:])
		n, err = ffs.Fp.Read(block[4:BlockSize])
		return err == nil && n == BlockSize-4
	}

	var b4 [4]byte
	copy(b4[:], buf[:])
	cpindex := B4toU32(b4[:])
	pos = uint64(cpindex) * uint64(BlockSize+4)
	if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
		return false
	}
	n, err = ffs.Tmp.FpCp.Read(b4[:])
	if err != nil || n != 4 {
		copy(block[:4], buf[:])
		n, err = ffs.Fp.Read(block[4:BlockSize])
		return err == nil && n == BlockSize-4
	}
	orgindex := B4toU32(b4[:])
	if orgindex != blockindex {
		copy(block[:4], buf[:])
		n, err = ffs.Fp.Read(block[4:BlockSize])
		return err == nil && n == BlockSize-4
	}
	n, err = ffs.Tmp.FpCp.Read(block[:BlockSize])
	return err == nil && n == BlockSize
}

func (ffs *FileFS) writeblock(blockindex uint32, block []byte) bool {
	if ffs.Tmp.State == 0 {
		return false
	}

	pos := uint64(blockindex) * BlockSize
	if ffsFsetpos(ffs.Fp, pos) != nil {
		return false
	}
	var buf [4]byte
	n, err := ffs.Fp.Read(buf[:])
	if err != nil || n != 4 {
		if blockindex < ffs.Tmp.TotalBlocksize {
			return false
		}
		addindex := blockindex - ffs.Tmp.TotalBlocksize
		pos = uint64(addindex)*uint64(BlockSize+4) + 4
		if ffsFsetpos(ffs.Tmp.FpAdd, pos) != nil {
			return false
		}
		n, err = ffs.Tmp.FpAdd.Write(block[:BlockSize])
		return err == nil && n == BlockSize
	}

	var b4 [4]byte
	copy(b4[:], buf[:])
	cpindex := B4toU32(b4[:])
	pos = uint64(cpindex) * uint64(BlockSize+4)
	if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
		return false
	}
	n, err = ffs.Tmp.FpCp.Read(b4[:])
	if err != nil || n != 4 {
		cpindex = uint32(ffs.Tmp.CpSize)
		pos = uint64(cpindex) * uint64(BlockSize+4)
		if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
			return false
		}
		U32toB4(blockindex, b4[:])
		if n, err = ffs.Tmp.FpCp.Write(b4[:]); err != nil || n != 4 {
			return false
		}
		if n, err = ffs.Tmp.FpCp.Write(block[:BlockSize]); err != nil || n != BlockSize {
			return false
		}
		pos = uint64(blockindex) * BlockSize
		if ffsFsetpos(ffs.Fp, pos) != nil {
			return false
		}
		U32toB4(cpindex, b4[:])
		if n, err = ffs.Fp.Write(b4[:]); err != nil || n != 4 {
			return false
		}
		ffs.Tmp.CpSize++
		return true
	}
	orgindex := B4toU32(b4[:])
	if orgindex != blockindex {
		cpindex = uint32(ffs.Tmp.CpSize)
		pos = uint64(cpindex) * uint64(BlockSize+4)
		if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
			return false
		}
		U32toB4(blockindex, b4[:])
		if n, err = ffs.Tmp.FpCp.Write(b4[:]); err != nil || n != 4 {
			return false
		}
		if n, err = ffs.Tmp.FpCp.Write(block[:BlockSize]); err != nil || n != BlockSize {
			return false
		}
		pos = uint64(blockindex) * BlockSize
		if ffsFsetpos(ffs.Fp, pos) != nil {
			return false
		}
		U32toB4(cpindex, b4[:])
		if n, err = ffs.Fp.Write(b4[:]); err != nil || n != 4 {
			return false
		}
		ffs.Tmp.CpSize++
		return true
	}

	pos = uint64(cpindex)*uint64(BlockSize+4) + 4
	if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
		return false
	}
	n, err = ffs.Tmp.FpCp.Write(block[:BlockSize])
	return err == nil && n == BlockSize
}

func (ffs *FileFS) removeblock(blockindex uint32) bool {
	if ffs.Tmp.State == 0 {
		return false
	}

	pos := uint64(blockindex) * BlockSize
	if ffsFsetpos(ffs.Fp, pos) != nil {
		return false
	}
	var buf [4]byte
	n, err := ffs.Fp.Read(buf[:])
	if err != nil || n != 4 {
		if blockindex < ffs.Tmp.TotalBlocksize {
			return false
		}
		addindex := blockindex - ffs.Tmp.TotalBlocksize
		pos = uint64(addindex)*uint64(BlockSize+4) + 4 + 4
		if ffsFsetpos(ffs.Tmp.FpAdd, pos) != nil {
			return false
		}
		var b4 [4]byte
		U32toB4(ffs.Tmp.NewUnusedBlockhead, b4[:])
		if n, err = ffs.Tmp.FpAdd.Write(b4[:]); err != nil || n != 4 {
			return false
		}
		ffs.Tmp.NewUnusedBlockhead = blockindex
		return true
	}

	var b4 [4]byte
	copy(b4[:], buf[:])
	cpindex := B4toU32(b4[:])
	pos = uint64(cpindex) * uint64(BlockSize+4)
	if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
		return false
	}
	n, err = ffs.Tmp.FpCp.Read(b4[:])
	if err != nil || n != 4 {
		cpindex = uint32(ffs.Tmp.CpSize)
		pos = uint64(cpindex) * uint64(BlockSize+4)
		if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
			return false
		}
		U32toB4(blockindex, b4[:])
		if n, err = ffs.Tmp.FpCp.Write(b4[:]); err != nil || n != 4 {
			return false
		}
		var block [BlockSize]byte
		U32toB4(ffs.Tmp.NewUnusedBlockhead, b4[:])
		copy(block[:4], b4[:])
		pos += 8
		if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
			return false
		}
		if n, err = ffs.Tmp.FpCp.Write(block[:]); err != nil || n != BlockSize {
			return false
		}
		pos = uint64(blockindex) * BlockSize
		if ffsFsetpos(ffs.Fp, pos) != nil {
			return false
		}
		U32toB4(cpindex, b4[:])
		if n, err = ffs.Fp.Write(b4[:]); err != nil || n != 4 {
			return false
		}
		ffs.Tmp.CpSize++
		ffs.Tmp.NewUnusedBlockhead = blockindex
		return true
	}
	orgindex := B4toU32(b4[:])
	if orgindex != blockindex {
		cpindex = uint32(ffs.Tmp.CpSize)
		pos = uint64(cpindex) * uint64(BlockSize+4)
		if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
			return false
		}
		U32toB4(blockindex, b4[:])
		if n, err = ffs.Tmp.FpCp.Write(b4[:]); err != nil || n != 4 {
			return false
		}
		var block [BlockSize]byte
		U32toB4(ffs.Tmp.NewUnusedBlockhead, b4[:])
		copy(block[:4], b4[:])
		pos += 8
		if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
			return false
		}
		if n, err = ffs.Tmp.FpCp.Write(block[:]); err != nil || n != BlockSize {
			return false
		}
		pos = uint64(blockindex) * BlockSize
		if ffsFsetpos(ffs.Fp, pos) != nil {
			return false
		}
		U32toB4(cpindex, b4[:])
		if n, err = ffs.Fp.Write(b4[:]); err != nil || n != 4 {
			return false
		}
		ffs.Tmp.CpSize++
		ffs.Tmp.NewUnusedBlockhead = blockindex
		return true
	}
	pos += 8
	if ffsFsetpos(ffs.Tmp.FpCp, pos) != nil {
		return false
	}
	U32toB4(ffs.Tmp.NewUnusedBlockhead, b4[:])
	if n, err = ffs.Tmp.FpCp.Write(b4[:]); err != nil || n != 4 {
		return false
	}
	ffs.Tmp.NewUnusedBlockhead = blockindex
	return true
}

func (ffs *FileFS) findPathBlockindex(blockindex uint32, pathname string) uint32 {
	var block [BlockSize]byte
	index := blockindex
	var b4 [4]byte
	var b2 [2]byte
	var s [BlockNameMaxSize + 1]byte

	if !ffs.readblock(index, block[:]) {
		return 0
	}
	copy(b4[:], block[12+1+14+4:12+1+14+4+4])
	stopBlockindex := B4toU32(b4[:])
	copy(b2[:], block[12+1+14+4+4:12+1+14+4+4+2])
	offset := B2toU16(b2[:])

	for {
		k := BlockHead
		for i := 0; i < BlockItemMaxCount; i++ {
			state := block[k]
			k++
			dirFile := state & 0x01
			if dirFile == 1 {
				k += 24
				if index == stopBlockindex && k+1 >= int(offset) {
					return 0
				}
				continue
			}
			copy(s[:BlockNameMaxSize], block[k:k+BlockNameMaxSize])
			k += BlockNameMaxSize
			if cstrFromFixed(s[:]) != pathname {
				k += 10
				if index == stopBlockindex && k+1 >= int(offset) {
					return 0
				}
				continue
			}
			copy(b4[:], block[k:k+4])
			return B4toU32(b4[:])
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
