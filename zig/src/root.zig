const std = @import("std");

pub const types = @import("types.zig");
pub const util = @import("util.zig");

const mount_mod = @import("mount.zig");
const fopen_mod = @import("fopen.zig");
const readwrite_mod = @import("readwrite.zig");
const seek_mod = @import("seek.zig");
const exist_mod = @import("exist.zig");
const remove_mod = @import("remove.zig");
const rename_mod = @import("rename.zig");
const move_mod = @import("move.zig");
const copy_mod = @import("copy.zig");
const pwd_mod = @import("pwd.zig");
const mkdir_mod = @import("mkdir.zig");
const rmdir_mod = @import("rmdir.zig");
const readdir_mod = @import("readdir.zig");
const txn_mod = @import("txn.zig");

pub const BlockSize = types.BlockSize;
pub const BlockItemMaxCount = types.BlockItemMaxCount;
pub const BlockHead = types.BlockHead;
pub const BlockNameMaxSize = types.BlockNameMaxSize;
pub const BlockStartBlockindex = types.BlockStartBlockindex;
pub const BlockStopBlockindex = types.BlockStopBlockindex;
pub const BlockOffset = types.BlockOffset;

pub const DTFile = types.DTFile;
pub const DTDir = types.DTDir;
pub const DTRoot = types.DTRoot;

pub const SeekSet = types.SeekSet;
pub const SeekCur = types.SeekCur;
pub const SeekEnd = types.SeekEnd;

pub const File = types.File;
pub const Dir = types.Dir;
pub const Dirent = types.Dirent;
pub const OpenDirResult = types.OpenDirResult;
pub const TMP = types.TMP;
pub const BlockArray = types.BlockArray;

pub const FileFS = struct {
    allocator: std.mem.Allocator,
    io_threaded: std.Io.Threaded,
    io: std.Io,

    fp: ?std.Io.File = null,
    filename: [types.PathBufferLen]u8 = [_]u8{0} ** types.PathBufferLen,
    filename_len: usize = 0,
    journal: [types.PathBufferLen]u8 = [_]u8{0} ** types.PathBufferLen,
    journal_len: usize = 0,

    tmp: TMP = .{},

    pwd: [types.PathBufferLen]u8 = [_]u8{0} ** types.PathBufferLen,
    pwd_len: usize = 0,
    pwd_blockindex: u32 = 0,

    pwd_tmp: [types.PathBufferLen]u8 = [_]u8{0} ** types.PathBufferLen,
    pwd_tmp_len: usize = 0,

    pub fn destroy(self: *FileFS) void {
        self.umount();
        self.io_threaded.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn mount(self: *FileFS, path: []const u8) bool {
        return mount_mod.mount(self, path);
    }

    pub fn umount(self: *FileFS) void {
        mount_mod.umount(self);
    }

    pub fn isMount(self: *FileFS) bool {
        return mount_mod.isMount(self);
    }

    pub fn fopen(self: *FileFS, filename: []const u8, mode: []const u8) ?*File {
        return fopen_mod.fopen(self, filename, mode);
    }

    pub fn fread(self: *FileFS, ptr: []u8, size: usize, nmemb: usize, stream: *File) usize {
        return readwrite_mod.fread(self, ptr, size, nmemb, stream);
    }

    pub fn fwrite(self: *FileFS, ptr: []const u8, size: usize, nmemb: usize, stream: *File) usize {
        return readwrite_mod.fwrite(self, ptr, size, nmemb, stream);
    }

    pub fn fclose(self: *FileFS, stream: *File) void {
        readwrite_mod.fclose(self, stream);
    }

    pub fn fseek(self: *FileFS, stream: *File, offset: i64, whence: i32) bool {
        return seek_mod.fseek(self, stream, offset, whence);
    }

    pub fn ftell(self: *FileFS, stream: *File) u64 {
        return seek_mod.ftell(self, stream);
    }

    pub fn rewind(self: *FileFS, stream: *File) void {
        seek_mod.rewind(self, stream);
    }

    pub fn fileExist(self: *FileFS, filename: []const u8) bool {
        return exist_mod.fileExist(self, filename);
    }

    pub fn dirExist(self: *FileFS, pathname: []const u8) bool {
        return exist_mod.dirExist(self, pathname);
    }

    pub fn remove(self: *FileFS, filename: []const u8) i32 {
        return remove_mod.remove(self, filename);
    }

    pub fn rename(self: *FileFS, old_name: []const u8, new_name: []const u8) i32 {
        return rename_mod.rename(self, old_name, new_name);
    }

    pub fn move(self: *FileFS, from_name: []const u8, to_path: []const u8) i32 {
        return move_mod.move(self, from_name, to_path);
    }

    pub fn copy(self: *FileFS, from_name: []const u8, to_name: []const u8) i32 {
        return copy_mod.copy(self, from_name, to_name);
    }

    pub fn chdir(self: *FileFS, pathname: []const u8) bool {
        return pwd_mod.chdir(self, pathname);
    }

    pub fn getcwd(self: *FileFS) []const u8 {
        return pwd_mod.getcwd(self);
    }

    pub fn mkdir(self: *FileFS, pathname: []const u8) i32 {
        return mkdir_mod.mkdir(self, pathname);
    }

    pub fn rmdir(self: *FileFS, pathname: []const u8) i32 {
        return rmdir_mod.rmdir(self, pathname);
    }

    pub fn opendir(self: *FileFS, path: []const u8) ?OpenDirResult {
        return readdir_mod.opendir(self, path);
    }

    pub fn readdir(self: *FileFS, dir: *Dir) ?*Dirent {
        return readdir_mod.readdir(self, dir);
    }

    pub fn closedir(self: *FileFS, dir: *Dir) void {
        readdir_mod.closedir(self, dir);
    }

    pub fn begin(self: *FileFS) bool {
        return txn_mod.begin(self);
    }

    pub fn commit(self: *FileFS) bool {
        return txn_mod.commit(self);
    }

    pub fn rollback(self: *FileFS) void {
        txn_mod.rollback(self);
    }
};

pub fn create(allocator: std.mem.Allocator) !*FileFS {
    const self = try allocator.create(FileFS);
    self.* = .{
        .allocator = allocator,
        .io_threaded = .init(allocator, .{}),
        .io = undefined,
    };
    self.io = self.io_threaded.io();
    return self;
}

pub fn mkfs(path: []const u8) !void {
    try mount_mod.mkfs(path);
}

pub fn mkfsBool(path: []const u8) bool {
    mkfs(path) catch return false;
    return true;
}

test "mkfs + mount" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const image_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/test.ffs", .{tmp.sub_path});
    defer std.testing.allocator.free(image_path);

    try mkfs(image_path);

    const ffs = try create(std.testing.allocator);
    defer ffs.destroy();

    try std.testing.expect(ffs.mount(image_path));
    try std.testing.expect(ffs.isMount());
    try std.testing.expectEqualStrings("/", ffs.getcwd());
}

