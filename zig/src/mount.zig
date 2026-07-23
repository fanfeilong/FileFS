const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const journal = @import("journal.zig");
const txn = @import("txn.zig");

pub fn mkfs(filename: []const u8) !void {
    var io_threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    const fp = try std.Io.Dir.cwd().createFile(io, filename, .{
        .read = true,
        .truncate = true,
    });
    defer fp.close(io);

    var block = util.blockZero();
    var b4: [4]u8 = undefined;
    var b2: [2]u8 = undefined;

    @memcpy(block[0..4], types.magic_number[0..]);
    util.u32ToB4(2, &b4);
    @memcpy(block[4..8], b4[0..]);
    try util.writeAllAt(io, fp, 0, block[0..]);

    block = util.blockZero();
    var k: usize = 12;
    block[k] = 0;
    k += 1;
    block[k] = '.';
    k += types.BlockNameMaxSize;
    util.u32ToB4(1, &b4);
    @memcpy(block[k .. k + 4], b4[0..]);
    k += 4;
    @memcpy(block[k .. k + 4], b4[0..]);
    k += 4;
    util.u16ToB2(4 + 4 + 4 + 25 + 25, &b2);
    @memcpy(block[k .. k + 2], b2[0..]);
    k += 2;

    block[k] = 0;
    k += 1;
    block[k] = '.';
    block[k + 1] = '.';
    try util.writeAllAt(io, fp, types.BlockSize, block[0..]);
    util.fflush(io, fp);

    var journal_path: [types.PathBufferLen]u8 = [_]u8{0} ** types.PathBufferLen;
    var journal_len: usize = 0;
    if (util.bufferSet(journal_path[0..], &journal_len, filename) and journal_len + 2 <= journal_path.len) {
        journal_path[journal_len] = '-';
        journal_path[journal_len + 1] = 'j';
        util.deleteFileIfExists(io, journal_path[0 .. journal_len + 2]);
    }
}

pub fn mount(self: anytype, filename: []const u8) bool {
    const fp = std.Io.Dir.cwd().openFile(self.io, filename, .{ .mode = .read_write }) catch return false;

    var block = util.blockZero();
    util.readExactAt(self.io, fp, 0, block[0..]) catch {
        fp.close(self.io);
        return false;
    };
    if (!std.mem.eql(u8, block[0..4], types.magic_number[0..])) {
        fp.close(self.io);
        return false;
    }
    const bs = util.b4ToU32(block[4..8]);
    if (bs < 2) {
        fp.close(self.io);
        return false;
    }

    util.readExactAt(self.io, fp, types.BlockSize, block[0..]) catch {
        fp.close(self.io);
        return false;
    };

    var k: usize = 12;
    if (block[k] != 0) {
        fp.close(self.io);
        return false;
    }
    k += 1;
    var name: [types.BlockNameMaxSize + 1]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 1);
    @memcpy(name[0..types.BlockNameMaxSize], block[k .. k + types.BlockNameMaxSize]);
    if (!std.mem.eql(u8, util.fixedCStr(name[0..]), ".")) {
        fp.close(self.io);
        return false;
    }
    k += 24;
    if (block[k] != 0) {
        fp.close(self.io);
        return false;
    }
    k += 1;
    @memset(name[0..], 0);
    @memcpy(name[0..types.BlockNameMaxSize], block[k .. k + types.BlockNameMaxSize]);
    if (!std.mem.eql(u8, util.fixedCStr(name[0..]), "..")) {
        fp.close(self.io);
        return false;
    }

    umount(self);
    self.fp = fp;
    if (!util.setMountedPaths(self, filename)) {
        fp.close(self.io);
        self.fp = null;
        return false;
    }
    if (!util.bufferSet(self.pwd[0..], &self.pwd_len, "/")) {
        fp.close(self.io);
        self.fp = null;
        return false;
    }
    self.pwd_blockindex = 1;
    self.pwd_tmp_len = 0;
    journal.j2ffs(self);
    return true;
}

pub fn umount(self: anytype) void {
    if (self.fp) |fp| {
        fp.close(self.io);
        self.fp = null;
    }
    if (self.journal_len != 0) {
        util.deleteFileIfExists(self.io, self.journal[0..self.journal_len]);
    }
    txn.tmpstop(self);
    util.clearMountedPaths(self);
    self.pwd_len = 0;
    self.pwd_blockindex = 0;
    self.pwd_tmp_len = 0;
}

pub fn isMount(self: anytype) bool {
    return self.fp != null;
}
