const types = @import("types.zig");
const util = @import("util.zig");
const txn = @import("txn.zig");
const block_mod = @import("block.zig");

pub fn fread(self: anytype, ptr: []u8, size: usize, nmemb: usize, stream: *types.File) usize {
    if (self.fp == null) return 0;
    if (stream.mode == 1 or stream.mode == 2) return 0;
    if (stream.pos_blockindex == 0) return 0;

    const want_size = size * nmemb;
    var k: usize = 0;
    var block = util.blockZero();
    var blockindex = stream.pos_blockindex;
    var b4: [4]u8 = undefined;

    while (true) {
        if (!block_mod.readblock(self, blockindex, block[0..])) {
            return 0;
        }
        @memcpy(b4[0..], block[4..8]);
        const nextindex = util.b4ToU32(b4[0..]);

        if (stream.pos_offset == types.BlockSize) {
            stream.pos_blockindex = blockindex;
            stream.pos_offset = types.BlockHead;
        }

        if (blockindex == stream.file_stop_blockindex) {
            var n: usize = @max(0, util.u16ToUsize(stream.file_offset) - util.u16ToUsize(stream.pos_offset));
            if (n == 0) {
                return k;
            }
            if (want_size - k < n) {
                n = want_size - k;
            }
            @memcpy(ptr[k .. k + n], block[stream.pos_offset .. util.u16ToUsize(stream.pos_offset) + n]);
            k += n;
            stream.pos_blockindex = blockindex;
            stream.pos_offset += util.usizeToU16(n);
            stream.pos += n;
            return k;
        }

        var n = types.BlockSize - util.u16ToUsize(stream.pos_offset);
        if (n == 0) {
            return k;
        }
        if (want_size - k < n) {
            n = want_size - k;
        }
        @memcpy(ptr[k .. k + n], block[stream.pos_offset .. util.u16ToUsize(stream.pos_offset) + n]);
        k += n;
        stream.pos_blockindex = blockindex;
        stream.pos_offset += util.usizeToU16(n);
        stream.pos += n;
        if (k >= want_size) {
            return k;
        }

        blockindex = nextindex;
        if (nextindex == 0) {
            return k;
        }
    }
}

