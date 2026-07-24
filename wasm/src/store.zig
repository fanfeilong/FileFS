const std = @import("std");

pub const BlockSize: usize = 512;
pub const BlockItemMaxCount: usize = 20;
pub const BlockHead: usize = 12;
pub const BlockNameMaxSize: usize = 14;
pub const BlockStopBlockIndex: usize = 31;
pub const BlockOffset: usize = 35;
pub const DirectoryEntrySize: usize = 25;
pub const DirectoryBaseOffset: u16 = BlockHead + DirectoryEntrySize * 2;
pub const MagicNumber = [4]u8{ 0x78, 0x11, 0x45, 0x14 };
pub const FilePayloadSize: usize = BlockSize - BlockHead;

fn Vec(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        ptr: ?[*]T = null,
        len: usize = 0,
        capacity: usize = 0,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            if (self.capacity > 0) {
                self.allocator.free(self.ptr.?[0..self.capacity]);
            }
            self.ptr = null;
            self.len = 0;
            self.capacity = 0;
        }

        pub fn items(self: *const Self) []const T {
            if (self.len == 0) {
                return &[_]T{};
            }
            return self.ptr.?[0..self.len];
        }

        pub fn sliceMut(self: *Self) []T {
            if (self.len == 0) {
                return @constCast((&[_]T{})[0..]);
            }
            return self.ptr.?[0..self.len];
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.len = 0;
        }

        pub fn ensureCapacity(self: *Self, needed: usize) !void {
            if (needed <= self.capacity) {
                return;
            }

            var new_capacity: usize = if (self.capacity == 0) 4 else self.capacity;
            while (new_capacity < needed) {
                new_capacity *= 2;
            }

            const new_slice = try self.allocator.alloc(T, new_capacity);
            if (self.len > 0) {
                @memcpy(new_slice[0..self.len], self.ptr.?[0..self.len]);
            }
            if (self.capacity > 0) {
                self.allocator.free(self.ptr.?[0..self.capacity]);
            }
            self.ptr = new_slice.ptr;
            self.capacity = new_capacity;
        }

        pub fn resize(self: *Self, new_len: usize, fill: T) !void {
            const old_len = self.len;
            try self.ensureCapacity(new_len);
            if (new_len > old_len) {
                for (self.ptr.?[old_len..new_len]) |*item| {
                    item.* = fill;
                }
            }
            self.len = new_len;
        }

        pub fn append(self: *Self, item: T) !void {
            try self.ensureCapacity(self.len + 1);
            self.ptr.?[self.len] = item;
            self.len += 1;
        }

        pub fn appendSlice(self: *Self, values: []const T) !void {
            if (values.len == 0) {
                return;
            }
            try self.ensureCapacity(self.len + values.len);
            @memcpy(self.ptr.?[self.len .. self.len + values.len], values);
            self.len += values.len;
        }

        pub fn clone(self: *const Self) !Self {
            var out = Self.init(self.allocator);
            errdefer out.deinit();
            try out.appendSlice(self.items());
            return out;
        }
    };
}

pub const ByteBuffer = Vec(u8);
const U32Buffer = Vec(u32);
const EntryBuffer = Vec(DirEntry);
const SegmentBuffer = Vec(Segment);

pub const Error = error{
    InvalidImage,
    NotMounted,
    InvalidPath,
    NameTooLong,
    PathNotFound,
    NotDirectory,
    NotFile,
    AlreadyExists,
    DirectoryNotEmpty,
};

const Segment = struct {
    bytes: [BlockNameMaxSize]u8 = [_]u8{0} ** BlockNameMaxSize,
    len: usize = 0,

    fn init(name: []const u8) !Segment {
        if (name.len == 0 or name.len > BlockNameMaxSize) {
            return error.NameTooLong;
        }
        var segment = Segment{};
        segment.len = name.len;
        @memcpy(segment.bytes[0..name.len], name);
        return segment;
    }

    fn slice(self: *const Segment) []const u8 {
        return self.bytes[0..self.len];
    }
};

const ParsedPath = struct {
    absolute: bool,
    trailing_slash: bool,
    segments: SegmentBuffer,

    fn init(allocator: std.mem.Allocator) ParsedPath {
        return .{
            .absolute = false,
            .trailing_slash = false,
            .segments = SegmentBuffer.init(allocator),
        };
    }

    fn deinit(self: *ParsedPath) void {
        self.segments.deinit();
    }
};

