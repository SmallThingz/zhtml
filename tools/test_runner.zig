//! Default test runner for unit tests.
const builtin = @import("builtin");

const std = @import("std");
const Io = std.Io;
const fatal = std.process.fatal;
const testing = std.testing;
const assert = std.debug.assert;
const panic = std.debug.panic;
const fuzz_abi = std.Build.abi.fuzz;

pub const std_options: std.Options = .{
    .logFn = log,
};

var log_err_count: usize = 0;
var fba: std.heap.FixedBufferAllocator = .init(&fba_buffer);
var fba_buffer: [8192]u8 = undefined;
var stdin_buffer: [4096]u8 = undefined;
var stdout_buffer: [4096]u8 = undefined;
var stdin_reader: Io.File.Reader = undefined;
var stdout_writer: Io.File.Writer = undefined;
const runner_threaded_io: Io = Io.Threaded.global_single_threaded.io();

/// Keep in sync with logic in `std.Build.addRunArtifact` which decides whether
/// the test runner will communicate with the build runner via `std.zig.Server`.
const need_simple = switch (builtin.zig_backend) {
    .stage2_aarch64,
    .stage2_powerpc,
    .stage2_riscv64,
    => true,
    else => false,
};

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();

    if (builtin.cpu.arch.isSpirV()) {
        // SPIR-V needs an special test-runner
        return;
    }

    if (need_simple) {
        return mainSimple() catch |err| panic("test failure: {t}", .{err});
    }

    const args = init.args.toSlice(fba.allocator()) catch |err| panic("unable to parse command line args: {t}", .{err});

    var listen = false;
    var opt_cache_dir: ?[]const u8 = null;
    var child_test_name: ?[]const u8 = null;
    var filter: ?[]const u8 = null;
    var jobs: ?usize = null;
    var seed: ?u32 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--listen=-")) {
            listen = true;
        } else if (std.mem.eql(u8, arg, "--zhttp-run-test")) {
            i += 1;
            if (i >= args.len) panic("missing value for --zhttp-run-test", .{});
            child_test_name = args[i];
        } else if (std.mem.eql(u8, arg, "--test-filter")) {
            i += 1;
            if (i >= args.len) panic("missing value for --test-filter", .{});
            filter = args[i];
        } else if (std.mem.startsWith(u8, arg, "--test-filter=")) {
            filter = arg["--test-filter=".len..];
        } else if (std.mem.eql(u8, arg, "--jobs")) {
            i += 1;
            if (i >= args.len) panic("missing value for --jobs", .{});
            jobs = parseUsize(args[i]) catch panic("invalid --jobs value: {s}", .{args[i]});
        } else if (std.mem.startsWith(u8, arg, "--jobs=")) {
            const v = arg["--jobs=".len..];
            jobs = parseUsize(v) catch panic("invalid --jobs value: {s}", .{v});
        } else if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            if (i >= args.len) panic("missing value for --seed", .{});
            seed = parseU32(args[i]) catch panic("invalid --seed value: {s}", .{args[i]});
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            const v = arg["--seed=".len..];
            seed = parseU32(v) catch panic("invalid --seed value: {s}", .{v});
        } else if (std.mem.eql(u8, arg, "--cache-dir")) {
            i += 1;
            if (i >= args.len) panic("missing value for --cache-dir", .{});
            opt_cache_dir = args[i];
        } else if (std.mem.startsWith(u8, arg, "--cache-dir=")) {
            opt_cache_dir = arg["--cache-dir=".len..];
        } else if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else {
            // Ignore unknown args to remain compatible with zig test flags.
        }
    }

    if (seed) |s| testing.random_seed = s;

    if (builtin.fuzz) {
        const cache_dir = opt_cache_dir orelse @panic("missing --cache-dir=[path] argument");
        fuzz_abi.fuzzer_init(.fromSlice(cache_dir));
    }

    if (listen) {
        return mainServer(init) catch |err| panic("internal test runner failure: {t}", .{err});
    }

    if (child_test_name) |name| return runSingleTest(init, name, seed);
    return mainTerminal(init, filter, jobs, seed);
}

