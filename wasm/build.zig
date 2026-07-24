const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const module = b.addModule("filefs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const wasm = b.addExecutable(.{
        .name = "filefs",
        .root_module = module,
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.export_memory = true;

    b.installArtifact(wasm);
}
