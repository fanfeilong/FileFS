const util = @import("util.zig");
const types = @import("types.zig");

pub fn j2ffs(self: anytype) void {
    const main = self.fp orelse return;
    const fpj = std.Io.Dir.cwd().openFile(self.io, self.journal[0..self.journal_len], .{}) catch return;
    defer {
        fpj.close(self.io);
        util.deleteFileIfExists(self.io, self.journal[0..self.journal_len]);
    }

    var state: [1]u8 = undefined;
    util.readExactAt(self.io, fpj, 0, state[0..]) catch return;
    if (state[0] != 0xff) {
        return;
    }

    var index_block: [4 + types.BlockSize]u8 = [_]u8{0} ** (4 + types.BlockSize);
    var pos: u64 = 1;
    while (true) {
        util.readExactAt(self.io, fpj, pos, index_block[0..]) catch break;
        const index = util.b4ToU32(index_block[0..4]);
        util.writeAllAt(self.io, main, @as(u64, index) * @as(u64, types.BlockSize), index_block[4..]) catch break;
        pos += index_block.len;
    }
    util.fflush(self.io, main);
}

const std = @import("std");
