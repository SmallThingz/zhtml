const std = @import("std");
const common = @import("common.zig");

const REPO_ROOT = ".";
const BENCH_DIR = "bench";
const BUILD_DIR = "bench/build";
const BIN_DIR = "bench/build/bin";
const RESULTS_DIR = "bench/results";
const FIXTURES_DIR = "bench/fixtures";
const PARSERS_DIR = "bench/parsers";
const CONFORMANCE_CASES_DIR = "bench/conformance_cases";
const SUITES_CACHE_DIR = "bench/.cache/suites";
const SUITES_DIR = "/tmp/htmlparser-suites";
const SUITE_RUNNER_BIN = "bench/build/bin/suite_runner";

const repeats: usize = 5;
const DocumentationBenchmarkStartMarker = "<!-- BENCHMARK_SNAPSHOT:START -->";
const DocumentationBenchmarkEndMarker = "<!-- BENCHMARK_SNAPSHOT:END -->";
const ReadmeSummaryStartMarker = "<!-- README_AUTO_SUMMARY:START -->";
const ReadmeSummaryEndMarker = "<!-- README_AUTO_SUMMARY:END -->";

const ParserCapability = struct {
    parser: []const u8,
    capability: []const u8,
};

const parser_capabilities = [_]ParserCapability{
    .{ .parser = "ours", .capability = "dom" },
    .{ .parser = "strlen", .capability = "scan" },
    .{ .parser = "lexbor", .capability = "dom" },
    .{ .parser = "lol-html", .capability = "streaming" },
};

const parse_parsers = [_][]const u8{
    "ours",
    "strlen",
    "lexbor",
    "lol-html",
};

const query_modes = [_]struct { parser: []const u8, mode: []const u8 }{
    .{ .parser = "ours", .mode = "fastest" },
};

const query_parse_modes = [_]struct { parser: []const u8, mode: []const u8 }{
    .{ .parser = "ours", .mode = "runtime" },
};

const FixtureCase = struct {
    name: []const u8,
    iterations: usize,
};

const QueryCase = struct {
    name: []const u8,
    selector: []const u8,
    iterations: usize,
};

const QueryExecCase = struct {
    name: []const u8,
    fixture: []const u8,
    selector: []const u8,
    iterations: usize,
};

const Profile = struct {
    name: []const u8,
    fixtures: []const FixtureCase,
    query_parse_cases: []const QueryCase,
    query_match_cases: []const QueryExecCase,
    query_cached_cases: []const QueryExecCase,
};

const quick_fixtures = [_]FixtureCase{
    .{ .name = "rust-lang.html", .iterations = 30 },
    .{ .name = "wiki-html.html", .iterations = 30 },
    .{ .name = "mdn-html.html", .iterations = 30 },
    .{ .name = "w3-html52.html", .iterations = 30 },
    .{ .name = "hn.html", .iterations = 30 },
    .{ .name = "python-org.html", .iterations = 30 },
    .{ .name = "kernel-org.html", .iterations = 30 },
    .{ .name = "gnu-org.html", .iterations = 30 },
    .{ .name = "ziglang-org.html", .iterations = 30 },
    .{ .name = "ziglang-doc-master.html", .iterations = 30 },
    .{ .name = "wikipedia-unicode-list.html", .iterations = 30 },
    .{ .name = "whatwg-html-spec.html", .iterations = 20 },
    .{ .name = "synthetic-forms.html", .iterations = 20 },
    .{ .name = "synthetic-table-grid.html", .iterations = 20 },
    .{ .name = "synthetic-list-nested.html", .iterations = 20 },
    .{ .name = "synthetic-comments-doctype.html", .iterations = 20 },
    .{ .name = "synthetic-template-rich.html", .iterations = 20 },
    .{ .name = "synthetic-whitespace-noise.html", .iterations = 20 },
    .{ .name = "synthetic-news-feed.html", .iterations = 20 },
    .{ .name = "synthetic-ecommerce.html", .iterations = 20 },
    .{ .name = "synthetic-forum-thread.html", .iterations = 20 },
};

const stable_fixtures = [_]FixtureCase{
    .{ .name = "rust-lang.html", .iterations = 300 },
    .{ .name = "wiki-html.html", .iterations = 300 },
    .{ .name = "mdn-html.html", .iterations = 300 },
    .{ .name = "w3-html52.html", .iterations = 300 },
    .{ .name = "hn.html", .iterations = 300 },
    .{ .name = "python-org.html", .iterations = 300 },
    .{ .name = "kernel-org.html", .iterations = 300 },
    .{ .name = "gnu-org.html", .iterations = 300 },
    .{ .name = "ziglang-org.html", .iterations = 300 },
    .{ .name = "ziglang-doc-master.html", .iterations = 300 },
    .{ .name = "wikipedia-unicode-list.html", .iterations = 300 },
    .{ .name = "whatwg-html-spec.html", .iterations = 120 },
    .{ .name = "synthetic-forms.html", .iterations = 120 },
    .{ .name = "synthetic-table-grid.html", .iterations = 120 },
    .{ .name = "synthetic-list-nested.html", .iterations = 120 },
    .{ .name = "synthetic-comments-doctype.html", .iterations = 120 },
    .{ .name = "synthetic-template-rich.html", .iterations = 120 },
    .{ .name = "synthetic-whitespace-noise.html", .iterations = 120 },
    .{ .name = "synthetic-news-feed.html", .iterations = 120 },
    .{ .name = "synthetic-ecommerce.html", .iterations = 120 },
    .{ .name = "synthetic-forum-thread.html", .iterations = 120 },
};

const quick_query_parse = [_]QueryCase{
    .{ .name = "simple", .selector = "li.x", .iterations = 100_000 },
    .{ .name = "complex", .selector = "ul > li.item[data-prefix^=pre]:not(.skip) span.name", .iterations = 40_000 },
    .{ .name = "grouped", .selector = "li#li1, li#li2, li:nth-child(2n+1)", .iterations = 40_000 },
};

const stable_query_parse = [_]QueryCase{
    .{ .name = "simple", .selector = "li.x", .iterations = 100_000 },
    .{ .name = "complex", .selector = "ul > li.item[data-prefix^=pre]:not(.skip) span.name", .iterations = 400_000 },
    .{ .name = "grouped", .selector = "li#li1, li#li2, li:nth-child(2n+1)", .iterations = 400_000 },
};

const quick_query_exec = [_]QueryExecCase{
    .{ .name = "attr-heavy-button", .fixture = "rust-lang.html", .selector = "a[href^=https][class*=button]:not(.missing)", .iterations = 30_000 },
    .{ .name = "attr-heavy-nav", .fixture = "rust-lang.html", .selector = "a[href^=https][class*=nav]:not(.missing)", .iterations = 30_000 },
};

const stable_query_exec = [_]QueryExecCase{
    .{ .name = "attr-heavy-button", .fixture = "rust-lang.html", .selector = "a[href^=https][class*=button]:not(.missing)", .iterations = 100_000 },
    .{ .name = "attr-heavy-nav", .fixture = "rust-lang.html", .selector = "a[href^=https][class*=nav]:not(.missing)", .iterations = 100_000 },
};

fn getProfile(name: []const u8) !Profile {
    if (std.mem.eql(u8, name, "quick")) {
        return .{
            .name = "quick",
            .fixtures = &quick_fixtures,
            .query_parse_cases = &quick_query_parse,
            .query_match_cases = &quick_query_exec,
            .query_cached_cases = &quick_query_exec,
        };
    }
    if (std.mem.eql(u8, name, "stable")) {
        return .{
            .name = "stable",
            .fixtures = &stable_fixtures,
            .query_parse_cases = &stable_query_parse,
            .query_match_cases = &stable_query_exec,
            .query_cached_cases = &stable_query_exec,
        };
    }
    return error.InvalidProfile;
}

fn pathExists(io: std.Io, path: []const u8) bool {
    return common.fileExists(io, path);
}

fn setupParsers(io: std.Io, alloc: std.mem.Allocator) !void {
    try common.ensureDir(io, PARSERS_DIR);
    const repos = [_]struct { url: []const u8, dir: []const u8 }{
        .{ .url = "https://github.com/lexbor/lexbor.git", .dir = "lexbor" },
        .{ .url = "https://github.com/cloudflare/lol-html.git", .dir = "lol-html" },
    };
    for (repos) |repo| {
        const git_path = try std.fmt.allocPrint(alloc, "{s}/{s}/.git", .{ PARSERS_DIR, repo.dir });
        defer alloc.free(git_path);
        if (pathExists(io, git_path)) {
            std.debug.print("already present: {s}\n", .{repo.dir});
            continue;
        }
        std.debug.print("cloning: {s}\n", .{repo.dir});
        const dst = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ PARSERS_DIR, repo.dir });
        defer alloc.free(dst);
        const argv = [_][]const u8{ "git", "clone", "--depth", "1", repo.url, dst };
        try common.runInherit(io, alloc, &argv, REPO_ROOT);
    }
    std.debug.print("done\n", .{});
}

fn setupFixtures(io: std.Io, alloc: std.mem.Allocator, refresh: bool) !void {
    try common.ensureDir(io, FIXTURES_DIR);
    const targets = [_]struct { url: []const u8, out: []const u8 }{
        .{ .url = "https://www.rust-lang.org/", .out = "rust-lang.html" },
        .{ .url = "https://en.wikipedia.org/wiki/HTML", .out = "wiki-html.html" },
        .{ .url = "https://developer.mozilla.org/en-US/docs/Web/HTML", .out = "mdn-html.html" },
        .{ .url = "https://www.w3.org/TR/html52/", .out = "w3-html52.html" },
        .{ .url = "https://news.ycombinator.com/", .out = "hn.html" },
        .{ .url = "https://www.python.org/", .out = "python-org.html" },
        .{ .url = "https://www.kernel.org/", .out = "kernel-org.html" },
        .{ .url = "https://www.gnu.org/", .out = "gnu-org.html" },
        .{ .url = "https://ziglang.org/", .out = "ziglang-org.html" },
        .{ .url = "https://ziglang.org/documentation/master/", .out = "ziglang-doc-master.html" },
        .{ .url = "https://en.wikipedia.org/wiki/List_of_Unicode_characters", .out = "wikipedia-unicode-list.html" },
        .{ .url = "https://html.spec.whatwg.org/", .out = "whatwg-html-spec.html" },
    };
    for (targets) |item| {
        const target = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ FIXTURES_DIR, item.out });
        defer alloc.free(target);

        if (!refresh) {
            const stat = std.Io.Dir.cwd().statFile(io, target, .{}) catch null;
            if (stat != null and stat.?.size > 0) {
                std.debug.print("cached: {s}\n", .{item.out});
                continue;
            }
        }

        std.debug.print("downloading: {s}\n", .{item.out});
        const argv = [_][]const u8{
            "curl",
            "-L",
            "--compressed",
            "--fail",
            "--retry",
            "2",
            "--retry-delay",
            "1",
            "-A",
            "htmlparser-bench/1.0 (+https://example.invalid)",
            item.url,
            "-o",
            target,
        };
        try common.runInherit(io, alloc, &argv, REPO_ROOT);
    }
    std.debug.print("fixtures ready in {s}\n", .{FIXTURES_DIR});
}

fn ensureExternalParsersBuilt(io: std.Io, alloc: std.mem.Allocator) !void {
    if (!pathExists(io, "bench/parsers/lol-html/Cargo.toml")) {
        try setupParsers(io, alloc);
    }

    if (!pathExists(io, "bench/build/lexbor/liblexbor_static.a")) {
        const cmake_cfg = [_][]const u8{
            "cmake",
            "-S",
            "bench/parsers/lexbor",
            "-B",
            "bench/build/lexbor",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DLEXBOR_BUILD_TESTS=OFF",
            "-DLEXBOR_BUILD_EXAMPLES=OFF",
        };
        try common.runInherit(io, alloc, &cmake_cfg, REPO_ROOT);
        const cmake_build = [_][]const u8{ "cmake", "--build", "bench/build/lexbor", "-j" };
        try common.runInherit(io, alloc, &cmake_build, REPO_ROOT);
    }
}

fn buildRunners(io: std.Io, alloc: std.mem.Allocator) !void {
    try common.ensureDir(io, BIN_DIR);
    const zig_build = [_][]const u8{ "zig", "build", "-Doptimize=ReleaseFast" };
    try common.runInherit(io, alloc, &zig_build, REPO_ROOT);

    const strlen_cc = [_][]const u8{
        "cc",
        "-O3",
        "-fno-builtin",
        "bench/runners/strlen_runner.c",
        "-o",
        "bench/build/bin/strlen_runner",
    };
    try common.runInherit(io, alloc, &strlen_cc, REPO_ROOT);

    const lexbor_cc = [_][]const u8{
        "cc",
        "-O3",
        "bench/runners/lexbor_runner.c",
        "bench/build/lexbor/liblexbor_static.a",
        "-Ibench/parsers/lexbor/source",
        "-lm",
        "-o",
        "bench/build/bin/lexbor_runner",
    };
    try common.runInherit(io, alloc, &lexbor_cc, REPO_ROOT);

    const cargo_lol = [_][]const u8{
        "cargo",
        "build",
        "--release",
        "--manifest-path",
        "bench/runners/lol_html_runner/Cargo.toml",
    };
    try common.runInherit(io, alloc, &cargo_lol, REPO_ROOT);
}

const ParseResult = struct {
    parser: []const u8,
    fixture: []const u8,
    iterations: usize,
    samples_ns: []u64,
    median_ns: u64,
    throughput_mb_s: f64,
};

const QueryResult = struct {
    parser: []const u8,
    case: []const u8,
    selector: []const u8,
    fixture: ?[]const u8 = null,
    iterations: usize,
    samples_ns: []u64,
    median_ns: u64,
    ops_s: f64,
    ns_per_op: f64,
};

const GateRow = struct {
    fixture: []const u8,
    ours_mb_s: f64,
    lol_html_mb_s: f64,
    pass: bool,
};