pub fn fwrite(self: anytype, ptr: []const u8, size: usize, nmemb: usize, stream: *types.File) usize {
    if (self.fp == null) return 0;
    if (stream.mode == 0) return 0;

    const want_size = size * nmemb;
    if (want_size == 0) return 0;

    const auto_started = self.tmp.state == 0;
    if (auto_started and !txn.tmpstart(self, 1)) {
        return 0;
    }

    var cut: usize = 0;
    var new_block = util.blockZero();
    var pos_block = util.blockZero();
    var dir_block = util.blockZero();
    var b4: [4]u8 = undefined;
    var b2: [2]u8 = undefined;
    var next_blockindex: u32 = 0;

    if (stream.pos_blockindex == 0) {
        const new_blockindex = block_mod.genblockindex(self);
        if (new_blockindex == 0) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 0;
        }
        if (!block_mod.writeblock(self, new_blockindex, pos_block[0..])) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 0;
        }
        if (!block_mod.readblock(self, stream.dir_blockindex, dir_block[0..])) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 0;
        }
        util.u32ToB4(new_blockindex, &b4);
        @memcpy(dir_block[stream.dir_offset - 10 .. stream.dir_offset - 6], b4[0..]);
        @memcpy(dir_block[stream.dir_offset - 6 .. stream.dir_offset - 2], b4[0..]);
        const off: u16 = types.BlockHead;
        util.u16ToB2(off, &b2);
        @memcpy(dir_block[stream.dir_offset - 2 .. stream.dir_offset], b2[0..]);
        stream.file_start_blockindex = new_blockindex;
        stream.file_stop_blockindex = new_blockindex;
        stream.file_offset = 0;
        stream.pos_blockindex = new_blockindex;
        stream.pos_offset = types.BlockHead;
        stream.pos = 0;
        if (!block_mod.writeblock(self, stream.dir_blockindex, dir_block[0..])) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 0;
        }
        next_blockindex = 0;
    } else {
        if (!block_mod.readblock(self, stream.pos_blockindex, pos_block[0..])) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 0;
        }
        @memcpy(b4[0..], pos_block[4..8]);
        next_blockindex = util.b4ToU32(b4[0..]);
    }

    while (true) {
        if (stream.pos_offset == types.BlockSize) {
            if (next_blockindex == 0) {
                const new_blockindex = block_mod.genblockindex(self);
                if (new_blockindex == 0) {
                    if (self.tmp.state == 1) txn.tmpstop(self);
                    return 0;
                }
                new_block = util.blockZero();
                util.u32ToB4(stream.pos_blockindex, &b4);
                @memcpy(new_block[8..12], b4[0..]);
                util.u32ToB4(new_blockindex, &b4);
                @memcpy(pos_block[4..8], b4[0..]);
                if (!block_mod.writeblock(self, stream.pos_blockindex, pos_block[0..])) {
                    if (self.tmp.state == 1) txn.tmpstop(self);
                    return 0;
                }
                stream.pos_blockindex = new_blockindex;
                stream.pos_offset = types.BlockHead;
                @memcpy(pos_block[0..], new_block[0..]);
                next_blockindex = 0;
            } else {
                if (!block_mod.readblock(self, next_blockindex, pos_block[0..])) {
                    if (self.tmp.state == 1) txn.tmpstop(self);
                    return 0;
                }
                @memcpy(b4[0..], pos_block[4..8]);
                next_blockindex = util.b4ToU32(b4[0..]);
                stream.pos_blockindex = next_blockindex;
                stream.pos_offset = types.BlockHead;
            }
        }

        const avail = types.BlockSize - util.u16ToUsize(stream.pos_offset);
        if (want_size - cut <= avail) {
            const n = want_size - cut;
            @memcpy(pos_block[stream.pos_offset .. util.u16ToUsize(stream.pos_offset) + n], ptr[cut .. cut + n]);
            cut += n;
            if (!block_mod.writeblock(self, stream.pos_blockindex, pos_block[0..])) {
                if (self.tmp.state == 1) txn.tmpstop(self);
                return 0;
            }
            stream.pos_offset += util.usizeToU16(n);
            stream.pos += n;

            var update_size = false;
            if (stream.pos_blockindex > stream.file_stop_blockindex) {
                update_size = true;
            } else if (stream.pos_blockindex == stream.file_stop_blockindex and stream.pos_offset > stream.file_offset) {
                update_size = true;
            }
            if (update_size) {
                if (!block_mod.readblock(self, stream.dir_blockindex, dir_block[0..])) {
                    if (self.tmp.state == 1) txn.tmpstop(self);
                    return 0;
                }
                stream.file_stop_blockindex = stream.pos_blockindex;
                stream.file_offset = stream.pos_offset;
                util.u32ToB4(stream.pos_blockindex, &b4);
                @memcpy(dir_block[stream.dir_offset - 6 .. stream.dir_offset - 2], b4[0..]);
                util.u16ToB2(stream.pos_offset, &b2);
                @memcpy(dir_block[stream.dir_offset - 2 .. stream.dir_offset], b2[0..]);
                if (!block_mod.writeblock(self, stream.dir_blockindex, dir_block[0..])) {
                    if (self.tmp.state == 1) txn.tmpstop(self);
                    return 0;
                }
            }
            if (self.tmp.state == 1 and !txn.commit(self)) {
                return 0;
            }
            return want_size;
        }

        const n = avail;
        @memcpy(pos_block[stream.pos_offset .. util.u16ToUsize(stream.pos_offset) + n], ptr[cut .. cut + n]);
        cut += n;
        if (!block_mod.writeblock(self, stream.pos_blockindex, pos_block[0..])) {
            if (self.tmp.state == 1) txn.tmpstop(self);
            return 0;
        }
        stream.pos_offset += util.usizeToU16(n);
        stream.pos += n;

        if (want_size - cut == 0) {
            var update_size = false;
            if (stream.pos_blockindex > stream.file_stop_blockindex) {
                update_size = true;
            } else if (stream.pos_blockindex == stream.file_stop_blockindex and stream.pos_offset > stream.file_offset) {
                update_size = true;
            }
            if (update_size) {
                if (!block_mod.readblock(self, stream.dir_blockindex, dir_block[0..])) {
                    if (self.tmp.state == 1) txn.tmpstop(self);
                    return 0;
                }
                stream.file_stop_blockindex = stream.pos_blockindex;
                stream.file_offset = stream.pos_offset;
                util.u32ToB4(stream.pos_blockindex, &b4);
                @memcpy(dir_block[stream.dir_offset - 6 .. stream.dir_offset - 2], b4[0..]);
                util.u16ToB2(stream.pos_offset, &b2);
                @memcpy(dir_block[stream.dir_offset - 2 .. stream.dir_offset], b2[0..]);
                if (!block_mod.writeblock(self, stream.dir_blockindex, dir_block[0..])) {
                    if (self.tmp.state == 1) txn.tmpstop(self);
                    return 0;
                }
            }
            if (self.tmp.state == 1 and !txn.commit(self)) {
                return 0;
            }
            return want_size;
        }
    }
}

pub fn fclose(self: anytype, stream: *types.File) void {
    self.allocator.destroy(stream);
}
