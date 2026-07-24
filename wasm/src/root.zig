const std = @import("std");
const store = @import("store.zig");

const allocator = std.heap.wasm_allocator;

const HandleSlot = struct {
    id: u32,
    fs: *store.FileSystem,
};

var slots: [256]?HandleSlot = [_]?HandleSlot{null} ** 256;
var next_handle: u32 = 1;
var last_error_buffer: ?store.ByteBuffer = null;
var result_buffer: ?store.ByteBuffer = null;

fn lastErrorBuffer() *store.ByteBuffer {
    if (last_error_buffer == null) {
        last_error_buffer = store.ByteBuffer.init(allocator);
    }
    return &last_error_buffer.?;
}

fn resultBuffer() *store.ByteBuffer {
    if (result_buffer == null) {
        result_buffer = store.ByteBuffer.init(allocator);
    }
    return &result_buffer.?;
}

fn setError(message: []const u8) void {
    var buffer = lastErrorBuffer();
    buffer.clearRetainingCapacity();
    buffer.appendSlice(message) catch {};
}

fn clearError() void {
    lastErrorBuffer().clearRetainingCapacity();
}

fn setResult(bytes: []const u8) bool {
    const buffer = resultBuffer();
    buffer.clearRetainingCapacity();
    buffer.appendSlice(bytes) catch {
        setError("OutOfMemory");
        return false;
    };
    return true;
}

fn sliceConst(ptr: u32, len: u32) []const u8 {
    if (ptr == 0 or len == 0) {
        return &[_]u8{};
    }
    const bytes: [*]const u8 = @ptrFromInt(ptr);
    return bytes[0..len];
}

fn lookup(handle: u32) ?*store.FileSystem {
    for (&slots) |*slot| {
        if (slot.*) |value| {
            if (value.id == handle) {
                return value.fs;
            }
        }
    }
    return null;
}

fn requireFs(handle: u32) ?*store.FileSystem {
    const fs = lookup(handle) orelse {
        setError("InvalidHandle");
        return null;
    };
    return fs;
}

fn failWith(err: anyerror) u32 {
    setError(@errorName(err));
    return 0;
}

export fn filefs_alloc(len: u32) u32 {
    clearError();
    if (len == 0) {
        return 0;
    }
    const mem = allocator.alloc(u8, len) catch {
        setError("OutOfMemory");
        return 0;
    };
    return @intCast(@intFromPtr(mem.ptr));
}

export fn filefs_free(ptr: u32, len: u32) void {
    if (ptr == 0 or len == 0) {
        return;
    }
    const bytes: [*]u8 = @ptrFromInt(ptr);
    allocator.free(bytes[0..len]);
}

export fn filefs_create() u32 {
    clearError();
    for (&slots) |*slot| {
        if (slot.* == null) {
            const fs = allocator.create(store.FileSystem) catch {
                setError("OutOfMemory");
                return 0;
            };
            fs.* = store.FileSystem.init(allocator);
            const handle = next_handle;
            next_handle += 1;
            slot.* = .{ .id = handle, .fs = fs };
            return handle;
        }
    }
    setError("HandleTableFull");
    return 0;
}

export fn filefs_destroy(handle: u32) void {
    clearError();
    for (&slots) |*slot| {
        if (slot.*) |value| {
            if (value.id == handle) {
                value.fs.deinit();
                allocator.destroy(value.fs);
                slot.* = null;
                return;
            }
        }
    }
}

export fn filefs_mkfs(handle: u32) u32 {
    clearError();
    const fs = requireFs(handle) orelse return 0;
    fs.mkfs() catch |err| return failWith(err);
    return 1;
}

export fn filefs_mount(handle: u32) u32 {
    clearError();
    const fs = requireFs(handle) orelse return 0;
    fs.mount() catch |err| return failWith(err);
    return 1;
}

export fn filefs_getcwd(handle: u32) u32 {
    clearError();
    const fs = requireFs(handle) orelse return 0;
    const buffer = resultBuffer();
    fs.getcwd(buffer) catch |err| return failWith(err);
    return 1;
}

export fn filefs_mkdir(handle: u32, path_ptr: u32, path_len: u32) u32 {
    clearError();
    const fs = requireFs(handle) orelse return 0;
    fs.mkdir(sliceConst(path_ptr, path_len)) catch |err| return failWith(err);
    return 1;
}