fn parseUsize(s: []const u8) !usize {
    return std.fmt.parseUnsigned(usize, s, 10);
}

fn parseU32(s: []const u8) !u32 {
    return std.fmt.parseUnsigned(u32, s, 0);
}

fn printHelp() void {
    std.debug.print(
        "Usage: test-runner [--test-filter <str>] [--jobs <n>] [--seed <n>]\n",
        .{},
    );
}

fn mainServer(init: std.process.Init.Minimal) !void {
    @disableInstrumentation();
    stdin_reader = .initStreaming(.stdin(), runner_threaded_io, &stdin_buffer);
    stdout_writer = .initStreaming(.stdout(), runner_threaded_io, &stdout_buffer);
    var server = try std.zig.Server.init(.{
        .in = &stdin_reader.interface,
        .out = &stdout_writer.interface,
        .zig_version = builtin.zig_version_string,
    });

    while (true) {
        const hdr = try server.receiveMessage();
        switch (hdr.tag) {
            .exit => {
                return std.process.exit(0);
            },
            .query_test_metadata => {
                testing.allocator_instance = .{};
                defer if (testing.allocator_instance.deinit() == .leak) {
                    @panic("internal test runner memory leak");
                };

                var string_bytes: std.ArrayList(u8) = .empty;
                defer string_bytes.deinit(testing.allocator);
                try string_bytes.append(testing.allocator, 0); // Reserve 0 for null.

                const test_fns = builtin.test_functions;
                const names = try testing.allocator.alloc(u32, test_fns.len);
                defer testing.allocator.free(names);
                const expected_panic_msgs = try testing.allocator.alloc(u32, test_fns.len);
                defer testing.allocator.free(expected_panic_msgs);

                for (test_fns, names, expected_panic_msgs) |test_fn, *name, *expected_panic_msg| {
                    name.* = @intCast(string_bytes.items.len);
                    try string_bytes.ensureUnusedCapacity(testing.allocator, test_fn.name.len + 1);
                    string_bytes.appendSliceAssumeCapacity(test_fn.name);
                    string_bytes.appendAssumeCapacity(0);
                    expected_panic_msg.* = 0;
                }

                try server.serveTestMetadata(.{
                    .names = names,
                    .expected_panic_msgs = expected_panic_msgs,
                    .string_bytes = string_bytes.items,
                });
            },

            .run_test => {
                testing.environ = init.environ;
                testing.allocator_instance = .{};
                testing.io_instance = .init(testing.allocator, .{
                    .argv0 = .init(init.args),
                    .environ = init.environ,
                });
                log_err_count = 0;
                const index = try server.receiveBody_u32();
                const test_fn = builtin.test_functions[index];
                is_fuzz_test = false;

                // let the build server know we're starting the test now
                try server.serveStringMessage(.test_started, &.{});

                const TestResults = std.zig.Server.Message.TestResults;
                const status: TestResults.Status = if (test_fn.func()) |v| s: {
                    v;
                    break :s .pass;
                } else |err| switch (err) {
                    error.SkipZigTest => .skip,
                    else => s: {
                        if (@errorReturnTrace()) |trace| {
                            std.debug.dumpErrorReturnTrace(trace);
                        }
                        break :s .fail;
                    },
                };
                testing.io_instance.deinit();
                const leak_count = testing.allocator_instance.detectLeaks();
                testing.allocator_instance.deinitWithoutLeakChecks();
                try server.serveTestResults(.{
                    .index = index,
                    .flags = .{
                        .status = status,
                        .fuzz = is_fuzz_test,
                        .log_err_count = std.math.lossyCast(
                            @FieldType(TestResults.Flags, "log_err_count"),
                            log_err_count,
                        ),
                        .leak_count = std.math.lossyCast(
                            @FieldType(TestResults.Flags, "leak_count"),
                            leak_count,
                        ),
                    },
                });
            },
            .start_fuzzing => {
                // This ensures that this code won't be analyzed and hence reference fuzzer symbols
                // since they are not present.
                if (!builtin.fuzz) unreachable;

                var gpa_instance: std.heap.DebugAllocator(.{}) = .init;
                defer if (gpa_instance.deinit() == .leak) {
                    @panic("internal test runner memory leak");
                };
                const gpa = gpa_instance.allocator();
                var io_instance: Io.Threaded = .init(gpa, .{
                    .argv0 = .init(init.args),
                    .environ = init.environ,
                });
                defer io_instance.deinit();
                const io = io_instance.io();

                const mode: fuzz_abi.LimitKind = @enumFromInt(try server.receiveBody_u8());
                const amount_or_instance = try server.receiveBody_u64();
                const main_instance = mode == .iterations or amount_or_instance == 0;

                if (main_instance) {
                    const coverage = fuzz_abi.fuzzer_coverage();
                    try server.serveCoverageIdMessage(
                        coverage.id,
                        coverage.runs,
                        coverage.unique,
                        coverage.seen,
                    );
                }

                const n_tests: u32 = try server.receiveBody_u32();
                const test_indexes = try gpa.alloc(u32, n_tests);
                defer gpa.free(test_indexes);
                fuzz_runner = .{
                    .indexes = test_indexes,
                    .server = &server,
                    .gpa = gpa,
                    .io = io,
                    .input_poller = undefined,
                };

                {
                    var large_name_buf: std.ArrayList(u8) = .empty;
                    defer large_name_buf.deinit(gpa);
                    for (test_indexes) |*i| {
                        const name_len = try server.receiveBody_u32();
                        const name = if (name_len <= server.in.buffer.len)
                            try server.in.take(name_len)
                        else large_name: {
                            try large_name_buf.resize(gpa, name_len);
                            try server.in.readSliceAll(large_name_buf.items);
                            break :large_name large_name_buf.items;
                        };

                        for (0.., builtin.test_functions) |test_i, test_fn| {
                            if (std.mem.eql(u8, name, test_fn.name)) {
                                i.* = @intCast(test_i);
                                break;
                            }
                        } else {
                            panic("fuzz test {s} no longer exists", .{name});
                        }

                        if (main_instance) {
                            const relocated_entry_addr = @intFromPtr(builtin.test_functions[i.*].func);
                            const entry_addr = fuzz_abi.fuzzer_unslide_address(relocated_entry_addr);
                            try server.serveU64Message(.fuzz_start_addr, entry_addr);
                        }
                    }
                }

                fuzz_abi.fuzzer_main(n_tests, testing.random_seed, mode, amount_or_instance);

                assert(mode != .forever);
                std.process.exit(0);
            },

            else => {
                std.debug.print("unsupported message: {x}\n", .{@intFromEnum(hdr.tag)});
                std.process.exit(1);
            },
        }
    }
}

