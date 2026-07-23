const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");

pub fn genblockindex(self: anytype) u32 {
    var block = util.blockZero();

    if (self.tmp.new_unused_blockhead > 0) {
        const blockindex = self.tmp.new_unused_blockhead;
        if (!readblock(self, blockindex, block[0..])) {
            return 0;
        }
        self.tmp.new_unused_blockhead = util.b4ToU32(block[4..8]);
        return blockindex;
    }

    const blockindex = self.tmp.new_total_blocksize;
    const addindex = blockindex - self.tmp.total_blocksize;
    const pos = @as(u64, addindex) * @as(u64, 4 + types.BlockSize);
    const fp_add = self.tmp.fp_add orelse return 0;
    var b4: [4]u8 = undefined;
    util.u32ToB4(blockindex, &b4);
    util.writeAllAt(self.io, fp_add, pos, b4[0..]) catch return 0;
    util.writeAllAt(self.io, fp_add, pos + 4, block[0..]) catch return 0;
    self.tmp.new_total_blocksize += 1;
    return blockindex;
}

pub fn readblock(self: anytype, blockindex: u32, block: []u8) bool {
    const main = self.fp orelse return false;
    const pos = @as(u64, blockindex) * @as(u64, types.BlockSize);
    var buf: [4]u8 = undefined;
    util.readExactAt(self.io, main, pos, buf[0..]) catch {
        if (self.tmp.state == 0) {
            return false;
        }
        if (blockindex < self.tmp.total_blocksize) {
            return false;
        }
        const fp_add = self.tmp.fp_add orelse return false;
        const addindex = blockindex - self.tmp.total_blocksize;
        const add_pos = @as(u64, addindex) * @as(u64, types.BlockSize + 4) + 4;
        util.readExactAt(self.io, fp_add, add_pos, block[0..types.BlockSize]) catch return false;
        return true;
    };

    if (self.tmp.state == 0) {
        @memcpy(block[0..4], buf[0..]);
        util.readExactAt(self.io, main, pos + 4, block[4..types.BlockSize]) catch return false;
        return true;
    }

    var b4: [4]u8 = undefined;
    @memcpy(b4[0..], buf[0..]);
    const cpindex = util.b4ToU32(b4[0..]);
    const fp_cp = self.tmp.fp_cp orelse return false;
    const cp_pos = @as(u64, cpindex) * @as(u64, types.BlockSize + 4);
    util.readExactAt(self.io, fp_cp, cp_pos, b4[0..]) catch {
        @memcpy(block[0..4], buf[0..]);
        util.readExactAt(self.io, main, pos + 4, block[4..types.BlockSize]) catch return false;
        return true;
    };
    const orgindex = util.b4ToU32(b4[0..]);
    if (orgindex != blockindex) {
        @memcpy(block[0..4], buf[0..]);
        util.readExactAt(self.io, main, pos + 4, block[4..types.BlockSize]) catch return false;
        return true;
    }
    util.readExactAt(self.io, fp_cp, cp_pos + 4, block[0..types.BlockSize]) catch return false;
    return true;
}

pub fn writeblock(self: anytype, blockindex: u32, block: []const u8) bool {
    if (self.tmp.state == 0) {
        return false;
    }

    const main = self.fp orelse return false;
    const pos = @as(u64, blockindex) * @as(u64, types.BlockSize);
    var buf: [4]u8 = undefined;
    util.readExactAt(self.io, main, pos, buf[0..]) catch {
        if (blockindex < self.tmp.total_blocksize) {
            return false;
        }
        const addindex = blockindex - self.tmp.total_blocksize;
        const add_pos = @as(u64, addindex) * @as(u64, types.BlockSize + 4) + 4;
        const fp_add = self.tmp.fp_add orelse return false;
        util.writeAllAt(self.io, fp_add, add_pos, block[0..types.BlockSize]) catch return false;
        return true;
    };

    var b4: [4]u8 = undefined;
    @memcpy(b4[0..], buf[0..]);
    var cpindex = util.b4ToU32(b4[0..]);
    const fp_cp = self.tmp.fp_cp orelse return false;
    var cp_pos = @as(u64, cpindex) * @as(u64, types.BlockSize + 4);
    util.readExactAt(self.io, fp_cp, cp_pos, b4[0..]) catch {
        cpindex = self.tmp.cp_size;
        cp_pos = @as(u64, cpindex) * @as(u64, types.BlockSize + 4);
        util.u32ToB4(blockindex, &b4);
        util.writeAllAt(self.io, fp_cp, cp_pos, b4[0..]) catch return false;
        util.writeAllAt(self.io, fp_cp, cp_pos + 4, block[0..types.BlockSize]) catch return false;
        util.u32ToB4(cpindex, &b4);
        util.writeAllAt(self.io, main, pos, b4[0..]) catch return false;
        self.tmp.cp_size +%= 1;
        return true;
    };
    const orgindex = util.b4ToU32(b4[0..]);
    if (orgindex != blockindex) {
        cpindex = self.tmp.cp_size;
        cp_pos = @as(u64, cpindex) * @as(u64, types.BlockSize + 4);
        util.u32ToB4(blockindex, &b4);
        util.writeAllAt(self.io, fp_cp, cp_pos, b4[0..]) catch return false;
        util.writeAllAt(self.io, fp_cp, cp_pos + 4, block[0..types.BlockSize]) catch return false;
        util.u32ToB4(cpindex, &b4);
        util.writeAllAt(self.io, main, pos, b4[0..]) catch return false;
        self.tmp.cp_size +%= 1;
        return true;
    }

    util.writeAllAt(self.io, fp_cp, cp_pos + 4, block[0..types.BlockSize]) catch return false;
    return true;
}

