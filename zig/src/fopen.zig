const types = @import("types.zig");
const util = @import("util.zig");
const block_mod = @import("block.zig");
const helpers = @import("fopen_helpers.zig");
const std = @import("std");

pub fn fopen(self: anytype, filename: []const u8, mode: []const u8) ?*types.File {
    if (self.fp == null) {
        return null;
    }
    if (filename.len == 0 or mode.len == 0) {
        return null;
    }

    const bmode: u8 = if (std.mem.eql(u8, mode, "r"))
        0
    else if (std.mem.eql(u8, mode, "w"))
        1
    else if (std.mem.eql(u8, mode, "a"))
        2
    else if (std.mem.eql(u8, mode, "r+"))
        3
    else if (std.mem.eql(u8, mode, "w+"))
        4
    else if (std.mem.eql(u8, mode, "a+"))
        5
    else
        return null;

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
            if (slen == 0) {
                continue;
            }
            const index = block_mod.findPathBlockindex(self, blockindex, s[0..slen]);
            if (index < 1) {
                return null;
            }
            blockindex = index;
            slen = 0;
            continue;
        }
        s[slen] = filename[i];
        slen += 1;
        if (slen > types.BlockNameMaxSize) {
            return null;
        }
    }
    if (slen == 0) {
        return null;
    }
    const lastname = s[0..slen];
    if (std.mem.eql(u8, lastname, ".") or std.mem.eql(u8, lastname, "..")) {
        return null;
    }

    return switch (bmode) {
        0, 3 => helpers.doFopenR(self, lastname, bmode, blockindex),
        1, 4 => helpers.doFopenW(self, lastname, bmode, blockindex),
        2, 5 => helpers.doFopenA(self, lastname, bmode, blockindex),
        else => null,
    };
}
