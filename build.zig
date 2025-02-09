const std = @import("std");
const microzig = @import("microzig");

const MicroBuild = microzig.MicroBuild(.{
    .rp2xxx = true,
});

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    const fw = mb.add_firmware(.{
        .name = "test",
        .root_source_file = b.path("src/main.zig"),
        .target = mb.ports.rp2xxx.boards.raspberrypi.pico,
        .optimize = optimize,
    });
    mb.install_firmware(fw, .{});
}
