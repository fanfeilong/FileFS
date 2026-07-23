const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const txn = @import("txn.zig");
const block_mod = @import("block.zig");

pub fn remove(self: anytype, filename: []const u8) i32 {
    if (self.fp == null or filename.len == 0) return 1;
    if (filename[filename.len - 1] == '/') return 5;

    var blockindex: u32 = undefined;
    var start: usize = undefined;
    if (filename[0] == '/') {
        blockindex = 1;
        start = 1;
    } else {
        blockindex = util.currentPwdBlockindex(self);
        start = 0;
    }

    var s: [types.BlockNameMaxSize + 2]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 2);
    var slen: usize = 0;
    var i: usize = start;
    while (i < filename.len) : (i += 1) {
        if (filename[i] == '/') {
            if (slen == 0) continue;
            const index = block_mod.findPathBlockindex(self, blockindex, s[0..slen]);
            if (index < 1) return 3;
            blockindex = index;
            slen = 0;
            continue;
        }
        s[slen] = filename[i];
        slen += 1;
        if (slen > types.BlockNameMaxSize) return 4;
    }
    if (slen == 0) return 2;
    var lastname_buf: [types.BlockNameMaxSize + 1]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 1);
    @memcpy(lastname_buf[0..slen], s[0..slen]);
    const lastname = lastname_buf[0..slen];
    if (std.mem.eql(u8, lastname, ".") or std.mem.eql(u8, lastname, "..")) return 5;

    var ba: [4]types.BlockArray = .{ .{}, .{}, .{}, .{} };
    var ba_used: usize = 0;
    var block_head: []u8 = undefined;
    var block_last: []u8 = undefined;
    var block_item: []u8 = undefined;
    var block_prev: []u8 = undefined;
    var block_item_index: u32 = 0;
    var block_last_index: u32 = 0;
    var block_prev_index: u32 = 0;
    var block_head_index: u32 = 0;

    var block = util.blockZero();
    var b4: [4]u8 = undefined;
    var b2: [2]u8 = undefined;

    if (!block_mod.readblock(self, blockindex, block[0..])) return 1;
    @memcpy(ba[0].block[0..], block[0..]);
    ba[0].blockindex = blockindex;
    ba[0].active = true;
    block_head = ba[0].block[0..];
    block_head_index = blockindex;
    ba_used = 1;

    @memcpy(b4[0..], block_head[12 + 1 + 14 + 4 .. 12 + 1 + 14 + 8]);
    const stop_blockindex = util.b4ToU32(b4[0..]);
    @memcpy(b2[0..], block_head[12 + 1 + 14 + 4 + 4 .. 12 + 1 + 14 + 4 + 6]);
    var offset = util.b2ToU16(b2[0..]);

    if (stop_blockindex == block_head_index) {
        block_last = block_head;
        block_last_index = block_head_index;
    } else {
        if (!block_mod.readblock(self, stop_blockindex, ba[1].block[0..])) return 1;
        ba[1].blockindex = stop_blockindex;
        ba[1].active = true;
        block_last = ba[1].block[0..];
        block_last_index = stop_blockindex;
        ba_used += 1;
    }

    var file_start: u32 = 0;
    var file_stop: u32 = 0;
    var item_offset: u16 = 0;
    var flag = false;
    var index = block_head_index;
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
                if (index == stop_blockindex and k + 1 >= util.u16ToUsize(offset)) return 2;
                continue;
            }
            if ((state & 0x01) == 0) return 2;
            @memcpy(b4[0..], block[k .. k + 4]);
            file_start = util.b4ToU32(b4[0..]);
            @memcpy(b4[0..], block[k + 4 .. k + 8]);
            file_stop = util.b4ToU32(b4[0..]);
            item_offset = util.usizeToU16(k + 10);

            var u = false;
            var j: usize = 0;
            while (j < ba_used) : (j += 1) {
                if (ba[j].blockindex == index) {
                    block_item = ba[j].block[0..];
                    block_item_index = index;
                    u = true;
                    break;
                }
            }
            if (!u) {
                @memcpy(ba[ba_used].block[0..], block[0..]);
                ba[ba_used].blockindex = index;
                ba[ba_used].active = true;
                block_item = ba[ba_used].block[0..];
                block_item_index = index;
                ba_used += 1;
            }
            flag = true;
            break;
        }
        if (flag) break;
        @memcpy(b4[0..], block[4..8]);
        index = util.b4ToU32(b4[0..]);
        if (index == 0) return 1;
        if (!block_mod.readblock(self, index, block[0..])) return 1;
    }

    if (self.tmp.state == 0 and !txn.tmpstart(self, 1)) return 1;

    if (file_start > 0) {
        var file_block_stop = util.blockZero();
        if (!block_mod.readblock(self, file_stop, file_block_stop[0..])) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }
        util.u32ToB4(self.tmp.new_unused_blockhead, &b4);
        @memcpy(file_block_stop[4..8], b4[0..]);
        self.tmp.new_unused_blockhead = file_start;
        if (!block_mod.writeblock(self, file_stop, file_block_stop[0..])) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }
    }

    if (block_item_index != stop_blockindex or item_offset != offset) {
        std.mem.copyForwards(u8, block_item[item_offset - 25 .. item_offset], block_last[offset - 25 .. offset]);
    }

    offset -= 25;
    util.u16ToB2(offset, &b2);
    @memcpy(block_head[types.BlockOffset .. types.BlockOffset + 2], b2[0..]);

    if (offset < 25) {
        @memcpy(b4[0..], block_last[8..12]);
        block_prev_index = util.b4ToU32(b4[0..]);
        _ = block_mod.removeblock(self, block_last_index);
        var k_idx: isize = -1;
        var bi: usize = 0;
        while (bi < ba_used) : (bi += 1) {
            if (ba[bi].blockindex == block_last_index) {
                ba[bi].active = false;
                k_idx = @intCast(bi);
                break;
            }
        }
        if (k_idx < 0) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }
        var u = false;
        bi = 0;
        while (bi < ba_used) : (bi += 1) {
            if (ba[bi].blockindex == block_prev_index) {
                block_prev = ba[bi].block[0..];
                u = true;
                break;
            }
        }
        if (!u) {
            if (!block_mod.readblock(self, block_prev_index, block[0..])) {
                if (self.tmp.state == 1) txn.tmpstop(self);
                return 1;
            }
            @memcpy(ba[@intCast(k_idx)].block[0..], block[0..]);
            ba[@intCast(k_idx)].blockindex = block_prev_index;
            ba[@intCast(k_idx)].active = true;
            block_prev = ba[@intCast(k_idx)].block[0..];
        }
        @memset(block_prev[4..8], 0);
        util.u32ToB4(block_prev_index, &b4);
        @memcpy(block_head[types.BlockStopBlockindex .. types.BlockStopBlockindex + 4], b4[0..]);
        offset = types.BlockSize;
        util.u16ToB2(offset, &b2);
        @memcpy(block_head[types.BlockOffset .. types.BlockOffset + 2], b2[0..]);
    }

    for (ba[0..ba_used]) |entry| {
        if (!entry.active) continue;
        if (!block_mod.writeblock(self, entry.blockindex, entry.block[0..])) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }
    }
    if (self.tmp.state == 1 and !txn.commit(self)) return 1;
    return 0;
}