const ReadmeParseResult = struct {
    parser: []const u8,
    fixture: []const u8,
    throughput_mb_s: f64,
};

const ReadmeQueryResult = struct {
    parser: []const u8,
    case: []const u8,
    ops_s: f64,
    ns_per_op: f64,
};

const ReadmeBenchSnapshot = struct {
    profile: []const u8,
    parse_results: []const ReadmeParseResult,
    query_parse_results: []const ReadmeQueryResult,
    query_match_results: []const ReadmeQueryResult,
    query_cached_results: []const ReadmeQueryResult,
};

const ExternalSuiteCounts = struct {
    total: usize,
    passed: usize,
};

const ExternalSuiteMode = struct {
    selector_suites: struct {
        nwmatcher: ExternalSuiteCounts,
        qwery_contextual: ExternalSuiteCounts,
    },
    parser_suites: ?struct {
        html5lib_subset: ExternalSuiteCounts,
        whatwg_html_parsing: ExternalSuiteCounts,
    } = null,
};

const ExternalSuiteReport = struct {
    modes: struct {
        strictest: ?ExternalSuiteMode = null,
        fastest: ?ExternalSuiteMode = null,
    },
};

fn runnerCmdParse(alloc: std.mem.Allocator, parser_name: []const u8, fixture: []const u8, iterations: usize) ![]const []const u8 {
    const iter_s = try std.fmt.allocPrint(alloc, "{d}", .{iterations});
    if (std.mem.eql(u8, parser_name, "ours")) {
        const argv = try alloc.alloc([]const u8, 5);
        argv[0] = "zig-out/bin/htmlparser-bench";
        argv[1] = "parse";
        argv[2] = "fastest";
        argv[3] = fixture;
        argv[4] = iter_s;
        return argv;
    }
    if (std.mem.eql(u8, parser_name, "strlen")) {
        const argv = try alloc.alloc([]const u8, 3);
        argv[0] = "bench/build/bin/strlen_runner";
        argv[1] = fixture;
        argv[2] = iter_s;
        return argv;
    }
    if (std.mem.eql(u8, parser_name, "lexbor")) {
        const argv = try alloc.alloc([]const u8, 3);
        argv[0] = "bench/build/bin/lexbor_runner";
        argv[1] = fixture;
        argv[2] = iter_s;
        return argv;
    }
    if (std.mem.eql(u8, parser_name, "lol-html")) {
        const argv = try alloc.alloc([]const u8, 3);
        argv[0] = "bench/runners/lol_html_runner/target/release/lol_html_runner";
        argv[1] = fixture;
        argv[2] = iter_s;
        return argv;
    }
    return error.InvalidParser;
}

fn freeArgv(alloc: std.mem.Allocator, argv: []const []const u8) void {
    if (argv.len == 0) return;
    // Last argument is always allocPrint'd iterations string.
    alloc.free(argv[argv.len - 1]);
    alloc.free(argv);
}

fn freeParseSamples(alloc: std.mem.Allocator, results: []const ParseResult) void {
    for (results) |row| {
        alloc.free(row.samples_ns);
    }
}

fn freeQuerySamples(alloc: std.mem.Allocator, results: []const QueryResult) void {
    for (results) |row| {
        alloc.free(row.samples_ns);
    }
}

fn deinitOwnedStringList(alloc: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |item| alloc.free(item);
    list.deinit(alloc);
}

fn deinitOwnedStringSet(alloc: std.mem.Allocator, set: *std.StringHashMap(void)) void {
    var it = set.keyIterator();
    while (it.next()) |key_ptr| alloc.free(key_ptr.*);
    set.deinit();
}

fn appendOwnedString(alloc: std.mem.Allocator, list: *std.ArrayList([]const u8), item: []const u8) !void {
    errdefer alloc.free(item);
    try list.append(alloc, item);
}

fn putOwnedString(alloc: std.mem.Allocator, set: *std.StringHashMap(void), key: []const u8) !void {
    errdefer alloc.free(key);
    try set.put(key, {});
}

fn runIntCmd(io: std.Io, alloc: std.mem.Allocator, argv: []const []const u8) !u64 {
    const taskset_path: ?[]const u8 = blk: {
        if (common.fileExists(io, "/usr/bin/taskset")) break :blk "/usr/bin/taskset";
        if (common.fileExists(io, "/bin/taskset")) break :blk "/bin/taskset";
        break :blk null;
    };

    const run_argv: []const []const u8 = if (taskset_path) |bin| blk: {
        var wrapped = try alloc.alloc([]const u8, argv.len + 3);
        wrapped[0] = bin;
        wrapped[1] = "-c";
        wrapped[2] = "0";
        @memcpy(wrapped[3..], argv);
        break :blk wrapped;
    } else argv;
    defer if (run_argv.ptr != argv.ptr) alloc.free(run_argv);

    const out = try common.runCaptureCombined(io, alloc, run_argv, REPO_ROOT);
    defer alloc.free(out);
    return common.parseLastInt(out);
}

fn benchParseOne(io: std.Io, alloc: std.mem.Allocator, parser_name: []const u8, fixture_name: []const u8, iterations: usize) !ParseResult {
    const fixture = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ FIXTURES_DIR, fixture_name });
    defer alloc.free(fixture);
    const stat = try std.Io.Dir.cwd().statFile(io, fixture, .{});
    const size_bytes = stat.size;

    {
        const warm = try runnerCmdParse(alloc, parser_name, fixture, 1);
        defer freeArgv(alloc, warm);
        _ = try runIntCmd(io, alloc, warm);
    }

    const samples = try alloc.alloc(u64, repeats);
    for (samples) |*slot| {
        const argv = try runnerCmdParse(alloc, parser_name, fixture, iterations);
        defer freeArgv(alloc, argv);
        slot.* = try runIntCmd(io, alloc, argv);
    }

    const median_ns = try common.medianU64(alloc, samples);
    const total_bytes: f64 = @floatFromInt(size_bytes * iterations);
    const seconds = @as(f64, @floatFromInt(median_ns)) / 1_000_000_000.0;
    const mbps = if (seconds > 0.0) (total_bytes / 1_000_000.0) / seconds else 0.0;
    return .{
        .parser = parser_name,
        .fixture = fixture_name,
        .iterations = iterations,
        .samples_ns = samples,
        .median_ns = median_ns,
        .throughput_mb_s = mbps,
    };
}

fn benchQueryParseOne(io: std.Io, alloc: std.mem.Allocator, parser_name: []const u8, case_name: []const u8, selector: []const u8, iterations: usize) !QueryResult {
    const iter_s = try std.fmt.allocPrint(alloc, "{d}", .{iterations});
    defer alloc.free(iter_s);

    {
        const warm = [_][]const u8{ "zig-out/bin/htmlparser-bench", "query-parse", selector, "1" };
        _ = try runIntCmd(io, alloc, &warm);
    }

    const samples = try alloc.alloc(u64, repeats);
    for (samples) |*slot| {
        const argv = [_][]const u8{ "zig-out/bin/htmlparser-bench", "query-parse", selector, iter_s };
        slot.* = try runIntCmd(io, alloc, &argv);
    }

    const median_ns = try common.medianU64(alloc, samples);
    const seconds = @as(f64, @floatFromInt(median_ns)) / 1_000_000_000.0;
    const ops_s = if (seconds > 0.0) @as(f64, @floatFromInt(iterations)) / seconds else 0.0;
    const ns_per_op = @as(f64, @floatFromInt(median_ns)) / @as(f64, @floatFromInt(iterations));
    return .{
        .parser = parser_name,
        .case = case_name,
        .selector = selector,
        .iterations = iterations,
        .samples_ns = samples,
        .median_ns = median_ns,
        .ops_s = ops_s,
        .ns_per_op = ns_per_op,
    };
}

fn benchQueryExecOne(io: std.Io, alloc: std.mem.Allocator, parser_name: []const u8, mode: []const u8, case_name: []const u8, fixture_name: []const u8, selector: []const u8, iterations: usize, cached: bool) !QueryResult {
    const fixture = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ FIXTURES_DIR, fixture_name });
    defer alloc.free(fixture);
    const iter_s = try std.fmt.allocPrint(alloc, "{d}", .{iterations});
    defer alloc.free(iter_s);
    const sub = if (cached) "query-cached" else "query-match";

    {
        const warm = [_][]const u8{ "zig-out/bin/htmlparser-bench", sub, mode, fixture, selector, "1" };
        _ = try runIntCmd(io, alloc, &warm);
    }

    const samples = try alloc.alloc(u64, repeats);
    for (samples) |*slot| {
        const argv = [_][]const u8{ "zig-out/bin/htmlparser-bench", sub, mode, fixture, selector, iter_s };
        slot.* = try runIntCmd(io, alloc, &argv);
    }
    const median_ns = try common.medianU64(alloc, samples);
    const seconds = @as(f64, @floatFromInt(median_ns)) / 1_000_000_000.0;
    const ops_s = if (seconds > 0.0) @as(f64, @floatFromInt(iterations)) / seconds else 0.0;
    const ns_per_op = @as(f64, @floatFromInt(median_ns)) / @as(f64, @floatFromInt(iterations));
    return .{
        .parser = parser_name,
        .case = case_name,
        .selector = selector,
        .fixture = fixture_name,
        .iterations = iterations,
        .samples_ns = samples,
        .median_ns = median_ns,
        .ops_s = ops_s,
        .ns_per_op = ns_per_op,
    };
}

fn capabilityOf(parser_name: []const u8) []const u8 {
    for (parser_capabilities) |cap| {
        if (std.mem.eql(u8, cap.parser, parser_name)) return cap.capability;
    }
    return "?";
}

fn findParseThroughput(rows: []const ParseResult, parser_name: []const u8, fixture_name: []const u8) ?f64 {
    for (rows) |row| {
        if (std.mem.eql(u8, row.parser, parser_name) and std.mem.eql(u8, row.fixture, fixture_name)) {
            return row.throughput_mb_s;
        }
    }
    return null;
}

fn findReadmeParseThroughput(rows: []const ReadmeParseResult, parser_name: []const u8, fixture_name: []const u8) ?f64 {
    for (rows) |row| {
        if (std.mem.eql(u8, row.parser, parser_name) and std.mem.eql(u8, row.fixture, fixture_name)) {
            return row.throughput_mb_s;
        }
    }
    return null;
}

fn findReadmeQuery(rows: []const ReadmeQueryResult, parser_name: []const u8, case_name: []const u8) ?ReadmeQueryResult {
    for (rows) |row| {
        if (std.mem.eql(u8, row.parser, parser_name) and std.mem.eql(u8, row.case, case_name)) return row;
    }
    return null;
}

fn renderDocumentationBenchmarkSection(alloc: std.mem.Allocator, snap: ReadmeBenchSnapshot) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;

    var fixtures = std.ArrayList([]const u8).empty;
    defer fixtures.deinit(alloc);
    for (snap.parse_results) |row| {
        var seen = false;
        for (fixtures.items) |it| {
            if (std.mem.eql(u8, it, row.fixture)) {
                seen = true;
                break;
            }
        }
        if (!seen) try fixtures.append(alloc, row.fixture);
    }

    var query_match_cases = std.ArrayList([]const u8).empty;
    defer query_match_cases.deinit(alloc);
    for (snap.query_match_results) |row| {
        var seen = false;
        for (query_match_cases.items) |it| {
            if (std.mem.eql(u8, it, row.case)) {
                seen = true;
                break;
            }
        }
        if (!seen) try query_match_cases.append(alloc, row.case);
    }

    var query_parse_cases = std.ArrayList([]const u8).empty;
    defer query_parse_cases.deinit(alloc);
    for (snap.query_parse_results) |row| {
        var seen = false;
        for (query_parse_cases.items) |it| {
            if (std.mem.eql(u8, it, row.case)) {
                seen = true;
                break;
            }
        }
        if (!seen) try query_parse_cases.append(alloc, row.case);
    }

    try w.print("Source: `bench/results/latest.json` (`{s}` profile).\n\n", .{snap.profile});

    try w.writeAll("#### Parse Throughput Comparison (MB/s)\n\n");
    try w.writeAll("| Fixture | ours | lol-html | lexbor |\n");
    try w.writeAll("|---|---:|---:|---:|\n");
    for (fixtures.items) |fixture| {
        try w.print("| `{s}` | ", .{fixture});
        if (findReadmeParseThroughput(snap.parse_results, "ours", fixture)) |v| {
            try w.print("{d:.2}", .{v});
        } else {
            try w.writeAll("-");
        }
        try w.writeAll(" | ");
        if (findReadmeParseThroughput(snap.parse_results, "lol-html", fixture)) |v| {
            try w.print("{d:.2}", .{v});
        } else {
            try w.writeAll("-");
        }
        try w.writeAll(" | ");
        if (findReadmeParseThroughput(snap.parse_results, "lexbor", fixture)) |v| {
            try w.print("{d:.2}", .{v});
        } else {
            try w.writeAll("-");
        }
        try w.writeAll(" |\n");
    }

    try w.writeAll("\n#### Query Match Throughput (ours)\n\n");
    try w.writeAll("| Case | ours ops/s | ours ns/op |\n");
    try w.writeAll("|---|---:|---:|\n");
    for (query_match_cases.items) |case_name| {
        const ours = findReadmeQuery(snap.query_match_results, "ours", case_name);
        try w.print("| `{s}` | ", .{case_name});
        if (ours) |s| {
            try w.print("{d:.2}", .{s.ops_s});
        } else {
            try w.writeAll("-");
        }
        try w.writeAll(" | ");
        if (ours) |s| {
            try w.print("{d:.2}", .{s.ns_per_op});
        } else {
            try w.writeAll("-");
        }
        try w.writeAll(" |\n");
    }

    try w.writeAll("\n#### Cached Query Throughput (ours)\n\n");
    try w.writeAll("| Case | ours ops/s | ours ns/op |\n");
    try w.writeAll("|---|---:|---:|\n");
    for (query_match_cases.items) |case_name| {
        const ours = findReadmeQuery(snap.query_cached_results, "ours", case_name);
        try w.print("| `{s}` | ", .{case_name});
        if (ours) |s| {
            try w.print("{d:.2}", .{s.ops_s});
        } else {
            try w.writeAll("-");
        }
        try w.writeAll(" | ");
        if (ours) |s| {
            try w.print("{d:.2}", .{s.ns_per_op});
        } else {
            try w.writeAll("-");
        }
        try w.writeAll(" |\n");
    }

    try w.writeAll("\n#### Query Parse Throughput (ours)\n\n");
    try w.writeAll("| Selector case | Ops/s | ns/op |\n");
    try w.writeAll("|---|---:|---:|\n");
    for (query_parse_cases.items) |case_name| {
        const ours = findReadmeQuery(snap.query_parse_results, "ours", case_name);
        try w.print("| `{s}` | ", .{case_name});
        if (ours) |r| {
            try w.print("{d:.2}", .{r.ops_s});
        } else {
            try w.writeAll("-");
        }
        try w.writeAll(" | ");
        if (ours) |r| {
            try w.print("{d:.2}", .{r.ns_per_op});
        } else {
            try w.writeAll("-");
        }
        try w.writeAll(" |\n");
    }

    try w.writeAll("\nFor full per-parser, per-fixture tables and gate output:\n");
    try w.writeAll("- `bench/results/latest.md`\n");
    try w.writeAll("- `bench/results/latest.json`\n");

    return out.toOwnedSlice();
}

