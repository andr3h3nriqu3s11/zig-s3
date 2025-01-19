const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the s3 library module
    const s3_module = b.addModule("s3", .{
        .root_source_file = b.path("src/s3/lib.zig"),
    });

    // Create the library that others can use as a dependency
    const lib = b.addStaticLibrary(.{
        .name = "s3-client",
        .root_source_file = b.path("src/s3/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.root_module.addImport("s3", s3_module);
    b.installArtifact(lib);

    // Create the example executable
    const exe = b.addExecutable(.{
        .name = "s3-example",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("s3", s3_module);
    b.installArtifact(exe);

    // Create "run" step for the example
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the example application");
    run_step.dependOn(&run_cmd.step);

    // Add tests
    const lib_tests = b.addTest(.{
        .root_source_file = b.path("src/s3/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    // Add documentation
    const docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate library documentation");
    docs_step.dependOn(&docs.step);

    // Add formatting
    const fmt = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
        .check = true,
    });

    const fmt_step = b.step("fmt", "Format source files");
    fmt_step.dependOn(&fmt.step);
}
