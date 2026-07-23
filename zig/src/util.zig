const std = @import("std");
const types = @import("types.zig");

pub fn b4ToU32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

pub fn u32ToB4(v: u32, out: *[4]u8) void {
    out[0] = @truncate(v & 0xff);
    out[1] = @truncate((v >> 8) & 0xff);
    out[2] = @truncate((v >> 16) & 0xff);
    out[3] = @truncate((v >> 24) & 0xff);
}

pub fn b2ToU16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

pub fn u16ToB2(v: u16, out: *[2]u8) void {
    out[0] = @truncate(v & 0xff);
    out[1] = @truncate((v >> 8) & 0xff);
}

pub fn u16ToUsize(v: u16) usize {
    return @intCast(v);
}

pub fn usizeToU16(v: usize) u16 {
    return @intCast(v);
}

pub fn usizeToU32(v: usize) u32 {
    return @intCast(v);
}

pub fn fixedCStr(bytes: []const u8) []const u8 {
    var n: usize = 0;
    while (n < bytes.len and bytes[n] != 0) : (n += 1) {}
    return bytes[0..n];
}

pub fn copyNameInto(dst: []u8, name: []const u8) void {
    @memset(dst, 0);
    const n = @min(dst.len, name.len);
    @memcpy(dst[0..n], name[0..n]);
}

pub fn bufferSet(buf: []u8, len_ptr: *usize, src: []const u8) bool {
    if (src.len > buf.len) {
        return false;
    }
    @memset(buf, 0);
    if (src.len > 0) {
        @memcpy(buf[0..src.len], src);
    }
    len_ptr.* = src.len;
    return true;
}

pub fn bufferSlice(buf: []const u8, len: usize) []const u8 {
    return buf[0..len];
}

pub fn currentPwd(self: anytype) []const u8 {
    if (self.tmp.state == 0) {
        return self.pwd[0..self.pwd_len];
    }
    return self.tmp.pwd[0..self.tmp.pwd_len];
}

pub fn currentPwdBlockindex(self: anytype) u32 {
    if (self.tmp.state == 0) {
        return self.pwd_blockindex;
    }
    return self.tmp.pwd_blockindex;
}

pub fn initPwdTmp(self: anytype, src: []const u8) bool {
    return bufferSet(self.pwd_tmp[0..], &self.pwd_tmp_len, src);
}

pub fn addToPwdTmp(self: anytype, name: []const u8) bool {
    if (std.mem.eql(u8, name, ".")) {
        return true;
    }

    if (std.mem.eql(u8, name, "..")) {
        var i: usize = 1;
        while (i < self.pwd_tmp_len) : (i += 1) {
            const idx = self.pwd_tmp_len - i - 1;
            if (self.pwd_tmp[idx] == '/') {
                self.pwd_tmp_len -= i;
                if (self.pwd_tmp_len < self.pwd_tmp.len) {
                    self.pwd_tmp[self.pwd_tmp_len] = 0;
                }
                return true;
            }
        }
        return false;
    }

    if (self.pwd_tmp_len + name.len + 1 > self.pwd_tmp.len) {
        return false;
    }
    @memcpy(self.pwd_tmp[self.pwd_tmp_len .. self.pwd_tmp_len + name.len], name);
    self.pwd_tmp_len += name.len;
    self.pwd_tmp[self.pwd_tmp_len] = '/';
    self.pwd_tmp_len += 1;
    if (self.pwd_tmp_len < self.pwd_tmp.len) {
        self.pwd_tmp[self.pwd_tmp_len] = 0;
    }
    return true;
}

pub fn setMountedPaths(self: anytype, filename: []const u8) bool {
    if (!bufferSet(self.filename[0..], &self.filename_len, filename)) {
        return false;
    }
    if (filename.len + 2 > self.journal.len) {
        return false;
    }
    @memset(self.journal[0..], 0);
    if (filename.len > 0) {
        @memcpy(self.journal[0..filename.len], filename);
    }
    self.journal[filename.len] = '-';
    self.journal[filename.len + 1] = 'j';
    self.journal_len = filename.len + 2;
    return true;
}

pub fn clearMountedPaths(self: anytype) void {
    self.filename_len = 0;
    self.journal_len = 0;
    if (self.filename.len > 0) self.filename[0] = 0;
    if (self.journal.len > 0) self.journal[0] = 0;
}

pub fn readExactAt(io: std.Io, file: std.Io.File, pos: u64, dest: []u8) !void {
    var read_buffer: [64]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    try reader.seekTo(pos);
    try reader.interface.readSliceAll(dest);
}

pub fn writeAllAt(io: std.Io, file: std.Io.File, pos: u64, src: []const u8) !void {
    var write_buffer: [64]u8 = undefined;
    var writer = file.writer(io, &write_buffer);
    try writer.seekTo(pos);
    try writer.interface.writeAll(src);
    try writer.flush();
}

pub fn appendAll(io: std.Io, file: std.Io.File, pos_ptr: *u64, src: []const u8) !void {
    try writeAllAt(io, file, pos_ptr.*, src);
    pos_ptr.* += src.len;
}

pub fn fflush(io: std.Io, file: std.Io.File) void {
    file.sync(io) catch {};
}

pub fn deleteFileIfExists(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

var temp_counter: u64 = 0;

pub fn createTempFile(self: anytype, prefix: []const u8, path_buf: []u8, len_ptr: *usize) ?std.Io.File {
    var attempts: usize = 0;
    while (attempts < 1024) : (attempts += 1) {
        temp_counter += 1;
        const path = std.fmt.bufPrint(path_buf, "/tmp/{s}{d}", .{ prefix, temp_counter }) catch return null;
        const file = std.Io.Dir.cwd().createFile(self.io, path, .{
            .read = true,
            .truncate = true,
            .exclusive = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return null,
        };
        len_ptr.* = path.len;
        return file;
    }
    return null;
}

pub fn blockZero() [types.BlockSize]u8 {
    return [_]u8{0} ** types.BlockSize;
}
