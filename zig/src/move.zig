const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const block_mod = @import("block.zig");
const rename_mod = @import("rename.zig");

pub fn move(self: anytype, from_name: []const u8, to_path: []const u8) i32 {
    if (self.fp == null or from_name.len == 0 or to_path.len == 0) return 1;

    var blockindex: u32 = undefined;
    var start: usize = undefined;
    if (from_name[0] == '/') {
        blockindex = 1;
        start = 1;
    } else {
        blockindex = util.currentPwdBlockindex(self);
        start = 0;
    }
    var s: [types.BlockNameMaxSize + 2]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 2);
    var slen: usize = 0;
    var i: usize = start;
    while (i < from_name.len) : (i += 1) {
        if (from_name[i] == '/') {
            if (slen == 0) continue;
            if (i == from_name.len - 1) break;
            const index = block_mod.findPathBlockindex(self, blockindex, s[0..slen]);
            if (index < 1) return 2;
            blockindex = index;
            slen = 0;
            continue;
        }
        s[slen] = from_name[i];
        slen += 1;
        if (slen > types.BlockNameMaxSize) return 2;
    }
    var from_lastname_buf: [types.BlockNameMaxSize + 1]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 1);
    @memcpy(from_lastname_buf[0..slen], s[0..slen]);
    const from_lastname = from_lastname_buf[0..slen];
    if (std.mem.eql(u8, from_lastname, ".") or std.mem.eql(u8, from_lastname, "..")) return 2;
    const from_blockindex = blockindex;
    const from_type_dir: u8 = if (from_name[from_name.len - 1] == '/') 1 else 0;

    if (to_path[0] == '/') {
        blockindex = 1;
        start = 1;
    } else {
        blockindex = util.currentPwdBlockindex(self);
        start = 0;
    }
    slen = 0;
    i = start;
    while (i < to_path.len) : (i += 1) {
        if (to_path[i] == '/') {
            if (slen == 0) continue;
            const index = block_mod.findPathBlockindex(self, blockindex, s[0..slen]);
            if (index < 1) return 3;
            blockindex = index;
            slen = 0;
            continue;
        }
        s[slen] = to_path[i];
        slen += 1;
        if (slen > types.BlockNameMaxSize) return 3;
    }
    if (slen > 0) {
        const index = block_mod.findPathBlockindex(self, blockindex, s[0..slen]);
        if (index < 1) return 3;
        blockindex = index;
    }

    return rename_mod.doRename(self, from_lastname, from_blockindex, from_type_dir, from_lastname, blockindex, from_type_dir);
}