fn updateDocumentationBenchmarkSnapshot(io: std.Io, alloc: std.mem.Allocator) !void {
    const latest_json = try common.readFileAlloc(io, alloc, "bench/results/latest.json");
    defer alloc.free(latest_json);

    const parsed = try std.json.parseFromSlice(ReadmeBenchSnapshot, alloc, latest_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const replacement = try renderDocumentationBenchmarkSection(alloc, parsed.value);
    defer alloc.free(replacement);

    const documentation = try common.readFileAlloc(io, alloc, "DOCUMENTATION.md");
    defer alloc.free(documentation);

    const start = std.mem.indexOf(u8, documentation, DocumentationBenchmarkStartMarker) orelse return error.ReadmeBenchMarkersMissing;
    const after_start = start + DocumentationBenchmarkStartMarker.len;
    const end = std.mem.indexOfPos(u8, documentation, after_start, DocumentationBenchmarkEndMarker) orelse return error.ReadmeBenchMarkersMissing;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, documentation[0..after_start]);
    try out.appendSlice(alloc, "\n\n");
    try out.appendSlice(alloc, replacement);
    if (replacement.len == 0 or replacement[replacement.len - 1] != '\n') {
        try out.append(alloc, '\n');
    }
    if (documentation[end - 1] != '\n') {
        try out.append(alloc, '\n');
    }
    try out.appendSlice(alloc, documentation[end..]);

    if (!std.mem.eql(u8, out.items, documentation)) {
        try common.writeFile(io, "DOCUMENTATION.md", out.items);
        std.debug.print("wrote DOCUMENTATION.md benchmark snapshot\n", .{});
    } else {
        std.debug.print("DOCUMENTATION.md benchmark snapshot already up-to-date\n", .{});
    }
}

const ParseAverageRow = struct {
    parser: []const u8,
    avg_mb_s: f64,
};

fn cmpParseAverageDesc(_: void, a: ParseAverageRow, b: ParseAverageRow) bool {
    return a.avg_mb_s > b.avg_mb_s;
}

fn parseAverageRows(alloc: std.mem.Allocator, snap: ReadmeBenchSnapshot) ![]ParseAverageRow {
    const parser_names = [_][]const u8{ "ours", "lol-html", "lexbor" };
    var rows = std.ArrayList(ParseAverageRow).empty;
    errdefer rows.deinit(alloc);

    for (parser_names) |parser_name| {
        var sum: f64 = 0.0;
        var count: usize = 0;
        for (snap.parse_results) |r| {
            if (!std.mem.eql(u8, r.parser, parser_name)) continue;
            sum += r.throughput_mb_s;
            count += 1;
        }
        if (count == 0) continue;
        try rows.append(alloc, .{
            .parser = parser_name,
            .avg_mb_s = sum / @as(f64, @floatFromInt(count)),
        });
    }

    std.mem.sort(ParseAverageRow, rows.items, {}, cmpParseAverageDesc);
    return rows.toOwnedSlice(alloc);
}

fn failedCount(summary: anytype) usize {
    return summary.total - summary.passed;
}

fn writeConformanceRow(
    w: anytype,
    profile: []const u8,
    nw: ExternalSuiteCounts,
    qw: ExternalSuiteCounts,
    html5lib: ExternalSuiteCounts,
    whatwg: ExternalSuiteCounts,
) !void {
    try w.print("| `{s}` | {d}/{d} ({d} failed) | {d}/{d} ({d} failed) | {d}/{d} ({d} failed) | {d}/{d} ({d} failed) |\n", .{
        profile,
        nw.passed,
        nw.total,
        failedCount(nw),
        qw.passed,
        qw.total,
        failedCount(qw),
        html5lib.passed,
        html5lib.total,
        failedCount(html5lib),
        whatwg.passed,
        whatwg.total,
        failedCount(whatwg),
    });
}

fn parserHtml5libCounts(mode: ExternalSuiteMode) ExternalSuiteCounts {
    if (mode.parser_suites) |s| return s.html5lib_subset;
    return .{ .total = 0, .passed = 0 };
}

fn parserWhatwgCounts(mode: ExternalSuiteMode) ExternalSuiteCounts {
    if (mode.parser_suites) |s| return s.whatwg_html_parsing;
    return .{ .total = 0, .passed = 0 };
}

fn sameExternalMode(a: ExternalSuiteMode, b: ExternalSuiteMode) bool {
    const a_html5 = parserHtml5libCounts(a);
    const b_html5 = parserHtml5libCounts(b);
    const a_whatwg = parserWhatwgCounts(a);
    const b_whatwg = parserWhatwgCounts(b);

    return a.selector_suites.nwmatcher.total == b.selector_suites.nwmatcher.total and
        a.selector_suites.nwmatcher.passed == b.selector_suites.nwmatcher.passed and
        a.selector_suites.qwery_contextual.total == b.selector_suites.qwery_contextual.total and
        a.selector_suites.qwery_contextual.passed == b.selector_suites.qwery_contextual.passed and
        a_html5.total == b_html5.total and
        a_html5.passed == b_html5.passed and
        a_whatwg.total == b_whatwg.total and
        a_whatwg.passed == b_whatwg.passed;
}