pub fn removeblock(self: anytype, blockindex: u32) bool {
    if (self.tmp.state == 0) {
        return false;
    }

    const main = self.fp orelse return false;
    const pos = @as(u64, blockindex) * @as(u64, types.BlockSize);
    var buf: [4]u8 = undefined;
    util.readExactAt(self.io, main, pos, buf[0..]) catch {
        if (blockindex < self.tmp.total_blocksize) {
            return false;
        }
        const addindex = blockindex - self.tmp.total_blocksize;
        const add_pos = @as(u64, addindex) * @as(u64, types.BlockSize + 4) + 8;
        const fp_add = self.tmp.fp_add orelse return false;
        var b4: [4]u8 = undefined;
        util.u32ToB4(self.tmp.new_unused_blockhead, &b4);
        util.writeAllAt(self.io, fp_add, add_pos, b4[0..]) catch return false;
        self.tmp.new_unused_blockhead = blockindex;
        return true;
    };

    var b4: [4]u8 = undefined;
    @memcpy(b4[0..], buf[0..]);
    var cpindex = util.b4ToU32(b4[0..]);
    const fp_cp = self.tmp.fp_cp orelse return false;
    var cp_pos = @as(u64, cpindex) * @as(u64, types.BlockSize + 4);
    util.readExactAt(self.io, fp_cp, cp_pos, b4[0..]) catch {
        cpindex = self.tmp.cp_size;
        cp_pos = @as(u64, cpindex) * @as(u64, types.BlockSize + 4);
        util.u32ToB4(blockindex, &b4);
        util.writeAllAt(self.io, fp_cp, cp_pos, b4[0..]) catch return false;
        var block = util.blockZero();
        util.u32ToB4(self.tmp.new_unused_blockhead, &b4);
        @memcpy(block[0..4], b4[0..]);
        util.writeAllAt(self.io, fp_cp, cp_pos + 4, block[0..]) catch return false;
        util.u32ToB4(cpindex, &b4);
        util.writeAllAt(self.io, main, pos, b4[0..]) catch return false;
        self.tmp.cp_size +%= 1;
        self.tmp.new_unused_blockhead = blockindex;
        return true;
    };
    const orgindex = util.b4ToU32(b4[0..]);
    if (orgindex != blockindex) {
        cpindex = self.tmp.cp_size;
        cp_pos = @as(u64, cpindex) * @as(u64, types.BlockSize + 4);
        util.u32ToB4(blockindex, &b4);
        util.writeAllAt(self.io, fp_cp, cp_pos, b4[0..]) catch return false;
        var block = util.blockZero();
        util.u32ToB4(self.tmp.new_unused_blockhead, &b4);
        @memcpy(block[0..4], b4[0..]);
        util.writeAllAt(self.io, fp_cp, cp_pos + 4, block[0..]) catch return false;
        util.u32ToB4(cpindex, &b4);
        util.writeAllAt(self.io, main, pos, b4[0..]) catch return false;
        self.tmp.cp_size +%= 1;
        self.tmp.new_unused_blockhead = blockindex;
        return true;
    }

    util.u32ToB4(self.tmp.new_unused_blockhead, &b4);
    util.writeAllAt(self.io, fp_cp, cp_pos + 8, b4[0..]) catch return false;
    self.tmp.new_unused_blockhead = blockindex;
    return true;
}

pub fn findPathBlockindex(self: anytype, blockindex: u32, pathname: []const u8) u32 {
    var block = util.blockZero();
    var index = blockindex;
    var b4: [4]u8 = undefined;
    var b2: [2]u8 = undefined;
    var s: [types.BlockNameMaxSize + 1]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 1);

    if (!readblock(self, index, block[0..])) {
        return 0;
    }
    @memcpy(b4[0..], block[12 + 1 + 14 + 4 .. 12 + 1 + 14 + 8]);
    const stop_blockindex = util.b4ToU32(b4[0..]);
    @memcpy(b2[0..], block[12 + 1 + 14 + 4 + 4 .. 12 + 1 + 14 + 4 + 6]);
    const offset = util.b2ToU16(b2[0..]);

    while (true) {
        var k: usize = types.BlockHead;
        var i: usize = 0;
        while (i < types.BlockItemMaxCount) : (i += 1) {
            const state = block[k];
            k += 1;
            const dir_file = state & 0x01;
            if (dir_file == 1) {
                k += 24;
                if (index == stop_blockindex and k + 1 >= util.u16ToUsize(offset)) {
                    return 0;
                }
                continue;
            }
            @memset(s[0..], 0);
            @memcpy(s[0..types.BlockNameMaxSize], block[k .. k + types.BlockNameMaxSize]);
            k += types.BlockNameMaxSize;
            if (!std.mem.eql(u8, util.fixedCStr(s[0..]), pathname)) {
                k += 10;
                if (index == stop_blockindex and k + 1 >= util.u16ToUsize(offset)) {
                    return 0;
                }
                continue;
            }
            @memcpy(b4[0..], block[k .. k + 4]);
            return util.b4ToU32(b4[0..]);
        }

        @memcpy(b4[0..], block[4..8]);
        index = util.b4ToU32(b4[0..]);
        if (index == 0) {
            return 0;
        }
        if (!readblock(self, index, block[0..])) {
            return 0;
        }
    }
}
