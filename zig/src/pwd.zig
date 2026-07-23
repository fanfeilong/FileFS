const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const block_mod = @import("block.zig");

pub fn chdir(self: anytype, pathname: []const u8) bool {
    if (self.fp == null) {
        return false;
    }
    var blockindex: u32 = undefined;
    var start: usize = undefined;
    if (pathname.len > 0 and pathname[0] == '/') {
        blockindex = 1;
        start = 1;
        if (!util.initPwdTmp(self, "/")) return false;
    } else {
        blockindex = util.currentPwdBlockindex(self);
        if (!util.initPwdTmp(self, util.currentPwd(self))) return false;
        start = 0;
    }

    var s: [types.BlockNameMaxSize + 2]u8 = [_]u8{0} ** (types.BlockNameMaxSize + 2);
    var slen: usize = 0;
    var i: usize = start;
    while (i < pathname.len) : (i += 1) {
        if (pathname[i] == '/') {
            if (slen == 0) continue;
            const index = block_mod.findPathBlockindex(self, blockindex, s[0..slen]);
            if (index < 1) return false;
            blockindex = index;
            if (!util.addToPwdTmp(self, s[0..slen])) return false;
            slen = 0;
            continue;
        }
        s[slen] = pathname[i];
        slen += 1;
        if (slen > types.BlockNameMaxSize) return false;
    }
    if (slen > 0) {
        const index = block_mod.findPathBlockindex(self, blockindex, s[0..slen]);
        if (index < 1) return false;
        blockindex = index;
        if (!util.addToPwdTmp(self, s[0..slen])) return false;
    }

    if (self.tmp.state == 0) {
        if (!util.bufferSet(self.pwd[0..], &self.pwd_len, self.pwd_tmp[0..self.pwd_tmp_len])) return false;
        self.pwd_blockindex = blockindex;
    } else {
        if (!util.bufferSet(self.tmp.pwd[0..], &self.tmp.pwd_len, self.pwd_tmp[0..self.pwd_tmp_len])) return false;
        self.tmp.pwd_blockindex = blockindex;
    }
    return true;
}

pub fn getcwd(self: anytype) []const u8 {
    if (self.tmp.state == 0) {
        return self.pwd[0..self.pwd_len];
    }
    return self.tmp.pwd[0..self.tmp.pwd_len];
}
