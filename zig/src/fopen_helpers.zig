const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const txn = @import("txn.zig");
const block_mod = @import("block.zig");

pub fn doFopenR(self: anytype, lastname: []const u8, mode: u8, block_head_index: u32) ?*types.File {
    var block = util.blockZero();
    var b4: [4]u8 = undefined;
    var b2: [2]u8 = undefined;

    if (!block_mod.readblock(self, block_head_index, block[0..])) {
        return null;
    }
    @memcpy(b4[0..], block[12 + 1 + 14 + 4 .. 12 + 1 + 14 + 8]);
    const stop_blockindex = util.b4ToU32(b4[0..]);
    @memcpy(b2[0..], block[12 + 1 + 14 + 4 + 4 .. 12 + 1 + 14 + 4 + 6]);
    const offset = util.b2ToU16(b2[0..]);

    var found = false;
    var dir_blockindex: u32 = 0;
    var dir_offset: u16 = 0;
    var index = block_head_index;
    var s: [types.BlockNameMaxSize + 1]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 1);

    while (true) {
        var k: usize = types.BlockHead;
        var i: usize = 0;
        while (i < types.BlockItemMaxCount) : (i += 1) {
            const state = block[k];
            k += 1;
            @memset(s[0..], 0);
            @memcpy(s[0..types.BlockNameMaxSize], block[k .. k + types.BlockNameMaxSize]);
            k += types.BlockNameMaxSize;
            if (!std.mem.eql(u8, util.fixedCStr(s[0..]), lastname)) {
                k += 10;
                if (index == stop_blockindex and k + 1 >= util.u16ToUsize(offset)) {
                    return null;
                }
                continue;
            }
            if ((state & 0x01) == 0) {
                return null;
            }
            dir_blockindex = index;
            dir_offset = util.usizeToU16(k + 10);
            found = true;
            break;
        }
        if (found) {
            break;
        }
        @memcpy(b4[0..], block[4..8]);
        index = util.b4ToU32(b4[0..]);
        if (index == 0) {
            return null;
        }
        if (!block_mod.readblock(self, index, block[0..])) {
            return null;
        }
    }

    const ff = self.allocator.create(types.File) catch return null;
    ff.* = .{};
    ff.mode = mode;
    ff.dir_blockindex = dir_blockindex;
    ff.dir_offset = dir_offset;
    @memcpy(b4[0..], block[dir_offset - 10 .. dir_offset - 6]);
    ff.file_start_blockindex = util.b4ToU32(b4[0..]);
    @memcpy(b4[0..], block[dir_offset - 6 .. dir_offset - 2]);
    ff.file_stop_blockindex = util.b4ToU32(b4[0..]);
    @memcpy(b2[0..], block[dir_offset - 2 .. dir_offset]);
    ff.file_offset = util.b2ToU16(b2[0..]);
    ff.pos_blockindex = ff.file_start_blockindex;
    ff.pos_offset = types.BlockHead;
    ff.pos = 0;
    return ff;
}