const DirEntry = struct {
    is_file: bool = false,
    name: [BlockNameMaxSize]u8 = [_]u8{0} ** BlockNameMaxSize,
    name_len: usize = 0,
    start_block_index: u32 = 0,
    stop_block_index: u32 = 0,
    file_offset: u16 = 0,

    fn init(is_file: bool, name: []const u8, start_block_index: u32, stop_block_index: u32, file_offset: u16) !DirEntry {
        if (name.len > BlockNameMaxSize) {
            return error.NameTooLong;
        }
        var entry = DirEntry{
            .is_file = is_file,
            .name_len = name.len,
            .start_block_index = start_block_index,
            .stop_block_index = stop_block_index,
            .file_offset = file_offset,
        };
        if (name.len > 0) {
            @memcpy(entry.name[0..name.len], name);
        }
        return entry;
    }

    fn nameSlice(self: *const DirEntry) []const u8 {
        return self.name[0..self.name_len];
    }

    fn setName(self: *DirEntry, name: []const u8) !void {
        if (name.len > BlockNameMaxSize) {
            return error.NameTooLong;
        }
        @memset(self.name[0..], 0);
        self.name_len = name.len;
        if (name.len > 0) {
            @memcpy(self.name[0..name.len], name);
        }
    }

    fn eqlName(self: *const DirEntry, name: []const u8) bool {
        return std.mem.eql(u8, self.nameSlice(), name);
    }

    fn fromBlock(block: []const u8, offset: usize) DirEntry {
        var entry = DirEntry{};
        entry.is_file = (block[offset] & 0x01) == 0x01;
        entry.name_len = fixedNameLen(block[offset + 1 .. offset + 1 + BlockNameMaxSize]);
        if (entry.name_len > 0) {
            @memcpy(entry.name[0..entry.name_len], block[offset + 1 .. offset + 1 + entry.name_len]);
        }
        entry.start_block_index = readU32(block, offset + 1 + BlockNameMaxSize);
        entry.stop_block_index = readU32(block, offset + 1 + BlockNameMaxSize + 4);
        entry.file_offset = readU16(block, offset + 1 + BlockNameMaxSize + 8);
        return entry;
    }

    fn writeToBlock(self: *const DirEntry, block: []u8, offset: usize) void {
        block[offset] = if (self.is_file) 1 else 0;
        @memset(block[offset + 1 .. offset + 1 + BlockNameMaxSize], 0);
        if (self.name_len > 0) {
            @memcpy(block[offset + 1 .. offset + 1 + self.name_len], self.name[0..self.name_len]);
        }
        writeU32(block, offset + 1 + BlockNameMaxSize, self.start_block_index);
        writeU32(block, offset + 1 + BlockNameMaxSize + 4, self.stop_block_index);
        writeU16(block, offset + 1 + BlockNameMaxSize + 8, self.file_offset);
    }
};

const DirectoryInfo = struct {
    entries: EntryBuffer,
    chain_indices: U32Buffer,
    stop_block_index: u32,
    offset: u16,

    fn init(allocator: std.mem.Allocator) DirectoryInfo {
        return .{
            .entries = EntryBuffer.init(allocator),
            .chain_indices = U32Buffer.init(allocator),
            .stop_block_index = 0,
            .offset = 0,
        };
    }

    fn deinit(self: *DirectoryInfo) void {
        self.entries.deinit();
        self.chain_indices.deinit();
    }
};

const DirectoryLocation = struct {
    block_index: u32,
    item_end_offset: u16,
    entry: DirEntry,
};

const ResolvedDirectory = struct {
    block_index: u32,
    absolute_path: ByteBuffer,

    fn init(allocator: std.mem.Allocator) ResolvedDirectory {
        return .{
            .block_index = 0,
            .absolute_path = ByteBuffer.init(allocator),
        };
    }

    fn deinit(self: *ResolvedDirectory) void {
        self.absolute_path.deinit();
    }
};

const ResolvedParent = struct {
    parent_block_index: u32,
    last_name: Segment,
    has_last_name: bool,
    trailing_slash: bool,
};

const Transaction = struct {
    image: ByteBuffer,
    pwd: ByteBuffer,
    pwd_block_index: u32,
    mounted: bool,

    fn deinit(self: *Transaction) void {
        self.image.deinit();
        self.pwd.deinit();
    }
};

