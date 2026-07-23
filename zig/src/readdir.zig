const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const block_mod = @import("block.zig");

pub fn opendir(self: anytype, path: []const u8) ?types.OpenDirResult {
    if (self.fp == null) return null;

    const dir = self.allocator.create(types.Dir) catch return null;
    dir.* = .{};

    var blockindex: u32 = undefined;
    var start: usize = undefined;
    if (path.len > 0 and path[0] == '/') {
        blockindex = 1;
        start = 1;
        if (!util.initPwdTmp(self, "/")) {
            self.allocator.destroy(dir);
            return null;
        }
    } else {
        blockindex = util.currentPwdBlockindex(self);
        if (!util.initPwdTmp(self, util.currentPwd(self))) {
            self.allocator.destroy(dir);
            return null;
        }
        start = 0;
    }

    var s: [types.BlockNameMaxSize + 2]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 2);
    var slen: usize = 0;
    var i: usize = start;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            if (slen == 0) continue;
            const comp = s[0..slen];
            const index = block_mod.findPathBlockindex(self, blockindex, comp);
            if (index < 1) {
                self.allocator.destroy(dir);
                return null;
            }
            blockindex = index;
            slen = 0;
            if (!util.addToPwdTmp(self, comp)) {
                self.allocator.destroy(dir);
                return null;
            }
            continue;
        }
        s[slen] = path[i];
        slen += 1;
        if (slen > types.BlockNameMaxSize) {
            self.allocator.destroy(dir);
            return null;
        }
    }
    if (slen > 0) {
        const index = block_mod.findPathBlockindex(self, blockindex, s[0..slen]);
        if (index < 1) {
            self.allocator.destroy(dir);
            return null;
        }
        blockindex = index;
        if (!util.addToPwdTmp(self, s[0..slen])) {
            self.allocator.destroy(dir);
            return null;
        }
    }

    if (!block_mod.readblock(self, blockindex, dir.block[0..])) {
        self.allocator.destroy(dir);
        return null;
    }
    var b4: [4]u8 = undefined;
    var b2: [2]u8 = undefined;
    @memcpy(b4[0..], dir.block[12 + 1 + 14 + 4 .. 12 + 1 + 14 + 8]);
    dir.stop_blockindex = util.b4ToU32(b4[0..]);
    @memcpy(b2[0..], dir.block[12 + 1 + 14 + 4 + 4 .. 12 + 1 + 14 + 4 + 6]);
    dir.offset = util.b2ToU16(b2[0..]);
    dir.blockindex = blockindex;
    dir.searchindex = 0;
    return .{ .dir = dir, .absolute_path = self.pwd_tmp[0..self.pwd_tmp_len] };
}

pub fn readdir(self: anytype, dir: *types.Dir) ?*types.Dirent {
    if (self.fp == null) return null;

    var block = dir.block[0..];
    var k: usize = types.BlockHead + dir.searchindex * 25;
    if (dir.blockindex == dir.stop_blockindex and k + 1 >= util.u16ToUsize(dir.offset)) {
        return null;
    }
    var b4: [4]u8 = undefined;
    while (true) {
        if (dir.searchindex >= types.BlockItemMaxCount) {
            const nextindex = util.b4ToU32(block[4..8]);
            if (nextindex == 0) return null;
            if (!block_mod.readblock(self, nextindex, dir.block[0..])) return null;
            block = dir.block[0..];
            dir.searchindex = 0;
            dir.blockindex = nextindex;
            k = types.BlockHead;
            continue;
        }

        const state = block[k];
        k += 1;
        const dir_file = state & 0x01;
        dir.dirp.d_type = if (dir_file == 1) types.DTFile else types.DTDir;
        @memset(dir.dirp.d_name[0..], 0);
        @memcpy(dir.dirp.d_name[0..types.BlockNameMaxSize], block[k .. k + types.BlockNameMaxSize]);
        k += types.BlockNameMaxSize;
        const name = util.fixedCStr(dir.dirp.d_name[0..]);
        dir.dirp.d_namlen = name.len;
        if (std.mem.eql(u8, name, ".")) {
            @memcpy(b4[0..], block[k .. k + 4]);
            if (util.b4ToU32(b4[0..]) == 1) dir.dirp.d_type = types.DTRoot;
        } else if (std.mem.eql(u8, name, "..")) {
            @memcpy(b4[0..], block[k .. k + 4]);
            if (util.b4ToU32(b4[0..]) == 0) dir.dirp.d_type = types.DTRoot;
        }
        k += 10;
        dir.searchindex += 1;
        return &dir.dirp;
    }
}

pub fn closedir(self: anytype, dir: *types.Dir) void {
    self.allocator.destroy(dir);
}