pub fn doFopenCreatefileitem(self: anytype, lastname: []const u8, org_start_blockindex: u32, org_stop_blockindex: u32, org_offset: u16, dir_block: []u8, dir_blockindex: *u32, dir_offset: *u16) bool {
    var b4: [4]u8 = undefined;
    var b2: [2]u8 = undefined;
    var ba: [2]types.BlockArray = .{ .{}, .{} };
    var block_start: []u8 = undefined;
    var block_stop: []u8 = undefined;
    var block_start_index: u32 = 0;
    var block_stop_index: u32 = 0;

    if (!block_mod.readblock(self, org_start_blockindex, ba[0].block[0..])) {
        return false;
    }
    ba[0].blockindex = org_start_blockindex;
    ba[0].active = true;
    block_start = ba[0].block[0..];
    block_start_index = ba[0].blockindex;

    if (org_stop_blockindex == org_start_blockindex) {
        block_stop = block_start;
        block_stop_index = block_start_index;
    } else {
        if (!block_mod.readblock(self, org_stop_blockindex, ba[1].block[0..])) {
            return false;
        }
        ba[1].blockindex = org_stop_blockindex;
        ba[1].active = true;
        block_stop = ba[1].block[0..];
        block_stop_index = ba[1].blockindex;
    }

    if (self.tmp.state == 0 and !txn.tmpstart(self, 1)) {
        return false;
    }

    if (util.u16ToUsize(org_offset) < types.BlockSize) {
        var k = util.u16ToUsize(org_offset);
        block_stop[k] = 1;
        k += 1;
        util.copyNameInto(block_stop[k .. k + types.BlockNameMaxSize], lastname);
        k += types.BlockNameMaxSize;
        k += 4;
        k += 4;
        k += 2;
        const new_offset = util.usizeToU16(k);
        util.u16ToB2(new_offset, &b2);
        @memcpy(block_start[types.BlockOffset .. types.BlockOffset + 2], b2[0..]);

        for (ba) |entry| {
            if (!entry.active) continue;
            if (!block_mod.writeblock(self, entry.blockindex, entry.block[0..])) {
                if (self.tmp.state == 1) txn.tmpstop(self);
                return false;
            }
        }
        if (self.tmp.state == 1 and !txn.commit(self)) {
            return false;
        }
        @memcpy(dir_block, block_stop[0..types.BlockSize]);
        dir_blockindex.* = block_stop_index;
        dir_offset.* = new_offset;
        return true;
    }

    const blockindex2 = block_mod.genblockindex(self);
    if (blockindex2 == 0) {
        if (self.tmp.state == 1) txn.tmpstop(self);
        return false;
    }
    var block2 = util.blockZero();
    var k: usize = 8;
    util.u32ToB4(org_stop_blockindex, &b4);
    @memcpy(block2[k .. k + 4], b4[0..]);
    k += 4;
    block2[k] = 1;
    k += 1;
    util.copyNameInto(block2[k .. k + types.BlockNameMaxSize], lastname);
    k += types.BlockNameMaxSize;
    k += 4;
    k += 4;
    k += 2;
    const new_offset = util.usizeToU16(k);
    util.u16ToB2(new_offset, &b2);
    @memcpy(block_start[types.BlockOffset .. types.BlockOffset + 2], b2[0..]);
    util.u32ToB4(blockindex2, &b4);
    @memcpy(block_start[types.BlockStopBlockindex .. types.BlockStopBlockindex + 4], b4[0..]);
    @memcpy(block_stop[4..8], b4[0..]);

    for (ba) |entry| {
        if (!entry.active) continue;
        if (!block_mod.writeblock(self, entry.blockindex, entry.block[0..])) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return false;
        }
    }
    if (self.tmp.state == 1 and !txn.commit(self)) {
        return false;
    }
    @memcpy(dir_block, block2[0..types.BlockSize]);
    dir_blockindex.* = blockindex2;
    dir_offset.* = new_offset;
    return true;
}

pub fn doFopenCleanfilecontent(self: anytype, dir_block: []u8, dir_blockindex: u32, dir_offset: u16) bool {
    var b4: [4]u8 = undefined;
    @memcpy(b4[0..], dir_block[dir_offset - 10 .. dir_offset - 6]);
    const file_start = util.b4ToU32(b4[0..]);
    @memcpy(b4[0..], dir_block[dir_offset - 6 .. dir_offset - 2]);
    const file_stop = util.b4ToU32(b4[0..]);
    if (file_start == 0) {
        return true;
    }

    if (self.tmp.state == 0 and !txn.tmpstart(self, 1)) {
        return false;
    }

    var file_block_stop = util.blockZero();
    if (!block_mod.readblock(self, file_stop, file_block_stop[0..])) {
        if (self.tmp.state == 1) txn.tmpstop(self);
        return false;
    }
    util.u32ToB4(self.tmp.new_unused_blockhead, &b4);
    @memcpy(file_block_stop[4..8], b4[0..]);
    self.tmp.new_unused_blockhead = file_start;

    @memset(dir_block[dir_offset - 10 .. dir_offset], 0);

    if (!block_mod.writeblock(self, dir_blockindex, dir_block)) {
        if (self.tmp.state == 1) txn.tmpstop(self);
        return false;
    }
    if (!block_mod.writeblock(self, file_stop, file_block_stop[0..])) {
        if (self.tmp.state == 1) txn.tmpstop(self);
        return false;
    }
    if (self.tmp.state == 1 and !txn.commit(self)) {
        return false;
    }
    return true;
}

pub fn doFopenW(self: anytype, lastname: []const u8, mode: u8, block_head_index: u32) ?*types.File {
    var block = util.blockZero();
    var b4: [4]u8 = undefined;
    var b2: [2]u8 = undefined;

    if (!block_mod.readblock(self, block_head_index, block[0..])) {
        return null;
    }
    @memcpy(b4[0..], block[12 + 1 + 14 + 4 .. 12 + 1 + 14 + 8]);
    const stop_blockindex = util.b4ToU32(b4[0..]);
    @memcpy(b2[0..], block[12 + 1 + 14 + 4 + 4 .. 12 + 1 + 14 + 4 + 6]);
    const offset = util.b2ToU16(b2[0..]);

    var found = false;
    var dir_exists = false;
    var dir_blockindex: u32 = 0;
    var dir_offset: u16 = 0;
    var index = block_head_index;
    var s: [types.BlockNameMaxSize + 1]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 1);

    while (true) {
        var k: usize = types.BlockHead;
        var i: usize = 0;
        while (i < types.BlockItemMaxCount) : (i += 1) {
            const state = block[k];
            k += 1;
            @memset(s[0..], 0);
            @memcpy(s[0..types.BlockNameMaxSize], block[k .. k + types.BlockNameMaxSize]);
            k += types.BlockNameMaxSize;
            if (!std.mem.eql(u8, util.fixedCStr(s[0..]), lastname)) {
                k += 10;
                if (index == stop_blockindex and k + 1 >= util.u16ToUsize(offset)) {
                    found = true;
                    break;
                }
                continue;
            }
            if ((state & 0x01) == 0) {
                return null;
            }
            dir_blockindex = index;
            dir_offset = util.usizeToU16(k + 10);
            dir_exists = true;
            found = true;
            break;
        }
        if (found) break;
        @memcpy(b4[0..], block[4..8]);
        index = util.b4ToU32(b4[0..]);
        if (index == 0) return null;
        if (!block_mod.readblock(self, index, block[0..])) return null;
    }

    if (!dir_exists) {
        if (!doFopenCreatefileitem(self, lastname, block_head_index, stop_blockindex, offset, block[0..], &dir_blockindex, &dir_offset)) {
            return null;
        }
    } else {
        if (!doFopenCleanfilecontent(self, block[0..], dir_blockindex, dir_offset)) {
            return null;
        }
    }

    const ff = self.allocator.create(types.File) catch return null;
    ff.* = .{ .mode = mode, .dir_blockindex = dir_blockindex, .dir_offset = dir_offset };
    return ff;
}

