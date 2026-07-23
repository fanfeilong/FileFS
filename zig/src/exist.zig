const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const block_mod = @import("block.zig");

pub fn stat(self: anytype, name: []const u8) u8 {
    if (name.len == 0 or self.fp == null) return 0;

    var block = util.blockZero();
    var blockindex: u32 = undefined;
    var start: usize = undefined;
    if (name[0] == '/') {
        blockindex = 1;
        start = 1;
    } else {
        blockindex = util.currentPwdBlockindex(self);
        start = 0;
    }

    var s: [types.BlockNameMaxSize + 2]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 2);
    var slen: usize = 0;
    var i: usize = start;
    while (i < name.len) : (i += 1) {
        if (name[i] == '/') {
            if (slen == 0) continue;
            const index = block_mod.findPathBlockindex(self, blockindex, s[0..slen]);
            if (index < 1) return 0;
            blockindex = index;
            slen = 0;
            continue;
        }
        s[slen] = name[i];
        slen += 1;
        if (slen > types.BlockNameMaxSize) return 0;
    }
    if (slen == 0) return 2;
    var lastname_buf: [types.BlockNameMaxSize + 1]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 1);
    @memcpy(lastname_buf[0..slen], s[0..slen]);
    const lastname = lastname_buf[0..slen];

    var b4: [4]u8 = undefined;
    var b2: [2]u8 = undefined;
    if (!block_mod.readblock(self, blockindex, block[0..])) return 0;
    @memcpy(b4[0..], block[12 + 1 + 14 + 4 .. 12 + 1 + 14 + 8]);
    const stop_blockindex = util.b4ToU32(b4[0..]);
    @memcpy(b2[0..], block[12 + 1 + 14 + 4 + 4 .. 12 + 1 + 14 + 4 + 6]);
    const offset = util.b2ToU16(b2[0..]);

    var index = blockindex;
    while (true) {
        var k: usize = types.BlockHead;
        var item: usize = 0;
        while (item < types.BlockItemMaxCount) : (item += 1) {
            const state = block[k];
            k += 1;
            @memset(s[0..], 0);
            @memcpy(s[0..types.BlockNameMaxSize], block[k .. k + types.BlockNameMaxSize]);
            k += types.BlockNameMaxSize;
            if (!std.mem.eql(u8, util.fixedCStr(s[0..types.BlockNameMaxSize + 1]), lastname)) {
                k += 10;
                if (index == stop_blockindex and k + 1 >= util.u16ToUsize(offset)) return 0;
                continue;
            }
            const dir_file = state & 0x01;
            if (dir_file == 0) return 2;
            return 1;
        }
        @memcpy(b4[0..], block[4..8]);
        index = util.b4ToU32(b4[0..]);
        if (index == 0) return 0;
        if (!block_mod.readblock(self, index, block[0..])) return 0;
    }
}

pub fn fileExist(self: anytype, filename: []const u8) bool {
    return stat(self, filename) == 1;
}

pub fn dirExist(self: anytype, pathname: []const u8) bool {
    return stat(self, pathname) == 2;
}