pub const FileSystem = struct {
    allocator: std.mem.Allocator,
    image: ByteBuffer,
    mounted: bool = false,
    pwd: ByteBuffer,
    pwd_block_index: u32 = 0,
    tx: ?Transaction = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .image = ByteBuffer.init(allocator),
            .pwd = ByteBuffer.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.rollback();
        self.image.deinit();
        self.pwd.deinit();
    }

    pub fn mkfs(self: *Self) !void {
        var super_block = [_]u8{0} ** BlockSize;
        @memcpy(super_block[0..4], MagicNumber[0..]);
        writeU32(super_block[0..], 4, 2);

        var root_block = [_]u8{0} ** BlockSize;
        var k: usize = BlockHead;
        root_block[k] = 0;
        k += 1;
        root_block[k] = '.';
        k += BlockNameMaxSize;
        writeU32(root_block[0..], k, 1);
        k += 4;
        writeU32(root_block[0..], k, 1);
        k += 4;
        writeU16(root_block[0..], k, DirectoryBaseOffset);
        k += 2;
        root_block[k] = 0;
        k += 1;
        root_block[k] = '.';
        root_block[k + 1] = '.';

        var image = self.imageBuffer();
        try image.resize(BlockSize * 2, 0);
        const bytes = image.sliceMut();
        @memset(bytes, 0);
        @memcpy(bytes[0..BlockSize], super_block[0..]);
        @memcpy(bytes[BlockSize .. BlockSize * 2], root_block[0..]);

        self.setMounted(false);
        self.currentPwd().clearRetainingCapacity();
        self.setPwdBlockIndex(0);
    }

    pub fn mount(self: *Self) !void {
        const image = self.imageSlice();
        if (image.len < BlockSize * 2) {
            return Error.InvalidImage;
        }
        if (!std.mem.eql(u8, image[0..4], MagicNumber[0..])) {
            return Error.InvalidImage;
        }
        if (readU32(image, 4) < 2) {
            return Error.InvalidImage;
        }

        var root_block = [_]u8{0} ** BlockSize;
        if (!self.readBlock(1, &root_block)) {
            return Error.InvalidImage;
        }

        if (root_block[BlockHead] != 0) {
            return Error.InvalidImage;
        }
        if (!fixedNameEquals(root_block[BlockHead + 1 .. BlockHead + 1 + BlockNameMaxSize], ".")) {
            return Error.InvalidImage;
        }
        const dotdot_offset = BlockHead + DirectoryEntrySize;
        if (root_block[dotdot_offset] != 0) {
            return Error.InvalidImage;
        }
        if (!fixedNameEquals(root_block[dotdot_offset + 1 .. dotdot_offset + 1 + BlockNameMaxSize], "..")) {
            return Error.InvalidImage;
        }

        self.setMounted(true);
        try self.currentPwdSet("/");
        self.setPwdBlockIndex(1);
    }

    pub fn getcwd(self: *Self, out: *ByteBuffer) !void {
        try self.ensureMounted();
        out.clearRetainingCapacity();
        try out.appendSlice(self.currentPwd().items());
    }

    pub fn chdir(self: *Self, dir_path: []const u8) !void {
        try self.ensureMounted();
        var resolved = try self.resolveDirectoryPath(dir_path);
        defer resolved.deinit();
        try self.currentPwdSet(resolved.absolute_path.items());
        self.setPwdBlockIndex(resolved.block_index);
    }

    pub fn mkdir(self: *Self, dir_path: []const u8) !void {
        try self.ensureMounted();
        const parent = try self.resolveParentPath(dir_path);
        if (!parent.has_last_name) {
            return Error.InvalidPath;
        }
        const name = parent.last_name.slice();
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
            return Error.InvalidPath;
        }

        var parent_info = try self.readDirectoryEntries(parent.parent_block_index);
        defer parent_info.deinit();
        if (findEntryIndex(parent_info.entries.items(), name) != null) {
            return Error.AlreadyExists;
        }

        const child_block_index = try self.allocBlock();
        var child_entries = [_]DirEntry{
            try DirEntry.init(false, ".", child_block_index, child_block_index, DirectoryBaseOffset),
            try DirEntry.init(false, "..", parent.parent_block_index, 0, 0),
        };
        const child_chain = [_]u32{child_block_index};
        try self.rewriteDirectory(child_block_index, child_entries[0..], child_chain[0..]);

        try parent_info.entries.append(try DirEntry.init(false, name, child_block_index, 0, 0));
        try self.rewriteDirectory(parent.parent_block_index, parent_info.entries.items(), parent_info.chain_indices.items());
    }

    pub fn writeFile(self: *Self, file_path: []const u8, data: []const u8) !void {
        try self.ensureMounted();
        const parent = try self.resolveParentPath(file_path);
        if (!parent.has_last_name or parent.trailing_slash) {
            return Error.InvalidPath;
        }
        const name = parent.last_name.slice();
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
            return Error.InvalidPath;
        }

        var parent_info = try self.readDirectoryEntries(parent.parent_block_index);
        defer parent_info.deinit();

        const existing_index = findEntryIndex(parent_info.entries.items(), name);
        var entry: DirEntry = undefined;
        if (existing_index) |idx| {
            entry = parent_info.entries.sliceMut()[idx];
            if (!entry.is_file) {
                return Error.NotFile;
            }
            if (entry.start_block_index > 0) {
                try self.freeChain(entry.start_block_index, entry.stop_block_index);
            }
        } else {
            entry = try DirEntry.init(true, name, 0, 0, 0);
        }

        if (data.len == 0) {
            entry.start_block_index = 0;
            entry.stop_block_index = 0;
            entry.file_offset = 0;
        } else {
            const required_blocks = (data.len + FilePayloadSize - 1) / FilePayloadSize;
            var chain = U32Buffer.init(self.allocator);
            defer chain.deinit();
            for (0..required_blocks) |_| {
                try chain.append(try self.allocBlock());
            }

            for (chain.items(), 0..) |block_index, i| {
                var block = [_]u8{0} ** BlockSize;
                const next_index = if (i + 1 < chain.len) chain.items()[i + 1] else 0;
                const prev_index = if (i > 0) chain.items()[i - 1] else 0;
                writeU32(block[0..], 4, next_index);
                writeU32(block[0..], 8, prev_index);

                const start = i * FilePayloadSize;
                const end = @min(start + FilePayloadSize, data.len);
                const chunk = data[start..end];
                @memcpy(block[BlockHead .. BlockHead + chunk.len], chunk);
                if (!self.writeBlock(block_index, &block)) {
                    return Error.InvalidImage;
                }
            }

            entry.start_block_index = chain.items()[0];
            entry.stop_block_index = chain.items()[chain.len - 1];
            const last_size = data.len - (required_blocks - 1) * FilePayloadSize;
            entry.file_offset = @intCast(BlockHead + last_size);
        }

        if (existing_index) |idx| {
            parent_info.entries.sliceMut()[idx] = entry;
        } else {
            try parent_info.entries.append(entry);
        }
        try self.rewriteDirectory(parent.parent_block_index, parent_info.entries.items(), parent_info.chain_indices.items());
    }

    pub fn readFile(self: *Self, file_path: []const u8, out: *ByteBuffer) !void {
        try self.ensureMounted();
        const location = try self.requireFileLocation(file_path);
        out.clearRetainingCapacity();
        if (location.entry.start_block_index == 0) {
            return;
        }

        const total_len = self.getFileLength(
            location.entry.start_block_index,
            location.entry.stop_block_index,
            location.entry.file_offset,
        );
        try out.resize(total_len, 0);

        var written: usize = 0;
        var block_index = location.entry.start_block_index;
        while (block_index != 0) {
            var block = [_]u8{0} ** BlockSize;
            if (!self.readBlock(block_index, &block)) {
                return Error.InvalidImage;
            }
            const next_index = readU32(block[0..], 4);
            const end_offset: usize = if (block_index == location.entry.stop_block_index) location.entry.file_offset else BlockSize;
            const chunk = block[BlockHead..end_offset];
            @memcpy(out.sliceMut()[written .. written + chunk.len], chunk);
            written += chunk.len;
            if (block_index == location.entry.stop_block_index) {
                break;
            }
            block_index = next_index;
        }
    }

    pub fn copyFile(self: *Self, from_path: []const u8, to_path: []const u8) !void {
        var tmp = ByteBuffer.init(self.allocator);
        defer tmp.deinit();
        try self.readFile(from_path, &tmp);
        try self.writeFile(to_path, tmp.items());
    }

    pub fn rename(self: *Self, from_path: []const u8, to_path: []const u8) !void {
        try self.ensureMounted();
        const from = try self.resolveParentPath(from_path);
        const to = try self.resolveParentPath(to_path);
        if (!from.has_last_name or std.mem.eql(u8, from.last_name.slice(), ".") or std.mem.eql(u8, from.last_name.slice(), "..")) {
            return Error.InvalidPath;
        }
        if (!to.has_last_name or std.mem.eql(u8, to.last_name.slice(), ".") or std.mem.eql(u8, to.last_name.slice(), "..")) {
            return Error.InvalidPath;
        }

        var from_info = try self.readDirectoryEntries(from.parent_block_index);
        defer from_info.deinit();
        const from_index = findEntryIndex(from_info.entries.items(), from.last_name.slice()) orelse return Error.PathNotFound;
        const from_entry = from_info.entries.items()[from_index];
        if (from.trailing_slash and from_entry.is_file) {
            return Error.NotDirectory;
        }
        if (to.trailing_slash and from_entry.is_file) {
            return Error.InvalidPath;
        }

        if (from.parent_block_index == to.parent_block_index and
            std.mem.eql(u8, from.last_name.slice(), to.last_name.slice()) and
            from.trailing_slash == to.trailing_slash)
        {
            return;
        }

        if (from.parent_block_index == to.parent_block_index) {
            if (findEntryIndex(from_info.entries.items(), to.last_name.slice()) != null) {
                return Error.AlreadyExists;
            }
            var renamed = from_info.entries.items()[from_index];
            try renamed.setName(to.last_name.slice());
            from_info.entries.sliceMut()[from_index] = renamed;
            try self.rewriteDirectory(from.parent_block_index, from_info.entries.items(), from_info.chain_indices.items());
            return;
        }

        var to_info = try self.readDirectoryEntries(to.parent_block_index);
        defer to_info.deinit();
        if (findEntryIndex(to_info.entries.items(), to.last_name.slice()) != null) {
            return Error.AlreadyExists;
        }

        var moved = from_info.entries.items()[from_index];
        try moved.setName(to.last_name.slice());
        removeEntryAt(&from_info.entries, from_index);
        try to_info.entries.append(moved);
        try self.rewriteDirectory(from.parent_block_index, from_info.entries.items(), from_info.chain_indices.items());
        try self.rewriteDirectory(to.parent_block_index, to_info.entries.items(), to_info.chain_indices.items());

        if (!moved.is_file) {
            var child_info = try self.readDirectoryEntries(moved.start_block_index);
            defer child_info.deinit();
            child_info.entries.sliceMut()[1].start_block_index = to.parent_block_index;
            try self.rewriteDirectory(moved.start_block_index, child_info.entries.items(), child_info.chain_indices.items());
        }
    }

    pub fn removeFile(self: *Self, file_path: []const u8) !void {
        try self.ensureMounted();
        const parent = try self.resolveParentPath(file_path);
        if (!parent.has_last_name or parent.trailing_slash) {
            return Error.InvalidPath;
        }
        const name = parent.last_name.slice();
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
            return Error.InvalidPath;
        }

        var parent_info = try self.readDirectoryEntries(parent.parent_block_index);
        defer parent_info.deinit();
        const index = findEntryIndex(parent_info.entries.items(), name) orelse return Error.PathNotFound;
        const entry = parent_info.entries.items()[index];
        if (!entry.is_file) {
            return Error.NotFile;
        }
        if (entry.start_block_index > 0) {
            try self.freeChain(entry.start_block_index, entry.stop_block_index);
        }
        removeEntryAt(&parent_info.entries, index);
        try self.rewriteDirectory(parent.parent_block_index, parent_info.entries.items(), parent_info.chain_indices.items());
    }

    pub fn listDir(self: *Self, dir_path: []const u8, out: *ByteBuffer) !void {
        try self.ensureMounted();
        var resolved = try self.resolveDirectoryPath(dir_path);
        defer resolved.deinit();
        var info = try self.readDirectoryEntries(resolved.block_index);
        defer info.deinit();

        out.clearRetainingCapacity();
        for (info.entries.items()) |entry| {
            const type_code: u8 = blk: {
                if (entry.is_file) break :blk '0';
                if (std.mem.eql(u8, entry.nameSlice(), ".")) {
                    if (entry.start_block_index == 1) break :blk '2';
                } else if (std.mem.eql(u8, entry.nameSlice(), "..")) {
                    if (entry.start_block_index == 0) break :blk '2';
                }
                break :blk '1';
            };
            try out.append(type_code);
            try out.append('\t');
            try out.appendSlice(entry.nameSlice());
            try out.append('\n');
        }
    }

    pub fn begin(self: *Self) !void {
        try self.ensureMounted();
        self.rollback();
        self.tx = .{
            .image = try self.image.clone(),
            .pwd = try self.pwd.clone(),
            .pwd_block_index = self.pwd_block_index,
            .mounted = self.mounted,
        };
    }

    pub fn commit(self: *Self) !void {
        if (self.tx) |*tx| {
            self.image.deinit();
            self.pwd.deinit();
            self.image = tx.image;
            self.pwd = tx.pwd;
            self.pwd_block_index = tx.pwd_block_index;
            self.mounted = tx.mounted;
            self.tx = null;
        }
    }

    pub fn rollback(self: *Self) void {
        if (self.tx) |*tx| {
            tx.deinit();
            self.tx = null;
        }
    }

    pub fn imageSlice(self: *Self) []const u8 {
        return self.imageBuffer().items();
    }

    fn ensureMounted(self: *Self) !void {
        if (!self.isMounted()) {
            return Error.NotMounted;
        }
    }

    fn isMounted(self: *Self) bool {
        if (self.tx) |*tx| {
            return tx.mounted;
        }
        return self.mounted;
    }

    fn setMounted(self: *Self, mounted: bool) void {
        if (self.tx) |*tx| {
            tx.mounted = mounted;
        } else {
            self.mounted = mounted;
        }
    }

    fn imageBuffer(self: *Self) *ByteBuffer {
        if (self.tx) |*tx| {
            return &tx.image;
        }
        return &self.image;
    }

    fn currentPwd(self: *Self) *ByteBuffer {
        if (self.tx) |*tx| {
            return &tx.pwd;
        }
        return &self.pwd;
    }

    fn currentPwdSet(self: *Self, value: []const u8) !void {
        var pwd = self.currentPwd();
        pwd.clearRetainingCapacity();
        try pwd.appendSlice(value);
    }

    fn currentPwdBlockIndex(self: *Self) u32 {
        if (self.tx) |*tx| {
            return tx.pwd_block_index;
        }
        return self.pwd_block_index;
    }

    fn setPwdBlockIndex(self: *Self, value: u32) void {
        if (self.tx) |*tx| {
            tx.pwd_block_index = value;
        } else {
            self.pwd_block_index = value;
        }
    }

    fn readBlock(self: *Self, block_index: u32, out: *[BlockSize]u8) bool {
        const image = self.imageSlice();
        const start = @as(usize, block_index) * BlockSize;
        const end = start + BlockSize;
        if (end > image.len) {
            return false;
        }
        @memcpy(out[0..], image[start..end]);
        return true;
    }

    fn writeBlock(self: *Self, block_index: u32, block: *const [BlockSize]u8) bool {
        var image = self.imageBuffer();
        const start = @as(usize, block_index) * BlockSize;
        const end = start + BlockSize;
        if (end > image.len) {
            return false;
        }
        @memcpy(image.sliceMut()[start..end], block[0..]);
        return true;
    }

    fn allocBlock(self: *Self) !u32 {
        const unused_head = readU32(self.imageSlice(), 8);
        if (unused_head > 0) {
            var free_block = [_]u8{0} ** BlockSize;
            if (!self.readBlock(unused_head, &free_block)) {
                return Error.InvalidImage;
            }
            writeU32(self.imageBuffer().sliceMut(), 8, readU32(free_block[0..], 4));
            return unused_head;
        }

        const total = readU32(self.imageSlice(), 4);
        var image = self.imageBuffer();
        try image.resize((@as(usize, total) + 1) * BlockSize, 0);
        writeU32(image.sliceMut(), 4, total + 1);
        return total;
    }

    fn freeBlock(self: *Self, block_index: u32) !void {
        var block = [_]u8{0} ** BlockSize;
        writeU32(block[0..], 4, readU32(self.imageSlice(), 8));
        if (!self.writeBlock(block_index, &block)) {
            return Error.InvalidImage;
        }
        writeU32(self.imageBuffer().sliceMut(), 8, block_index);
    }

    fn freeChain(self: *Self, start_block_index: u32, stop_block_index: u32) !void {
        if (start_block_index == 0) {
            return;
        }
        var current = start_block_index;
        while (current != 0) {
            var block = [_]u8{0} ** BlockSize;
            if (!self.readBlock(current, &block)) {
                return Error.InvalidImage;
            }
            const next = readU32(block[0..], 4);
            try self.freeBlock(current);
            if (current == stop_block_index) {
                break;
            }
            current = next;
        }
    }

    fn resolveDirectoryPath(self: *Self, dir_path: []const u8) !ResolvedDirectory {
        var parsed = try parsePath(self.allocator, dir_path);
        defer parsed.deinit();

        var result = ResolvedDirectory.init(self.allocator);
        errdefer result.deinit();
        result.block_index = if (parsed.absolute) 1 else self.currentPwdBlockIndex();
        try result.absolute_path.appendSlice(if (parsed.absolute) "/" else self.currentPwd().items());

        for (parsed.segments.items()) |segment| {
            const next_index = try self.findPathBlockIndex(result.block_index, segment.slice());
            if (next_index == 0) {
                return Error.PathNotFound;
            }
            result.block_index = next_index;
            try appendPathSegment(&result.absolute_path, segment.slice());
        }

        return result;
    }

    fn resolveParentPath(self: *Self, target_path: []const u8) !ResolvedParent {
        if (target_path.len == 0) {
            return Error.InvalidPath;
        }
        var parsed = try parsePath(self.allocator, target_path);
        defer parsed.deinit();

        var block_index: u32 = if (parsed.absolute) 1 else self.currentPwdBlockIndex();
        if (parsed.segments.len == 0) {
            return .{
                .parent_block_index = block_index,
                .last_name = Segment{},
                .has_last_name = false,
                .trailing_slash = parsed.trailing_slash,
            };
        }

        if (parsed.segments.len > 1) {
            for (parsed.segments.items()[0 .. parsed.segments.len - 1]) |segment| {
                const next_index = try self.findPathBlockIndex(block_index, segment.slice());
                if (next_index == 0) {
                    return Error.PathNotFound;
                }
                block_index = next_index;
            }
        }

        return .{
            .parent_block_index = block_index,
            .last_name = parsed.segments.items()[parsed.segments.len - 1],
            .has_last_name = true,
            .trailing_slash = parsed.trailing_slash,
        };
    }

    fn requireFileLocation(self: *Self, file_path: []const u8) !DirectoryLocation {
        const parent = try self.resolveParentPath(file_path);
        if (!parent.has_last_name or parent.trailing_slash) {
            return Error.InvalidPath;
        }
        const location = try self.findDirectoryEntryLocation(parent.parent_block_index, parent.last_name.slice()) orelse return Error.PathNotFound;
        if (!location.entry.is_file) {
            return Error.NotFile;
        }
        return location;
    }

    fn findPathBlockIndex(self: *Self, block_index: u32, name: []const u8) !u32 {
        const location = try self.findDirectoryEntryLocation(block_index, name);
        if (location == null or location.?.entry.is_file) {
            return 0;
        }
        return location.?.entry.start_block_index;
    }

    fn findDirectoryEntryLocation(self: *Self, block_index: u32, name: []const u8) !?DirectoryLocation {
        var block = [_]u8{0} ** BlockSize;
        if (!self.readBlock(block_index, &block)) {
            return Error.InvalidImage;
        }

        const stop_block_index = readU32(block[0..], BlockStopBlockIndex);
        const offset = readU16(block[0..], BlockOffset);
        var current_index = block_index;
        while (true) {
            var k: usize = BlockHead;
            var i: usize = 0;
            while (i < BlockItemMaxCount) : (i += 1) {
                const entry_name = block[k + 1 .. k + 1 + BlockNameMaxSize];
                if (fixedNameEquals(entry_name, name)) {
                    return .{
                        .block_index = current_index,
                        .item_end_offset = @intCast(k + 1 + BlockNameMaxSize + 10),
                        .entry = DirEntry.fromBlock(block[0..], k),
                    };
                }
                k += DirectoryEntrySize;
                if (current_index == stop_block_index and k + 1 >= offset) {
                    return null;
                }
            }

            current_index = readU32(block[0..], 4);
            if (current_index == 0) {
                return null;
            }
            if (!self.readBlock(current_index, &block)) {
                return Error.InvalidImage;
            }
        }
    }

    fn readDirectoryEntries(self: *Self, head_block_index: u32) !DirectoryInfo {
        var head = [_]u8{0} ** BlockSize;
        if (!self.readBlock(head_block_index, &head)) {
            return Error.InvalidImage;
        }

        var result = DirectoryInfo.init(self.allocator);
        errdefer result.deinit();
        result.stop_block_index = readU32(head[0..], BlockStopBlockIndex);
        result.offset = readU16(head[0..], BlockOffset);

        var block = head;
        var current_index = head_block_index;
        while (true) {
            try result.chain_indices.append(current_index);
            var k: usize = BlockHead;
            while (k + 1 < BlockSize) {
                if (current_index == result.stop_block_index and k + 1 >= result.offset) {
                    return result;
                }
                try result.entries.append(DirEntry.fromBlock(block[0..], k));
                k += DirectoryEntrySize;
            }

            if (current_index == result.stop_block_index) {
                return result;
            }

            current_index = readU32(block[0..], 4);
            if (current_index == 0) {
                return result;
            }
            if (!self.readBlock(current_index, &block)) {
                return Error.InvalidImage;
            }
        }
    }

    fn rewriteDirectory(self: *Self, head_block_index: u32, entries: []const DirEntry, existing_chain_indices: []const u32) !void {
        if (entries.len < 2 or !entries[0].eqlName(".") or !entries[1].eqlName("..")) {
            return Error.InvalidImage;
        }

        var cloned = EntryBuffer.init(self.allocator);
        defer cloned.deinit();
        try cloned.appendSlice(entries);

        var chain = U32Buffer.init(self.allocator);
        defer chain.deinit();
        if (existing_chain_indices.len == 0) {
            var current = try self.readDirectoryEntries(head_block_index);
            defer current.deinit();
            try chain.appendSlice(current.chain_indices.items());
        } else {
            try chain.appendSlice(existing_chain_indices);
        }

        const required_blocks = @max(@as(usize, 1), (cloned.len + BlockItemMaxCount - 1) / BlockItemMaxCount);
        while (chain.len < required_blocks) {
            try chain.append(try self.allocBlock());
        }
        if (chain.len > required_blocks) {
            for (chain.items()[required_blocks..]) |extra| {
                try self.freeBlock(extra);
            }
            chain.len = required_blocks;
        }

        const stop_block_index = chain.items()[chain.len - 1];
        const entries_in_last_block = cloned.len % BlockItemMaxCount;
        const final_offset: usize = if (entries_in_last_block == 0) BlockSize else BlockHead + entries_in_last_block * DirectoryEntrySize;

        cloned.sliceMut()[0].is_file = false;
        try cloned.sliceMut()[0].setName(".");
        cloned.sliceMut()[0].start_block_index = head_block_index;
        cloned.sliceMut()[0].stop_block_index = stop_block_index;
        cloned.sliceMut()[0].file_offset = @intCast(final_offset);
        cloned.sliceMut()[1].is_file = false;
        try cloned.sliceMut()[1].setName("..");

        for (chain.items(), 0..) |block_index, slot| {
            var block = [_]u8{0} ** BlockSize;
            const next_index = if (slot + 1 < chain.len) chain.items()[slot + 1] else 0;
            const prev_index = if (slot > 0) chain.items()[slot - 1] else 0;
            writeU32(block[0..], 4, next_index);
            writeU32(block[0..], 8, prev_index);

            const start = slot * BlockItemMaxCount;
            const end = @min(start + BlockItemMaxCount, cloned.len);
            var k: usize = BlockHead;
            for (cloned.items()[start..end]) |entry| {
                entry.writeToBlock(block[0..], k);
                k += DirectoryEntrySize;
            }
            if (!self.writeBlock(block_index, &block)) {
                return Error.InvalidImage;
            }
        }
    }

    fn getFileLength(self: *Self, start_block_index: u32, stop_block_index: u32, file_offset: u16) usize {
        if (start_block_index == 0) {
            return 0;
        }
        var length: usize = 0;
        var current = start_block_index;
        while (current != 0) {
            if (current == stop_block_index) {
                length += @as(usize, file_offset) - BlockHead;
                break;
            }
            length += FilePayloadSize;
            var block = [_]u8{0} ** BlockSize;
            if (!self.readBlock(current, &block)) {
                break;
            }
            current = readU32(block[0..], 4);
        }
        return length;
    }
};