const Status = enum {
    pass,
    fail,
    skip,
    leak,
    crash,
};

const Summary = struct {
    pass: usize = 0,
    fail: usize = 0,
    skip: usize = 0,
    leak: usize = 0,
    crash: usize = 0,
};

fn mainTerminal(init: std.process.Init.Minimal, filter: ?[]const u8, jobs: ?usize, seed: ?u32) void {
    @disableInstrumentation();
    if (builtin.fuzz) @panic("fuzz test requires server");

    const args = init.args.toSlice(fba.allocator()) catch |err| {
        panic("unable to parse command line args: {t}", .{err});
    };
    const argv0 = if (args.len > 0) args[0] else "test-runner";
    var threaded = Io.Threaded.init(std.heap.page_allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    defer threaded.deinit();

    runAllTests(std.heap.page_allocator, threaded.io(), argv0, filter, jobs, seed) catch |err| {
        panic("test runner failed: {t}", .{err});
    };
}

fn runAllTests(
    gpa: std.mem.Allocator,
    io: std.Io,
    argv0: []const u8,
    filter: ?[]const u8,
    jobs: ?usize,
    seed: ?u32,
) !void {
    var tests: std.ArrayList([]const u8) = .empty;
    defer tests.deinit(gpa);

    for (builtin.test_functions) |t| {
        if (filter) |f| {
            if (std.mem.indexOf(u8, t.name, f) == null) continue;
        }
        try tests.append(gpa, t.name);
    }

    if (tests.items.len == 0) {
        std.debug.print("0 tests selected\n", .{});
        return;
    }

    const cpu_count = std.Thread.getCpuCount() catch 1;
    var job_count = jobs orelse cpu_count;
    if (job_count == 0) job_count = 1;
    if (job_count > tests.items.len) job_count = tests.items.len;

    var next_index: std.atomic.Value(usize) = .init(0);
    var summary: Summary = .{};
    var print_mutex: std.Io.Mutex = .init;
    var count_mutex: std.Io.Mutex = .init;

    var ctx = WorkerCtx{
        .gpa = gpa,
        .io = io,
        .argv0 = argv0,
        .tests = tests.items,
        .seed = seed,
        .next_index = &next_index,
        .summary = &summary,
        .print_mutex = &print_mutex,
        .count_mutex = &count_mutex,
    };

    if (builtin.single_threaded or job_count == 1) {
        worker(&ctx);
    } else {
        const threads = try gpa.alloc(std.Thread, job_count);
        defer gpa.free(threads);
        var spawned: usize = 0;
        errdefer for (threads[0..spawned]) |t| t.join();
        for (threads) |*t| {
            t.* = try std.Thread.spawn(.{}, worker, .{&ctx});
            spawned += 1;
        }
        for (threads) |t| t.join();
    }

    std.debug.print(
        "\npass: {d}  fail: {d}  skip: {d}  leak: {d}  crash: {d}\n",
        .{ summary.pass, summary.fail, summary.skip, summary.leak, summary.crash },
    );

    if (summary.fail != 0 or summary.crash != 0 or summary.leak != 0) {
        std.process.exit(1);
    }
}

const WorkerCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    argv0: []const u8,
    tests: []const []const u8,
    seed: ?u32,
    next_index: *std.atomic.Value(usize),
    summary: *Summary,
    print_mutex: *std.Io.Mutex,
    count_mutex: *std.Io.Mutex,
};

