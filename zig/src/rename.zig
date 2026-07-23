const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const txn = @import("txn.zig");
const block_mod = @import("block.zig");

pub fn doRename(self: anytype, old_lastname: []const u8, old_blockindex: u32, old_type_dir: u8, new_lastname: []const u8, new_blockindex: u32, new_type_dir: u8) i32 {
    var b4: [4]u8 = undefined;
    var b2: [2]u8 = undefined;
    var s: [types.BlockNameMaxSize + 2]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 2);

    var old_ba: [4]types.BlockArray = .{ .{}, .{}, .{}, .{} };
    var old_ba_used: usize = 0;
    var old_block_head: []u8 = undefined;
    var old_block_last: []u8 = undefined;
    var old_block_item: []u8 = undefined;
    var old_block_prev: []u8 = undefined;
    var old_block_item_index: u32 = 0;
    var old_block_last_index: u32 = 0;
    var old_block_prev_index: u32 = 0;
    var old_block_head_index: u32 = 0;

    var old_block = util.blockZero();
    if (!block_mod.readblock(self, old_blockindex, old_block[0..])) return 1;
    @memcpy(old_ba[0].block[0..], old_block[0..]);
    old_ba[0].blockindex = old_blockindex;
    old_ba[0].active = true;
    old_block_head = old_ba[0].block[0..];
    old_block_head_index = old_blockindex;
    old_ba_used = 1;

    @memcpy(b4[0..], old_block_head[12 + 1 + 14 + 4 .. 12 + 1 + 14 + 8]);
    const old_stop_blockindex = util.b4ToU32(b4[0..]);
    @memcpy(b2[0..], old_block_head[12 + 1 + 14 + 4 + 4 .. 12 + 1 + 14 + 4 + 6]);
    var old_offset = util.b2ToU16(b2[0..]);

    if (old_stop_blockindex == old_block_head_index) {
        old_block_last = old_block_head;
        old_block_last_index = old_block_head_index;
    } else {
        if (!block_mod.readblock(self, old_stop_blockindex, old_ba[1].block[0..])) return 1;
        old_ba[1].blockindex = old_stop_blockindex;
        old_ba[1].active = true;
        old_block_last = old_ba[1].block[0..];
        old_block_last_index = old_stop_blockindex;
        old_ba_used += 1;
    }

    var old_item_offset: u16 = 0;
    var old_dir_file: u8 = 0;
    var flag = false;
    var index = old_block_head_index;
    while (true) {
        var k: usize = types.BlockHead;
        var item: usize = 0;
        while (item < types.BlockItemMaxCount) : (item += 1) {
            const state = old_block[k];
            k += 1;
            @memset(s[0..], 0);
            @memcpy(s[0..types.BlockNameMaxSize], old_block[k .. k + types.BlockNameMaxSize]);
            k += types.BlockNameMaxSize;
            if (!std.mem.eql(u8, util.fixedCStr(s[0..types.BlockNameMaxSize + 1]), old_lastname)) {
                k += 10;
                if (index == old_stop_blockindex and k + 1 >= util.u16ToUsize(old_offset)) return 4;
                continue;
            }
            old_dir_file = state & 0x01;
            if (old_type_dir == 1 and old_dir_file == 1) return 2;
            if (new_type_dir == 1 and old_dir_file == 1) return 6;
            old_item_offset = util.usizeToU16(k + 10);
            var u = false;
            var j: usize = 0;
            while (j < old_ba_used) : (j += 1) {
                if (old_ba[j].blockindex == index) {
                    old_block_item = old_ba[j].block[0..];
                    old_block_item_index = index;
                    u = true;
                    break;
                }
            }
            if (!u) {
                @memcpy(old_ba[old_ba_used].block[0..], old_block[0..]);
                old_ba[old_ba_used].blockindex = index;
                old_ba[old_ba_used].active = true;
                old_block_item = old_ba[old_ba_used].block[0..];
                old_block_item_index = index;
                old_ba_used += 1;
            }
            flag = true;
            break;
        }
        if (flag) break;
        @memcpy(b4[0..], old_block[4..8]);
        index = util.b4ToU32(b4[0..]);
        if (index == 0) return 1;
        if (!block_mod.readblock(self, index, old_block[0..])) return 1;
    }

    var new_ba: [2]types.BlockArray = .{ .{}, .{} };
    var new_ba_used: usize = 0;
    var new_block_head: []u8 = undefined;
    var new_block_last: []u8 = undefined;
    var new_block_head_index: u32 = 0;
    var new_block_last_index: u32 = 0;

    var new_block = util.blockZero();
    if (!block_mod.readblock(self, new_blockindex, new_block[0..])) return 1;
    @memcpy(new_ba[0].block[0..], new_block[0..]);
    new_ba[0].blockindex = new_blockindex;
    new_ba[0].active = true;
    new_block_head = new_ba[0].block[0..];
    new_block_head_index = new_blockindex;
    new_ba_used = 1;

    @memcpy(b4[0..], new_block_head[12 + 1 + 14 + 4 .. 12 + 1 + 14 + 8]);
    const new_stop_blockindex = util.b4ToU32(b4[0..]);
    @memcpy(b2[0..], new_block_head[12 + 1 + 14 + 4 + 4 .. 12 + 1 + 14 + 4 + 6]);
    var new_offset = util.b2ToU16(b2[0..]);

    if (new_stop_blockindex == new_block_head_index) {
        new_block_last = new_block_head;
        new_block_last_index = new_block_head_index;
    } else {
        if (!block_mod.readblock(self, new_stop_blockindex, new_ba[1].block[0..])) return 1;
        new_ba[1].blockindex = new_stop_blockindex;
        new_ba[1].active = true;
        new_block_last = new_ba[1].block[0..];
        new_block_last_index = new_stop_blockindex;
        new_ba_used += 1;
    }

    flag = false;
    index = new_block_head_index;
    while (true) {
        var k: usize = types.BlockHead;
        var item: usize = 0;
        while (item < types.BlockItemMaxCount) : (item += 1) {
            k += 1;
            @memset(s[0..], 0);
            @memcpy(s[0..types.BlockNameMaxSize], new_block[k .. k + types.BlockNameMaxSize]);
            k += types.BlockNameMaxSize;
            if (!std.mem.eql(u8, util.fixedCStr(s[0..types.BlockNameMaxSize + 1]), new_lastname)) {
                k += 10;
                if (index == new_stop_blockindex and k + 1 >= util.u16ToUsize(new_offset)) {
                    flag = true;
                    break;
                }
                continue;
            }
            return 5;
        }
        if (flag) break;
        @memcpy(b4[0..], new_block[4..8]);
        index = util.b4ToU32(b4[0..]);
        if (index == 0) return 1;
        if (!block_mod.readblock(self, index, new_block[0..])) return 1;
    }

    if (old_block_head_index == new_block_head_index) {
        util.copyNameInto(old_block_item[old_item_offset - 24 .. old_item_offset - 10], new_lastname);
        if (self.tmp.state == 0 and !txn.tmpstart(self, 1)) return 1;
        if (!block_mod.writeblock(self, old_block_item_index, old_block_item)) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }
        if (self.tmp.state == 1 and !txn.commit(self)) return 1;
        return 0;
    }

    if (self.tmp.state == 0 and !txn.tmpstart(self, 1)) return 1;

    if (old_dir_file == 0) {
        @memcpy(b4[0..], old_block_item[old_item_offset - 10 .. old_item_offset - 6]);
        const path_blockindex = util.b4ToU32(b4[0..]);
        var path_block = util.blockZero();
        if (!block_mod.readblock(self, path_blockindex, path_block[0..])) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }
        util.u32ToB4(new_block_head_index, &b4);
        @memcpy(path_block[types.BlockHead + 25 + 1 + 14 .. types.BlockHead + 25 + 1 + 18], b4[0..]);
        if (!block_mod.writeblock(self, path_blockindex, path_block[0..])) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }
    }

    var block2 = util.blockZero();
    var blockindex2: u32 = 0;
    if (util.u16ToUsize(new_offset) < types.BlockSize) {
        std.mem.copyForwards(u8, new_block_last[new_offset .. new_offset + 25], old_block_item[old_item_offset - 25 .. old_item_offset]);
        new_offset += 25;
        util.u16ToB2(new_offset, &b2);
        @memcpy(new_block_head[types.BlockOffset .. types.BlockOffset + 2], b2[0..]);
    } else {
        blockindex2 = block_mod.genblockindex(self);
        if (blockindex2 == 0) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }
        util.u32ToB4(new_block_last_index, &b4);
        @memcpy(block2[8..12], b4[0..]);
        std.mem.copyForwards(u8, block2[types.BlockHead .. types.BlockHead + 25], old_block_item[old_item_offset - 25 .. old_item_offset]);
        if (!block_mod.writeblock(self, blockindex2, block2[0..])) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }
        util.u32ToB4(blockindex2, &b4);
        @memcpy(new_block_last[4..8], b4[0..]);
        new_offset = types.BlockHead + 25;
        util.u16ToB2(new_offset, &b2);
        @memcpy(new_block_head[types.BlockOffset .. types.BlockOffset + 2], b2[0..]);
        @memcpy(new_block_head[types.BlockStopBlockindex .. types.BlockStopBlockindex + 4], b4[0..]);
    }
    for (new_ba[0..new_ba_used]) |entry| {
        if (!entry.active) continue;
        if (!block_mod.writeblock(self, entry.blockindex, entry.block[0..])) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }
    }

    if (old_block_item_index != old_stop_blockindex or old_item_offset != old_offset) {
        std.mem.copyForwards(u8, old_block_item[old_item_offset - 25 .. old_item_offset], old_block_last[old_offset - 25 .. old_offset]);
    }
    old_offset -= 25;
    util.u16ToB2(old_offset, &b2);
    @memcpy(old_block_head[types.BlockOffset .. types.BlockOffset + 2], b2[0..]);

    if (old_offset < 25) {
        @memcpy(b4[0..], old_block_last[8..12]);
        old_block_prev_index = util.b4ToU32(b4[0..]);
        _ = block_mod.removeblock(self, old_block_last_index);
        var k_idx: isize = -1;
        var i: usize = 0;
        while (i < old_ba_used) : (i += 1) {
            if (old_ba[i].blockindex == old_block_last_index) {
                old_ba[i].active = false;
                k_idx = @intCast(i);
                break;
            }
        }
        if (k_idx < 0) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }
        var u = false;
        i = 0;
        while (i < old_ba_used) : (i += 1) {
            if (old_ba[i].blockindex == old_block_prev_index) {
                old_block_prev = old_ba[i].block[0..];
                u = true;
                break;
            }
        }
        if (!u) {
            if (!block_mod.readblock(self, old_block_prev_index, old_block[0..])) {
                if (self.tmp.state == 1) txn.tmpstop(self);
                return 1;
            }
            @memcpy(old_ba[@intCast(k_idx)].block[0..], old_block[0..]);
            old_ba[@intCast(k_idx)].blockindex = old_block_prev_index;
            old_ba[@intCast(k_idx)].active = true;
            old_block_prev = old_ba[@intCast(k_idx)].block[0..];
        }
        @memset(old_block_prev[4..8], 0);
        util.u32ToB4(old_block_prev_index, &b4);
        @memcpy(old_block_head[types.BlockStopBlockindex .. types.BlockStopBlockindex + 4], b4[0..]);
        old_offset = types.BlockSize;
        util.u16ToB2(old_offset, &b2);
        @memcpy(old_block_head[types.BlockOffset .. types.BlockOffset + 2], b2[0..]);
    }
    for (old_ba[0..old_ba_used]) |entry| {
        if (!entry.active) continue;
        if (!block_mod.writeblock(self, entry.blockindex, entry.block[0..])) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 1;
        }
    }
    if (self.tmp.state == 1 and !txn.commit(self)) return 1;
    return 0;
}