fn readU32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value & 0xff);
    bytes[offset + 1] = @truncate((value >> 8) & 0xff);
    bytes[offset + 2] = @truncate((value >> 16) & 0xff);
    bytes[offset + 3] = @truncate((value >> 24) & 0xff);
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value & 0xff);
    bytes[offset + 1] = @truncate((value >> 8) & 0xff);
}

fn fixedNameLen(bytes: []const u8) usize {
    var len: usize = 0;
    while (len < bytes.len and bytes[len] != 0) : (len += 1) {}
    return len;
}

fn fixedNameEquals(bytes: []const u8, name: []const u8) bool {
    const len = fixedNameLen(bytes);
    return len == name.len and std.mem.eql(u8, bytes[0..len], name);
}

fn parsePath(allocator: std.mem.Allocator, input: []const u8) !ParsedPath {
    var parsed = ParsedPath.init(allocator);
    errdefer parsed.deinit();
    parsed.absolute = input.len > 0 and input[0] == '/';
    parsed.trailing_slash = input.len > 0 and input[input.len - 1] == '/';

    var start: usize = 0;
    while (start < input.len) {
        while (start < input.len and input[start] == '/') : (start += 1) {}
        if (start >= input.len) {
            break;
        }

        var end = start;
        while (end < input.len and input[end] != '/') : (end += 1) {}
        try parsed.segments.append(try Segment.init(input[start..end]));
        start = end;
    }

    return parsed;
}