fn worker(ctx: *WorkerCtx) void {
    while (true) {
        const idx = ctx.next_index.fetchAdd(1, .seq_cst);
        if (idx >= ctx.tests.len) break;

        const test_name = ctx.tests[idx];
        const result = runChildTest(ctx, test_name) catch |err| {
            ctx.print_mutex.lockUncancelable(ctx.io);
            defer ctx.print_mutex.unlock(ctx.io);
            std.debug.print("\n== TEST {s} ==\nrunner error: {s}\n", .{ test_name, @errorName(err) });
            ctx.count_mutex.lockUncancelable(ctx.io);
            ctx.summary.fail += 1;
            ctx.count_mutex.unlock(ctx.io);
            continue;
        };
        defer ctx.gpa.free(result.stdout);
        defer ctx.gpa.free(result.stderr);

        ctx.print_mutex.lockUncancelable(ctx.io);
        defer ctx.print_mutex.unlock(ctx.io);
        printTestOutput(ctx, test_name, result);

        ctx.count_mutex.lockUncancelable(ctx.io);
        switch (result.status) {
            .pass => ctx.summary.pass += 1,
            .fail => ctx.summary.fail += 1,
            .skip => ctx.summary.skip += 1,
            .leak => ctx.summary.leak += 1,
            .crash => ctx.summary.crash += 1,
        }
        ctx.count_mutex.unlock(ctx.io);
    }
}

