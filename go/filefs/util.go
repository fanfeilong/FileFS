package filefs

import (
	"os"
)

func B4toU32(byte4 []byte) uint32 {
	return uint32(byte4[0]&0xFF) |
		(uint32(byte4[1]&0xFF) << 8) |
		(uint32(byte4[2]&0xFF) << 16) |
		(uint32(byte4[3]&0xFF) << 24)
}

func U32toB4(v uint32, byte4 []byte) {
	byte4[0] = byte(v & 0x000000FF)
	byte4[1] = byte((v & 0x0000FF00) >> 8)
	byte4[2] = byte((v & 0x00FF0000) >> 16)
	byte4[3] = byte((v & 0xFF000000) >> 24)
}

func B2toU16(byte2 []byte) uint16 {
	return uint16(byte2[0]&0xFF) | (uint16(byte2[1]&0xFF) << 8)
}

func U16toB2(v uint16, byte2 []byte) {
	byte2[0] = byte(v & 0x00FF)
	byte2[1] = byte((v & 0xFF00) >> 8)
}

func ffsFsetpos(fp *os.File, pos uint64) error {
	_, err := fp.Seek(int64(pos), 0)
	return err
}

func ffsFflush(fp *os.File) {
	_ = fp.Sync()
}

func ffsRewind(fp *os.File) {
	_, _ = fp.Seek(0, 0)
}

// cstrFromFixed returns a Go string from a NUL-padded fixed buffer (C strcmp semantics).
func cstrFromFixed(b []byte) string {
	n := 0
	for n < len(b) && b[n] != 0 {
		n++
	}
	return string(b[:n])
}

// copyNameInto copies a name into a fixed BLOCK_NAME_MAXSIZE field (zero-padded).
func copyNameInto(dst []byte, name string) {
	for i := range dst {
		dst[i] = 0
	}
	n := len(name)
	if n > len(dst) {
		n = len(dst)
	}
	copy(dst[:n], name)
}