export fn filefs_chdir(handle: u32, path_ptr: u32, path_len: u32) u32 {
    clearError();
    const fs = requireFs(handle) orelse return 0;
    fs.chdir(sliceConst(path_ptr, path_len)) catch |err| return failWith(err);
    return 1;
}

export fn filefs_write_file(handle: u32, path_ptr: u32, path_len: u32, data_ptr: u32, data_len: u32) u32 {
    clearError();
    const fs = requireFs(handle) orelse return 0;
    fs.writeFile(sliceConst(path_ptr, path_len), sliceConst(data_ptr, data_len)) catch |err| return failWith(err);
    return 1;
}

export fn filefs_read_file(handle: u32, path_ptr: u32, path_len: u32) u32 {
    clearError();
    const fs = requireFs(handle) orelse return 0;
    const buffer = resultBuffer();
    fs.readFile(sliceConst(path_ptr, path_len), buffer) catch |err| return failWith(err);
    return 1;
}

export fn filefs_copy_file(handle: u32, from_ptr: u32, from_len: u32, to_ptr: u32, to_len: u32) u32 {
    clearError();
    const fs = requireFs(handle) orelse return 0;
    fs.copyFile(sliceConst(from_ptr, from_len), sliceConst(to_ptr, to_len)) catch |err| return failWith(err);
    return 1;
}

export fn filefs_rename(handle: u32, from_ptr: u32, from_len: u32, to_ptr: u32, to_len: u32) u32 {
    clearError();
    const fs = requireFs(handle) orelse return 0;
    fs.rename(sliceConst(from_ptr, from_len), sliceConst(to_ptr, to_len)) catch |err| return failWith(err);
    return 1;
}

export fn filefs_remove_file(handle: u32, path_ptr: u32, path_len: u32) u32 {
    clearError();
    const fs = requireFs(handle) orelse return 0;
    fs.removeFile(sliceConst(path_ptr, path_len)) catch |err| return failWith(err);
    return 1;
}

export fn filefs_list_dir(handle: u32, path_ptr: u32, path_len: u32) u32 {
    clearError();
    const fs = requireFs(handle) orelse return 0;
    const buffer = resultBuffer();
    fs.listDir(sliceConst(path_ptr, path_len), buffer) catch |err| return failWith(err);
    return 1;
}

export fn filefs_begin(handle: u32) u32 {
    clearError();
    const fs = requireFs(handle) orelse return 0;
    fs.begin() catch |err| return failWith(err);
    return 1;
}

export fn filefs_commit(handle: u32) u32 {
    clearError();
    const fs = requireFs(handle) orelse return 0;
    fs.commit() catch |err| return failWith(err);
    return 1;
}

export fn filefs_rollback(handle: u32) u32 {
    clearError();
    const fs = requireFs(handle) orelse return 0;
    fs.rollback();
    return 1;
}

export fn filefs_image_ptr(handle: u32) u32 {
    clearError();
    const fs = requireFs(handle) orelse return 0;
    const image = fs.imageSlice();
    if (image.len == 0) {
        return 0;
    }
    return @intCast(@intFromPtr(image.ptr));
}

export fn filefs_image_len(handle: u32) u32 {
    clearError();
    const fs = requireFs(handle) orelse return 0;
    return @intCast(fs.imageSlice().len);
}

export fn filefs_last_error_ptr() u32 {
    const buffer = lastErrorBuffer();
    if (buffer.len == 0) {
        return 0;
    }
    return @intCast(@intFromPtr(buffer.items().ptr));
}

export fn filefs_last_error_len() u32 {
    return @intCast(lastErrorBuffer().len);
}

export fn filefs_result_ptr() u32 {
    const buffer = resultBuffer();
    if (buffer.len == 0) {
        return 0;
    }
    return @intCast(@intFromPtr(buffer.items().ptr));
}

export fn filefs_result_len() u32 {
    return @intCast(resultBuffer().len);
}

test "store sanity" {
    var fs = store.FileSystem.init(std.testing.allocator);
    defer fs.deinit();

    try fs.mkfs();
    try fs.mount();
    try fs.mkdir("docs");
    try fs.chdir("docs");
    try fs.writeFile("note.txt", "hello");

    var out = store.ByteBuffer.init(std.testing.allocator);
    defer out.deinit();
    try fs.readFile("note.txt", &out);
    try std.testing.expectEqualStrings("hello", out.items());
}