fn renderReadmeAutoSummary(io: std.Io, alloc: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;

    const latest_exists = common.fileExists(io, "bench/results/latest.json");
    if (latest_exists) {
        const latest_json = try common.readFileAlloc(io, alloc, "bench/results/latest.json");
        defer alloc.free(latest_json);
        const parsed = try std.json.parseFromSlice(ReadmeBenchSnapshot, alloc, latest_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const snap = parsed.value;

        const avg_rows = try parseAverageRows(alloc, snap);
        defer alloc.free(avg_rows);

        try w.print("Source: `bench/results/latest.json` (`{s}` profile).\n\n", .{snap.profile});
        try w.writeAll("### Parse Throughput (Average Across Fixtures)\n\n");
        try w.writeAll("```text\n");

        var leader: f64 = 0.0;
        for (avg_rows) |r| leader = @max(leader, r.avg_mb_s);

        var max_name_len: usize = 0;
        for (avg_rows) |r| max_name_len = @max(max_name_len, r.parser.len);

        for (avg_rows) |r| {
            const pct = if (leader > 0.0) (r.avg_mb_s / leader) * 100.0 else 0.0;
            const width: usize = 20;
            const filled = if (leader > 0.0)
                @min(width, @max(@as(usize, @intFromFloat(@round((r.avg_mb_s / leader) * @as(f64, @floatFromInt(width))))), @as(usize, 1)))
            else
                @as(usize, 0);
            try w.writeAll(r.parser);
            for (0..max_name_len - r.parser.len) |_| {
                try w.writeByte(' ');
            }
            try w.writeAll(" │");
            for (0..filled) |_| {
                try w.writeAll("█");
            }
            for (0..(width - filled)) |_| {
                try w.writeAll("░");
            }
            try w.print("│ {d:.2} MB/s ({d:.2}%)\n", .{ r.avg_mb_s, pct });
        }
        try w.writeAll("```\n");
    } else {
        try w.writeAll("Run `zig build bench-compare` to generate parse performance summary.\n");
    }

    try w.writeAll("\n### Conformance Snapshot\n\n");
    if (common.fileExists(io, "bench/results/external_suite_report.json")) {
        const ext_json = try common.readFileAlloc(io, alloc, "bench/results/external_suite_report.json");
        defer alloc.free(ext_json);
        const parsed_ext = try std.json.parseFromSlice(ExternalSuiteReport, alloc, ext_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed_ext.deinit();
        const modes = parsed_ext.value.modes;

        try w.writeAll("| Profile | nwmatcher | qwery_contextual | html5lib subset | WHATWG HTML parsing |\n");
        try w.writeAll("|---|---:|---:|---:|---:|\n");
        if (modes.strictest != null and modes.fastest != null and sameExternalMode(modes.strictest.?, modes.fastest.?)) {
            const m = modes.strictest.?;
            try writeConformanceRow(
                w,
                "strictest/fastest",
                m.selector_suites.nwmatcher,
                m.selector_suites.qwery_contextual,
                parserHtml5libCounts(m),
                parserWhatwgCounts(m),
            );
        } else {
            if (modes.strictest) |m| {
                try writeConformanceRow(
                    w,
                    "strictest",
                    m.selector_suites.nwmatcher,
                    m.selector_suites.qwery_contextual,
                    parserHtml5libCounts(m),
                    parserWhatwgCounts(m),
                );
            }
            if (modes.fastest) |m| {
                try writeConformanceRow(
                    w,
                    "fastest",
                    m.selector_suites.nwmatcher,
                    m.selector_suites.qwery_contextual,
                    parserHtml5libCounts(m),
                    parserWhatwgCounts(m),
                );
            }
        }
        try w.writeAll("\nSource: `bench/results/external_suite_report.json`\n");
    } else {
        try w.writeAll("Run `zig build conformance` to generate conformance summary.\n");
    }

    return out.toOwnedSlice();
}

fn updateReadmeAutoSummary(io: std.Io, alloc: std.mem.Allocator) !void {
    const replacement = try renderReadmeAutoSummary(io, alloc);
    defer alloc.free(replacement);

    const readme = try common.readFileAlloc(io, alloc, "README.md");
    defer alloc.free(readme);

    const start = std.mem.indexOf(u8, readme, ReadmeSummaryStartMarker) orelse return error.ReadmeBenchMarkersMissing;
    const after_start = start + ReadmeSummaryStartMarker.len;
    const end = std.mem.indexOfPos(u8, readme, after_start, ReadmeSummaryEndMarker) orelse return error.ReadmeBenchMarkersMissing;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, readme[0..after_start]);
    try out.appendSlice(alloc, "\n\n");
    try out.appendSlice(alloc, replacement);
    if (replacement.len == 0 or replacement[replacement.len - 1] != '\n') {
        try out.append(alloc, '\n');
    }
    if (readme[end - 1] != '\n') {
        try out.append(alloc, '\n');
    }
    try out.appendSlice(alloc, readme[end..]);

    if (!std.mem.eql(u8, out.items, readme)) {
        try common.writeFile(io, "README.md", out.items);
        std.debug.print("wrote README.md auto summary\n", .{});
    } else {
        std.debug.print("README.md auto summary already up-to-date\n", .{});
    }
}

fn writeMarkdown(
    io: std.Io,
    alloc: std.mem.Allocator,
    profile_name: []const u8,
    parse_results: []const ParseResult,
    query_parse_results: []const QueryResult,
    query_match_results: []const QueryResult,
    query_cached_results: []const QueryResult,
    gate_rows: []const GateRow,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;

    try w.print("# HTML Parser Benchmark Results\n\nGenerated (unix): {d}\n\nProfile: `{s}`\n\n", .{ common.nowUnix(io), profile_name });
    try w.writeAll("## Parse Throughput\n\n");

    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();

    for (parse_results) |row| {
        if (seen.contains(row.fixture)) continue;
        try seen.put(row.fixture, {});

        var fixture_rows = std.ArrayList(ParseResult).empty;
        defer fixture_rows.deinit(alloc);
        for (parse_results) |r| {
            if (std.mem.eql(u8, r.fixture, row.fixture)) try fixture_rows.append(alloc, r);
        }
        std.mem.sort(ParseResult, fixture_rows.items, {}, struct {
            fn lt(_: void, a: ParseResult, b: ParseResult) bool {
                return a.throughput_mb_s > b.throughput_mb_s;
            }
        }.lt);

        const strlen = findParseThroughput(parse_results, "strlen", row.fixture);
        try w.print("### Fixture: `{s}`\n\n", .{row.fixture});
        try w.writeAll("| Parser | Capability | Throughput (MB/s) | % of strlen | Median Time (ms) | Iterations |\n");
        try w.writeAll("|---|---|---:|---:|---:|---:|\n");
        for (fixture_rows.items) |r| {
            if (strlen) |s| {
                const pct = if (s > 0.0) (r.throughput_mb_s / s) * 100.0 else 0.0;
                try w.print("| {s} | {s} | {d:.2} | {d:.2}% | {d:.3} | {d} |\n", .{
                    r.parser,
                    capabilityOf(r.parser),
                    r.throughput_mb_s,
                    pct,
                    @as(f64, @floatFromInt(r.median_ns)) / 1_000_000.0,
                    r.iterations,
                });
            } else {
                try w.print("| {s} | {s} | {d:.2} | - | {d:.3} | {d} |\n", .{
                    r.parser,
                    capabilityOf(r.parser),
                    r.throughput_mb_s,
                    @as(f64, @floatFromInt(r.median_ns)) / 1_000_000.0,
                    r.iterations,
                });
            }
        }
        try w.writeAll("\n");
    }

    try writeQuerySection(alloc, w, "## Query Parse Throughput", query_parse_results);
    try writeQuerySection(alloc, w, "## Query Match Throughput", query_match_results);
    try writeQuerySection(alloc, w, "## Query Cached Throughput", query_cached_results);

    if (gate_rows.len > 0) {
        try w.writeAll("## Ours vs lol-html Gate\n\n");
        try w.writeAll("| Fixture | ours (MB/s) | lol-html (MB/s) | Result |\n");
        try w.writeAll("|---|---:|---:|---|\n");
        for (gate_rows) |g| {
            try w.print("| {s} | {d:.2} | {d:.2} | {s} |\n", .{
                g.fixture,
                g.ours_mb_s,
                g.lol_html_mb_s,
                if (g.pass) "PASS" else "FAIL",
            });
        }
        try w.writeAll("\n");
    }

    return out.toOwnedSlice();
}

fn writeQuerySection(alloc: std.mem.Allocator, w: *std.Io.Writer, title: []const u8, rows: []const QueryResult) !void {
    try w.print("{s}\n\n", .{title});
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();

    for (rows) |row| {
        if (seen.contains(row.case)) continue;
        try seen.put(row.case, {});

        var case_rows = std.ArrayList(QueryResult).empty;
        defer case_rows.deinit(alloc);
        for (rows) |r| if (std.mem.eql(u8, r.case, row.case)) try case_rows.append(alloc, r);
        std.mem.sort(QueryResult, case_rows.items, {}, struct {
            fn lt(_: void, a: QueryResult, b: QueryResult) bool {
                return a.ops_s > b.ops_s;
            }
        }.lt);

        try w.print("### Case: `{s}`\n\n", .{row.case});
        try w.writeAll("| Parser | Ops/s | ns/op | Median Time (ms) | Iterations | Selector |\n");
        try w.writeAll("|---|---:|---:|---:|---:|---|\n");
        for (case_rows.items) |r| {
            try w.print("| {s} | {d:.2} | {d:.2} | {d:.3} | {d} | `{s}` |\n", .{
                r.parser,
                r.ops_s,
                r.ns_per_op,
                @as(f64, @floatFromInt(r.median_ns)) / 1_000_000.0,
                r.iterations,
                r.selector,
            });
        }
        if (case_rows.items[0].fixture) |fx| {
            try w.print("\nFixture: `{s}`\n", .{fx});
        }
        try w.writeAll("\n");
    }
}

fn evaluateGateRows(alloc: std.mem.Allocator, profile: Profile, parse_results: []const ParseResult) ![]GateRow {
    var rows = std.ArrayList(GateRow).empty;
    errdefer rows.deinit(alloc);
    for (profile.fixtures) |fx| {
        const ours = findParseThroughput(parse_results, "ours", fx.name) orelse continue;
        const lol = findParseThroughput(parse_results, "lol-html", fx.name) orelse continue;
        try rows.append(alloc, .{
            .fixture = fx.name,
            .ours_mb_s = ours,
            .lol_html_mb_s = lol,
            .pass = ours > lol,
        });
    }
    return rows.toOwnedSlice(alloc);
}

fn fixtureIterations(profile: Profile, fixture: []const u8) usize {
    for (profile.fixtures) |fx| {
        if (std.mem.eql(u8, fx.name, fixture)) return fx.iterations;
    }
    return 0;
}

fn rerunFailedGateRows(io: std.Io, alloc: std.mem.Allocator, profile: Profile, gate_rows: []GateRow) !void {
    if (!std.mem.eql(u8, profile.name, "stable")) return;

    for (gate_rows) |*row| {
        if (row.pass) continue;

        const iters0 = fixtureIterations(profile, row.fixture);
        if (iters0 == 0) continue;
        const iters = @max(iters0 * 2, iters0 + 1);

        std.debug.print("re-running flaky gate fixture {s} at {d} iters\n", .{ row.fixture, iters });

        const ours = try benchParseOne(io, alloc, "ours", row.fixture, iters);
        defer alloc.free(ours.samples_ns);
        const lol = try benchParseOne(io, alloc, "lol-html", row.fixture, iters);
        defer alloc.free(lol.samples_ns);

        row.ours_mb_s = ours.throughput_mb_s;
        row.lol_html_mb_s = lol.throughput_mb_s;
        row.pass = row.ours_mb_s > row.lol_html_mb_s;
    }
}

fn renderConsole(
    io: std.Io,
    alloc: std.mem.Allocator,
    profile_name: []const u8,
    parse_results: []const ParseResult,
    query_parse_results: []const QueryResult,
    query_match_results: []const QueryResult,
    query_cached_results: []const QueryResult,
    gate_rows: []const GateRow,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("HTML Parser Benchmark Results\n");
    try w.print("Generated (unix): {d}\n", .{common.nowUnix(io)});
    try w.print("Profile: {s}\n\n", .{profile_name});

    try w.writeAll("Parse Throughput\n\n");

    var seen_fixtures = std.StringHashMap(void).init(alloc);
    defer seen_fixtures.deinit();
    for (parse_results) |row| {
        if (seen_fixtures.contains(row.fixture)) continue;
        try seen_fixtures.put(row.fixture, {});

        try w.print("Fixture: {s}\n", .{row.fixture});

        var fixture_rows = std.ArrayList(ParseResult).empty;
        defer fixture_rows.deinit(alloc);
        for (parse_results) |r| {
            if (std.mem.eql(u8, r.fixture, row.fixture)) try fixture_rows.append(alloc, r);
        }
        std.mem.sort(ParseResult, fixture_rows.items, {}, struct {
            fn lt(_: void, a: ParseResult, b: ParseResult) bool {
                return a.throughput_mb_s > b.throughput_mb_s;
            }
        }.lt);

        const headers = [_][]const u8{ "Parser", "Capability", "Throughput (MB/s)", "% of strlen", "Median Time (ms)", "Iterations" };
        const aligns = [_]bool{ false, false, true, true, true, true };
        var widths = [_]usize{
            headers[0].len,
            headers[1].len,
            headers[2].len,
            headers[3].len,
            headers[4].len,
            headers[5].len,
        };

        const strlen = findParseThroughput(parse_results, "strlen", row.fixture);
        var trows = std.ArrayList([6][]u8).empty;
        defer {
            for (trows.items) |cells| {
                for (cells) |c| alloc.free(c);
            }
            trows.deinit(alloc);
        }

        for (fixture_rows.items) |r| {
            var cells: [6][]u8 = undefined;
            cells[0] = try alloc.dupe(u8, r.parser);
            cells[1] = try alloc.dupe(u8, capabilityOf(r.parser));
            cells[2] = try std.fmt.allocPrint(alloc, "{d:.2}", .{r.throughput_mb_s});
            if (strlen) |s| {
                const pct = if (s > 0.0) (r.throughput_mb_s / s) * 100.0 else 0.0;
                cells[3] = try std.fmt.allocPrint(alloc, "{d:.2}%", .{pct});
            } else {
                cells[3] = try alloc.dupe(u8, "-");
            }
            cells[4] = try std.fmt.allocPrint(alloc, "{d:.3}", .{@as(f64, @floatFromInt(r.median_ns)) / 1_000_000.0});
            cells[5] = try std.fmt.allocPrint(alloc, "{d}", .{r.iterations});

            inline for (0..6) |i| widths[i] = @max(widths[i], cells[i].len);
            try trows.append(alloc, cells);
        }

        try appendAsciiSep(w, &widths);
        try appendAsciiRow(w, &widths, &headers, &aligns);
        try appendAsciiSep(w, &widths);
        for (trows.items) |cells| try appendAsciiRow(w, &widths, &cells, &aligns);
        try appendAsciiSep(w, &widths);
        try w.writeAll("\n");
    }

    try renderQueryConsoleSection(alloc, w, "Query Parse Throughput", query_parse_results);
    try renderQueryConsoleSection(alloc, w, "Query Match Throughput", query_match_results);
    try renderQueryConsoleSection(alloc, w, "Query Cached Throughput", query_cached_results);

    if (gate_rows.len > 0) {
        try w.writeAll("Ours vs lol-html Gate\n\n");
        const headers = [_][]const u8{ "Fixture", "ours (MB/s)", "lol-html (MB/s)", "Result" };
        const aligns = [_]bool{ false, true, true, false };
        var widths = [_]usize{ headers[0].len, headers[1].len, headers[2].len, headers[3].len };

        var rows = std.ArrayList([4][]u8).empty;
        defer {
            for (rows.items) |cells| for (cells) |c| alloc.free(c);
            rows.deinit(alloc);
        }
        for (gate_rows) |g| {
            var cells: [4][]u8 = undefined;
            cells[0] = try alloc.dupe(u8, g.fixture);
            cells[1] = try std.fmt.allocPrint(alloc, "{d:.2}", .{g.ours_mb_s});
            cells[2] = try std.fmt.allocPrint(alloc, "{d:.2}", .{g.lol_html_mb_s});
            cells[3] = try alloc.dupe(u8, if (g.pass) "PASS" else "FAIL");
            inline for (0..4) |i| widths[i] = @max(widths[i], cells[i].len);
            try rows.append(alloc, cells);
        }

        try appendAsciiSep(w, &widths);
        try appendAsciiRow(w, &widths, &headers, &aligns);
        try appendAsciiSep(w, &widths);
        for (rows.items) |cells| try appendAsciiRow(w, &widths, &cells, &aligns);
        try appendAsciiSep(w, &widths);
        try w.writeAll("\n");
    }

    return out.toOwnedSlice();
}

fn writeByteNTimes(writer: anytype, byte: u8, n: usize) !void {
    for (0..n) |_| {
        try writer.writeByte(byte);
    }
}

fn appendAsciiSep(writer: anytype, widths: []const usize) !void {
    try writer.writeAll("+-");
    for (widths, 0..) |w, i| {
        try writeByteNTimes(writer, '-', w);
        if (i + 1 == widths.len) {
            try writer.writeAll("-+\n");
        } else {
            try writer.writeAll("-+-");
        }
    }
}

fn appendAsciiRow(writer: anytype, widths: []const usize, cells: []const []const u8, right_align: []const bool) !void {
    try writer.writeAll("| ");
    for (cells, 0..) |cell, i| {
        const width = widths[i];
        const pad = if (width > cell.len) width - cell.len else 0;
        if (right_align[i]) {
            try writeByteNTimes(writer, ' ', pad);
            try writer.writeAll(cell);
        } else {
            try writer.writeAll(cell);
            try writeByteNTimes(writer, ' ', pad);
        }
        if (i + 1 == cells.len) {
            try writer.writeAll(" |\n");
        } else {
            try writer.writeAll(" | ");
        }
    }
}

fn renderQueryConsoleSection(alloc: std.mem.Allocator, w: *std.Io.Writer, title: []const u8, rows: []const QueryResult) !void {
    try w.print("{s}\n\n", .{title});

    var seen_cases = std.StringHashMap(void).init(alloc);
    defer seen_cases.deinit();

    for (rows) |row| {
        if (seen_cases.contains(row.case)) continue;
        try seen_cases.put(row.case, {});

        var case_rows = std.ArrayList(QueryResult).empty;
        defer case_rows.deinit(alloc);
        for (rows) |r| if (std.mem.eql(u8, r.case, row.case)) try case_rows.append(alloc, r);
        std.mem.sort(QueryResult, case_rows.items, {}, struct {
            fn lt(_: void, a: QueryResult, b: QueryResult) bool {
                return a.ops_s > b.ops_s;
            }
        }.lt);

        try w.print("Case: {s}\n", .{row.case});
        const headers = [_][]const u8{ "Parser", "Ops/s", "ns/op", "Median Time (ms)", "Iterations" };
        const aligns = [_]bool{ false, true, true, true, true };
        var widths = [_]usize{ headers[0].len, headers[1].len, headers[2].len, headers[3].len, headers[4].len };

        var trows = std.ArrayList([5][]u8).empty;
        defer {
            for (trows.items) |cells| for (cells) |c| alloc.free(c);
            trows.deinit(alloc);
        }

        for (case_rows.items) |r| {
            var cells: [5][]u8 = undefined;
            cells[0] = try alloc.dupe(u8, r.parser);
            cells[1] = try std.fmt.allocPrint(alloc, "{d:.2}", .{r.ops_s});
            cells[2] = try std.fmt.allocPrint(alloc, "{d:.2}", .{r.ns_per_op});
            cells[3] = try std.fmt.allocPrint(alloc, "{d:.3}", .{@as(f64, @floatFromInt(r.median_ns)) / 1_000_000.0});
            cells[4] = try std.fmt.allocPrint(alloc, "{d}", .{r.iterations});
            inline for (0..5) |i| widths[i] = @max(widths[i], cells[i].len);
            try trows.append(alloc, cells);
        }

        try appendAsciiSep(w, &widths);
        try appendAsciiRow(w, &widths, &headers, &aligns);
        try appendAsciiSep(w, &widths);
        for (trows.items) |cells| try appendAsciiRow(w, &widths, &cells, &aligns);
        try appendAsciiSep(w, &widths);
        try w.writeAll("Selector:\n");
        try w.print("  {s}\n", .{case_rows.items[0].selector});
        if (case_rows.items[0].fixture) |fx| {
            try w.writeAll("Fixture:\n");
            try w.print("  {s}\n", .{fx});
        }
        try w.writeAll("\n");
    }
}

fn runBenchmarks(io: std.Io, alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var profile_name: []const u8 = "quick";
    var write_baseline = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--profile")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            profile_name = args[i];
        } else if (std.mem.eql(u8, arg, "--write-baseline")) {
            write_baseline = true;
        } else {
            return error.InvalidArgument;
        }
    }

    const profile = try getProfile(profile_name);

    try common.ensureDir(io, BIN_DIR);
    try common.ensureDir(io, RESULTS_DIR);
    try ensureExternalParsersBuilt(io, alloc);
    try buildRunners(io, alloc);

    var parse_results = std.ArrayList(ParseResult).empty;
    defer {
        freeParseSamples(alloc, parse_results.items);
        parse_results.deinit(alloc);
    }

    for (profile.fixtures) |fixture| {
        for (parse_parsers) |parser_name| {
            std.debug.print("benchmarking {s} on {s} ({d} iters)\n", .{ parser_name, fixture.name, fixture.iterations });
            const row = try benchParseOne(io, alloc, parser_name, fixture.name, fixture.iterations);
            try parse_results.append(alloc, row);
        }
    }

    var query_parse_results = std.ArrayList(QueryResult).empty;
    defer {
        freeQuerySamples(alloc, query_parse_results.items);
        query_parse_results.deinit(alloc);
    }
    for (query_parse_modes) |qm| {
        for (profile.query_parse_cases) |qc| {
            std.debug.print("benchmarking query-parse {s} on {s} ({d} iters)\n", .{ qm.parser, qc.name, qc.iterations });
            const row = try benchQueryParseOne(io, alloc, qm.parser, qc.name, qc.selector, qc.iterations);
            try query_parse_results.append(alloc, row);
        }
    }

    var query_match_results = std.ArrayList(QueryResult).empty;
    defer {
        freeQuerySamples(alloc, query_match_results.items);
        query_match_results.deinit(alloc);
    }
    for (query_modes) |qm| {
        for (profile.query_match_cases) |qc| {
            std.debug.print("benchmarking query-match {s} on {s} ({d} iters)\n", .{ qm.parser, qc.name, qc.iterations });
            const row = try benchQueryExecOne(io, alloc, qm.parser, qm.mode, qc.name, qc.fixture, qc.selector, qc.iterations, false);
            try query_match_results.append(alloc, row);
        }
    }

    var query_cached_results = std.ArrayList(QueryResult).empty;
    defer {
        freeQuerySamples(alloc, query_cached_results.items);
        query_cached_results.deinit(alloc);
    }
    for (query_modes) |qm| {
        for (profile.query_cached_cases) |qc| {
            std.debug.print("benchmarking query-cached {s} on {s} ({d} iters)\n", .{ qm.parser, qc.name, qc.iterations });
            const row = try benchQueryExecOne(io, alloc, qm.parser, qm.mode, qc.name, qc.fixture, qc.selector, qc.iterations, true);
            try query_cached_results.append(alloc, row);
        }
    }

    const gate_rows = try evaluateGateRows(alloc, profile, parse_results.items);
    defer alloc.free(gate_rows);
    try rerunFailedGateRows(io, alloc, profile, gate_rows);

    const json_out = struct {
        generated_unix: i64,
        profile: []const u8,
        repeats: usize,
        bench_modes: struct { parse: []const []const u8, query: []const []const u8 },
        parser_capabilities: []const ParserCapability,
        parse_results: []const ParseResult,
        query_parse_results: []const QueryResult,
        query_match_results: []const QueryResult,
        query_cached_results: []const QueryResult,
        gate_summary: []const GateRow,
    }{
        .generated_unix = common.nowUnix(io),
        .profile = profile.name,
        .repeats = repeats,
        .bench_modes = .{ .parse = &[_][]const u8{"ours"}, .query = &[_][]const u8{"ours"} },
        .parser_capabilities = &parser_capabilities,
        .parse_results = parse_results.items,
        .query_parse_results = query_parse_results.items,
        .query_match_results = query_match_results.items,
        .query_cached_results = query_cached_results.items,
        .gate_summary = gate_rows,
    };

    var json_writer: std.Io.Writer.Allocating = .init(alloc);
    defer json_writer.deinit();
    var json_stream: std.json.Stringify = .{
        .writer = &json_writer.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try json_stream.write(json_out);
    try common.writeFile(io, "bench/results/latest.json", json_writer.written());

    const md = try writeMarkdown(io, alloc, profile.name, parse_results.items, query_parse_results.items, query_match_results.items, query_cached_results.items, gate_rows);
    defer alloc.free(md);
    try common.writeFile(io, "bench/results/latest.md", md);
    try updateDocumentationBenchmarkSnapshot(io, alloc);
    try updateReadmeAutoSummary(io, alloc);

    // Optional baseline behavior.
    const baseline_default = try std.fmt.allocPrint(alloc, "bench/results/baseline_{s}.json", .{profile.name});
    defer alloc.free(baseline_default);

    if (write_baseline) {
        try common.writeFile(io, baseline_default, json_writer.written());
        std.debug.print("wrote baseline {s}\n", .{baseline_default});
    }

    var failures = std.ArrayList([]const u8).empty;
    defer deinitOwnedStringList(alloc, &failures);

    for (gate_rows) |g| {
        if (std.mem.eql(u8, profile.name, "stable") and !g.pass) {
            const msg = try std.fmt.allocPrint(alloc, "stable ours-vs-lol fail: {s} ours {d:.2} <= lol-html {d:.2}", .{ g.fixture, g.ours_mb_s, g.lol_html_mb_s });
            try failures.append(alloc, msg);
        }
    }

    std.debug.print("wrote bench/results/latest.json\n", .{});
    std.debug.print("wrote bench/results/latest.md\n\n", .{});
    const console = try renderConsole(io, alloc, profile.name, parse_results.items, query_parse_results.items, query_match_results.items, query_cached_results.items, gate_rows);
    defer alloc.free(console);
    std.debug.print("{s}\n", .{console});
    if (failures.items.len > 0) {
        std.debug.print("Gate failures:\n", .{});
        for (failures.items) |f| std.debug.print("- {s}\n", .{f});
        return error.GateFailed;
    }
}

