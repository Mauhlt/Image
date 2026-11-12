const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Only passed on to Vulkan (Image's modules inherit the optimize mode
    // of whatever compiles them).
    const optimize = b.standardOptimizeOption(.{});

    // SIMD tuning width in bytes; unset = std.simd.suggestVectorLength(u8) for the target.
    // Set it to run a wider (or narrower) build's vector code on this machine.
    const vector_bytes = b.option(usize, "vector-bytes", "SIMD tuning width in bytes (power of two, >= 16; default: suggested for the target CPU)");
    const options = b.addOptions();
    options.addOption(usize, "vector_bytes", vector_bytes orelse 0); // 0: suggested
    const options_mod = options.createModule();

    // "ImageCheck" (src/check): format-agnostic pre-decode validation. Only
    // std, no Vulkan: compiles for any target (wasm32-freestanding too), so
    // programs that only validate images can import it alone. Image's
    // module imports it and re-exports it as `Image.check`; its PNG codec
    // shares the CRC and IHDR rules from it.
    const check_mod = b.addModule("ImageCheck", .{
        .root_source_file = b.path("src/check/root.zig"),
        .target = target,
    });

    const mod = b.addModule("Image", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addImport("build_options", options_mod);
    mod.addImport("ImageCheck", check_mod);

    // Vulkan, with the same arguments other packages (Renderer) pass, so a
    // program using Image and Renderer gets one shared "Vulkan" module:
    // a source file may belong to only one module per compilation.
    mod.addImport("Vulkan", b.dependency("Vulkan", .{ .target = target, .optimize = optimize }).module("Vulkan"));

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.setCwd(b.path(".")); // cwd = project root when test runs
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    // The checker's own tests, and proof it builds for the browser.
    const check_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/check/root.zig"),
        .target = target,
    }) });
    test_step.dependOn(&b.addRunArtifact(check_tests).step);
    const wasm_check = b.addObject(.{ .name = "image-check-wasm32", .root_module = b.createModule(.{
        .root_source_file = b.path("src/check/root.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = .ReleaseSmall,
    }) });
    test_step.dependOn(&wasm_check.step);

    // ReleaseFast tests, e.g. for benchmarking
    const mod_release = b.addModule("ImageReleaseFast", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    mod_release.addImport("build_options", options_mod);
    mod_release.addImport("ImageCheck", check_mod);
    mod_release.addImport("Vulkan", b.dependency("Vulkan", .{ .target = target, .optimize = .ReleaseFast }).module("Vulkan"));

    const mod_tests_release = b.addTest(.{
        .root_module = mod_release,
    });

    const run_mod_tests_release = b.addRunArtifact(mod_tests_release);
    run_mod_tests_release.setCwd(b.path("."));
    const test_release_step = b.step("test-release", "Run tests in ReleaseFast");
    test_release_step.dependOn(&run_mod_tests_release.step);

    // Benchmarks (ReleaseFast)
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "Image", .module = mod_release }},
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.setCwd(b.path("."));
    const bench_step = b.step("bench", "Decode benchmarks (ReleaseFast)");
    bench_step.dependOn(&run_bench.step);
}
