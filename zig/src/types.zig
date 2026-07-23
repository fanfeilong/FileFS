const std = @import("std");

pub const BlockSize: usize = 512;
pub const BlockItemMaxCount: usize = 20;
pub const BlockHead: u16 = 12;
pub const BlockNameMaxSize: usize = 14;
pub const BlockStartBlockindex: usize = 27;
pub const BlockStopBlockindex: usize = 31;
pub const BlockOffset: usize = 35;
pub const PathBufferLen: usize = 4096;
pub const TempPathBufferLen: usize = 256;

pub const DTFile: i32 = 0;
pub const DTDir: i32 = 1;
pub const DTRoot: i32 = 2;

pub const SeekSet: i32 = 0;
pub const SeekCur: i32 = 1;
pub const SeekEnd: i32 = 2;

pub const magic_number = [4]u8{ 0x78, 0x11, 0x45, 0x14 };

pub const File = struct {
    mode: u8 = 0,

    dir_blockindex: u32 = 0,
    dir_offset: u16 = 0,

    file_start_blockindex: u32 = 0,
    file_stop_blockindex: u32 = 0,
    file_offset: u16 = 0,

    pos_blockindex: u32 = 0,
    pos_offset: u16 = 0,
    pos: u64 = 0,
};

pub const Dirent = struct {
    d_type: i32 = DTFile,
    d_namlen: usize = 0,
    d_name: [BlockNameMaxSize + 1]u8 = [_]u8{0} ** (BlockNameMaxSize + 1),
};

pub const Dir = struct {
    blockindex: u32 = 0,
    block: [BlockSize]u8 = [_]u8{0} ** BlockSize,
    searchindex: usize = 0,
    stop_blockindex: u32 = 0,
    offset: u16 = 0,
    dirp: Dirent = .{},
};

pub const TMP = struct {
    state: u8 = 0,

    pwd: [PathBufferLen]u8 = [_]u8{0} ** PathBufferLen,
    pwd_len: usize = 0,
    pwd_blockindex: u32 = 0,

    fp_cp: ?std.Io.File = null,
    fp_add: ?std.Io.File = null,
    cp_path: [TempPathBufferLen]u8 = [_]u8{0} ** TempPathBufferLen,
    cp_path_len: usize = 0,
    add_path: [TempPathBufferLen]u8 = [_]u8{0} ** TempPathBufferLen,
    add_path_len: usize = 0,

    cp_size: u8 = 0,

    total_blocksize: u32 = 0,
    unused_blockhead: u32 = 0,
    new_total_blocksize: u32 = 0,
    new_unused_blockhead: u32 = 0,
};

pub const BlockArray = struct {
    active: bool = false,
    block: [BlockSize]u8 = [_]u8{0} ** BlockSize,
    blockindex: u32 = 0,
};

pub const OpenDirResult = struct {
    dir: *Dir,
    absolute_path: []const u8,
};
