const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const txn = @import("txn.zig");
const block_mod = @import("block.zig");

pub fn copy(self: anytype, from_filename: []const u8, to_filename: []const u8) i32 {
    if (self.fp == null or from_filename.len == 0 or to_filename.len == 0) return 1;
    if (from_filename[from_filename.len - 1] == '/') return 2;

    var blockindex: u32 = undefined;
    var start: usize = undefined;
    if (from_filename[0] == '/') {
        blockindex = 1;
        start = 1;
    } else {
        blockindex = util.currentPwdBlockindex(self);
        start = 0;
    }
    var s: [types.BlockNameMaxSize + 2]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 2);
    var slen: usize = 0;
    var i: usize = start;
    while (i < from_filename.len) : (i += 1) {
        if (from_filename[i] == '/') {
            if (slen == 0) continue;
            if (i == from_filename.len - 1) break;
            const index = block_mod.findPathBlockindex(self, blockindex, s[0..slen]);
            if (index < 1) return 2;
            blockindex = index;
            slen = 0;
            continue;
        }
        s[slen] = from_filename[i];
        slen += 1;
        if (slen > types.BlockNameMaxSize) return 2;
    }
    var from_lastname_buf: [types.BlockNameMaxSize + 1]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 1);
    @memcpy(from_lastname_buf[0..slen], s[0..slen]);
    const from_lastname = from_lastname_buf[0..slen];
    if (std.mem.eql(u8, from_lastname, ".") or std.mem.eql(u8, from_lastname, "..")) return 2;
    const from_blockindex = blockindex;

    if (to_filename[to_filename.len - 1] == '/') return 3;
    if (to_filename[0] == '/') {
        blockindex = 1;
        start = 1;
    } else {
        blockindex = util.currentPwdBlockindex(self);
        start = 0;
    }
    slen = 0;
    i = start;
    while (i < to_filename.len) : (i += 1) {
        if (to_filename[i] == '/') {
            if (slen == 0) continue;
            if (i == to_filename.len - 1) break;
            const index = block_mod.findPathBlockindex(self, blockindex, s[0..slen]);
            if (index < 1) return 3;
            blockindex = index;
            slen = 0;
            continue;
        }
        s[slen] = to_filename[i];
        slen += 1;
        if (slen > types.BlockNameMaxSize) return 3;
    }
    var to_lastname_buf: [types.BlockNameMaxSize + 1]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 1);
    @memcpy(to_lastname_buf[0..slen], s[0..slen]);
    const to_lastname = to_lastname_buf[0..slen];
    if (std.mem.eql(u8, to_lastname, ".") or std.mem.eql(u8, to_lastname, "..")) return 3;
    const to_blockindex = blockindex;

    var b4: [4]u8 = undefined;
    var b2: [2]u8 = undefined;
    var from_block = util.blockZero();
    if (!block_mod.readblock(self, from_blockindex, from_block[0..])) return 1;
    @memcpy(b4[0..], from_block[12 + 1 + 14 + 4 .. 12 + 1 + 14 + 8]);
    const from_stop_blockindex = util.b4ToU32(b4[0..]);
    @memcpy(b2[0..], from_block[12 + 1 + 14 + 4 + 4 .. 12 + 1 + 14 + 4 + 6]);
    const from_offset = util.b2ToU16(b2[0..]);

    var from_file_start: u32 = 0;
    var from_file_stop: u32 = 0;
    var from_file_offset: u16 = 0;
    var flag = false;
    var index = from_blockindex;
    while (true) {
        var k: usize = types.BlockHead;
        var item: usize = 0;
        while (item < types.BlockItemMaxCount) : (item += 1) {
            const state = from_block[k];
            k += 1;
            @memset(s[0..], 0);
            @memcpy(s[0..types.BlockNameMaxSize], from_block[k .. k + types.BlockNameMaxSize]);
            k += types.BlockNameMaxSize;
            if (!std.mem.eql(u8, util.fixedCStr(s[0..types.BlockNameMaxSize + 1]), from_lastname)) {
                k += 10;
                if (index == from_stop_blockindex and k + 1 >= util.u16ToUsize(from_offset)) return 4;
                continue;
            }
            if ((state & 0x01) != 1) return 2;
            @memcpy(b4[0..], from_block[k .. k + 4]);
            k += 4;
            from_file_start = util.b4ToU32(b4[0..]);
            @memcpy(b4[0..], from_block[k .. k + 4]);
            k += 4;
            from_file_stop = util.b4ToU32(b4[0..]);
            @memcpy(b2[0..], from_block[k .. k + 2]);
            from_file_offset = util.b2ToU16(b2[0..]);
            flag = true;
            break;
        }
        if (flag) break;
        @memcpy(b4[0..], from_block[4..8]);
        index = util.b4ToU32(b4[0..]);
        if (index == 0) return 1;
        if (!block_mod.readblock(self, index, from_block[0..])) return 1;
    }

    var to_ba: [2]types.BlockArray = .{ .{}, .{} };
    var to_ba_used: usize = 0;
    var to_block_head: []u8 = undefined;
    var to_block_last: []u8 = undefined;
    var to_block_head_index: u32 = 0;
    var to_block_last_index: u32 = 0;

    var to_block = util.blockZero();
    if (!block_mod.readblock(self, to_blockindex, to_block[0..])) return 1;
    @memcpy(to_ba[0].block[0..], to_block[0..]);
    to_ba[0].blockindex = to_blockindex;
    to_ba[0].active = true;
    to_block_head = to_ba[0].block[0..];
    to_block_head_index = to_blockindex;
    to_ba_used = 1;

    @memcpy(b4[0..], to_block_head[12 + 1 + 14 + 4 .. 12 + 1 + 14 + 8]);
    const to_stop_blockindex = util.b4ToU32(b4[0..]);
    @memcpy(b2[0..], to_block_head[12 + 1 + 14 + 4 + 4 .. 12 + 1 + 14 + 4 + 6]);
    const to_offset = util.b2ToU16(b2[0..]);

    if (to_stop_blockindex == to_block_head_index) {
        to_block_last = to_block_head;
        to_block_last_index = to_block_head_index;
    } else {
        if (!block_mod.readblock(self, to_stop_blockindex, to_ba[1].block[0..])) return 1;
        to_ba[1].blockindex = to_stop_blockindex;
        to_ba[1].active = true;
        to_block_last = to_ba[1].block[0..];
        to_block_last_index = to_stop_blockindex;
        to_ba_used += 1;
    }

    flag = false;
    index = to_block_head_index;
    while (true) {
        var k: usize = types.BlockHead;
        var item: usize = 0;
        while (item < types.BlockItemMaxCount) : (item += 1) {
            k += 1;
            @memset(s[0..], 0);
            @memcpy(s[0..types.BlockNameMaxSize], to_block[k .. k + types.BlockNameMaxSize]);
            k += types.BlockNameMaxSize;
            if (!std.mem.eql(u8, util.fixedCStr(s[0..types.BlockNameMaxSize + 1]), to_lastname)) {
                k += 10;
                if (index == to_stop_blockindex and k + 1 >= util.u16ToUsize(to_offset)) {
                    flag = true;
                    break;
                }
                continue;
            }
            return 5;
        }
        if (flag) break;
        @memcpy(b4[0..], to_block[4..8]);
        index = util.b4ToU32(b4[0..]);
        if (index == 0) return 1;
        if (!block_mod.readblock(self, index, to_block[0..])) return 1;
    }

    if (self.tmp.state == 0 and !txn.tmpstart(self, 1)) return 1;

    var block2 = util.blockZero();
    var blockindex2: u32 = 0;
    var new_to_offset: u16 = 0;
    if (util.u16ToUsize(to_offset) < types.BlockSize) {
        @memset(to_block_last[to_offset .. to_offset + 25], 0);
        to_block_last[to_offset] = 1;
        util.copyNameInto(to_block_last[to_offset + 1 .. to_offset + 1 + types.BlockNameMaxSize], to_lastname);
        new_to_offset = to_offset + 25;
        util.u16ToB2(new_to_offset, &b2);
        @memcpy(to_block_head[types.BlockOffset .. types.BlockOffset + 2], b2[0..]);
    } else {
        blockindex2 = block_mod.genblockindex(self);
        if (blockindex2 == 0) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }
        util.u32ToB4(to_block_last_index, &b4);
        @memcpy(block2[8..12], b4[0..]);
        block2[types.BlockHead] = 1;
        util.copyNameInto(block2[types.BlockHead + 1 .. types.BlockHead + 1 + types.BlockNameMaxSize], to_lastname);
        util.u32ToB4(blockindex2, &b4);
        @memcpy(to_block_last[4..8], b4[0..]);
        new_to_offset = types.BlockHead + 25;
        util.u16ToB2(new_to_offset, &b2);
        @memcpy(to_block_head[types.BlockOffset .. types.BlockOffset + 2], b2[0..]);
        @memcpy(to_block_head[types.BlockStopBlockindex .. types.BlockStopBlockindex + 4], b4[0..]);
    }

    var to_file_start: u32 = 0;
    var to_file_stop: u32 = 0;
    var to_file_offset: u16 = 0;

    if (from_file_start > 0) {
        to_file_offset = from_file_offset;
        var from_index = from_file_start;
        if (!block_mod.readblock(self, from_index, from_block[0..])) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }
        @memcpy(b4[0..], from_block[4..8]);
        var from_next_index = util.b4ToU32(b4[0..]);

        var new_blockindex = block_mod.genblockindex(self);
        if (new_blockindex == 0) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }
        to_file_start = new_blockindex;
        to_file_stop = new_blockindex;
        var prev_index: u32 = 0;
        var new_block = util.blockZero();
        while (true) {
            @memcpy(new_block[0..], from_block[0..]);
            util.u32ToB4(prev_index, &b4);
            @memcpy(new_block[8..12], b4[0..]);
            if (from_index == from_file_stop) {
                to_file_stop = new_blockindex;
                if (!block_mod.writeblock(self, new_blockindex, new_block[0..])) {
                    if (self.tmp.state == 1) txn.tmpstop(self);
                    return 1;
                }
                break;
            }
            prev_index = new_blockindex;
            new_blockindex = block_mod.genblockindex(self);
            util.u32ToB4(new_blockindex, &b4);
            @memcpy(new_block[4..8], b4[0..]);
            if (!block_mod.writeblock(self, prev_index, new_block[0..])) {
                if (self.tmp.state == 1) txn.tmpstop(self);
                return 1;
            }
            from_index = from_next_index;
            if (!block_mod.readblock(self, from_index, from_block[0..])) {
                if (self.tmp.state == 1) txn.tmpstop(self);
                return 1;
            }
            @memcpy(b4[0..], from_block[4..8]);
            from_next_index = util.b4ToU32(b4[0..]);
        }
    }

    if (util.u16ToUsize(to_offset) < types.BlockSize) {
        util.u32ToB4(to_file_start, &b4);
        @memcpy(to_block_last[to_offset + 15 .. to_offset + 19], b4[0..]);
        util.u32ToB4(to_file_stop, &b4);
        @memcpy(to_block_last[to_offset + 19 .. to_offset + 23], b4[0..]);
        util.u16ToB2(to_file_offset, &b2);
        @memcpy(to_block_last[to_offset + 23 .. to_offset + 25], b2[0..]);
    } else {
        util.u32ToB4(to_file_start, &b4);
        @memcpy(block2[types.BlockHead + 15 .. types.BlockHead + 19], b4[0..]);
        util.u32ToB4(to_file_stop, &b4);
        @memcpy(block2[types.BlockHead + 19 .. types.BlockHead + 23], b4[0..]);
        util.u16ToB2(to_file_offset, &b2);
        @memcpy(block2[types.BlockHead + 23 .. types.BlockHead + 25], b2[0..]);
        if (!block_mod.writeblock(self, blockindex2, block2[0..])) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }
    }
    for (to_ba[0..to_ba_used]) |entry| {
        if (!entry.active) continue;
        if (!block_mod.writeblock(self, entry.blockindex, entry.block[0..])) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }
    }
    if (self.tmp.state == 1 and !txn.commit(self)) return 1;
    return 0;
}
