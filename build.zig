const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const mod = b.addModule("Image", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Libraries
    const libraries = [_][]const u8{"Vulkan"};
    for (libraries) |library| {
        const dep = b.dependency(library, .{});
        const new_mod = dep.module(library);
        mod.addImport(library, new_mod);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.setCwd(b.path(".")); // cwd = project root when test runs
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // ReleaseFast tests, e.g. for benchmarking
    const mod_release = b.addModule("ImageReleaseFast", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    for (libraries) |library| {
        const dep = b.dependency(library, .{});
        const new_mod = dep.module(library);
        mod_release.addImport(library, new_mod);
    }

    const mod_tests_release = b.addTest(.{
        .root_module = mod_release,
    });

    const run_mod_tests_release = b.addRunArtifact(mod_tests_release);
    run_mod_tests_release.setCwd(b.path("."));
    const test_release_step = b.step("test-release", "Run tests in ReleaseFast");
    test_release_step.dependOn(&run_mod_tests_release.step);
}
