const types = @import("types.zig");
const util = @import("util.zig");
const block_mod = @import("block.zig");

pub fn fseek(self: anytype, stream: *types.File, offset: i64, whence: i32) bool {
    if (self.fp == null) return false;
    if (stream.pos_blockindex == 0) return false;

    var block = util.blockZero();
    var b4: [4]u8 = undefined;

    if (whence == types.SeekCur) {
        if (offset == 0) return true;
        if (offset > 0) {
            var blockindex = stream.pos_blockindex;
            var new_offset = offset;
            var pos_offset = stream.pos_offset;
            while (true) {
                const blocksize: u16 = if (blockindex == stream.file_stop_blockindex) stream.file_offset else types.BlockSize;
                if (blockindex == stream.file_stop_blockindex) {
                    if (@as(i64, blocksize) - @as(i64, pos_offset) >= new_offset) {
                        stream.pos_offset += @intCast(new_offset);
                        stream.pos += @intCast(new_offset);
                    } else {
                        stream.pos_offset += blocksize - pos_offset;
                        stream.pos += blocksize - pos_offset;
                    }
                    return true;
                }
                stream.pos_offset = types.BlockSize;
                stream.pos += types.BlockSize - pos_offset;
                new_offset -= @as(i64, @intCast(types.BlockSize - pos_offset));
                pos_offset = types.BlockHead;

                if (!block_mod.readblock(self, blockindex, block[0..])) return true;
                @memcpy(b4[0..], block[8..12]);
                const next_blockindex = util.b4ToU32(b4[0..]);
                if (next_blockindex == 0) return true;
                blockindex = next_blockindex;
                stream.pos_blockindex = blockindex;
            }
        }

        var blockindex = stream.pos_blockindex;
        var new_offset = -offset;
        var pos_offset = stream.pos_offset;
        while (true) {
            if (@as(i64, pos_offset) - @as(i64, types.BlockHead) >= new_offset) {
                stream.pos_offset -= @intCast(new_offset);
                stream.pos -= @intCast(new_offset);
                return true;
            }
            stream.pos_offset -= pos_offset;
            stream.pos -= pos_offset;
            new_offset -= @as(i64, pos_offset);
            pos_offset = types.BlockSize;

            if (!block_mod.readblock(self, blockindex, block[0..])) return true;
            @memcpy(b4[0..], block[4..8]);
            const prev_blockindex = util.b4ToU32(b4[0..]);
            if (prev_blockindex == 0) return true;
            blockindex = prev_blockindex;
            stream.pos_blockindex = blockindex;
        }
    }

    if (whence == types.SeekEnd) {
        var pos = stream.pos - (stream.pos_offset - types.BlockHead);
        var index = stream.pos_blockindex;
        while (true) {
            if (index == stream.file_stop_blockindex) {
                pos += stream.file_offset - types.BlockHead;
                break;
            }
            if (!block_mod.readblock(self, index, block[0..])) return false;
            pos += types.BlockSize - types.BlockHead;
            @memcpy(b4[0..], block[4..8]);
            index = util.b4ToU32(b4[0..]);
        }
        stream.pos_blockindex = stream.file_stop_blockindex;
        stream.pos_offset = stream.file_offset;
        stream.pos = pos;

        if (offset == 0) return true;
        if (offset < 0) {
            var blockindex = stream.pos_blockindex;
            var new_offset = -offset;
            var pos_offset = stream.pos_offset;
            while (true) {
                if (@as(i64, pos_offset) - @as(i64, types.BlockHead) >= new_offset) {
                    stream.pos_offset -= @intCast(new_offset);
                    stream.pos -= @intCast(new_offset);
                    return true;
                }
                stream.pos_offset -= pos_offset;
                stream.pos -= pos_offset;
                new_offset -= @as(i64, pos_offset);
                pos_offset = types.BlockSize;

                if (!block_mod.readblock(self, blockindex, block[0..])) return true;
                @memcpy(b4[0..], block[4..8]);
                const prev_blockindex = util.b4ToU32(b4[0..]);
                if (prev_blockindex == 0) return true;
                blockindex = prev_blockindex;
                stream.pos_blockindex = blockindex;
            }
        }
        return false;
    }

    if (whence == types.SeekSet) {
        stream.pos_blockindex = stream.file_start_blockindex;
        stream.pos_offset = types.BlockHead;
        stream.pos = 0;
        if (offset == 0) return true;
        if (offset > 0) {
            var blockindex = stream.pos_blockindex;
            var new_offset = offset;
            var pos_offset = stream.pos_offset;
            while (true) {
                const blocksize: u16 = if (blockindex == stream.file_stop_blockindex) stream.file_offset else types.BlockSize;
                if (blockindex == stream.file_stop_blockindex) {
                    if (@as(i64, blocksize) - @as(i64, pos_offset) >= new_offset) {
                        stream.pos_offset += @intCast(new_offset);
                        stream.pos += @intCast(new_offset);
                    } else {
                        stream.pos_offset += blocksize - pos_offset;
                        stream.pos += blocksize - pos_offset;
                    }
                    return true;
                }
                stream.pos_offset = types.BlockSize;
                stream.pos += types.BlockSize - pos_offset;
                new_offset -= @as(i64, @intCast(types.BlockSize - pos_offset));
                pos_offset = types.BlockHead;

                if (!block_mod.readblock(self, blockindex, block[0..])) return true;
                @memcpy(b4[0..], block[8..12]);
                const next_blockindex = util.b4ToU32(b4[0..]);
                if (next_blockindex == 0) return true;
                blockindex = next_blockindex;
                stream.pos_blockindex = blockindex;
            }
        }
        return false;
    }

    return false;
}

pub fn ftell(self: anytype, stream: *types.File) u64 {
    _ = self;
    return stream.pos;
}

pub fn rewind(self: anytype, stream: *types.File) void {
    _ = fseek(self, stream, 0, types.SeekSet);
}