pub fn rename(self: anytype, old_name: []const u8, new_name: []const u8) i32 {
    if (self.fp == null or old_name.len == 0 or new_name.len == 0) return 1;

    var blockindex: u32 = undefined;
    var start: usize = undefined;
    if (old_name[0] == '/') {
        blockindex = 1;
        start = 1;
    } else {
        blockindex = util.currentPwdBlockindex(self);
        start = 0;
    }
    var s: [types.BlockNameMaxSize + 2]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 2);
    var slen: usize = 0;
    var i: usize = start;
    while (i < old_name.len) : (i += 1) {
        if (old_name[i] == '/') {
            if (slen == 0) continue;
            if (i == old_name.len - 1) break;
            const index = block_mod.findPathBlockindex(self, blockindex, s[0..slen]);
            if (index < 1) return 2;
            blockindex = index;
            slen = 0;
            continue;
        }
        s[slen] = old_name[i];
        slen += 1;
        if (slen > types.BlockNameMaxSize) return 2;
    }
    var old_lastname_buf: [types.BlockNameMaxSize + 1]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 1);
    @memcpy(old_lastname_buf[0..slen], s[0..slen]);
    const old_lastname = old_lastname_buf[0..slen];
    if (std.mem.eql(u8, old_lastname, ".") or std.mem.eql(u8, old_lastname, "..")) return 2;
    const old_blockindex = blockindex;
    const old_type_dir: u8 = if (old_name[old_name.len - 1] == '/') 1 else 0;

    if (new_name[0] == '/') {
        blockindex = 1;
        start = 1;
    } else {
        blockindex = util.currentPwdBlockindex(self);
        start = 0;
    }
    slen = 0;
    i = start;
    while (i < new_name.len) : (i += 1) {
        if (new_name[i] == '/') {
            if (slen == 0) continue;
            if (i == new_name.len - 1) break;
            const index = block_mod.findPathBlockindex(self, blockindex, s[0..slen]);
            if (index < 1) return 3;
            blockindex = index;
            slen = 0;
            continue;
        }
        s[slen] = new_name[i];
        slen += 1;
        if (slen > types.BlockNameMaxSize) return 3;
    }
    var new_lastname_buf: [types.BlockNameMaxSize + 1]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 1);
    @memcpy(new_lastname_buf[0..slen], s[0..slen]);
    const new_lastname = new_lastname_buf[0..slen];
    if (std.mem.eql(u8, new_lastname, ".") or std.mem.eql(u8, new_lastname, "..")) return 3;
    const new_blockindex = blockindex;
    const new_type_dir: u8 = if (new_name[new_name.len - 1] == '/') 1 else 0;

    return doRename(self, old_lastname, old_blockindex, old_type_dir, new_lastname, new_blockindex, new_type_dir);
}
