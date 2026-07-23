const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const txn = @import("txn.zig");
const block_mod = @import("block.zig");

pub fn doMkdir(self: anytype, lastname: []const u8, start_blockindex: u32, start_block: []u8, cur_blockindex: u32, cur_block: []u8, stop_blockindex: u32, offset: u16) i32 {
    _ = stop_blockindex;
    if (self.tmp.state == 0 and !txn.tmpstart(self, 1)) {
        return 1;
    }

    var b4: [4]u8 = undefined;
    var b2: [2]u8 = undefined;
    var new_block = util.blockZero();
    var block2 = util.blockZero();

    if (util.u16ToUsize(offset) < types.BlockSize) {
        const new_blockindex = block_mod.genblockindex(self);
        if (new_blockindex == 0) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }
        var k: usize = types.BlockHead;
        new_block[k] = 0;
        k += 1;
        new_block[k] = '.';
        k += types.BlockNameMaxSize;
        util.u32ToB4(new_blockindex, &b4);
        @memcpy(new_block[k .. k + 4], b4[0..]);
        k += 4;
        @memcpy(new_block[k .. k + 4], b4[0..]);
        k += 4;
        util.u16ToB2(4 + 4 + 4 + 25 + 25, &b2);
        @memcpy(new_block[k .. k + 2], b2[0..]);
        k += 2;
        new_block[k] = 0;
        k += 1;
        new_block[k] = '.';
        new_block[k + 1] = '.';
        k += types.BlockNameMaxSize;
        util.u32ToB4(start_blockindex, &b4);
        @memcpy(new_block[k .. k + 4], b4[0..]);
        if (!block_mod.writeblock(self, new_blockindex, new_block[0..])) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }

        k = util.u16ToUsize(offset);
        cur_block[k] = 0;
        k += 1;
        util.copyNameInto(cur_block[k .. k + types.BlockNameMaxSize], lastname);
        k += types.BlockNameMaxSize;
        util.u32ToB4(new_blockindex, &b4);
        @memcpy(cur_block[k .. k + 4], b4[0..]);
        k += 4;
        k += 4;
        k += 2;
        const new_offset = util.usizeToU16(k);
        util.u16ToB2(new_offset, &b2);

        if (cur_blockindex == start_blockindex) {
            @memcpy(cur_block[types.BlockOffset .. types.BlockOffset + 2], b2[0..]);
            if (!block_mod.writeblock(self, cur_blockindex, cur_block)) {
                if (self.tmp.state == 1) txn.tmpstop(self);
                return 1;
            }
            if (self.tmp.state == 1 and !txn.commit(self)) return 1;
        } else {
            if (!block_mod.writeblock(self, cur_blockindex, cur_block)) {
                if (self.tmp.state == 1) txn.tmpstop(self);
                return 1;
            }
            @memcpy(start_block[types.BlockOffset .. types.BlockOffset + 2], b2[0..]);
            if (!block_mod.writeblock(self, start_blockindex, start_block)) {
                if (self.tmp.state == 1) txn.tmpstop(self);
                return 1;
            }
            if (self.tmp.state == 1 and !txn.commit(self)) return 1;
        }
        return 0;
    }

    const new_blockindex = block_mod.genblockindex(self);
    if (new_blockindex == 0) {
        if (self.tmp.state == 1) txn.tmpstop(self);
        return 1;
    }
    const blockindex2 = block_mod.genblockindex(self);
    if (blockindex2 == 0) {
        if (self.tmp.state == 1) txn.tmpstop(self);
        return 1;
    }

    var k: usize = 8;
    util.u32ToB4(cur_blockindex, &b4);
    @memcpy(block2[k .. k + 4], b4[0..]);
    k += 4;
    block2[k] = 0;
    k += 1;
    util.copyNameInto(block2[k .. k + types.BlockNameMaxSize], lastname);
    k += types.BlockNameMaxSize;
    util.u32ToB4(new_blockindex, &b4);
    @memcpy(block2[k .. k + 4], b4[0..]);
    k += 4;
    k += 4;
    k += 2;
    const new_offset = util.usizeToU16(k);
    if (!block_mod.writeblock(self, blockindex2, block2[0..])) {
        if (self.tmp.state == 1) txn.tmpstop(self);
        return 1;
    }

    new_block = util.blockZero();
    k = types.BlockHead;
    new_block[k] = 0;
    k += 1;
    new_block[k] = '.';
    k += types.BlockNameMaxSize;
    util.u32ToB4(new_blockindex, &b4);
    @memcpy(new_block[k .. k + 4], b4[0..]);
    k += 4;
    @memcpy(new_block[k .. k + 4], b4[0..]);
    k += 4;
    util.u16ToB2(4 + 4 + 4 + 25 + 25, &b2);
    @memcpy(new_block[k .. k + 2], b2[0..]);
    k += 2;
    new_block[k] = 0;
    k += 1;
    new_block[k] = '.';
    new_block[k + 1] = '.';
    k += types.BlockNameMaxSize;
    util.u32ToB4(start_blockindex, &b4);
    @memcpy(new_block[k .. k + 4], b4[0..]);
    if (!block_mod.writeblock(self, new_blockindex, new_block[0..])) {
        if (self.tmp.state == 1) txn.tmpstop(self);
        return 1;
    }

    util.u16ToB2(new_offset, &b2);
    util.u32ToB4(blockindex2, &b4);
    @memcpy(cur_block[4..8], b4[0..]);
    if (cur_blockindex == start_blockindex) {
        @memcpy(cur_block[types.BlockStopBlockindex .. types.BlockStopBlockindex + 4], b4[0..]);
        @memcpy(cur_block[types.BlockOffset .. types.BlockOffset + 2], b2[0..]);
        if (!block_mod.writeblock(self, cur_blockindex, cur_block)) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }
        if (self.tmp.state == 1 and !txn.commit(self)) return 1;
    } else {
        if (!block_mod.writeblock(self, cur_blockindex, cur_block)) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }
        @memcpy(start_block[types.BlockStopBlockindex .. types.BlockStopBlockindex + 4], b4[0..]);
        @memcpy(start_block[types.BlockOffset .. types.BlockOffset + 2], b2[0..]);
        if (!block_mod.writeblock(self, start_blockindex, start_block)) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }
        if (self.tmp.state == 1 and !txn.commit(self)) return 1;
    }
    return 0;
}