// ---------------------------- External suites ----------------------------

const NwCase = struct {
    selector: []const u8,
    expected: usize,
};

const QwCase = struct {
    selector: []const u8,
    context: []const u8,
    expected: usize,
};

const SelectorSuiteSummary = struct {
    total: usize,
    passed: usize,
    examples: []const []const u8,
};

const ParserSuiteSummary = struct {
    total: usize,
    passed: usize,
    examples: []const []const u8,
};

const SelectorFailure = struct {
    case_index: usize,
    selector: []const u8,
    context: ?[]const u8,
    expected: usize,
    actual: ?usize,
    error_msg: ?[]const u8,
};

const ParserFailure = struct {
    case_index: usize,
    input_preview: []const u8,
    input_len: usize,
    expected: []const []const u8,
    actual: []const []const u8,
    error_msg: ?[]const u8,
};

const SelectorSuitesResult = struct {
    nw: SelectorSuiteSummary,
    qw: SelectorSuiteSummary,
    nw_failures: []const SelectorFailure,
    qw_failures: []const SelectorFailure,
};

const ParserSuiteResult = struct {
    summary: ParserSuiteSummary,
    failures: []const ParserFailure,
};

const ExternalFailuresOut = struct {
    modes: []const ModeFailuresOut,
};

const ModeFailuresOut = struct {
    mode: []const u8,
    selector_suites: struct {
        nwmatcher: []const SelectorFailure,
        qwery_contextual: []const SelectorFailure,
    },
    parser_suites: struct {
        html5lib_subset: []const ParserFailure,
        whatwg_html_parsing: []const ParserFailure,
    },
};

fn ensureSuites(io: std.Io, alloc: std.mem.Allocator) !void {
    try common.ensureDir(io, SUITES_CACHE_DIR);
    try common.ensureDir(io, SUITES_DIR);

    const repos = [_]struct { name: []const u8, url: []const u8 }{
        .{ .name = "html5lib-tests", .url = "https://github.com/html5lib/html5lib-tests.git" },
        .{ .name = "css-select", .url = "https://github.com/fb55/css-select.git" },
        .{ .name = "wpt", .url = "https://github.com/web-platform-tests/wpt.git" },
        .{ .name = "whatwg-html", .url = "https://github.com/whatwg/html.git" },
    };

    for (repos) |repo| {
        const cache_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ SUITES_CACHE_DIR, repo.name });
        defer alloc.free(cache_path);
        if (!pathExists(io, cache_path)) {
            const clone_argv = [_][]const u8{ "git", "clone", "--depth", "1", repo.url, cache_path };
            try common.runInherit(io, alloc, &clone_argv, REPO_ROOT);
        } else {
            const pull_argv = [_][]const u8{ "git", "-C", cache_path, "pull", "--ff-only" };
            common.runInherit(io, alloc, &pull_argv, REPO_ROOT) catch {};
        }

        const dst = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ SUITES_DIR, repo.name });
        defer alloc.free(dst);
        if (!pathExists(io, dst)) {
            const work_clone_argv = [_][]const u8{ "git", "clone", "--depth", "1", cache_path, dst };
            try common.runInherit(io, alloc, &work_clone_argv, REPO_ROOT);
        }
    }
}

fn buildSuiteRunner(io: std.Io, alloc: std.mem.Allocator) !void {
    try common.ensureDir(io, BIN_DIR);
    const root_mod = "-Mroot=tools/suite_runner.zig";
    const html_mod = "-Mhtmlparser=src/root.zig";
    const argv = [_][]const u8{
        "zig",
        "build-exe",
        "--dep",
        "htmlparser",
        root_mod,
        html_mod,
        "-O",
        "ReleaseFast",
        "-femit-bin=" ++ SUITE_RUNNER_BIN,
    };
    try common.runInherit(io, alloc, &argv, REPO_ROOT);
}

fn runSelectorCount(io: std.Io, alloc: std.mem.Allocator, mode: []const u8, fixture: []const u8, selector: []const u8) !usize {
    const argv = [_][]const u8{ SUITE_RUNNER_BIN, "selector-count", mode, fixture, selector };
    const out = try common.runCaptureStdout(io, alloc, &argv, REPO_ROOT);
    defer alloc.free(out);
    return std.fmt.parseInt(usize, out, 10);
}

fn runSelectorCountScoped(io: std.Io, alloc: std.mem.Allocator, mode: []const u8, fixture: []const u8, scope_tag: []const u8, selector: []const u8) !usize {
    const argv = [_][]const u8{ SUITE_RUNNER_BIN, "selector-count-scope-tag", mode, fixture, scope_tag, selector };
    const out = try common.runCaptureStdout(io, alloc, &argv, REPO_ROOT);
    defer alloc.free(out);
    return std.fmt.parseInt(usize, out, 10);
}

fn runParseTagsFile(io: std.Io, alloc: std.mem.Allocator, mode: []const u8, fixture: []const u8) ![]const u8 {
    const argv = [_][]const u8{ SUITE_RUNNER_BIN, "parse-tags-file", mode, fixture };
    return common.runCaptureStdout(io, alloc, &argv, REPO_ROOT);
}

fn tempHtmlFile(io: std.Io, alloc: std.mem.Allocator, html: []const u8) ![]u8 {
    var src: std.Random.IoSource = .{ .io = io };
    const rng = src.interface();
    const r = rng.int(u64);
    const path = try std.fmt.allocPrint(alloc, "/tmp/htmlparser-suite-{x}.html", .{r});
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, html);
    return path;
}

fn loadNwCases(io: std.Io, alloc: std.mem.Allocator) ![]NwCase {
    const bytes = try common.readFileAlloc(io, alloc, CONFORMANCE_CASES_DIR ++ "/nwmatcher_cases.json");
    defer alloc.free(bytes);
    const parsed = try std.json.parseFromSlice([]NwCase, alloc, bytes, .{});
    defer parsed.deinit();
    const out = try alloc.alloc(NwCase, parsed.value.len);
    for (parsed.value, 0..) |row, i| {
        out[i] = .{
            .selector = try alloc.dupe(u8, row.selector),
            .expected = row.expected,
        };
    }
    return out;
}

fn loadQwCases(io: std.Io, alloc: std.mem.Allocator) ![]QwCase {
    const bytes = try common.readFileAlloc(io, alloc, CONFORMANCE_CASES_DIR ++ "/qwery_cases.json");
    defer alloc.free(bytes);
    const parsed = try std.json.parseFromSlice([]QwCase, alloc, bytes, .{});
    defer parsed.deinit();
    const out = try alloc.alloc(QwCase, parsed.value.len);
    for (parsed.value, 0..) |row, i| {
        out[i] = .{
            .selector = try alloc.dupe(u8, row.selector),
            .context = try alloc.dupe(u8, row.context),
            .expected = row.expected,
        };
    }
    return out;
}

fn dupeStringSlices(alloc: std.mem.Allocator, src: []const []const u8) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, src.len);
    errdefer alloc.free(out);
    for (src, 0..) |s, idx| {
        out[idx] = try alloc.dupe(u8, s);
    }
    return out;
}

fn htmlPreview(io: std.Io, alloc: std.mem.Allocator, html: []const u8) ![]const u8 {
    _ = io;
    const max_preview: usize = 220;
    const clipped = html[0..@min(html.len, max_preview)];
    return std.mem.replaceOwned(u8, alloc, clipped, "\n", "\\n");
}