const ChildResult = struct {
    status: Status,
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

fn runChildTest(ctx: *WorkerCtx, test_name: []const u8) !ChildResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.gpa);

    try argv.append(ctx.gpa, ctx.argv0);
    try argv.append(ctx.gpa, "--zhttp-run-test");
    try argv.append(ctx.gpa, test_name);

    var seed_buf: ?[]u8 = null;
    if (ctx.seed) |s| {
        const seed_str = try std.fmt.allocPrint(ctx.gpa, "{d}", .{s});
        seed_buf = seed_str;
        try argv.append(ctx.gpa, "--seed");
        try argv.append(ctx.gpa, seed_str);
    }
    defer if (seed_buf) |b| ctx.gpa.free(b);

    const pty_cmd = try buildScriptCommand(ctx.gpa, argv.items);
    defer ctx.gpa.free(pty_cmd);

    const script_argv = [_][]const u8{
        "script",
        "-qefc",
        pty_cmd,
        "/dev/null",
    };

    const result = try std.process.run(ctx.gpa, ctx.io, .{
        .argv = &script_argv,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
    });

    const status = classifyStatus(result.term);
    return .{
        .status = status,
        .term = result.term,
        // `script -qefc` multiplexes PTY stdout+stderr into stdout.
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn classifyStatus(term: std.process.Child.Term) Status {
    switch (term) {
        .exited => |code| return switch (code) {
            0 => .pass,
            2 => .skip,
            3 => .leak,
            else => .fail,
        },
        .signal, .stopped, .unknown => return .crash,
    }
}

fn printTestOutput(ctx: *const WorkerCtx, name: []const u8, res: ChildResult) void {
    const color = switch (res.status) {
        .pass => "\x1b[32m",
        .skip => "\x1b[94m",
        else => "\x1b[31m",
    };
    const label = switch (res.status) {
        .pass => "ok",
        .skip => "skip",
        .leak => "leak",
        .crash => "crash",
        .fail => "error",
    };

    var out_buf: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer out_buf.deinit();
    const w = &out_buf.writer;

    if (res.status == .pass or res.status == .skip) {
        w.print("{s}{s}\x1b[0m {s}", .{ color, label, name }) catch return;
        if (res.stdout.len > 0) {
            w.writeAll(" | out: ") catch return;
            writeSingleLine(w, res.stdout, 200) catch return;
        }
        if (res.stderr.len > 0) {
            w.writeAll(" | err: ") catch return;
            writeSingleLine(w, res.stderr, 200) catch return;
        }
        switch (res.term) {
            .exited => |code| if (code != 0) w.print(" | exit {d}", .{code}) catch return,
            .signal => |sig| w.print(" | signal {d}", .{@intFromEnum(sig)}) catch return,
            .stopped => |code| w.print(" | stopped {d}", .{code}) catch return,
            .unknown => |code| w.print(" | unknown {d}", .{code}) catch return,
        }
        w.writeByte('\n') catch return;
        std.Io.File.stdout().writeStreamingAll(ctx.io, out_buf.written()) catch {};
        return;
    }

    w.print("{s}{s}\x1b[0m {s}", .{ color, label, name }) catch return;
    switch (res.term) {
        .exited => |code| if (code != 0) w.print(" | exit {d}", .{code}) catch return,
        .signal => |sig| w.print(" | signal {d}", .{@intFromEnum(sig)}) catch return,
        .stopped => |code| w.print(" | stopped {d}", .{code}) catch return,
        .unknown => |code| w.print(" | unknown {d}", .{code}) catch return,
    }
    w.writeAll("\n\n") catch return;

    if (res.stdout.len > 0) {
        w.writeAll("---- child output (pty merged stdout/stderr) ----\n") catch return;
        w.writeAll(res.stdout) catch return;
        if (res.stdout[res.stdout.len - 1] != '\n') w.writeByte('\n') catch return;
    }
    if (res.stderr.len > 0) {
        w.writeAll("---- script stderr ----\n") catch return;
        w.writeAll(res.stderr) catch return;
        if (res.stderr[res.stderr.len - 1] != '\n') w.writeByte('\n') catch return;
    }
    w.writeByte('\n') catch return;
    std.Io.File.stdout().writeStreamingAll(ctx.io, out_buf.written()) catch {};
}

fn writeSingleLine(w: *std.Io.Writer, bytes: []const u8, max_len: usize) !void {
    var written: usize = 0;
    for (bytes) |c| {
        if (written >= max_len) break;
        switch (c) {
            '\n', '\r', '\t' => {
                try w.writeByte(' ');
                written += 1;
            },
            else => {
                try w.print("{c}", .{c});
                written += 1;
            },
        }
    }
    if (bytes.len > max_len) try w.writeAll("...");
}

fn buildScriptCommand(alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    for (argv, 0..) |arg, i| {
        if (i != 0) try out.append(alloc, ' ');
        try appendShellSingleQuoted(&out, alloc, arg);
    }
    return out.toOwnedSlice(alloc);
}

fn appendShellSingleQuoted(out: *std.ArrayList(u8), alloc: std.mem.Allocator, arg: []const u8) !void {
    try out.append(alloc, '\'');
    for (arg) |c| {
        if (c == '\'') {
            try out.appendSlice(alloc, "'\\''");
        } else {
            try out.append(alloc, c);
        }
    }
    try out.append(alloc, '\'');
}

fn runSingleTest(init: std.process.Init.Minimal, name: []const u8, seed: ?u32) void {
    if (seed) |s| testing.random_seed = s;

    const test_fn = findTest(name) orelse {
        std.debug.print("unknown test: {s}\n", .{name});
        std.process.exit(1);
    };

    testing.environ = init.environ;
    testing.log_level = .warn;
    testing.io_instance = .init(testing.allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    defer testing.io_instance.deinit();

    testing.allocator_instance = .{};
    log_err_count = 0;
    const result = test_fn.func();
    const leak_status = testing.allocator_instance.deinit();

    if (leak_status == .leak) {
        std.debug.print("memory leak\n", .{});
        std.process.exit(3);
    }
    if (log_err_count != 0) {
        std.debug.print("error logs detected\n", .{});
        std.process.exit(1);
    }

    if (result) |_| {
        std.process.exit(0);
    } else |err| switch (err) {
        error.SkipZigTest => std.process.exit(2),
        else => {
            std.debug.print("{s}\n", .{@errorName(err)});
            std.process.exit(1);
        },
    }
}

const TestFn = std.meta.Elem(@TypeOf(builtin.test_functions));

fn findTest(name: []const u8) ?TestFn {
    for (builtin.test_functions) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}

/// Simpler main(), exercising fewer language features, so that
/// work-in-progress backends can handle it.
pub fn mainSimple() anyerror!void {
    @disableInstrumentation();
    // is the backend capable of calling `Io.File.writeAll`?
    const enable_write = switch (builtin.zig_backend) {
        .stage2_aarch64, .stage2_riscv64 => true,
        else => false,
    };
    // is the backend capable of calling `Io.Writer.print`?
    const enable_print = switch (builtin.zig_backend) {
        .stage2_aarch64, .stage2_riscv64 => true,
        else => false,
    };

    testing.io_instance = .init(testing.allocator, .{});

    var passed: u64 = 0;
    var skipped: u64 = 0;
    var failed: u64 = 0;

    // we don't want to bring in File and Writer if the backend doesn't support it
    const stdout = if (enable_write) Io.File.stdout() else {};

    for (builtin.test_functions) |test_fn| {
        if (enable_write) {
            stdout.writeStreamingAll(runner_threaded_io, test_fn.name) catch {};
            stdout.writeStreamingAll(runner_threaded_io, "... ") catch {};
        }
        if (test_fn.func()) |_| {
            if (enable_write) stdout.writeStreamingAll(runner_threaded_io, "PASS\n") catch {};
        } else |err| {
            if (err != error.SkipZigTest) {
                if (enable_write) stdout.writeStreamingAll(runner_threaded_io, "FAIL\n") catch {};
                failed += 1;
                if (!enable_write) return err;
                continue;
            }
            if (enable_write) stdout.writeStreamingAll(runner_threaded_io, "SKIP\n") catch {};
            skipped += 1;
            continue;
        }
        passed += 1;
    }
    if (enable_print) {
        var unbuffered_stdout_writer = stdout.writer(runner_threaded_io, &.{});
        unbuffered_stdout_writer.interface.print(
            "{} passed, {} skipped, {} failed\n",
            .{ passed, skipped, failed },
        ) catch {};
    }
    if (failed != 0) std.process.exit(1);
}

var is_fuzz_test: bool = undefined;
var fuzz_runner: if (builtin.fuzz) struct {
    indexes: []u32,
    server: *std.zig.Server,
    gpa: std.mem.Allocator,
    io: Io,
    input_poller: Io.Future(Io.Cancelable!void),

    comptime {
        assert(builtin.fuzz); // `fuzz_runner` was analyzed in non-fuzzing compilation
    }

    export fn runner_test_run(i: u32) void {
        @disableInstrumentation();

        fuzz_runner.server.serveU32Message(.fuzz_test_change, i) catch |e| switch (e) {
            error.WriteFailed => panic("failed to write to stdout: {t}", .{stdout_writer.err.?}),
        };

        testing.allocator_instance = .{};
        defer if (testing.allocator_instance.deinit() == .leak) std.process.exit(1);
        is_fuzz_test = false;

        builtin.test_functions[fuzz_runner.indexes[i]].func() catch |err| switch (err) {
            error.SkipZigTest => return,
            else => {
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
                std.debug.print("failed with error.{t}\n", .{err});
                std.process.exit(1);
            },
        };

        if (!is_fuzz_test) @panic("missed call to std.testing.fuzz");
        if (log_err_count != 0) @panic("error logs detected");
    }

    export fn runner_test_name(i: u32) fuzz_abi.Slice {
        @disableInstrumentation();
        return .fromSlice(builtin.test_functions[fuzz_runner.indexes[i]].name);
    }

    export fn runner_broadcast_input(test_i: u32, bytes_slice: fuzz_abi.Slice) void {
        @disableInstrumentation();
        const bytes = bytes_slice.toSlice();
        fuzz_runner.server.serveBroadcastFuzzInputMessage(test_i, bytes) catch |e| switch (e) {
            error.WriteFailed => panic("failed to write to stdout: {t}", .{stdout_writer.err.?}),
        };
    }

    export fn runner_start_input_poller() void {
        @disableInstrumentation();
        const future = fuzz_runner.io.concurrent(inputPoller, .{}) catch |e| switch (e) {
            error.ConcurrencyUnavailable => @panic("failed to spawn concurrent fuzz input poller"),
        };
        fuzz_runner.input_poller = future;
    }

    export fn runner_stop_input_poller() void {
        @disableInstrumentation();
        assert(fuzz_runner.input_poller.cancel(fuzz_runner.io) == error.Canceled);
    }

    export fn runner_futex_wait(ptr: *const u32, expected: u32) bool {
        @disableInstrumentation();
        return fuzz_runner.io.futexWait(u32, ptr, expected) == error.Canceled;
    }

    export fn runner_futex_wake(ptr: *const u32, waiters: u32) void {
        @disableInstrumentation();
        fuzz_runner.io.futexWake(u32, ptr, waiters);
    }

    fn inputPoller() Io.Cancelable!void {
        @disableInstrumentation();
        switch (inputPollerInner()) {
            error.Canceled => return error.Canceled,
            error.ReadFailed => {
                if (stdin_reader.err.? == error.Canceled) return error.Canceled;
                panic("failed to read from stdin: {t}", .{stdin_reader.err.?});
            },
            error.EndOfStream => @panic("unexpected end of stdin"),
        }
    }

    fn inputPollerInner() (Io.Cancelable || Io.Reader.Error) {
        @disableInstrumentation();
        const server = fuzz_runner.server;
        var large_bytes_list: std.ArrayList(u8) = .empty;
        defer large_bytes_list.deinit(fuzz_runner.gpa);
        while (true) {
            const hdr = try server.receiveMessage();
            if (hdr.tag != .new_fuzz_input) {
                panic("unexpected message: {x}\n", .{@intFromEnum(hdr.tag)});
            }
            const test_i = try server.receiveBody_u32();
            const input_len = hdr.bytes_len - 4;
            const bytes = if (input_len <= server.in.buffer.len)
                try server.in.take(input_len)
            else bytes: {
                large_bytes_list.resize(fuzz_runner.gpa, @intCast(input_len)) catch @panic("OOM");
                try server.in.readSliceAll(large_bytes_list.items);
                break :bytes large_bytes_list.items;
            };
            if (fuzz_abi.fuzzer_receive_input(test_i, .fromSlice(bytes))) {
                return error.Canceled;
            }
        }
    }
} else void = undefined;

pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), *std.testing.Smith) anyerror!void,
    options: testing.FuzzInputOptions,
) anyerror!void {
    // Prevent this function from confusing the fuzzer by omitting its own code
    // coverage from being considered.
    @disableInstrumentation();

    // Some compiler backends are not capable of handling fuzz testing yet but
    // we still want CI test coverage enabled.
    if (need_simple) return;

    // Smoke test to ensure the test did not use conditional compilation to
    // contradict itself by making it not actually be a fuzz test when the test
    // is built in fuzz mode.
    is_fuzz_test = true;

    // Ensure no test failure occurred before starting fuzzing.
    if (log_err_count != 0) @panic("error logs detected");

    // libfuzzer is in a separate compilation unit so that its own code can be
    // excluded from code coverage instrumentation. It needs a function pointer
    // it can call for checking exactly one input. Inside this function we do
    // our standard unit test checks such as memory leaks, and interaction with
    // error logs.
    const global = struct {
        var ctx: @TypeOf(context) = undefined;

        fn test_one() callconv(.c) bool {
            @disableInstrumentation();
            testing.allocator_instance = .{};
            defer if (testing.allocator_instance.deinit() == .leak) std.process.exit(1);
            log_err_count = 0;
            testOne(ctx, @constCast(&testing.Smith{ .in = null })) catch |err| switch (err) {
                error.SkipZigTest => return true,
                else => {
                    const stderr = std.debug.lockStderr(&.{}).terminal();
                    p: {
                        if (@errorReturnTrace()) |trace| {
                            std.debug.writeErrorReturnTrace(trace, stderr) catch break :p;
                        }
                        stderr.writer.print("failed with error.{t}\n", .{err}) catch break :p;
                    }
                    std.process.exit(1);
                },
            };
            if (log_err_count != 0) {
                const stderr = std.debug.lockStderr(&.{}).terminal();
                stderr.writer.print("error logs detected\n", .{}) catch {};
                std.process.exit(1);
            }
            return false;
        }
    };

    if (builtin.fuzz) {
        // Preserve the calling test's allocator state
        const prev_allocator_state = testing.allocator_instance;
        testing.allocator_instance = .{};
        defer testing.allocator_instance = prev_allocator_state;

        global.ctx = context;
        fuzz_abi.fuzzer_set_test(&global.test_one);
        for (options.corpus) |elem|
            fuzz_abi.fuzzer_new_input(.fromSlice(elem));
        fuzz_abi.fuzzer_start_test();
        return;
    }

    // When the unit test executable is not built in fuzz mode, only run the
    // provided corpus.
    for (options.corpus) |input| {
        var smith: testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }

    // In case there is no provided corpus, also use an empty
    // string as a smoke test.
    var smith: testing.Smith = .{ .in = "" };
    try testOne(context, &smith);
}
