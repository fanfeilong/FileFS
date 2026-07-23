// Package filefs is a pure-Go port of FileFS — a virtual filesystem in a single file.
package filefs

import "os"

const (
	BlockSize         = 512
	BlockItemMaxCount = 20
	BlockHead         = 12
	BlockNameMaxSize  = 14
	// .->start_blockindex in block: head 12 + state 1 + name 14
	BlockStartBlockindex = 27
	// .->stop_blockindex: head 12 + state 1 + name 14 + start 4
	BlockStopBlockindex = 31
	// .->listsize/offset: head 12 + state 1 + name 14 + start 4 + stop 4
	BlockOffset = 35
)

// Dirent type constants (C: FFS_DT_*).
const (
	DTFile = 0
	DTDir  = 1
	DTRoot = 2
)

// Seek constants (C: FFS_SEEK_*).
const (
	SeekSet = 0
	SeekCur = 1
	SeekEnd = 2
)

var magicNumber = [4]byte{0x78, 0x11, 0x45, 0x14}

// File is an open virtual file handle (C: FFS_FILE).
// Mode:
//
//	0 "r", 1 "w", 2 "a", 3 "r+", 4 "w+", 5 "a+"
type File struct {
	Mode uint8

	DirBlockindex uint32
	DirOffset     uint16

	FileStartBlockindex uint32
	FileStopBlockindex  uint32
	FileOffset          uint16

	PosBlockindex uint32
	PosOffset     uint16
	Pos           uint64
}

// Dirent is a directory entry (C: FFS_dirent).
type Dirent struct {
	DType   int
	DNamlen int
	DName   [BlockNameMaxSize + 1]byte
}

// Dir is an open directory handle (C: FFS_DIR).
type Dir struct {
	Blockindex     uint32
	Block          [BlockSize]byte
	Searchindex    int
	StopBlockindex uint32
	Offset         uint16
	Dirp           Dirent
}

// TMP holds transaction / journal staging state (C: TMP).
type TMP struct {
	State uint8 // 0-normal, 1-auto commit, 2-manu commit

	Pwd           string
	PwdBlockindex uint32

	FpCp    *os.File
	FpAdd   *os.File
	CpPath  string // temp file path for FpCp
	AddPath string // temp file path for FpAdd

	CpSize uint8

	TotalBlocksize     uint32
	UnusedBlockhead    uint32
	NewTotalBlocksize  uint32
	NewUnusedBlockhead uint32
}

// FileFS is the filesystem instance (C: FileFS).
type FileFS struct {
	Fn  string
	Fp  *os.File
	Fnj string

	Tmp TMP

	Pwd           string
	PwdBlockindex uint32
	PwdTmp        string
}

// BlockArray caches a block during multi-block mutations (C: BlockArray).
type BlockArray struct {
	Active     uint8
	Block      [BlockSize]byte
	Blockindex uint32
}