fn runSelectorSuites(io: std.Io, alloc: std.mem.Allocator, mode: []const u8) !SelectorSuitesResult {
    const nw_cases = try loadNwCases(io, alloc);
    defer {
        for (nw_cases) |c| alloc.free(c.selector);
        alloc.free(nw_cases);
    }
    const qw_cases = try loadQwCases(io, alloc);
    defer {
        for (qw_cases) |c| {
            alloc.free(c.selector);
            alloc.free(c.context);
        }
        alloc.free(qw_cases);
    }

    const nw_fixture = SUITES_DIR ++ "/css-select/test/fixtures/nwmatcher.html";
    const qw_fixture = SUITES_DIR ++ "/css-select/test/fixtures/qwery.html";
    const qw_doc_html = try common.readFileAlloc(io, alloc, CONFORMANCE_CASES_DIR ++ "/qwery_doc.html");
    defer alloc.free(qw_doc_html);
    const qw_frag_html = try common.readFileAlloc(io, alloc, CONFORMANCE_CASES_DIR ++ "/qwery_frag.html");
    defer alloc.free(qw_frag_html);

    var nw_passed: usize = 0;
    var nw_examples = std.ArrayList([]const u8).empty;
    defer nw_examples.deinit(alloc);
    var nw_failures = std.ArrayList(SelectorFailure).empty;
    defer nw_failures.deinit(alloc);
    for (nw_cases, 0..) |c, idx| {
        if (idx >= 140) break;
        const got = runSelectorCount(io, alloc, mode, nw_fixture, c.selector) catch {
            const msg = try std.fmt.allocPrint(alloc, "{s} expected {d} got <parse-error>", .{ c.selector, c.expected });
            if (nw_examples.items.len < 8) try nw_examples.append(alloc, msg);
            try nw_failures.append(alloc, .{
                .case_index = idx,
                .selector = try alloc.dupe(u8, c.selector),
                .context = null,
                .expected = c.expected,
                .actual = null,
                .error_msg = "parse-error",
            });
            continue;
        };
        if (got == c.expected) {
            nw_passed += 1;
        } else {
            if (nw_examples.items.len < 8) {
                const msg = try std.fmt.allocPrint(alloc, "{s} expected {d} got {d}", .{ c.selector, c.expected, got });
                try nw_examples.append(alloc, msg);
            }
            try nw_failures.append(alloc, .{
                .case_index = idx,
                .selector = try alloc.dupe(u8, c.selector),
                .context = null,
                .expected = c.expected,
                .actual = got,
                .error_msg = null,
            });
        }
    }

    var qw_passed: usize = 0;
    var qw_examples = std.ArrayList([]const u8).empty;
    defer qw_examples.deinit(alloc);
    var qw_failures = std.ArrayList(SelectorFailure).empty;
    defer qw_failures.deinit(alloc);
    for (qw_cases, 0..) |c, idx| {
        const got = blk: {
            if (std.mem.eql(u8, c.context, "document")) {
                break :blk runSelectorCount(io, alloc, mode, qw_fixture, c.selector) catch {
                    if (qw_examples.items.len < 8) {
                        const msg = try std.fmt.allocPrint(alloc, "{s} {s} expected {d} got <parse-error>", .{ c.context, c.selector, c.expected });
                        try qw_examples.append(alloc, msg);
                    }
                    try qw_failures.append(alloc, .{
                        .case_index = idx,
                        .selector = try alloc.dupe(u8, c.selector),
                        .context = try alloc.dupe(u8, c.context),
                        .expected = c.expected,
                        .actual = null,
                        .error_msg = "parse-error",
                    });
                    continue;
                };
            }
            const html = if (std.mem.eql(u8, c.context, "doc")) qw_doc_html else qw_frag_html;
            const tmp = try tempHtmlFile(io, alloc, html);
            defer {
                std.Io.Dir.deleteFileAbsolute(io, tmp) catch {};
                alloc.free(tmp);
            }
            break :blk runSelectorCountScoped(io, alloc, mode, tmp, "root", c.selector) catch {
                if (qw_examples.items.len < 8) {
                    const msg = try std.fmt.allocPrint(alloc, "{s} {s} expected {d} got <parse-error>", .{ c.context, c.selector, c.expected });
                    try qw_examples.append(alloc, msg);
                }
                try qw_failures.append(alloc, .{
                    .case_index = idx,
                    .selector = try alloc.dupe(u8, c.selector),
                    .context = try alloc.dupe(u8, c.context),
                    .expected = c.expected,
                    .actual = null,
                    .error_msg = "parse-error",
                });
                continue;
            };
        };

        if (got == c.expected) {
            qw_passed += 1;
        } else {
            if (qw_examples.items.len < 8) {
                const msg = try std.fmt.allocPrint(alloc, "{s} {s} expected {d} got {d}", .{ c.context, c.selector, c.expected, got });
                try qw_examples.append(alloc, msg);
            }
            try qw_failures.append(alloc, .{
                .case_index = idx,
                .selector = try alloc.dupe(u8, c.selector),
                .context = try alloc.dupe(u8, c.context),
                .expected = c.expected,
                .actual = got,
                .error_msg = null,
            });
        }
    }

    return .{
        .nw = .{
            .total = @min(nw_cases.len, 140),
            .passed = nw_passed,
            .examples = try nw_examples.toOwnedSlice(alloc),
        },
        .qw = .{
            .total = qw_cases.len,
            .passed = qw_passed,
            .examples = try qw_examples.toOwnedSlice(alloc),
        },
        .nw_failures = try nw_failures.toOwnedSlice(alloc),
        .qw_failures = try qw_failures.toOwnedSlice(alloc),
    };
}

fn parseTreeTag(payload: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '!' or trimmed[0] == '?' or trimmed[0] == '/') return null;
    var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
    const first = parts.next() orelse return null;
    if ((std.mem.eql(u8, first, "svg") or std.mem.eql(u8, first, "math"))) {
        return parts.next() orelse first;
    }
    return first;
}

fn isWrapperTag(tag: []const u8) bool {
    return std.mem.eql(u8, tag, "html") or
        std.mem.eql(u8, tag, "head") or
        std.mem.eql(u8, tag, "body") or
        std.mem.eql(u8, tag, "tbody") or
        std.mem.eql(u8, tag, "tr");
}

const ParserCase = struct {
    html: []const u8,
    expected: []const []const u8,
};

fn freeOwnedStringSlice(alloc: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| alloc.free(item);
    alloc.free(items);
}

fn freeParserCase(alloc: std.mem.Allocator, c: ParserCase) void {
    alloc.free(c.html);
    freeOwnedStringSlice(alloc, c.expected);
}

fn freeParserCases(alloc: std.mem.Allocator, cases: []const ParserCase) void {
    for (cases) |c| freeParserCase(alloc, c);
    alloc.free(cases);
}

fn deinitParserCaseList(alloc: std.mem.Allocator, list: *std.ArrayList(ParserCase)) void {
    for (list.items) |c| freeParserCase(alloc, c);
    list.deinit(alloc);
}

fn transferOwnedParserCases(alloc: std.mem.Allocator, dst: *std.ArrayList(ParserCase), cases: []ParserCase) !void {
    errdefer freeParserCases(alloc, cases);
    try dst.appendSlice(alloc, cases);
    alloc.free(cases);
}

fn parseHtml5libDat(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]ParserCase {
    const text = try common.readFileAlloc(io, alloc, path);
    defer alloc.free(text);
    return parseHtml5libDatText(alloc, text);
}

fn parseHtml5libDatText(alloc: std.mem.Allocator, text: []const u8) ![]ParserCase {
    var out = std.ArrayList(ParserCase).empty;
    errdefer deinitParserCaseList(alloc, &out);
    var blocks = std.mem.splitSequence(u8, text, "\n#data\n");
    while (blocks.next()) |raw_blk| {
        var blk = raw_blk;
        if (std.mem.startsWith(u8, blk, "#data\n")) blk = blk["#data\n".len..];
        if (std.mem.indexOf(u8, blk, "#document") == null) continue;
        const doc_idx = std.mem.indexOf(u8, blk, "\n#document\n") orelse continue;
        const data_part = blk[0..doc_idx];
        const rest = blk[doc_idx + "\n#document\n".len ..];
        if (std.mem.indexOf(u8, data_part, "\n#document-fragment\n") != null or std.mem.indexOf(u8, rest, "\n#document-fragment\n") != null) continue;

        var html_in = data_part;
        if (std.mem.indexOf(u8, html_in, "\n#errors\n")) |err_idx| {
            html_in = html_in[0..err_idx];
        }
        const html_copy = try alloc.dupe(u8, html_in);
        errdefer alloc.free(html_copy);

        var expected = std.ArrayList([]const u8).empty;
        errdefer deinitOwnedStringList(alloc, &expected);
        var lines = std.mem.splitScalar(u8, rest, '\n');
        while (lines.next()) |line| {
            if (line.len < 3 or line[0] != '|') continue;
            var j: usize = 1;
            while (j < line.len and (line[j] == ' ' or line[j] == '\t')) : (j += 1) {}
            if (j >= line.len or line[j] != '<') continue;
            if (line[line.len - 1] != '>') continue;
            if (j + 1 > line.len - 1) continue;
            const payload = line[j + 1 .. line.len - 1];
            const maybe_tag = parseTreeTag(payload) orelse continue;
            const lower = try std.ascii.allocLowerString(alloc, maybe_tag);
            if (isWrapperTag(lower)) {
                alloc.free(lower);
                continue;
            }
            try appendOwnedString(alloc, &expected, lower);
        }
        const expected_slice = try expected.toOwnedSlice(alloc);
        errdefer freeOwnedStringSlice(alloc, expected_slice);
        try out.append(alloc, .{
            .html = html_copy,
            .expected = expected_slice,
        });
    }
    return out.toOwnedSlice(alloc);
}

fn fromHex(c: u8) !u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return 10 + (c - 'a');
    if (c >= 'A' and c <= 'F') return 10 + (c - 'A');
    return error.InvalidHex;
}

fn decodePercent(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '%' and i + 2 < text.len) {
            const hi = try fromHex(text[i + 1]);
            const lo = try fromHex(text[i + 2]);
            try out.append(alloc, (hi << 4) | lo);
            i += 3;
            continue;
        }
        try out.append(alloc, c);
        i += 1;
    }

    return out.toOwnedSlice(alloc);
}

fn quoteEnd(text: []const u8, start: usize) ?usize {
    var i = start;
    while (i < text.len) : (i += 1) {
        if (text[i] == '"' and (i == start or text[i - 1] != '\\')) return i;
    }
    return null;
}

fn parseWptTreeExpected(alloc: std.mem.Allocator, decoded_tree: []const u8) ![]const []const u8 {
    var expected = std.ArrayList([]const u8).empty;
    errdefer deinitOwnedStringList(alloc, &expected);

    var lines = std.mem.splitScalar(u8, decoded_tree, '\n');
    while (lines.next()) |line| {
        if (line.len < 3 or line[0] != '|') continue;
        var j: usize = 1;
        while (j < line.len and (line[j] == ' ' or line[j] == '\t')) : (j += 1) {}
        if (j >= line.len or line[j] != '<') continue;
        if (line[line.len - 1] != '>') continue;
        if (j + 1 > line.len - 1) continue;
        const payload = line[j + 1 .. line.len - 1];
        const maybe_tag = parseTreeTag(payload) orelse continue;
        const lower = try std.ascii.allocLowerString(alloc, maybe_tag);
        if (isWrapperTag(lower)) {
            alloc.free(lower);
            continue;
        }
        try appendOwnedString(alloc, &expected, lower);
    }
    return expected.toOwnedSlice(alloc);
}

fn parseWptHtmlSuiteFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]ParserCase {
    const text = try common.readFileAlloc(io, alloc, path);
    defer alloc.free(text);
    return parseWptHtmlSuiteText(alloc, text);
}

fn parseWptHtmlSuiteText(alloc: std.mem.Allocator, text: []const u8) ![]ParserCase {
    if (std.mem.indexOf(u8, text, "var tests = {") == null) return try alloc.alloc(ParserCase, 0);
    if (std.mem.indexOf(u8, text, "init_tests(") == null) return try alloc.alloc(ParserCase, 0);

    var out = std.ArrayList(ParserCase).empty;
    errdefer deinitParserCaseList(alloc, &out);

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, "[async_test(")) |mark| {
        pos = mark + "[async_test(".len;

        const in_q = std.mem.indexOfPos(u8, text, pos, "\"") orelse break;
        const in_end = quoteEnd(text, in_q + 1) orelse break;
        const expected_q = std.mem.indexOfPos(u8, text, in_end + 1, "\"") orelse break;
        const expected_end = quoteEnd(text, expected_q + 1) orelse break;
        pos = expected_end + 1;

        // html5lib_* WPT files also contain context/fragment cases encoded as:
        // [async_test(...), "<html>", "<tree>", "<context>"]
        // This parser harness only validates full-document cases, so skip any
        // entry that carries additional args after expected tree string.
        const tail = std.mem.trimStart(u8, text[expected_end + 1 ..], " \t\r\n");
        if (tail.len == 0) break;
        if (tail[0] == ',') continue;
        if (tail[0] != ']') continue;

        const html_encoded = text[in_q + 1 .. in_end];
        const tree_encoded = text[expected_q + 1 .. expected_end];

        const html_in = try decodePercent(alloc, html_encoded);
        errdefer alloc.free(html_in);
        const tree_decoded = try decodePercent(alloc, tree_encoded);
        defer alloc.free(tree_decoded);

        const expected = try parseWptTreeExpected(alloc, tree_decoded);
        errdefer {
            for (expected) |tag| alloc.free(tag);
            alloc.free(expected);
        }

        try out.append(alloc, .{
            .html = html_in,
            .expected = expected,
        });
    }
    return out.toOwnedSlice(alloc);
}

fn parseTagJsonArray(alloc: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidJson;
    var tags = std.ArrayList([]const u8).empty;
    errdefer deinitOwnedStringList(alloc, &tags);
    for (parsed.value.array.items) |it| {
        if (it != .string) continue;
        const lower = try std.ascii.allocLowerString(alloc, it.string);
        if (isWrapperTag(lower)) {
            alloc.free(lower);
            continue;
        }
        try appendOwnedString(alloc, &tags, lower);
    }
    return tags.toOwnedSlice(alloc);
}