pub fn doFopenA(self: anytype, lastname: []const u8, mode: u8, block_head_index: u32) ?*types.File {
    var block = util.blockZero();
    var b4: [4]u8 = undefined;
    var b2: [2]u8 = undefined;

    if (!block_mod.readblock(self, block_head_index, block[0..])) {
        return null;
    }
    @memcpy(b4[0..], block[12 + 1 + 14 + 4 .. 12 + 1 + 14 + 8]);
    const stop_blockindex = util.b4ToU32(b4[0..]);
    @memcpy(b2[0..], block[12 + 1 + 14 + 4 + 4 .. 12 + 1 + 14 + 4 + 6]);
    const offset = util.b2ToU16(b2[0..]);

    var found = false;
    var dir_exists = false;
    var dir_blockindex: u32 = 0;
    var dir_offset: u16 = 0;
    var index = block_head_index;
    var s: [types.BlockNameMaxSize + 1]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 1);

    while (true) {
        var k: usize = types.BlockHead;
        var i: usize = 0;
        while (i < types.BlockItemMaxCount) : (i += 1) {
            const state = block[k];
            k += 1;
            @memset(s[0..], 0);
            @memcpy(s[0..types.BlockNameMaxSize], block[k .. k + types.BlockNameMaxSize]);
            k += types.BlockNameMaxSize;
            if (!std.mem.eql(u8, util.fixedCStr(s[0..]), lastname)) {
                k += 10;
                if (index == stop_blockindex and k + 1 >= util.u16ToUsize(offset)) {
                    found = true;
                    break;
                }
                continue;
            }
            if ((state & 0x01) == 0) {
                return null;
            }
            dir_blockindex = index;
            dir_offset = util.usizeToU16(k + 10);
            dir_exists = true;
            found = true;
            break;
        }
        if (found) break;
        @memcpy(b4[0..], block[4..8]);
        index = util.b4ToU32(b4[0..]);
        if (index == 0) return null;
        if (!block_mod.readblock(self, index, block[0..])) return null;
    }

    if (!dir_exists) {
        if (!doFopenCreatefileitem(self, lastname, block_head_index, stop_blockindex, offset, block[0..], &dir_blockindex, &dir_offset)) {
            return null;
        }
        const ff = self.allocator.create(types.File) catch return null;
        ff.* = .{ .mode = mode, .dir_blockindex = dir_blockindex, .dir_offset = dir_offset };
        return ff;
    }

    @memcpy(b4[0..], block[dir_offset - 10 .. dir_offset - 6]);
    const file_start = util.b4ToU32(b4[0..]);
    @memcpy(b4[0..], block[dir_offset - 6 .. dir_offset - 2]);
    const file_stop = util.b4ToU32(b4[0..]);
    @memcpy(b2[0..], block[dir_offset - 2 .. dir_offset]);
    const file_offset = util.b2ToU16(b2[0..]);

    var pos: u64 = 0;
    index = file_start;
    while (true) {
        if (index == file_stop) {
            pos += file_offset - types.BlockHead;
            break;
        }
        if (!block_mod.readblock(self, index, block[0..])) {
            return null;
        }
        pos += types.BlockSize - types.BlockHead;
        @memcpy(b4[0..], block[4..8]);
        index = util.b4ToU32(b4[0..]);
    }

    const ff = self.allocator.create(types.File) catch return null;
    ff.* = .{
        .mode = mode,
        .dir_blockindex = dir_blockindex,
        .dir_offset = dir_offset,
        .file_start_blockindex = file_start,
        .file_stop_blockindex = file_stop,
        .file_offset = file_offset,
        .pos_blockindex = file_stop,
        .pos_offset = file_offset,
        .pos = pos,
    };
    return ff;
}