test "mkdir + chdir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const image_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/mkdir.ffs", .{tmp.sub_path});
    defer std.testing.allocator.free(image_path);

    try mkfs(image_path);

    const ffs = try create(std.testing.allocator);
    defer ffs.destroy();
    try std.testing.expect(ffs.mount(image_path));
    try std.testing.expectEqual(@as(i32, 0), ffs.mkdir("docs"));
    try std.testing.expect(ffs.chdir("docs"));
    try std.testing.expectEqualStrings("/docs/", ffs.getcwd());
}

test "fopen write/read roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const image_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/rw.ffs", .{tmp.sub_path});
    defer std.testing.allocator.free(image_path);

    try mkfs(image_path);

    const ffs = try create(std.testing.allocator);
    defer ffs.destroy();
    try std.testing.expect(ffs.mount(image_path));
    try std.testing.expectEqual(@as(i32, 0), ffs.mkdir("docs"));
    try std.testing.expect(ffs.chdir("docs"));

    const fp_w = ffs.fopen("note.txt", "w") orelse return error.TestUnexpectedResult;
    defer ffs.fclose(fp_w);
    const msg = "hello filefs";
    try std.testing.expectEqual(msg.len, ffs.fwrite(msg, 1, msg.len, fp_w));

    const fp_r = ffs.fopen("note.txt", "r") orelse return error.TestUnexpectedResult;
    defer ffs.fclose(fp_r);
    var buf: [64]u8 = [_]u8{0} ** 64;
    const n = ffs.fread(buf[0..], 1, buf.len, fp_r);
    try std.testing.expectEqualStrings(msg, buf[0..n]);
}

test "copy + rename + remove" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const image_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/ops.ffs", .{tmp.sub_path});
    defer std.testing.allocator.free(image_path);

    try mkfs(image_path);

    const ffs = try create(std.testing.allocator);
    defer ffs.destroy();
    try std.testing.expect(ffs.mount(image_path));
    try std.testing.expectEqual(@as(i32, 0), ffs.mkdir("docs"));
    try std.testing.expect(ffs.chdir("docs"));
    const fp = ffs.fopen("note.txt", "w") orelse return error.TestUnexpectedResult;
    defer ffs.fclose(fp);
    _ = ffs.fwrite("payload", 1, 7, fp);
    try std.testing.expect(ffs.chdir("/"));
    try std.testing.expectEqual(@as(i32, 0), ffs.copy("/docs/note.txt", "/copy.txt"));
    try std.testing.expectEqual(@as(i32, 0), ffs.rename("copy.txt", "renamed.txt"));
    try std.testing.expectEqual(@as(i32, 0), ffs.remove("renamed.txt"));
}

test "opendir lists docs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const image_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/dir.ffs", .{tmp.sub_path});
    defer std.testing.allocator.free(image_path);

    try mkfs(image_path);

    const ffs = try create(std.testing.allocator);
    defer ffs.destroy();
    try std.testing.expect(ffs.mount(image_path));
    try std.testing.expectEqual(@as(i32, 0), ffs.mkdir("docs"));

    const opened = ffs.opendir("/") orelse return error.TestUnexpectedResult;
    defer ffs.closedir(opened.dir);
    try std.testing.expect(opened.absolute_path.len != 0);

    var found = false;
    while (ffs.readdir(opened.dir)) |ent| {
        const name = util.fixedCStr(ent.d_name[0..]);
        if (std.mem.eql(u8, name, "docs") and ent.d_type == DTDir) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "begin commit transaction creates file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const image_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/txn.ffs", .{tmp.sub_path});
    defer std.testing.allocator.free(image_path);

    try mkfs(image_path);

    const ffs = try create(std.testing.allocator);
    defer ffs.destroy();
    try std.testing.expect(ffs.mount(image_path));
    try std.testing.expect(ffs.begin());
    const fp = ffs.fopen("txn.txt", "w") orelse return error.TestUnexpectedResult;
    defer ffs.fclose(fp);
    _ = ffs.fwrite("x", 1, 1, fp);
    try std.testing.expect(ffs.commit());
    try std.testing.expect(ffs.fileExist("txn.txt"));
}