pub fn mkdir(self: anytype, pathname: []const u8) i32 {
    if (pathname.len == 0 or self.fp == null) return 1;
    var blockindex: u32 = undefined;
    var start: usize = undefined;
    if (pathname[0] == '/') {
        blockindex = 1;
        start = 1;
    } else {
        blockindex = util.currentPwdBlockindex(self);
        start = 0;
    }

    var s: [types.BlockNameMaxSize + 2]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 2);
    var slen: usize = 0;
    var i: usize = start;
    while (i < pathname.len) : (i += 1) {
        if (pathname[i] == '/') {
            if (slen == 0) continue;
            const index = block_mod.findPathBlockindex(self, blockindex, s[0..slen]);
            if (index < 1) {
                if (i == pathname.len - 1) break;
                return 1;
            }
            blockindex = index;
            slen = 0;
            continue;
        }
        s[slen] = pathname[i];
        slen += 1;
        if (slen > types.BlockNameMaxSize) return 2;
    }
    if (slen == 0) return 3;
    var lastname_buf: [types.BlockNameMaxSize + 1]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 1);
    @memcpy(lastname_buf[0..slen], s[0..slen]);
    const lastname = lastname_buf[0..slen];
    if (lastname.len > types.BlockNameMaxSize) return 2;

    var start_block = util.blockZero();
    var block = util.blockZero();
    var b4: [4]u8 = undefined;
    var b2: [2]u8 = undefined;
    if (!block_mod.readblock(self, blockindex, block[0..])) return 1;
    @memcpy(start_block[0..], block[0..]);
    const start_blockindex = blockindex;

    @memcpy(b4[0..], block[12 + 1 + 14 + 4 .. 12 + 1 + 14 + 8]);
    const stop_blockindex = util.b4ToU32(b4[0..]);
    @memcpy(b2[0..], block[12 + 1 + 14 + 4 + 4 .. 12 + 1 + 14 + 4 + 6]);
    const offset = util.b2ToU16(b2[0..]);

    var flag = false;
    var index = start_blockindex;
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
                if (index == stop_blockindex and k + 1 >= util.u16ToUsize(offset)) {
                    flag = true;
                    break;
                }
                continue;
            }
            if ((state & 0x01) == 0) return 3;
            return 4;
        }
        if (flag) break;
        @memcpy(b4[0..], block[4..8]);
        index = util.b4ToU32(b4[0..]);
        if (index == 0) return 1;
        if (!block_mod.readblock(self, index, block[0..])) return 1;
    }

    return doMkdir(self, lastname, start_blockindex, start_block[0..], index, block[0..], stop_blockindex, offset);
}