fn appendPathSegment(path: *ByteBuffer, segment: []const u8) !void {
    if (std.mem.eql(u8, segment, ".")) {
        return;
    }
    if (std.mem.eql(u8, segment, "..")) {
        const items = path.items();
        if (items.len <= 1) {
            path.clearRetainingCapacity();
            try path.appendSlice("/");
            return;
        }
        var end = items.len;
        if (end > 1 and items[end - 1] == '/') {
            end -= 1;
        }
        while (end > 1 and items[end - 1] != '/') : (end -= 1) {}
        path.len = if (end <= 1) 1 else end;
        return;
    }

    if (std.mem.eql(u8, path.items(), "/")) {
        try path.appendSlice(segment);
        try path.append('/');
        return;
    }
    try path.appendSlice(segment);
    try path.append('/');
}

fn findEntryIndex(entries: []const DirEntry, name: []const u8) ?usize {
    for (entries, 0..) |entry, index| {
        if (entry.eqlName(name)) {
            return index;
        }
    }
    return null;
}

fn removeEntryAt(entries: *EntryBuffer, index: usize) void {
    if (index + 1 < entries.len) {
        std.mem.copyForwards(DirEntry, entries.sliceMut()[index .. entries.len - 1], entries.sliceMut()[index + 1 .. entries.len]);
    }
    entries.len -= 1;
}
