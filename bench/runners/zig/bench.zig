const std = @import("std");
const Io = std.Io;
const filefs = @import("filefs");

const PAYLOAD: usize = 4096;

fn median(samples: []f64) f64 {
    std.mem.sort(f64, samples, {}, comptime std.sort.asc(f64));
    const n = samples.len;
    if (n == 0) return 0;
    if (n % 2 == 0) return (samples[n / 2 - 1] + samples[n / 2]) / 2.0;
    return samples[n / 2];
}

fn nowNs(io: Io) f64 {
    return @floatFromInt(Io.Clock.awake.now(io).nanoseconds);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const iters: usize = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 40;
    const warmup: usize = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 2;

    const tmp = "bench-tmp";
    try Io.Dir.cwd().createDirPath(io, tmp);
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};

    const image = try std.fmt.allocPrint(allocator, "{s}/bench.ffs", .{tmp});
    defer allocator.free(image);
    var counter: usize = 0;

    var payload: [PAYLOAD]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);
    var buf: [PAYLOAD]u8 = undefined;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"language\":\"zig\",\"runtime\":\"zig\",\"ops\":{");
    var first = true;

    const emit = struct {
        fn call(list: *std.ArrayList(u8), gpa: std.mem.Allocator, first_flag: *bool, name: []const u8, ns: f64, n: usize) !void {
            if (!first_flag.*) try list.append(gpa, ',');
            first_flag.* = false;
            try list.print(gpa, "\"{s}\":{{\"ns_per_op\":{d:.3},\"iters\":{d}}}", .{ name, ns, n });
        }
    }.call;

    const Clock = struct {
        var io_handle: Io = undefined;
        fn timeLoop(iters2: usize, warmup2: usize, body: *const fn () anyerror!void) !struct { f64, usize } {
            var i: usize = 0;
            while (i < warmup2) : (i += 1) try body();
            var samples: [512]f64 = undefined;
            const n = @min(iters2, samples.len);
            i = 0;
            while (i < n) : (i += 1) {
                const t0 = nowNs(io_handle);
                try body();
                samples[i] = nowNs(io_handle) - t0;
            }
            return .{ median(samples[0..n]), n };
        }
    };
    Clock.io_handle = io;

    {
        const Ctx = struct {
            var tmp_path: []const u8 = undefined;
            var ctr: *usize = undefined;
            var io_handle: Io = undefined;
            fn body() anyerror!void {
                ctr.* += 1;
                var pbuf: [320]u8 = undefined;
                const p = try std.fmt.bufPrint(&pbuf, "{s}/mkfs{d}.ffs", .{ tmp_path, ctr.* });
                try filefs.mkfs(p);
                Io.Dir.cwd().deleteFile(io_handle, p) catch {};
                var jbuf: [330]u8 = undefined;
                const j = try std.fmt.bufPrint(&jbuf, "{s}-j", .{p});
                Io.Dir.cwd().deleteFile(io_handle, j) catch {};
            }
        };
        Ctx.tmp_path = tmp;
        Ctx.ctr = &counter;
        Ctx.io_handle = io;
        const r = try Clock.timeLoop(iters, warmup, Ctx.body);
        try emit(&out, allocator, &first, "mkfs", r[0], r[1]);
    }

    try filefs.mkfs(image);
    const ffs = try filefs.create(allocator);
    defer ffs.destroy();
    if (!ffs.mount(image)) return error.MountFailed;

    {
        const Ctx = struct {
            var handle: *filefs.FileFS = undefined;
            var image_path: []const u8 = undefined;
            fn body() anyerror!void {
                handle.umount();
                if (!handle.mount(image_path)) return error.MountFailed;
            }
        };
        Ctx.handle = ffs;
        Ctx.image_path = image;
        const r = try Clock.timeLoop(iters, warmup, Ctx.body);
        try emit(&out, allocator, &first, "mount_umount", r[0], r[1]);
    }

    {
        const Ctx = struct {
            var handle: *filefs.FileFS = undefined;
            var ctr: *usize = undefined;
            fn body() anyerror!void {
                ctr.* += 1;
                var nbuf: [64]u8 = undefined;
                const name = try std.fmt.bufPrint(&nbuf, "d{d}", .{ctr.*});
                if (handle.mkdir(name) != 0) return error.MkdirFailed;
            }
        };
        Ctx.handle = ffs;
        Ctx.ctr = &counter;
        const r = try Clock.timeLoop(iters, warmup, Ctx.body);
        try emit(&out, allocator, &first, "mkdir", r[0], r[1]);
    }

    if (ffs.mkdir("cwdbench") != 0) return error.MkdirFailed;
    {
        const Ctx = struct {
            var handle: *filefs.FileFS = undefined;
            fn body() anyerror!void {
                if (!handle.chdir("cwdbench")) return error.ChdirFailed;
                _ = handle.getcwd();
                if (!handle.chdir("/")) return error.ChdirFailed;
            }
        };
        Ctx.handle = ffs;
        const r = try Clock.timeLoop(iters, warmup, Ctx.body);
        try emit(&out, allocator, &first, "chdir_getcwd", r[0], r[1]);
    }

    {
        const Ctx = struct {
            var handle: *filefs.FileFS = undefined;
            var ctr: *usize = undefined;
            fn body() anyerror!void {
                ctr.* += 1;
                var nbuf: [80]u8 = undefined;
                const path = try std.fmt.bufPrint(&nbuf, "o{d}.txt", .{ctr.*});
                const f = handle.fopen(path, "w") orelse return error.OpenFailed;
                handle.fclose(f);
            }
        };
        Ctx.handle = ffs;
        Ctx.ctr = &counter;
        const r = try Clock.timeLoop(iters, warmup, Ctx.body);
        try emit(&out, allocator, &first, "open_write_close", r[0], r[1]);
    }

    {
        const seed = ffs.fopen("seed.bin", "w") orelse return error.OpenFailed;
        if (ffs.fwrite(payload[0..], 1, PAYLOAD, seed) != PAYLOAD) return error.WriteFailed;
        ffs.fclose(seed);
    }

    {
        const Ctx = struct {
            var handle: *filefs.FileFS = undefined;
            var data: *const [PAYLOAD]u8 = undefined;
            fn body() anyerror!void {
                const f = handle.fopen("wbench.bin", "w") orelse return error.OpenFailed;
                if (handle.fwrite(data[0..], 1, PAYLOAD, f) != PAYLOAD) return error.WriteFailed;
                handle.fclose(f);
            }
        };
        Ctx.handle = ffs;
        Ctx.data = &payload;
        const r = try Clock.timeLoop(iters, warmup, Ctx.body);
        try emit(&out, allocator, &first, "write_4kib", r[0], r[1]);
    }

    {
        const Ctx = struct {
            var handle: *filefs.FileFS = undefined;
            var outbuf: *[PAYLOAD]u8 = undefined;
            fn body() anyerror!void {
                const f = handle.fopen("seed.bin", "r") orelse return error.OpenFailed;
                if (handle.fread(outbuf[0..], 1, PAYLOAD, f) != PAYLOAD) return error.ReadFailed;
                handle.fclose(f);
            }
        };
        Ctx.handle = ffs;
        Ctx.outbuf = &buf;
        const r = try Clock.timeLoop(iters, warmup, Ctx.body);
        try emit(&out, allocator, &first, "read_4kib", r[0], r[1]);
    }

    {
        const Ctx = struct {
            var handle: *filefs.FileFS = undefined;
            fn body() anyerror!void {
                const f = handle.fopen("seed.bin", "r") orelse return error.OpenFailed;
                if (!handle.fseek(f, 0, filefs.SeekEnd)) return error.SeekFailed;
                _ = handle.ftell(f);
                handle.rewind(f);
                handle.fclose(f);
            }
        };
        Ctx.handle = ffs;
        const r = try Clock.timeLoop(iters, warmup, Ctx.body);
        try emit(&out, allocator, &first, "seek_tell_rewind", r[0], r[1]);
    }

    {
        const Ctx = struct {
            var handle: *filefs.FileFS = undefined;
            fn body() anyerror!void {
                _ = handle.remove("copy_dst.bin");
                if (handle.copy("seed.bin", "copy_dst.bin") != 0) return error.CopyFailed;
            }
        };
        Ctx.handle = ffs;
        const r = try Clock.timeLoop(iters, warmup, Ctx.body);
        try emit(&out, allocator, &first, "copy_file", r[0], r[1]);
    }

    {
        const Ctx = struct {
            var handle: *filefs.FileFS = undefined;
            var ctr: *usize = undefined;
            fn body() anyerror!void {
                ctr.* += 1;
                var sbuf: [80]u8 = undefined;
                const src = try std.fmt.bufPrint(&sbuf, "r{d}.txt", .{ctr.*});
                ctr.* += 1;
                var dbuf: [80]u8 = undefined;
                const dst = try std.fmt.bufPrint(&dbuf, "s{d}.txt", .{ctr.*});
                const f = handle.fopen(src, "w") orelse return error.OpenFailed;
                handle.fclose(f);
                if (handle.rename(src, dst) != 0) return error.RenameFailed;
                _ = handle.remove(dst);
            }
        };
        Ctx.handle = ffs;
        Ctx.ctr = &counter;
        const r = try Clock.timeLoop(iters, warmup, Ctx.body);
        try emit(&out, allocator, &first, "rename", r[0], r[1]);
    }

    {
        const Ctx = struct {
            var handle: *filefs.FileFS = undefined;
            var ctr: *usize = undefined;
            fn body() anyerror!void {
                ctr.* += 1;
                var nbuf: [80]u8 = undefined;
                const name = try std.fmt.bufPrint(&nbuf, "m{d}.txt", .{ctr.*});
                const f = handle.fopen(name, "w") orelse return error.OpenFailed;
                handle.fclose(f);
                if (handle.remove(name) != 0) return error.RemoveFailed;
            }
        };
        Ctx.handle = ffs;
        Ctx.ctr = &counter;
        const r = try Clock.timeLoop(iters, warmup, Ctx.body);
        try emit(&out, allocator, &first, "remove_file", r[0], r[1]);
    }

    {
        const Ctx = struct {
            var handle: *filefs.FileFS = undefined;
            fn body() anyerror!void {
                const opened = handle.opendir("/") orelse return error.OpenDirFailed;
                const dir = opened.dir;
                while (handle.readdir(dir) != null) {}
                handle.closedir(dir);
            }
        };
        Ctx.handle = ffs;
        const r = try Clock.timeLoop(iters, warmup, Ctx.body);
        try emit(&out, allocator, &first, "readdir", r[0], r[1]);
    }

    {
        const Ctx = struct {
            var handle: *filefs.FileFS = undefined;
            fn body() anyerror!void {
                _ = handle.fileExist("seed.bin");
                _ = handle.dirExist("cwdbench");
            }
        };
        Ctx.handle = ffs;
        const r = try Clock.timeLoop(iters, warmup, Ctx.body);
        try emit(&out, allocator, &first, "exists", r[0], r[1]);
    }

    {
        const Ctx = struct {
            var handle: *filefs.FileFS = undefined;
            var ctr: *usize = undefined;
            fn body() anyerror!void {
                if (!handle.begin()) return error.BeginFailed;
                ctr.* += 1;
                var nbuf: [80]u8 = undefined;
                const name = try std.fmt.bufPrint(&nbuf, "t{d}.txt", .{ctr.*});
                const f = handle.fopen(name, "w") orelse return error.OpenFailed;
                const x: [1]u8 = .{'x'};
                if (handle.fwrite(&x, 1, 1, f) != 1) return error.WriteFailed;
                handle.fclose(f);
                if (!handle.commit()) return error.CommitFailed;
            }
        };
        Ctx.handle = ffs;
        Ctx.ctr = &counter;
        const r = try Clock.timeLoop(iters, warmup, Ctx.body);
        try emit(&out, allocator, &first, "txn_commit", r[0], r[1]);
    }

    ffs.umount();
    try out.appendSlice(allocator, "}}\n");
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    try stdout_writer.interface.writeAll(out.items);
    try stdout_writer.interface.flush();
}
