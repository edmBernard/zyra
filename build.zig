const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zyra = b.addModule("zyra", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const example = b.addExecutable(.{
        .name = "naval_fate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zyra", .module = zyra }},
        }),
    });
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(b.getInstallStep());
    run_example.addPassthruArgs();
    const run_step = b.step("run", "Run the Naval Fate example");
    run_step.dependOn(&run_example.step);

    const library_tests = b.addTest(.{ .root_module = zyra });
    const run_library_tests = b.addRunArtifact(library_tests);
    const example_tests = b.addTest(.{ .root_module = example.root_module });
    const run_example_tests = b.addRunArtifact(example_tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_library_tests.step);
    test_step.dependOn(&run_example_tests.step);
}
