const std = @import("std");

const IntLen = enum {
    u16,
    u32,
    u64,
    usize,
};

/// Configures build artifacts, helper steps, and test/check pipelines.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const intlen = b.option(IntLen, "intlen", "Integer width used for document spans and node indexes") orelse .u32;

    const config_options = b.addOptions();
    config_options.addOption(IntLen, "intlen", intlen);

    const mod = b.addModule("html", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("config", config_options);

    const parse_mode_mod = b.createModule(.{
        .root_source_file = b.path("tools/parse_mode.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "html", .module = mod },
        },
    });

    const bench_exe = b.addExecutable(.{
        .name = "html-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "html", .module = mod },
                .{ .name = "parse_mode", .module = parse_mode_mod },
            },
        }),
    });

    const tools_exe = b.addExecutable(.{
        .name = "html-tools",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/scripts.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const install_bench = b.addInstallArtifact(bench_exe, .{});
    b.getInstallStep().dependOn(&install_bench.step);
    const bench_only_step = b.step("bench-only", "Build benchmark binary only");
    bench_only_step.dependOn(&install_bench.step);
    b.installArtifact(tools_exe);

    const tools_step = b.step("tools", "Run html-tools utility");
    const bench_compare_step = b.step("bench-compare", "Benchmark against external parser implementations");
    const bench_interleaved_step = b.step("bench-interleaved", "Compare two checkouts with interleaved benchmark runs");
    const conformance_step = b.step("conformance", "Run external parser/selector conformance suites (strictest+fastest)");
    const docs_check_step = b.step("docs-check", "Validate markdown links and documented commands");
    const examples_check_step = b.step("examples-check", "Compile and run all examples in test mode");
    const generate_entities_step = b.step("generate-entities", "Regenerate and format the GNU gperf named-entity lookup");
    const generate_entities_cmd = b.addSystemCommand(&.{ "python3", "bench/entity_lookup/generate.py" });
    generate_entities_step.dependOn(&generate_entities_cmd.step);

    const tools_cmd = b.addRunArtifact(tools_exe);

    const setup_parsers_cmd = b.addRunArtifact(tools_exe);
    setup_parsers_cmd.addArg("setup-parsers");

    const setup_fixtures_cmd = b.addRunArtifact(tools_exe);
    setup_fixtures_cmd.addArg("setup-fixtures");
    setup_fixtures_cmd.step.dependOn(&setup_parsers_cmd.step);

    const compare_cmd = b.addRunArtifact(tools_exe);
    compare_cmd.addArg("run-benchmarks");
    compare_cmd.step.dependOn(&setup_fixtures_cmd.step);

    const interleaved_cmd = b.addRunArtifact(tools_exe);
    interleaved_cmd.addArg("compare-worktrees");

    const conformance_cmd = b.addRunArtifact(tools_exe);
    conformance_cmd.addArg("run-external-suites");
    conformance_cmd.addArg("--mode");
    conformance_cmd.addArg("both");

    const docs_check_cmd = b.addRunArtifact(tools_exe);
    docs_check_cmd.addArg("docs-check");

    const examples_check_cmd = b.addRunArtifact(tools_exe);
    examples_check_cmd.addArg("examples-check");

    tools_step.dependOn(&tools_cmd.step);
    bench_compare_step.dependOn(&compare_cmd.step);
    bench_interleaved_step.dependOn(&interleaved_cmd.step);
    conformance_step.dependOn(&conformance_cmd.step);
    docs_check_step.dependOn(&docs_check_cmd.step);
    examples_check_step.dependOn(&examples_check_cmd.step);

    tools_cmd.step.dependOn(b.getInstallStep());
    setup_parsers_cmd.step.dependOn(b.getInstallStep());
    setup_fixtures_cmd.step.dependOn(b.getInstallStep());
    compare_cmd.step.dependOn(b.getInstallStep());
    interleaved_cmd.step.dependOn(b.getInstallStep());
    conformance_cmd.step.dependOn(b.getInstallStep());
    docs_check_cmd.step.dependOn(b.getInstallStep());
    examples_check_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        tools_cmd.addArgs(args);
        compare_cmd.addArgs(args);
        interleaved_cmd.addArgs(args);
        conformance_cmd.addArgs(args);
        docs_check_cmd.addArgs(args);
        examples_check_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .test_runner = .{ .path = b.path("tools/test_runner.zig"), .mode = .simple },
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const examples_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/tests/examples_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "html", .module = mod },
                .{ .name = "examples", .module = b.createModule(.{
                    .root_source_file = b.path("examples/examples.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "html", .module = mod },
                    },
                }) },
            },
        }),
        .test_runner = .{ .path = b.path("tools/test_runner.zig"), .mode = .simple },
    });
    const run_examples_tests = b.addRunArtifact(examples_tests);

    const behavioral_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/tests/behavioral_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "html", .module = mod },
            },
        }),
        .test_runner = .{ .path = b.path("tools/test_runner.zig"), .mode = .simple },
    });
    const run_behavioral_tests = b.addRunArtifact(behavioral_tests);

    const public_api_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/tests/public_api_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "html", .module = mod },
            },
        }),
        .test_runner = .{ .path = b.path("tools/test_runner.zig"), .mode = .simple },
    });
    const run_public_api_tests = b.addRunArtifact(public_api_tests);
    const public_api_test_step = b.step("test-public-api", "Run exhaustive consumer-facing public API tests");
    public_api_test_step.dependOn(&run_public_api_tests.step);

    const scripts_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/scripts.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .test_runner = .{ .path = b.path("tools/test_runner.zig"), .mode = .simple },
    });
    const run_scripts_tests = b.addRunArtifact(scripts_tests);

    const bench_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "html", .module = mod },
                .{ .name = "parse_mode", .module = parse_mode_mod },
            },
        }),
        .test_runner = .{ .path = b.path("tools/test_runner.zig"), .mode = .simple },
    });
    const run_bench_tests = b.addRunArtifact(bench_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_examples_tests.step);
    test_step.dependOn(&run_behavioral_tests.step);
    test_step.dependOn(&run_public_api_tests.step);
    test_step.dependOn(&run_scripts_tests.step);
    test_step.dependOn(&run_bench_tests.step);

    const ship_check_step = b.step("ship-check", "Run release-readiness checks (test + docs + examples)");
    ship_check_step.dependOn(test_step);
    ship_check_step.dependOn(docs_check_step);
    ship_check_step.dependOn(examples_check_step);
}
