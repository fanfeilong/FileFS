const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");

pub fn tmpstart(self: anytype, state: u8) bool {
    if (state == 0) {
        return false;
    }
    if (self.tmp.state != 0) {
        tmpstop(self);
    }

    const main = self.fp orelse return false;
    var block: [12]u8 = [_]u8{0} ** 12;
    util.readExactAt(self.io, main, 0, block[0..]) catch return false;
    self.tmp.total_blocksize = util.b4ToU32(block[4..8]);
    self.tmp.unused_blockhead = util.b4ToU32(block[8..12]);
    self.tmp.new_total_blocksize = self.tmp.total_blocksize;
    self.tmp.new_unused_blockhead = self.tmp.unused_blockhead;

    const fp_cp = util.createTempFile(self, "filefs-cp-", self.tmp.cp_path[0..], &self.tmp.cp_path_len) orelse return false;
    self.tmp.fp_cp = fp_cp;

    const fp_add = util.createTempFile(self, "filefs-add-", self.tmp.add_path[0..], &self.tmp.add_path_len) orelse {
        if (self.tmp.fp_cp) |file| {
            file.close(self.io);
            self.tmp.fp_cp = null;
        }
        util.deleteFileIfExists(self.io, self.tmp.cp_path[0..self.tmp.cp_path_len]);
        self.tmp.cp_path_len = 0;
        return false;
    };
    self.tmp.fp_add = fp_add;

    if (!util.bufferSet(self.tmp.pwd[0..], &self.tmp.pwd_len, self.pwd[0..self.pwd_len])) {
        tmpstop(self);
        return false;
    }
    self.tmp.pwd_blockindex = self.pwd_blockindex;
    self.tmp.cp_size = 0;
    self.tmp.state = state;
    return true;
}

pub fn tmpstop(self: anytype) void {
    if (self.tmp.fp_cp) |file| {
        file.close(self.io);
        self.tmp.fp_cp = null;
    }
    if (self.tmp.cp_path_len != 0) {
        util.deleteFileIfExists(self.io, self.tmp.cp_path[0..self.tmp.cp_path_len]);
        self.tmp.cp_path_len = 0;
    }
    if (self.tmp.fp_add) |file| {
        file.close(self.io);
        self.tmp.fp_add = null;
    }
    if (self.tmp.add_path_len != 0) {
        util.deleteFileIfExists(self.io, self.tmp.add_path[0..self.tmp.add_path_len]);
        self.tmp.add_path_len = 0;
    }
    self.tmp.pwd_len = 0;
    self.tmp.pwd_blockindex = 0;
    self.tmp.cp_size = 0;
    self.tmp.state = 0;
}

pub fn begin(self: anytype) bool {
    if (self.fp == null) {
        return false;
    }
    if (self.tmp.fp_cp != null) {
        rollback(self);
    }
    return tmpstart(self, 2);
}

pub fn rollback(self: anytype) void {
    if (self.fp == null) {
        return;
    }
    util.deleteFileIfExists(self.io, self.journal[0..self.journal_len]);
    if (self.tmp.fp_cp == null) {
        return;
    }
    tmpstop(self);
}

pub fn commit(self: anytype) bool {
    const main = self.fp orelse return true;
    if (self.tmp.fp_cp == null) {
        return true;
    }

    const fpj = std.Io.Dir.cwd().createFile(self.io, self.journal[0..self.journal_len], .{
        .read = true,
        .truncate = true,
    }) catch {
        tmpstop(self);
        return false;
    };

    var ok = true;
    var pos: u64 = 0;
    var signal = [1]u8{0};
    util.appendAll(self.io, fpj, &pos, signal[0..]) catch {
        ok = false;
    };

    var b4: [4]u8 = undefined;
    var block: [4 + types.BlockSize]u8 = [_]u8{0} ** (4 + types.BlockSize);

    if (ok and (self.tmp.total_blocksize != self.tmp.new_total_blocksize or self.tmp.unused_blockhead != self.tmp.new_unused_blockhead)) {
        @memset(block[0..], 0);
        util.u32ToB4(0, &b4);
        @memcpy(block[0..4], b4[0..]);
        @memcpy(block[4..8], types.magic_number[0..]);
        util.u32ToB4(self.tmp.new_total_blocksize, &b4);
        @memcpy(block[8..12], b4[0..]);
        util.u32ToB4(self.tmp.new_unused_blockhead, &b4);
        @memcpy(block[12..16], b4[0..]);
        util.appendAll(self.io, fpj, &pos, block[0..]) catch {
            ok = false;
        };
    }

    if (ok) {
        if (self.tmp.fp_cp) |cp| {
            var cp_pos: u64 = 0;
            while (true) {
                util.readExactAt(self.io, cp, cp_pos, block[0..]) catch break;
                util.appendAll(self.io, fpj, &pos, block[0..]) catch {
                    ok = false;
                    break;
                };
                cp_pos += block.len;
            }
        }
    }

    if (ok) {
        if (self.tmp.fp_add) |add| {
            var add_pos: u64 = 0;
            while (true) {
                util.readExactAt(self.io, add, add_pos, block[0..]) catch break;
                util.appendAll(self.io, fpj, &pos, block[0..]) catch {
                    ok = false;
                    break;
                };
                add_pos += block.len;
            }
        }
    }

    if (ok) {
        signal[0] = 0xff;
        util.writeAllAt(self.io, fpj, 0, signal[0..]) catch {
            ok = false;
        };
    }
    util.fflush(self.io, fpj);
    fpj.close(self.io);

    if (!ok) {
        tmpstop(self);
        return false;
    }

    const fpj_read = std.Io.Dir.cwd().openFile(self.io, self.journal[0..self.journal_len], .{}) catch {
        tmpstop(self);
        return false;
    };
    defer fpj_read.close(self.io);

    util.readExactAt(self.io, fpj_read, 0, signal[0..]) catch {
        tmpstop(self);
        return false;
    };

    pos = 1;
    while (true) {
        util.readExactAt(self.io, fpj_read, pos, block[0..]) catch break;
        const blockindex = util.b4ToU32(block[0..4]);
        util.writeAllAt(self.io, main, @as(u64, blockindex) * @as(u64, types.BlockSize), block[4..]) catch {
            tmpstop(self);
            return false;
        };
        pos += block.len;
    }

    util.fflush(self.io, main);
    util.deleteFileIfExists(self.io, self.journal[0..self.journal_len]);

    if (!util.bufferSet(self.pwd[0..], &self.pwd_len, self.tmp.pwd[0..self.tmp.pwd_len])) {
        tmpstop(self);
        return false;
    }
    self.pwd_blockindex = self.tmp.pwd_blockindex;

    tmpstop(self);
    return true;
}
