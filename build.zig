const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("image_to_ascii", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });
    const zigimg_mod = zigimg_dep.module("zigimg");

    const ppm_support_mod = b.createModule(.{
        .root_source_file = b.path("test_support/ppm.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "image_to_ascii", .module = mod },
        },
    });
    const image_loader_mod = b.createModule(.{
        .root_source_file = b.path("test_support/image_loader.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "image_to_ascii", .module = mod },
            .{ .name = "ppm_support", .module = ppm_support_mod },
            .{ .name = "zigimg", .module = zigimg_mod },
        },
    });
    const quality_tools_mod = b.createModule(.{
        .root_source_file = b.path("tools/quality.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "image_to_ascii", .module = mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "image-to-ascii",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "image_to_ascii", .module = mod },
                .{ .name = "ppm_support", .module = ppm_support_mod },
                .{ .name = "image_loader", .module = image_loader_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const bench_exe = b.addExecutable(.{
        .name = "image-to-ascii-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "image_to_ascii", .module = mod },
                .{ .name = "image_loader", .module = image_loader_mod },
                .{ .name = "quality_tools", .module = quality_tools_mod },
            },
        }),
    });

    const compare_exe = b.addExecutable(.{
        .name = "image-to-ascii-compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/render_compare.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "image_to_ascii", .module = mod },
                .{ .name = "ppm_support", .module = ppm_support_mod },
                .{ .name = "image_loader", .module = image_loader_mod },
            },
        }),
    });

    const calibrate_mod = b.createModule(.{
        .root_source_file = b.path("tools/calibrate_font.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    calibrate_mod.addIncludePath(b.path("tools/stb"));
    calibrate_mod.addCSourceFile(.{
        .file = b.path("tools/stb/stb_truetype_impl.c"),
        .flags = &.{"-std=c99"},
    });
    const calibrate_exe = b.addExecutable(.{
        .name = "image-to-ascii-calibrate",
        .root_module = calibrate_mod,
    });

    const run_step = b.step("run", "Run the CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const bench_step = b.step("bench", "Run renderer benchmarks");
    const bench_cmd = b.addRunArtifact(bench_exe);
    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }
    bench_step.dependOn(&bench_cmd.step);

    const compare_step = b.step("compare", "Render an image and score reconstruction quality");
    const compare_cmd = b.addRunArtifact(compare_exe);
    if (b.args) |args| {
        compare_cmd.addArgs(args);
    }
    compare_step.dependOn(&compare_cmd.step);

    const calibrate_step = b.step("calibrate", "Generate or inspect a glyph atlas (scaffold)");
    const calibrate_cmd = b.addRunArtifact(calibrate_exe);
    if (b.args) |args| {
        calibrate_cmd.addArgs(args);
    }
    calibrate_step.dependOn(&calibrate_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const ppm_support_tests = b.addTest(.{
        .root_module = ppm_support_mod,
    });
    const run_ppm_support_tests = b.addRunArtifact(ppm_support_tests);

    const image_loader_tests = b.addTest(.{
        .root_module = image_loader_mod,
    });
    const run_image_loader_tests = b.addRunArtifact(image_loader_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const bench_tests = b.addTest(.{
        .root_module = bench_exe.root_module,
    });
    const run_bench_tests = b.addRunArtifact(bench_tests);

    const compare_tests = b.addTest(.{
        .root_module = compare_exe.root_module,
    });
    const run_compare_tests = b.addRunArtifact(compare_tests);

    const calibrate_tests = b.addTest(.{
        .root_module = calibrate_exe.root_module,
    });
    const run_calibrate_tests = b.addRunArtifact(calibrate_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_ppm_support_tests.step);
    test_step.dependOn(&run_image_loader_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_bench_tests.step);
    test_step.dependOn(&run_compare_tests.step);
    test_step.dependOn(&run_calibrate_tests.step);
}