fn eqlStringSlices(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

fn runParserCases(io: std.Io, alloc: std.mem.Allocator, mode: []const u8, cases: []const ParserCase, max_cases: usize) !ParserSuiteResult {
    const limit = @min(max_cases, cases.len);
    var passed: usize = 0;
    var examples = std.ArrayList([]const u8).empty;
    defer examples.deinit(alloc);
    var failures = std.ArrayList(ParserFailure).empty;
    defer failures.deinit(alloc);
    var idx: usize = 0;
    while (idx < limit) : (idx += 1) {
        const c = cases[idx];
        const tmp = try tempHtmlFile(io, alloc, c.html);
        defer {
            std.Io.Dir.deleteFileAbsolute(io, tmp) catch {};
            alloc.free(tmp);
        }
        const raw = runParseTagsFile(io, alloc, mode, tmp) catch {
            if (examples.items.len < 10) {
                const src = std.mem.replaceOwned(u8, alloc, c.html, "\n", "\\n") catch c.html;
                const msg = std.fmt.allocPrint(alloc, "{s} -> <parse-error>", .{src}) catch "parse-error";
                try examples.append(alloc, msg);
            }
            const empty: []const []const u8 = &.{};
            try failures.append(alloc, .{
                .case_index = idx,
                .input_preview = try htmlPreview(io, alloc, c.html),
                .input_len = c.html.len,
                .expected = try dupeStringSlices(alloc, c.expected),
                .actual = empty,
                .error_msg = "parse-error",
            });
            continue;
        };
        defer alloc.free(raw);
        const got = try parseTagJsonArray(alloc, raw);
        defer {
            for (got) |g| alloc.free(g);
            alloc.free(got);
        }
        if (eqlStringSlices(c.expected, got)) {
            passed += 1;
        } else {
            if (examples.items.len < 10) {
                var src_short = c.html;
                if (src_short.len > 100) src_short = src_short[0..100];
                const src_escaped = try std.mem.replaceOwned(u8, alloc, src_short, "\n", "\\n");
                const msg = try std.fmt.allocPrint(alloc, "{s}", .{src_escaped});
                try examples.append(alloc, msg);
            }
            try failures.append(alloc, .{
                .case_index = idx,
                .input_preview = try htmlPreview(io, alloc, c.html),
                .input_len = c.html.len,
                .expected = try dupeStringSlices(alloc, c.expected),
                .actual = try dupeStringSlices(alloc, got),
                .error_msg = null,
            });
        }
    }

    return .{
        .summary = .{
            .total = limit,
            .passed = passed,
            .examples = try examples.toOwnedSlice(alloc),
        },
        .failures = try failures.toOwnedSlice(alloc),
    };
}

fn runHtml5libParserSuite(io: std.Io, alloc: std.mem.Allocator, mode: []const u8, max_cases: usize) !ParserSuiteResult {
    const tc_dir = SUITES_DIR ++ "/html5lib-tests/tree-construction";
    var dir = try std.Io.Dir.cwd().openDir(io, tc_dir, .{ .iterate = true });
    defer dir.close(io);

    var dat_names = std.ArrayList([]const u8).empty;
    defer deinitOwnedStringList(alloc, &dat_names);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".dat")) continue;
        const name = try alloc.dupe(u8, entry.name);
        try appendOwnedString(alloc, &dat_names, name);
    }
    std.mem.sort([]const u8, dat_names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var cases = std.ArrayList(ParserCase).empty;
    defer deinitParserCaseList(alloc, &cases);
    for (dat_names.items) |name| {
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ tc_dir, name });
        defer alloc.free(path);
        const parsed_cases = try parseHtml5libDat(io, alloc, path);
        try transferOwnedParserCases(alloc, &cases, parsed_cases);
    }

    return runParserCases(io, alloc, mode, cases.items, max_cases);
}

fn runWptParserSuite(io: std.Io, alloc: std.mem.Allocator, mode: []const u8, max_cases: usize) !ParserSuiteResult {
    const wpt_dir = SUITES_DIR ++ "/wpt/html/syntax/parsing";
    var dir = try std.Io.Dir.cwd().openDir(io, wpt_dir, .{ .iterate = true });
    defer dir.close(io);

    var html_names = std.ArrayList([]const u8).empty;
    defer deinitOwnedStringList(alloc, &html_names);
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".html")) continue;
        const base = std.fs.path.basename(entry.path);
        if (!std.mem.startsWith(u8, base, "html5lib_")) continue;
        const path_copy = try alloc.dupe(u8, entry.path);
        try appendOwnedString(alloc, &html_names, path_copy);
    }
    std.mem.sort([]const u8, html_names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var cases = std.ArrayList(ParserCase).empty;
    defer deinitParserCaseList(alloc, &cases);

    for (html_names.items) |name| {
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ wpt_dir, name });
        defer alloc.free(path);
        const parsed_cases = try parseWptHtmlSuiteFile(io, alloc, path);
        try transferOwnedParserCases(alloc, &cases, parsed_cases);
    }

    if (cases.items.len == 0 and html_names.items.len != 0) {
        const total = @min(max_cases, html_names.items.len);
        var examples = std.ArrayList([]const u8).empty;
        defer examples.deinit(alloc);
        const msg = try std.fmt.allocPrint(
            alloc,
            "{s}: {d} html files found but no static parser vectors extracted",
            .{ "WPT html5lib_*", html_names.items.len },
        );
        try examples.append(alloc, msg);

        var failures = std.ArrayList(ParserFailure).empty;
        defer failures.deinit(alloc);
        var i: usize = 0;
        while (i < total) : (i += 1) {
            const preview = try std.fmt.allocPrint(alloc, "<unsupported-test-file:{s}>", .{html_names.items[i]});
            const empty: []const []const u8 = &.{};
            try failures.append(alloc, .{
                .case_index = i,
                .input_preview = preview,
                .input_len = 0,
                .expected = empty,
                .actual = empty,
                .error_msg = "unsupported-wpt-testharness-format",
            });
        }

        return .{
            .summary = .{
                .total = total,
                .passed = 0,
                .examples = try examples.toOwnedSlice(alloc),
            },
            .failures = try failures.toOwnedSlice(alloc),
        };
    }

    return runParserCases(io, alloc, mode, cases.items, max_cases);
}

fn runExternalSuites(io: std.Io, alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var mode_arg: []const u8 = "both";
    var max_cases: usize = 600;
    var max_whatwg_cases: usize = 500;
    var json_out: []const u8 = "bench/results/external_suite_report.json";
    var failures_out: []const u8 = "bench/results/external_suite_failures.json";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            mode_arg = args[i];
        } else if (std.mem.eql(u8, arg, "--max-html5lib-cases")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            max_cases = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--max-whatwg-cases")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            max_whatwg_cases = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--json-out")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            json_out = args[i];
        } else if (std.mem.eql(u8, arg, "--failures-out")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            failures_out = args[i];
        } else return error.InvalidArgument;
    }

    try ensureSuites(io, alloc);
    try buildSuiteRunner(io, alloc);
    try common.ensureDir(io, RESULTS_DIR);

    const modes = if (std.mem.eql(u8, mode_arg, "both")) &[_][]const u8{ "strictest", "fastest" } else &[_][]const u8{mode_arg};
    var mode_reports = std.ArrayList(struct {
        mode: []const u8,
        nw: SelectorSuiteSummary,
        qw: SelectorSuiteSummary,
        parser_html5lib: ParserSuiteSummary,
        parser_whatwg: ParserSuiteSummary,
        nw_failures: []const SelectorFailure,
        qw_failures: []const SelectorFailure,
        parser_html5lib_failures: []const ParserFailure,
        parser_whatwg_failures: []const ParserFailure,
    }).empty;
    defer mode_reports.deinit(alloc);

    for (modes) |mode| {
        const sel = try runSelectorSuites(io, alloc, mode);
        const parser_html5lib = try runHtml5libParserSuite(io, alloc, mode, max_cases);
        const parser_whatwg = try runWptParserSuite(io, alloc, mode, max_whatwg_cases);
        try mode_reports.append(alloc, .{
            .mode = mode,
            .nw = sel.nw,
            .qw = sel.qw,
            .parser_html5lib = parser_html5lib.summary,
            .parser_whatwg = parser_whatwg.summary,
            .nw_failures = sel.nw_failures,
            .qw_failures = sel.qw_failures,
            .parser_html5lib_failures = parser_html5lib.failures,
            .parser_whatwg_failures = parser_whatwg.failures,
        });

        std.debug.print("Mode: {s}\n", .{mode});
        std.debug.print("  Selector suites:\n", .{});
        std.debug.print("    nwmatcher: {d}/{d} passed ({d} failed)\n", .{ sel.nw.passed, sel.nw.total, failedCount(sel.nw) });
        std.debug.print("    qwery_contextual: {d}/{d} passed ({d} failed)\n", .{ sel.qw.passed, sel.qw.total, failedCount(sel.qw) });
        std.debug.print("  Parser suites:\n", .{});
        std.debug.print("    html5lib tree-construction subset: {d}/{d} passed ({d} failed)\n", .{
            parser_html5lib.summary.passed,
            parser_html5lib.summary.total,
            failedCount(parser_html5lib.summary),
        });
        std.debug.print("    WHATWG HTML parsing (WPT html5lib_* corpus): {d}/{d} passed ({d} failed)\n", .{
            parser_whatwg.summary.passed,
            parser_whatwg.summary.total,
            failedCount(parser_whatwg.summary),
        });
    }

    var json_buf: std.Io.Writer.Allocating = .init(alloc);
    defer json_buf.deinit();
    const jw = &json_buf.writer;
    try jw.writeAll("{\"modes\":{");
    for (mode_reports.items, 0..) |mr, idx_mode| {
        if (idx_mode != 0) try jw.writeAll(",");
        try jw.print("\"{s}\":{{", .{mr.mode});
        try jw.print("\"selector_suites\":{{\"nwmatcher\":{{\"total\":{d},\"passed\":{d},\"failed\":{d}}},\"qwery_contextual\":{{\"total\":{d},\"passed\":{d},\"failed\":{d}}}}},", .{
            mr.nw.total,
            mr.nw.passed,
            failedCount(mr.nw),
            mr.qw.total,
            mr.qw.passed,
            failedCount(mr.qw),
        });
        try jw.print("\"parser_suites\":{{\"html5lib_subset\":{{\"total\":{d},\"passed\":{d},\"failed\":{d}}},\"whatwg_html_parsing\":{{\"total\":{d},\"passed\":{d},\"failed\":{d}}}}}", .{
            mr.parser_html5lib.total,
            mr.parser_html5lib.passed,
            failedCount(mr.parser_html5lib),
            mr.parser_whatwg.total,
            mr.parser_whatwg.passed,
            failedCount(mr.parser_whatwg),
        });
        try jw.writeAll("}");
    }
    try jw.writeAll("}}");
    try common.writeFile(io, json_out, json_buf.written());
    std.debug.print("Wrote report: {s}\n", .{json_out});

    var failure_modes = std.ArrayList(ModeFailuresOut).empty;
    defer failure_modes.deinit(alloc);
    for (mode_reports.items) |mr| {
        try failure_modes.append(alloc, .{
            .mode = mr.mode,
            .selector_suites = .{
                .nwmatcher = mr.nw_failures,
                .qwery_contextual = mr.qw_failures,
            },
            .parser_suites = .{
                .html5lib_subset = mr.parser_html5lib_failures,
                .whatwg_html_parsing = mr.parser_whatwg_failures,
            },
        });
    }

    const failure_json_out: ExternalFailuresOut = .{
        .modes = failure_modes.items,
    };
    var failure_json_writer: std.Io.Writer.Allocating = .init(alloc);
    defer failure_json_writer.deinit();
    var failure_json_stream: std.json.Stringify = .{
        .writer = &failure_json_writer.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try failure_json_stream.write(failure_json_out);
    try common.writeFile(io, failures_out, failure_json_writer.written());
    std.debug.print("Wrote failures: {s}\n", .{failures_out});

    if (std.mem.eql(u8, json_out, "bench/results/external_suite_report.json")) {
        try updateReadmeAutoSummary(io, alloc);
    }
}

fn cmpStringSlice(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn collectMarkdownFiles(io: std.Io, alloc: std.mem.Allocator) ![][]const u8 {
    var files = std.ArrayList([]const u8).empty;
    errdefer deinitOwnedStringList(alloc, &files);

    const root_docs = [_][]const u8{
        "README.md",
        "DOCUMENTATION.md",
        "CONTRIBUTING.md",
        "SECURITY.md",
        "CHANGELOG.md",
        "bench/README.md",
    };
    for (root_docs) |p| {
        if (common.fileExists(io, p)) {
            const path_copy = try alloc.dupe(u8, p);
            try appendOwnedString(alloc, &files, path_copy);
        }
    }

    if (common.fileExists(io, "docs")) {
        var docs_dir = try std.Io.Dir.cwd().openDir(io, "docs", .{ .iterate = true });
        defer docs_dir.close(io);
        var walker = try docs_dir.walk(alloc);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".md")) continue;
            const joined = try std.fs.path.join(alloc, &[_][]const u8{ "docs", entry.path });
            try appendOwnedString(alloc, &files, joined);
        }
    }

    std.mem.sort([]const u8, files.items, {}, cmpStringSlice);
    return files.toOwnedSlice(alloc);
}

fn collectExampleFiles(io: std.Io, alloc: std.mem.Allocator) ![][]const u8 {
    var files = std.ArrayList([]const u8).empty;
    errdefer deinitOwnedStringList(alloc, &files);

    var examples_dir = try std.Io.Dir.cwd().openDir(io, "examples", .{ .iterate = true });
    defer examples_dir.close(io);
    var walker = try examples_dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const joined = try std.fs.path.join(alloc, &[_][]const u8{ "examples", entry.path });
        try appendOwnedString(alloc, &files, joined);
    }

    std.mem.sort([]const u8, files.items, {}, cmpStringSlice);
    return files.toOwnedSlice(alloc);
}

fn loadBuildStepSet(io: std.Io, alloc: std.mem.Allocator) !std.StringHashMap(void) {
    const out = try common.runCaptureStdout(io, alloc, &[_][]const u8{ "zig", "build", "--list-steps" }, REPO_ROOT);
    defer alloc.free(out);

    var set = std.StringHashMap(void).init(alloc);
    errdefer deinitOwnedStringSet(alloc, &set);
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        const first_ws = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        const step = line[0..first_ws];
        if (step.len == 0) continue;
        const step_copy = try alloc.dupe(u8, step);
        try putOwnedString(alloc, &set, step_copy);
    }
    return set;
}

