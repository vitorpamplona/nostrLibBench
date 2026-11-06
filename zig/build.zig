const std = @import("std");

// Three executables from one source tree:
//   libbench            the driver: flags, manifest, host info, one child process per client
//   libbench-zignostr   zig-nostr/nostr clients (it compiles libsecp256k1 0.7.1 from source)
//   libbench-libnostrz  privkeyio/libnostr-z clients (noscrypt over the system libsecp256k1)
// Each library brings its own libsecp256k1, so they live in separate binaries.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const common = b.createModule(.{
        .root_source_file = b.path("src/common.zig"),
        .target = target,
        .optimize = optimize,
    });

    const driver = b.addExecutable(.{
        .name = "libbench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/driver.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "common", .module = common }},
        }),
    });
    b.installArtifact(driver);

    const zig_nostr = b.dependency("zig_nostr", .{ .target = target, .optimize = optimize });
    const exe_zn = b.addExecutable(.{
        .name = "libbench-zignostr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib_zignostr.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "common", .module = common },
                .{ .name = "nostr", .module = zig_nostr.module("nostr") },
            },
        }),
    });
    b.installArtifact(exe_zn);

    const libnostr_z = b.dependency("libnostr_z", .{ .target = target, .optimize = optimize });
    const exe_lz = b.addExecutable(.{
        .name = "libbench-libnostrz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib_libnostrz.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "common", .module = common },
                .{ .name = "nostr", .module = libnostr_z.module("nostr") },
            },
        }),
    });
    b.installArtifact(exe_lz);
}