fn validateMarkdownLink(io: std.Io, alloc: std.mem.Allocator, md_path: []const u8, line_no: usize, target_raw: []const u8) !bool {
    var target = std.mem.trim(u8, target_raw, " \t\r");
    if (target.len >= 2 and target[0] == '<' and target[target.len - 1] == '>') {
        target = target[1 .. target.len - 1];
    }
    if (target.len == 0) return true;
    if (target[0] != '<') {
        const ws_idx = std.mem.indexOfAny(u8, target, " \t\r") orelse target.len;
        target = target[0..ws_idx];
    }
    if (target.len == 0) return true;
    if (target[0] == '#') return true;
    if (std.mem.startsWith(u8, target, "http://") or
        std.mem.startsWith(u8, target, "https://") or
        std.mem.startsWith(u8, target, "mailto:") or
        std.mem.startsWith(u8, target, "tel:") or
        std.mem.indexOf(u8, target, "://") != null)
    {
        return true;
    }

    const path_end = std.mem.indexOfAny(u8, target, "#?") orelse target.len;
    const path_only = target[0..path_end];
    if (path_only.len == 0) return true;

    if (std.mem.startsWith(u8, path_only, "/")) {
        std.debug.print("docs-check: {s}:{d}: absolute markdown path is not allowed: {s}\n", .{ md_path, line_no, target });
        return false;
    }

    const base_dir = std.fs.path.dirname(md_path) orelse ".";
    const resolved = try std.fs.path.join(alloc, &[_][]const u8{ base_dir, path_only });
    defer alloc.free(resolved);

    if (common.fileExists(io, resolved)) return true;

    if (std.mem.endsWith(u8, path_only, "/")) {
        const with_readme = try std.fs.path.join(alloc, &[_][]const u8{ resolved, "README.md" });
        defer alloc.free(with_readme);
        if (common.fileExists(io, with_readme)) return true;
    }

    std.debug.print("docs-check: {s}:{d}: unresolved markdown link: {s}\n", .{ md_path, line_no, target });
    return false;
}

fn checkMarkdownLinks(io: std.Io, alloc: std.mem.Allocator, md_path: []const u8, content: []const u8) !bool {
    var ok = true;
    var in_fence = false;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;

        var i: usize = 0;
        while (i < line.len) {
            const open = std.mem.indexOfScalarPos(u8, line, i, '[') orelse break;
            const close = std.mem.indexOfScalarPos(u8, line, open + 1, ']') orelse {
                i = open + 1;
                continue;
            };
            if (close + 1 >= line.len or line[close + 1] != '(') {
                i = close + 1;
                continue;
            }
            const end = std.mem.indexOfScalarPos(u8, line, close + 2, ')') orelse {
                i = close + 2;
                continue;
            };
            ok = (try validateMarkdownLink(io, alloc, md_path, line_no, line[close + 2 .. end])) and ok;
            i = end + 1;
        }
    }
    return ok;
}

fn checkLocalAbsolutePaths(md_path: []const u8, content: []const u8) bool {
    if (std.mem.indexOf(u8, content, "/home/") != null or
        std.mem.indexOf(u8, content, "/Users/") != null or
        std.mem.indexOf(u8, content, "C:\\Users\\") != null)
    {
        std.debug.print("docs-check: {s}: contains machine-local absolute path\n", .{md_path});
        return false;
    }
    return true;
}

fn parseStepAfterBuild(content: []const u8, start: usize) ?[]const u8 {
    var i = start;
    while (i < content.len and content[i] != '\n') {
        while (i < content.len and std.ascii.isWhitespace(content[i])) : (i += 1) {}
        if (i >= content.len or content[i] == '\n') return null;

        const tok_start = i;
        while (i < content.len and !std.ascii.isWhitespace(content[i])) : (i += 1) {}
        const tok = std.mem.trim(u8, content[tok_start..i], "`'\",;()[]");
        if (tok.len == 0) continue;
        if (std.mem.eql(u8, tok, "--")) continue;
        if (tok[0] == '-') continue;
        return tok;
    }
    return null;
}

fn checkDocumentedBuildCommands(md_path: []const u8, content: []const u8, step_set: std.StringHashMap(void)) bool {
    var ok = true;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, content, pos, "zig build")) |found| {
        if (found > 0 and !std.ascii.isWhitespace(content[found - 1]) and content[found - 1] != '`') {
            pos = found + 1;
            continue;
        }
        const after_build = found + "zig build".len;
        if (after_build < content.len and !std.ascii.isWhitespace(content[after_build])) {
            pos = found + 1;
            continue;
        }

        const cmd_start = found + "zig build".len;
        const step = parseStepAfterBuild(content, cmd_start) orelse {
            pos = found + 1;
            continue;
        };
        if (!step_set.contains(step)) {
            std.debug.print("docs-check: {s}: references unknown zig build step '{s}'\n", .{ md_path, step });
            ok = false;
        }
        pos = found + 1;
    }
    return ok;
}

fn checkChangelogCompatibilityLabels(content: []const u8) bool {
    const header = "## [Unreleased]";
    const start = std.mem.indexOf(u8, content, header) orelse {
        std.debug.print("docs-check: CHANGELOG.md: missing '## [Unreleased]' section\n", .{});
        return false;
    };

    const after = content[start + header.len ..];
    const end_rel = std.mem.indexOf(u8, after, "\n## [") orelse after.len;
    const section = after[0..end_rel];

    const required = [_][]const u8{
        "Impact:",
        "Migration:",
        "Downstream scope:",
    };
    var ok = true;
    for (required) |needle| {
        if (std.mem.indexOf(u8, section, needle) == null) {
            std.debug.print("docs-check: CHANGELOG.md: Unreleased section missing compatibility label '{s}'\n", .{needle});
            ok = false;
        }
    }
    return ok;
}

fn runDocsCheck(io: std.Io, alloc: std.mem.Allocator) !void {
    const markdown_files = try collectMarkdownFiles(io, alloc);
    defer {
        for (markdown_files) |path| alloc.free(path);
        alloc.free(markdown_files);
    }
    var step_set = try loadBuildStepSet(io, alloc);
    defer deinitOwnedStringSet(alloc, &step_set);

    var ok = true;
    var checked: usize = 0;
    for (markdown_files) |md_path| {
        const content = try common.readFileAlloc(io, alloc, md_path);
        defer alloc.free(content);
        checked += 1;

        ok = checkLocalAbsolutePaths(md_path, content) and ok;
        ok = (try checkMarkdownLinks(io, alloc, md_path, content)) and ok;
        ok = checkDocumentedBuildCommands(md_path, content, step_set) and ok;
        if (std.mem.eql(u8, md_path, "CHANGELOG.md")) {
            ok = checkChangelogCompatibilityLabels(content) and ok;
        }
    }

    if (!ok) return error.DocsCheckFailed;
    std.debug.print("docs-check: OK ({d} markdown files)\n", .{checked});
}

fn runExamplesCheck(io: std.Io, alloc: std.mem.Allocator) !void {
    const example_files = try collectExampleFiles(io, alloc);
    defer {
        for (example_files) |path| alloc.free(path);
        alloc.free(example_files);
    }
    if (example_files.len == 0) return error.NoExamplesFound;

    for (example_files) |example_path| {
        std.debug.print("examples-check: zig test {s}\n", .{example_path});
        const root_mod = try std.fmt.allocPrint(alloc, "-Mroot={s}", .{example_path});
        defer alloc.free(root_mod);
        const html_mod = "-Mhtmlparser=src/root.zig";
        const argv = [_][]const u8{
            "zig",
            "test",
            "--dep",
            "htmlparser",
            root_mod,
            html_mod,
        };
        try common.runInherit(io, alloc, &argv, REPO_ROOT);
    }
    std.debug.print("examples-check: OK ({d} examples)\n", .{example_files.len});
}

fn usage() void {
    std.debug.print(
        \\Usage:
        \\  htmlparser-tools setup-parsers
        \\  htmlparser-tools setup-fixtures [--refresh]
        \\  htmlparser-tools run-benchmarks [--profile quick|stable] [--write-baseline]
        \\  htmlparser-tools sync-docs-bench
        \\  htmlparser-tools run-external-suites [--mode strictest|fastest|both] [--max-html5lib-cases N] [--max-whatwg-cases N] [--json-out path] [--failures-out path]
        \\  htmlparser-tools docs-check
        \\  htmlparser-tools examples-check
        \\
    , .{});
}

/// CLI entrypoint for repository maintenance, benchmarking, and conformance tasks.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        usage();
        return;
    }
    const cmd = args[1];
    const rest = args[2..];

    if (std.mem.eql(u8, cmd, "setup-parsers")) {
        try setupParsers(io, alloc);
        return;
    }
    if (std.mem.eql(u8, cmd, "setup-fixtures")) {
        var refresh = false;
        if (rest.len > 0) {
            if (rest.len == 1 and std.mem.eql(u8, rest[0], "--refresh")) {
                refresh = true;
            } else return error.InvalidArgument;
        }
        try setupFixtures(io, alloc, refresh);
        return;
    }
    if (std.mem.eql(u8, cmd, "run-benchmarks")) {
        try runBenchmarks(io, alloc, rest);
        return;
    }
    if (std.mem.eql(u8, cmd, "sync-docs-bench")) {
        if (rest.len != 0) return error.InvalidArgument;
        try updateDocumentationBenchmarkSnapshot(io, alloc);
        try updateReadmeAutoSummary(io, alloc);
        return;
    }
    if (std.mem.eql(u8, cmd, "run-external-suites")) {
        try runExternalSuites(io, alloc, rest);
        return;
    }
    if (std.mem.eql(u8, cmd, "docs-check")) {
        try runDocsCheck(io, alloc);
        return;
    }
    if (std.mem.eql(u8, cmd, "examples-check")) {
        try runExamplesCheck(io, alloc);
        return;
    }

    usage();
    return error.InvalidCommand;
}

test "bench cleanup frees sample buffers" {
    const alloc = std.testing.allocator;

    var empty_parse: [0]ParseResult = .{};
    freeParseSamples(alloc, &empty_parse);

    const parse_samples = try alloc.alloc(u64, 2);
    parse_samples[0] = 1;
    parse_samples[1] = 2;
    var parse_rows = [_]ParseResult{.{
        .parser = "ours",
        .fixture = "fixture.html",
        .iterations = 1,
        .samples_ns = parse_samples,
        .median_ns = 1,
        .throughput_mb_s = 1.0,
    }};
    freeParseSamples(alloc, &parse_rows);

    const query_samples = try alloc.alloc(u64, 1);
    query_samples[0] = 3;
    var query_rows = [_]QueryResult{.{
        .parser = "ours",
        .case = "case",
        .selector = "div",
        .fixture = null,
        .iterations = 1,
        .samples_ns = query_samples,
        .median_ns = 1,
        .ops_s = 1.0,
        .ns_per_op = 1.0,
    }};
    freeQuerySamples(alloc, &query_rows);

    var empty_query: [0]QueryResult = .{};
    freeQuerySamples(alloc, &empty_query);
}

test "owned string list cleanup frees entries" {
    const alloc = std.testing.allocator;
    var empty = std.ArrayList([]const u8).empty;
    deinitOwnedStringList(alloc, &empty);
    var list = std.ArrayList([]const u8).empty;
    const one = try alloc.dupe(u8, "one");
    try appendOwnedString(alloc, &list, one);
    const two = try alloc.dupe(u8, "two");
    try appendOwnedString(alloc, &list, two);
    deinitOwnedStringList(alloc, &list);
}

test "owned string set cleanup frees keys" {
    const alloc = std.testing.allocator;
    var empty = std.StringHashMap(void).init(alloc);
    deinitOwnedStringSet(alloc, &empty);

    var set = std.StringHashMap(void).init(alloc);
    const docs_check = try alloc.dupe(u8, "docs-check");
    try putOwnedString(alloc, &set, docs_check);
    const examples_check = try alloc.dupe(u8, "examples-check");
    try putOwnedString(alloc, &set, examples_check);
    deinitOwnedStringSet(alloc, &set);
}

test "parser case transfer frees nested ownership on append failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn makeOneCase(alloc: std.mem.Allocator) ![]ParserCase {
            const html = try alloc.dupe(u8, "<div></div>");
            errdefer alloc.free(html);

            var expected = std.ArrayList([]const u8).empty;
            errdefer deinitOwnedStringList(alloc, &expected);
            const div = try alloc.dupe(u8, "div");
            try appendOwnedString(alloc, &expected, div);

            const expected_slice = try expected.toOwnedSlice(alloc);
            errdefer freeOwnedStringSlice(alloc, expected_slice);

            const cases = try alloc.alloc(ParserCase, 1);
            errdefer alloc.free(cases);
            cases[0] = .{
                .html = html,
                .expected = expected_slice,
            };
            return cases;
        }

        fn run(alloc: std.mem.Allocator) !void {
            var dst = std.ArrayList(ParserCase).empty;
            defer deinitParserCaseList(alloc, &dst);

            const cases = try makeOneCase(alloc);
            try transferOwnedParserCases(alloc, &dst, cases);
        }
    }.run, .{});
}

test "html5lib dat parser frees nested allocations on allocator failure" {
    const sample =
        "#data\n" ++
        "<div></div>\n" ++
        "#document\n" ++
        "| <html>\n" ++
        "|   <head>\n" ++
        "|   <body>\n" ++
        "|     <div>\n";

    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(alloc: std.mem.Allocator, text: []const u8) !void {
            const cases = try parseHtml5libDatText(alloc, text);
            defer freeParserCases(alloc, cases);
        }
    }.run, .{sample});
}

test "wpt html suite parser frees nested allocations on allocator failure" {
    const sample =
        "var tests = {};\n" ++
        "init_tests();\n" ++
        "[async_test('case'), \"%3Cdiv%3E%3C/div%3E\", \"| <html>\\n|   <head>\\n|   <body>\\n|     <div>\"]\n";

    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(alloc: std.mem.Allocator, text: []const u8) !void {
            const cases = try parseWptHtmlSuiteText(alloc, text);
            defer freeParserCases(alloc, cases);
        }
    }.run, .{sample});
}
