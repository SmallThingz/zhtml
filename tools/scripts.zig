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

fn pathExists(path: []const u8) bool {
    return common.fileExists(path);
}

fn setupParsers(alloc: std.mem.Allocator) !void {
    try common.ensureDir(PARSERS_DIR);
    const repos = [_]struct { url: []const u8, dir: []const u8 }{
        .{ .url = "https://github.com/lexbor/lexbor.git", .dir = "lexbor" },
        .{ .url = "https://github.com/cloudflare/lol-html.git", .dir = "lol-html" },
    };
    for (repos) |repo| {
        const git_path = try std.fmt.allocPrint(alloc, "{s}/{s}/.git", .{ PARSERS_DIR, repo.dir });
        defer alloc.free(git_path);
        if (pathExists(git_path)) {
            std.debug.print("already present: {s}\n", .{repo.dir});
            continue;
        }
        std.debug.print("cloning: {s}\n", .{repo.dir});
        const dst = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ PARSERS_DIR, repo.dir });
        defer alloc.free(dst);
        const argv = [_][]const u8{ "git", "clone", "--depth", "1", repo.url, dst };
        try common.runInherit(alloc, &argv, REPO_ROOT);
    }
    std.debug.print("done\n", .{});
}

fn setupFixtures(alloc: std.mem.Allocator, refresh: bool) !void {
    try common.ensureDir(FIXTURES_DIR);
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
            const stat = std.fs.cwd().statFile(target) catch null;
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
        try common.runInherit(alloc, &argv, REPO_ROOT);
    }
    std.debug.print("fixtures ready in {s}\n", .{FIXTURES_DIR});
}

fn ensureExternalParsersBuilt(alloc: std.mem.Allocator) !void {
    if (!pathExists("bench/parsers/lol-html/Cargo.toml")) {
        try setupParsers(alloc);
    }

    if (!pathExists("bench/build/lexbor/liblexbor_static.a")) {
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
        try common.runInherit(alloc, &cmake_cfg, REPO_ROOT);
        const cmake_build = [_][]const u8{ "cmake", "--build", "bench/build/lexbor", "-j" };
        try common.runInherit(alloc, &cmake_build, REPO_ROOT);
    }
}

fn buildRunners(alloc: std.mem.Allocator) !void {
    try common.ensureDir(BIN_DIR);
    const zig_build = [_][]const u8{ "zig", "build", "-Doptimize=ReleaseFast" };
    try common.runInherit(alloc, &zig_build, REPO_ROOT);

    const strlen_cc = [_][]const u8{
        "cc",
        "-O3",
        "-fno-builtin",
        "bench/runners/strlen_runner.c",
        "-o",
        "bench/build/bin/strlen_runner",
    };
    try common.runInherit(alloc, &strlen_cc, REPO_ROOT);

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
    try common.runInherit(alloc, &lexbor_cc, REPO_ROOT);

    const cargo_lol = [_][]const u8{
        "cargo",
        "build",
        "--release",
        "--manifest-path",
        "bench/runners/lol_html_runner/Cargo.toml",
    };
    try common.runInherit(alloc, &cargo_lol, REPO_ROOT);
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
    mode: []const u8,
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
    failed: usize,
};

const ExternalSuiteMode = struct {
    selector_suites: struct {
        nwmatcher: ExternalSuiteCounts,
        qwery_contextual: ExternalSuiteCounts,
    },
    parser_suites: ?struct {
        html5lib_subset: ExternalSuiteCounts,
        whatwg_html_parsing: ExternalSuiteCounts,
        wpt_html_parsing: ExternalSuiteCounts,
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

fn runIntCmd(alloc: std.mem.Allocator, argv: []const []const u8) !u64 {
    const taskset_path: ?[]const u8 = blk: {
        if (common.fileExists("/usr/bin/taskset")) break :blk "/usr/bin/taskset";
        if (common.fileExists("/bin/taskset")) break :blk "/bin/taskset";
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

    const out = try common.runCaptureCombined(alloc, run_argv, REPO_ROOT);
    defer alloc.free(out);
    return common.parseLastInt(out);
}

fn benchParseOne(alloc: std.mem.Allocator, parser_name: []const u8, fixture_name: []const u8, iterations: usize) !ParseResult {
    const fixture = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ FIXTURES_DIR, fixture_name });
    defer alloc.free(fixture);
    const stat = try std.fs.cwd().statFile(fixture);
    const size_bytes = stat.size;

    {
        const warm = try runnerCmdParse(alloc, parser_name, fixture, 1);
        defer freeArgv(alloc, warm);
        _ = try runIntCmd(alloc, warm);
    }

    const samples = try alloc.alloc(u64, repeats);
    for (samples) |*slot| {
        const argv = try runnerCmdParse(alloc, parser_name, fixture, iterations);
        defer freeArgv(alloc, argv);
        slot.* = try runIntCmd(alloc, argv);
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

fn benchQueryParseOne(alloc: std.mem.Allocator, parser_name: []const u8, case_name: []const u8, selector: []const u8, iterations: usize) !QueryResult {
    const iter_s = try std.fmt.allocPrint(alloc, "{d}", .{iterations});
    defer alloc.free(iter_s);

    {
        const warm = [_][]const u8{ "zig-out/bin/htmlparser-bench", "query-parse", selector, "1" };
        _ = try runIntCmd(alloc, &warm);
    }

    const samples = try alloc.alloc(u64, repeats);
    for (samples) |*slot| {
        const argv = [_][]const u8{ "zig-out/bin/htmlparser-bench", "query-parse", selector, iter_s };
        slot.* = try runIntCmd(alloc, &argv);
    }

    const median_ns = try common.medianU64(alloc, samples);
    const seconds = @as(f64, @floatFromInt(median_ns)) / 1_000_000_000.0;
    const ops_s = if (seconds > 0.0) @as(f64, @floatFromInt(iterations)) / seconds else 0.0;
    const ns_per_op = @as(f64, @floatFromInt(median_ns)) / @as(f64, @floatFromInt(iterations));
    return .{
        .parser = parser_name,
        .mode = "runtime",
        .case = case_name,
        .selector = selector,
        .iterations = iterations,
        .samples_ns = samples,
        .median_ns = median_ns,
        .ops_s = ops_s,
        .ns_per_op = ns_per_op,
    };
}

fn benchQueryExecOne(alloc: std.mem.Allocator, parser_name: []const u8, mode: []const u8, case_name: []const u8, fixture_name: []const u8, selector: []const u8, iterations: usize, cached: bool) !QueryResult {
    const fixture = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ FIXTURES_DIR, fixture_name });
    defer alloc.free(fixture);
    const iter_s = try std.fmt.allocPrint(alloc, "{d}", .{iterations});
    defer alloc.free(iter_s);
    const sub = if (cached) "query-cached" else "query-match";

    {
        const warm = [_][]const u8{ "zig-out/bin/htmlparser-bench", sub, mode, fixture, selector, "1" };
        _ = try runIntCmd(alloc, &warm);
    }

    const samples = try alloc.alloc(u64, repeats);
    for (samples) |*slot| {
        const argv = [_][]const u8{ "zig-out/bin/htmlparser-bench", sub, mode, fixture, selector, iter_s };
        slot.* = try runIntCmd(alloc, &argv);
    }
    const median_ns = try common.medianU64(alloc, samples);
    const seconds = @as(f64, @floatFromInt(median_ns)) / 1_000_000_000.0;
    const ops_s = if (seconds > 0.0) @as(f64, @floatFromInt(iterations)) / seconds else 0.0;
    const ns_per_op = @as(f64, @floatFromInt(median_ns)) / @as(f64, @floatFromInt(iterations));
    return .{
        .parser = parser_name,
        .mode = mode,
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

fn appendUniqueString(list: *std.ArrayList([]const u8), alloc: std.mem.Allocator, value: []const u8) !void {
    for (list.items) |it| {
        if (std.mem.eql(u8, it, value)) return;
    }
    try list.append(alloc, value);
}

fn writeMaybeF64(w: anytype, value: ?f64) !void {
    if (value) |v| {
        try w.print("{d:.2}", .{v});
    } else {
        try w.writeAll("-");
    }
}

fn renderDocumentationBenchmarkSection(alloc: std.mem.Allocator, snap: ReadmeBenchSnapshot) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    const w = out.writer(alloc);

    var fixtures = std.ArrayList([]const u8).empty;
    defer fixtures.deinit(alloc);
    for (snap.parse_results) |row| {
        try appendUniqueString(&fixtures, alloc, row.fixture);
    }

    var query_match_cases = std.ArrayList([]const u8).empty;
    defer query_match_cases.deinit(alloc);
    for (snap.query_match_results) |row| {
        try appendUniqueString(&query_match_cases, alloc, row.case);
    }

    var query_parse_cases = std.ArrayList([]const u8).empty;
    defer query_parse_cases.deinit(alloc);
    for (snap.query_parse_results) |row| {
        try appendUniqueString(&query_parse_cases, alloc, row.case);
    }

    try w.print("Source: `bench/results/latest.json` (`{s}` profile).\n\n", .{snap.profile});

    try w.writeAll("#### Parse Throughput Comparison (MB/s)\n\n");
    try w.writeAll("| Fixture | ours | lol-html | lexbor |\n");
    try w.writeAll("|---|---:|---:|---:|\n");
    for (fixtures.items) |fixture| {
        try w.print("| `{s}` | ", .{fixture});
        try writeMaybeF64(w, findReadmeParseThroughput(snap.parse_results, "ours", fixture));
        try w.writeAll(" | ");
        try writeMaybeF64(w, findReadmeParseThroughput(snap.parse_results, "lol-html", fixture));
        try w.writeAll(" | ");
        try writeMaybeF64(w, findReadmeParseThroughput(snap.parse_results, "lexbor", fixture));
        try w.writeAll(" |\n");
    }

    try w.writeAll("\n#### Query Match Throughput (ours)\n\n");
    try w.writeAll("| Case | ours ops/s | ours ns/op |\n");
    try w.writeAll("|---|---:|---:|\n");
    for (query_match_cases.items) |case_name| {
        const ours = findReadmeQuery(snap.query_match_results, "ours", case_name);
        try w.print("| `{s}` | ", .{case_name});
        try writeMaybeF64(w, if (ours) |s| s.ops_s else null);
        try w.writeAll(" | ");
        try writeMaybeF64(w, if (ours) |s| s.ns_per_op else null);
        try w.writeAll(" |\n");
    }

    try w.writeAll("\n#### Cached Query Throughput (ours)\n\n");
    try w.writeAll("| Case | ours ops/s | ours ns/op |\n");
    try w.writeAll("|---|---:|---:|\n");
    for (query_match_cases.items) |case_name| {
        const ours = findReadmeQuery(snap.query_cached_results, "ours", case_name);
        try w.print("| `{s}` | ", .{case_name});
        try writeMaybeF64(w, if (ours) |s| s.ops_s else null);
        try w.writeAll(" | ");
        try writeMaybeF64(w, if (ours) |s| s.ns_per_op else null);
        try w.writeAll(" |\n");
    }

    try w.writeAll("\n#### Query Parse Throughput (ours)\n\n");
    try w.writeAll("| Selector case | Ops/s | ns/op |\n");
    try w.writeAll("|---|---:|---:|\n");
    for (query_parse_cases.items) |case_name| {
        const ours = findReadmeQuery(snap.query_parse_results, "ours", case_name);
        try w.print("| `{s}` | ", .{case_name});
        try writeMaybeF64(w, if (ours) |r| r.ops_s else null);
        try w.writeAll(" | ");
        try writeMaybeF64(w, if (ours) |r| r.ns_per_op else null);
        try w.writeAll(" |\n");
    }

    try w.writeAll("\nFor full per-parser, per-fixture tables and gate output:\n");
    try w.writeAll("- `bench/results/latest.md`\n");
    try w.writeAll("- `bench/results/latest.json`\n");

    return out.toOwnedSlice(alloc);
}

fn updateDocumentationBenchmarkSnapshot(alloc: std.mem.Allocator) !void {
    const latest_json = try common.readFileAlloc(alloc, "bench/results/latest.json");
    defer alloc.free(latest_json);

    const parsed = try std.json.parseFromSlice(ReadmeBenchSnapshot, alloc, latest_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const replacement = try renderDocumentationBenchmarkSection(alloc, parsed.value);
    defer alloc.free(replacement);

    const documentation = try common.readFileAlloc(alloc, "DOCUMENTATION.md");
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
        try common.writeFile("DOCUMENTATION.md", out.items);
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

fn writeSpaces(w: anytype, count: usize) !void {
    for (0..count) |_| try w.writeAll(" ");
}

fn writeRepeatGlyph(w: anytype, glyph: []const u8, count: usize) !void {
    for (0..count) |_| try w.writeAll(glyph);
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

fn writeConformanceRow(
    w: anytype,
    profile: []const u8,
    nw: ExternalSuiteCounts,
    qw: ExternalSuiteCounts,
    html5lib: ExternalSuiteCounts,
    whatwg: ExternalSuiteCounts,
    wpt: ExternalSuiteCounts,
) !void {
    try w.print("| `{s}` | {d}/{d} ({d} failed) | {d}/{d} ({d} failed) | {d}/{d} ({d} failed) | {d}/{d} ({d} failed) | {d}/{d} ({d} failed) |\n", .{
        profile,
        nw.passed,
        nw.total,
        nw.failed,
        qw.passed,
        qw.total,
        qw.failed,
        html5lib.passed,
        html5lib.total,
        html5lib.failed,
        whatwg.passed,
        whatwg.total,
        whatwg.failed,
        wpt.passed,
        wpt.total,
        wpt.failed,
    });
}

fn parserHtml5libCounts(mode: ExternalSuiteMode) ExternalSuiteCounts {
    if (mode.parser_suites) |s| return s.html5lib_subset;
    return .{ .total = 0, .passed = 0, .failed = 0 };
}

fn parserWhatwgCounts(mode: ExternalSuiteMode) ExternalSuiteCounts {
    if (mode.parser_suites) |s| return s.whatwg_html_parsing;
    return .{ .total = 0, .passed = 0, .failed = 0 };
}

fn parserWptCounts(mode: ExternalSuiteMode) ExternalSuiteCounts {
    if (mode.parser_suites) |s| return s.wpt_html_parsing;
    return .{ .total = 0, .passed = 0, .failed = 0 };
}

fn sameExternalMode(a: ExternalSuiteMode, b: ExternalSuiteMode) bool {
    const a_html5 = parserHtml5libCounts(a);
    const b_html5 = parserHtml5libCounts(b);
    const a_whatwg = parserWhatwgCounts(a);
    const b_whatwg = parserWhatwgCounts(b);
    const a_wpt = parserWptCounts(a);
    const b_wpt = parserWptCounts(b);

    return a.selector_suites.nwmatcher.total == b.selector_suites.nwmatcher.total and
        a.selector_suites.nwmatcher.passed == b.selector_suites.nwmatcher.passed and
        a.selector_suites.nwmatcher.failed == b.selector_suites.nwmatcher.failed and
        a.selector_suites.qwery_contextual.total == b.selector_suites.qwery_contextual.total and
        a.selector_suites.qwery_contextual.passed == b.selector_suites.qwery_contextual.passed and
        a.selector_suites.qwery_contextual.failed == b.selector_suites.qwery_contextual.failed and
        a_html5.total == b_html5.total and
        a_html5.passed == b_html5.passed and
        a_html5.failed == b_html5.failed and
        a_whatwg.total == b_whatwg.total and
        a_whatwg.passed == b_whatwg.passed and
        a_whatwg.failed == b_whatwg.failed and
        a_wpt.total == b_wpt.total and
        a_wpt.passed == b_wpt.passed and
        a_wpt.failed == b_wpt.failed;
}

fn renderReadmeAutoSummary(alloc: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    const w = out.writer(alloc);

    const latest_exists = common.fileExists("bench/results/latest.json");
    if (latest_exists) {
        const latest_json = try common.readFileAlloc(alloc, "bench/results/latest.json");
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
            try writeSpaces(w, max_name_len - r.parser.len);
            try w.writeAll(" │");
            try writeRepeatGlyph(w, "█", filled);
            try writeRepeatGlyph(w, "░", width - filled);
            try w.print("│ {d:.2} MB/s ({d:.2}%)\n", .{ r.avg_mb_s, pct });
        }
        try w.writeAll("```\n");
    } else {
        try w.writeAll("Run `zig build bench-compare` to generate parse performance summary.\n");
    }

    try w.writeAll("\n### Conformance Snapshot\n\n");
    if (common.fileExists("bench/results/external_suite_report.json")) {
        const ext_json = try common.readFileAlloc(alloc, "bench/results/external_suite_report.json");
        defer alloc.free(ext_json);
        const parsed_ext = try std.json.parseFromSlice(ExternalSuiteReport, alloc, ext_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed_ext.deinit();
        const modes = parsed_ext.value.modes;

        try w.writeAll("| Profile | nwmatcher | qwery_contextual | html5lib subset | WHATWG HTML parsing | WPT HTML parsing |\n");
        try w.writeAll("|---|---:|---:|---:|---:|---:|\n");
        if (modes.strictest != null and modes.fastest != null and sameExternalMode(modes.strictest.?, modes.fastest.?)) {
            const m = modes.strictest.?;
            try writeConformanceRow(
                w,
                "strictest/fastest",
                m.selector_suites.nwmatcher,
                m.selector_suites.qwery_contextual,
                parserHtml5libCounts(m),
                parserWhatwgCounts(m),
                parserWptCounts(m),
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
                    parserWptCounts(m),
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
                    parserWptCounts(m),
                );
            }
        }
        try w.writeAll("\nSource: `bench/results/external_suite_report.json`\n");
    } else {
        try w.writeAll("Run `zig build conformance` to generate conformance summary.\n");
    }

    return out.toOwnedSlice(alloc);
}

fn updateReadmeAutoSummary(alloc: std.mem.Allocator) !void {
    const replacement = try renderReadmeAutoSummary(alloc);
    defer alloc.free(replacement);

    const readme = try common.readFileAlloc(alloc, "README.md");
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
        try common.writeFile("README.md", out.items);
        std.debug.print("wrote README.md auto summary\n", .{});
    } else {
        std.debug.print("README.md auto summary already up-to-date\n", .{});
    }
}

fn writeMarkdown(
    alloc: std.mem.Allocator,
    profile_name: []const u8,
    parse_results: []const ParseResult,
    query_parse_results: []const QueryResult,
    query_match_results: []const QueryResult,
    query_cached_results: []const QueryResult,
    gate_rows: []const GateRow,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    const w = out.writer(alloc);

    try w.print("# HTML Parser Benchmark Results\n\nGenerated (unix): {d}\n\nProfile: `{s}`\n\n", .{ common.nowUnix(), profile_name });
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

    try writeQuerySection(alloc, &out, "## Query Parse Throughput", query_parse_results);
    try writeQuerySection(alloc, &out, "## Query Match Throughput", query_match_results);
    try writeQuerySection(alloc, &out, "## Query Cached Throughput", query_cached_results);

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

    return out.toOwnedSlice(alloc);
}

fn writeQuerySection(alloc: std.mem.Allocator, out: *std.ArrayList(u8), title: []const u8, rows: []const QueryResult) !void {
    const w = out.writer(alloc);
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

fn rerunFailedGateRows(alloc: std.mem.Allocator, profile: Profile, gate_rows: []GateRow) !void {
    if (!std.mem.eql(u8, profile.name, "stable")) return;

    for (gate_rows) |*row| {
        if (row.pass) continue;

        const iters0 = fixtureIterations(profile, row.fixture);
        if (iters0 == 0) continue;
        const iters = @max(iters0 * 2, iters0 + 1);

        std.debug.print("re-running flaky gate fixture {s} at {d} iters\n", .{ row.fixture, iters });

        const ours = try benchParseOne(alloc, "ours", row.fixture, iters);
        defer alloc.free(ours.samples_ns);
        const lol = try benchParseOne(alloc, "lol-html", row.fixture, iters);
        defer alloc.free(lol.samples_ns);

        row.ours_mb_s = ours.throughput_mb_s;
        row.lol_html_mb_s = lol.throughput_mb_s;
        row.pass = row.ours_mb_s > row.lol_html_mb_s;
    }
}

fn renderConsole(
    alloc: std.mem.Allocator,
    profile_name: []const u8,
    parse_results: []const ParseResult,
    query_parse_results: []const QueryResult,
    query_match_results: []const QueryResult,
    query_cached_results: []const QueryResult,
    gate_rows: []const GateRow,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    const w = out.writer(alloc);

    try w.writeAll("HTML Parser Benchmark Results\n");
    try w.print("Generated (unix): {d}\n", .{common.nowUnix()});
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

    try renderQueryConsoleSection(alloc, &out, "Query Parse Throughput", query_parse_results);
    try renderQueryConsoleSection(alloc, &out, "Query Match Throughput", query_match_results);
    try renderQueryConsoleSection(alloc, &out, "Query Cached Throughput", query_cached_results);

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

    return out.toOwnedSlice(alloc);
}

fn appendAsciiSep(writer: anytype, widths: []const usize) !void {
    try writer.writeAll("+-");
    for (widths, 0..) |w, i| {
        try writer.writeByteNTimes('-', w);
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
            try writer.writeByteNTimes(' ', pad);
            try writer.writeAll(cell);
        } else {
            try writer.writeAll(cell);
            try writer.writeByteNTimes(' ', pad);
        }
        if (i + 1 == cells.len) {
            try writer.writeAll(" |\n");
        } else {
            try writer.writeAll(" | ");
        }
    }
}

fn renderQueryConsoleSection(alloc: std.mem.Allocator, out: *std.ArrayList(u8), title: []const u8, rows: []const QueryResult) !void {
    const w = out.writer(alloc);
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

fn runBenchmarks(alloc: std.mem.Allocator, args: []const []const u8) !void {
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

    try common.ensureDir(BIN_DIR);
    try common.ensureDir(RESULTS_DIR);
    try ensureExternalParsersBuilt(alloc);
    try buildRunners(alloc);

    var parse_results = std.ArrayList(ParseResult).empty;
    defer parse_results.deinit(alloc);

    for (profile.fixtures) |fixture| {
        for (parse_parsers) |parser_name| {
            std.debug.print("benchmarking {s} on {s} ({d} iters)\n", .{ parser_name, fixture.name, fixture.iterations });
            const row = try benchParseOne(alloc, parser_name, fixture.name, fixture.iterations);
            try parse_results.append(alloc, row);
        }
    }

    var query_parse_results = std.ArrayList(QueryResult).empty;
    defer query_parse_results.deinit(alloc);
    for (query_parse_modes) |qm| {
        for (profile.query_parse_cases) |qc| {
            std.debug.print("benchmarking query-parse {s} on {s} ({d} iters)\n", .{ qm.parser, qc.name, qc.iterations });
            const row = try benchQueryParseOne(alloc, qm.parser, qc.name, qc.selector, qc.iterations);
            try query_parse_results.append(alloc, row);
        }
    }

    var query_match_results = std.ArrayList(QueryResult).empty;
    defer query_match_results.deinit(alloc);
    for (query_modes) |qm| {
        for (profile.query_match_cases) |qc| {
            std.debug.print("benchmarking query-match {s} on {s} ({d} iters)\n", .{ qm.parser, qc.name, qc.iterations });
            const row = try benchQueryExecOne(alloc, qm.parser, qm.mode, qc.name, qc.fixture, qc.selector, qc.iterations, false);
            try query_match_results.append(alloc, row);
        }
    }

    var query_cached_results = std.ArrayList(QueryResult).empty;
    defer query_cached_results.deinit(alloc);
    for (query_modes) |qm| {
        for (profile.query_cached_cases) |qc| {
            std.debug.print("benchmarking query-cached {s} on {s} ({d} iters)\n", .{ qm.parser, qc.name, qc.iterations });
            const row = try benchQueryExecOne(alloc, qm.parser, qm.mode, qc.name, qc.fixture, qc.selector, qc.iterations, true);
            try query_cached_results.append(alloc, row);
        }
    }

    const gate_rows = try evaluateGateRows(alloc, profile, parse_results.items);
    defer alloc.free(gate_rows);
    try rerunFailedGateRows(alloc, profile, gate_rows);

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
        .generated_unix = common.nowUnix(),
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

    var json_writer: std.io.Writer.Allocating = .init(alloc);
    defer json_writer.deinit();
    var json_stream: std.json.Stringify = .{
        .writer = &json_writer.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try json_stream.write(json_out);
    try common.writeFile("bench/results/latest.json", json_writer.written());

    const md = try writeMarkdown(alloc, profile.name, parse_results.items, query_parse_results.items, query_match_results.items, query_cached_results.items, gate_rows);
    defer alloc.free(md);
    try common.writeFile("bench/results/latest.md", md);
    try updateDocumentationBenchmarkSnapshot(alloc);
    try updateReadmeAutoSummary(alloc);

    // Optional baseline behavior.
    const baseline_default = try std.fmt.allocPrint(alloc, "bench/results/baseline_{s}.json", .{profile.name});
    defer alloc.free(baseline_default);

    if (write_baseline) {
        try common.writeFile(baseline_default, json_writer.written());
        std.debug.print("wrote baseline {s}\n", .{baseline_default});
    }

    var failures = std.ArrayList([]const u8).empty;
    defer failures.deinit(alloc);

    for (gate_rows) |g| {
        if (std.mem.eql(u8, profile.name, "stable") and !g.pass) {
            const msg = try std.fmt.allocPrint(alloc, "stable ours-vs-lol fail: {s} ours {d:.2} <= lol-html {d:.2}", .{ g.fixture, g.ours_mb_s, g.lol_html_mb_s });
            try failures.append(alloc, msg);
        }
    }

    std.debug.print("wrote bench/results/latest.json\n", .{});
    std.debug.print("wrote bench/results/latest.md\n\n", .{});
    const console = try renderConsole(alloc, profile.name, parse_results.items, query_parse_results.items, query_match_results.items, query_cached_results.items, gate_rows);
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
    failed: usize,
    examples: []const []const u8,
};

const ParserSuiteSummary = struct {
    total: usize,
    passed: usize,
    failed: usize,
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
        wpt_html_parsing: []const ParserFailure,
    },
};

fn ensureSuites(alloc: std.mem.Allocator) !void {
    try common.ensureDir(SUITES_CACHE_DIR);
    try common.ensureDir(SUITES_DIR);

    const repos = [_]struct { name: []const u8, url: []const u8 }{
        .{ .name = "html5lib-tests", .url = "https://github.com/html5lib/html5lib-tests.git" },
        .{ .name = "css-select", .url = "https://github.com/fb55/css-select.git" },
        .{ .name = "wpt", .url = "https://github.com/web-platform-tests/wpt.git" },
        .{ .name = "whatwg-html", .url = "https://github.com/whatwg/html.git" },
    };

    for (repos) |repo| {
        const cache_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ SUITES_CACHE_DIR, repo.name });
        defer alloc.free(cache_path);
        if (!pathExists(cache_path)) {
            const clone_argv = [_][]const u8{ "git", "clone", "--depth", "1", repo.url, cache_path };
            try common.runInherit(alloc, &clone_argv, REPO_ROOT);
        } else {
            const pull_argv = [_][]const u8{ "git", "-C", cache_path, "pull", "--ff-only" };
            common.runInherit(alloc, &pull_argv, REPO_ROOT) catch {};
        }

        const dst = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ SUITES_DIR, repo.name });
        defer alloc.free(dst);
        if (!pathExists(dst)) {
            const work_clone_argv = [_][]const u8{ "git", "clone", "--depth", "1", cache_path, dst };
            try common.runInherit(alloc, &work_clone_argv, REPO_ROOT);
        }
    }
}

fn buildSuiteRunner(alloc: std.mem.Allocator) !void {
    try common.ensureDir(BIN_DIR);
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
    try common.runInherit(alloc, &argv, REPO_ROOT);
}

fn runSelectorCount(alloc: std.mem.Allocator, mode: []const u8, fixture: []const u8, selector: []const u8) !usize {
    const argv = [_][]const u8{ SUITE_RUNNER_BIN, "selector-count", mode, fixture, selector };
    const out = try common.runCaptureStdout(alloc, &argv, REPO_ROOT);
    defer alloc.free(out);
    return std.fmt.parseInt(usize, out, 10);
}

fn runSelectorCountScoped(alloc: std.mem.Allocator, mode: []const u8, fixture: []const u8, scope_tag: []const u8, selector: []const u8) !usize {
    const argv = [_][]const u8{ SUITE_RUNNER_BIN, "selector-count-scope-tag", mode, fixture, scope_tag, selector };
    const out = try common.runCaptureStdout(alloc, &argv, REPO_ROOT);
    defer alloc.free(out);
    return std.fmt.parseInt(usize, out, 10);
}

fn runParseTagsFile(alloc: std.mem.Allocator, mode: []const u8, fixture: []const u8) ![]const u8 {
    const argv = [_][]const u8{ SUITE_RUNNER_BIN, "parse-tags-file", mode, fixture };
    return common.runCaptureStdout(alloc, &argv, REPO_ROOT);
}

fn tempHtmlFile(alloc: std.mem.Allocator, html: []const u8) ![]u8 {
    const r = std.crypto.random.int(u64);
    const path = try std.fmt.allocPrint(alloc, "/tmp/htmlparser-suite-{x}.html", .{r});
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(html);
    return path;
}

fn loadNwCases(alloc: std.mem.Allocator) ![]NwCase {
    const bytes = try common.readFileAlloc(alloc, CONFORMANCE_CASES_DIR ++ "/nwmatcher_cases.json");
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

fn loadQwCases(alloc: std.mem.Allocator) ![]QwCase {
    const bytes = try common.readFileAlloc(alloc, CONFORMANCE_CASES_DIR ++ "/qwery_cases.json");
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

fn htmlPreview(alloc: std.mem.Allocator, html: []const u8) ![]const u8 {
    const max_preview: usize = 220;
    const clipped = html[0..@min(html.len, max_preview)];
    return std.mem.replaceOwned(u8, alloc, clipped, "\n", "\\n");
}

fn runSelectorSuites(alloc: std.mem.Allocator, mode: []const u8) !SelectorSuitesResult {
    const nw_cases = try loadNwCases(alloc);
    defer {
        for (nw_cases) |c| alloc.free(c.selector);
        alloc.free(nw_cases);
    }
    const qw_cases = try loadQwCases(alloc);
    defer {
        for (qw_cases) |c| {
            alloc.free(c.selector);
            alloc.free(c.context);
        }
        alloc.free(qw_cases);
    }

    const nw_fixture = SUITES_DIR ++ "/css-select/test/fixtures/nwmatcher.html";
    const qw_fixture = SUITES_DIR ++ "/css-select/test/fixtures/qwery.html";
    const qw_doc_html = try common.readFileAlloc(alloc, CONFORMANCE_CASES_DIR ++ "/qwery_doc.html");
    defer alloc.free(qw_doc_html);
    const qw_frag_html = try common.readFileAlloc(alloc, CONFORMANCE_CASES_DIR ++ "/qwery_frag.html");
    defer alloc.free(qw_frag_html);

    var nw_passed: usize = 0;
    var nw_examples = std.ArrayList([]const u8).empty;
    defer nw_examples.deinit(alloc);
    var nw_failures = std.ArrayList(SelectorFailure).empty;
    defer nw_failures.deinit(alloc);
    for (nw_cases, 0..) |c, idx| {
        if (idx >= 140) break;
        const got = runSelectorCount(alloc, mode, nw_fixture, c.selector) catch {
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
                break :blk runSelectorCount(alloc, mode, qw_fixture, c.selector) catch {
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
            const tmp = try tempHtmlFile(alloc, html);
            defer {
                std.fs.deleteFileAbsolute(tmp) catch {};
                alloc.free(tmp);
            }
            break :blk runSelectorCountScoped(alloc, mode, tmp, "root", c.selector) catch {
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
            .failed = @min(nw_cases.len, 140) - nw_passed,
            .examples = try nw_examples.toOwnedSlice(alloc),
        },
        .qw = .{
            .total = qw_cases.len,
            .passed = qw_passed,
            .failed = qw_cases.len - qw_passed,
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

fn parseHtml5libDat(alloc: std.mem.Allocator, path: []const u8, out: *std.ArrayList(ParserCase)) !void {
    const text = try common.readFileAlloc(alloc, path);
    defer alloc.free(text);
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

        var expected = std.ArrayList([]const u8).empty;
        errdefer expected.deinit(alloc);
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
            try expected.append(alloc, lower);
        }
        try out.append(alloc, .{
            .html = html_copy,
            .expected = try expected.toOwnedSlice(alloc),
        });
    }
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
    errdefer expected.deinit(alloc);

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
        try expected.append(alloc, lower);
    }
    return expected.toOwnedSlice(alloc);
}

fn parseWptHtmlSuiteFile(alloc: std.mem.Allocator, path: []const u8, out: *std.ArrayList(ParserCase)) !void {
    const text = try common.readFileAlloc(alloc, path);
    defer alloc.free(text);

    if (std.mem.indexOf(u8, text, "var tests = {") == null) return;
    if (std.mem.indexOf(u8, text, "init_tests(") == null) return;

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
        const tail = std.mem.trimLeft(u8, text[expected_end + 1 ..], " \t\r\n");
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
}

fn parseTagJsonArray(alloc: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidJson;
    var tags = std.ArrayList([]const u8).empty;
    errdefer tags.deinit(alloc);
    for (parsed.value.array.items) |it| {
        if (it != .string) continue;
        const lower = try std.ascii.allocLowerString(alloc, it.string);
        if (isWrapperTag(lower)) {
            alloc.free(lower);
            continue;
        }
        try tags.append(alloc, lower);
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

fn runParserCases(alloc: std.mem.Allocator, mode: []const u8, cases: []const ParserCase, max_cases: usize) !ParserSuiteResult {
    const limit = @min(max_cases, cases.len);
    var passed: usize = 0;
    var examples = std.ArrayList([]const u8).empty;
    defer examples.deinit(alloc);
    var failures = std.ArrayList(ParserFailure).empty;
    defer failures.deinit(alloc);
    var idx: usize = 0;
    while (idx < limit) : (idx += 1) {
        const c = cases[idx];
        const tmp = try tempHtmlFile(alloc, c.html);
        defer {
            std.fs.deleteFileAbsolute(tmp) catch {};
            alloc.free(tmp);
        }
        const raw = runParseTagsFile(alloc, mode, tmp) catch {
            if (examples.items.len < 10) {
                const src = std.mem.replaceOwned(u8, alloc, c.html, "\n", "\\n") catch c.html;
                const msg = std.fmt.allocPrint(alloc, "{s} -> <parse-error>", .{src}) catch "parse-error";
                try examples.append(alloc, msg);
            }
            const empty: []const []const u8 = &.{};
            try failures.append(alloc, .{
                .case_index = idx,
                .input_preview = try htmlPreview(alloc, c.html),
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
                .input_preview = try htmlPreview(alloc, c.html),
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
            .failed = limit - passed,
            .examples = try examples.toOwnedSlice(alloc),
        },
        .failures = try failures.toOwnedSlice(alloc),
    };
}

fn runHtml5libParserSuite(alloc: std.mem.Allocator, mode: []const u8, max_cases: usize) !ParserSuiteResult {
    const tc_dir = SUITES_DIR ++ "/html5lib-tests/tree-construction";
    var dir = try std.fs.cwd().openDir(tc_dir, .{ .iterate = true });
    defer dir.close();

    var dat_names = std.ArrayList([]const u8).empty;
    defer dat_names.deinit(alloc);
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".dat")) continue;
        try dat_names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, dat_names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var cases = std.ArrayList(ParserCase).empty;
    defer {
        for (cases.items) |c| {
            alloc.free(c.html);
            for (c.expected) |tag| alloc.free(tag);
            alloc.free(c.expected);
        }
        cases.deinit(alloc);
    }
    for (dat_names.items) |name| {
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ tc_dir, name });
        defer alloc.free(path);
        try parseHtml5libDat(alloc, path, &cases);
    }

    return runParserCases(alloc, mode, cases.items, max_cases);
}

fn runWptParserSuite(alloc: std.mem.Allocator, mode: []const u8, max_cases: usize, whatwg_only: bool) !ParserSuiteResult {
    const wpt_dir = SUITES_DIR ++ "/wpt/html/syntax/parsing";
    var dir = try std.fs.cwd().openDir(wpt_dir, .{ .iterate = true });
    defer dir.close();

    var html_names = std.ArrayList([]const u8).empty;
    defer html_names.deinit(alloc);
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".html")) continue;
        const is_html5lib = std.mem.startsWith(u8, entry.name, "html5lib_");
        if (whatwg_only and !is_html5lib) continue;
        try html_names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, html_names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var cases = std.ArrayList(ParserCase).empty;
    defer {
        for (cases.items) |c| {
            alloc.free(c.html);
            for (c.expected) |tag| alloc.free(tag);
            alloc.free(c.expected);
        }
        cases.deinit(alloc);
    }

    for (html_names.items) |name| {
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ wpt_dir, name });
        defer alloc.free(path);
        try parseWptHtmlSuiteFile(alloc, path, &cases);
    }

    return runParserCases(alloc, mode, cases.items, max_cases);
}

fn runExternalSuites(alloc: std.mem.Allocator, args: []const []const u8) !void {
    var mode_arg: []const u8 = "both";
    var max_cases: usize = 600;
    var max_wpt_cases: usize = 500;
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
        } else if (std.mem.eql(u8, arg, "--max-wpt-cases")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            max_wpt_cases = try std.fmt.parseInt(usize, args[i], 10);
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

    try ensureSuites(alloc);
    try buildSuiteRunner(alloc);
    try common.ensureDir(RESULTS_DIR);

    const modes = if (std.mem.eql(u8, mode_arg, "both")) &[_][]const u8{ "strictest", "fastest" } else &[_][]const u8{mode_arg};
    var mode_reports = std.ArrayList(struct {
        mode: []const u8,
        nw: SelectorSuiteSummary,
        qw: SelectorSuiteSummary,
        parser_html5lib: ParserSuiteSummary,
        parser_whatwg: ParserSuiteSummary,
        parser_wpt: ParserSuiteSummary,
        nw_failures: []const SelectorFailure,
        qw_failures: []const SelectorFailure,
        parser_html5lib_failures: []const ParserFailure,
        parser_whatwg_failures: []const ParserFailure,
        parser_wpt_failures: []const ParserFailure,
    }).empty;
    defer mode_reports.deinit(alloc);

    for (modes) |mode| {
        const sel = try runSelectorSuites(alloc, mode);
        const parser_html5lib = try runHtml5libParserSuite(alloc, mode, max_cases);
        const parser_whatwg = try runWptParserSuite(alloc, mode, max_whatwg_cases, true);
        const parser_wpt = try runWptParserSuite(alloc, mode, max_wpt_cases, false);
        try mode_reports.append(alloc, .{
            .mode = mode,
            .nw = sel.nw,
            .qw = sel.qw,
            .parser_html5lib = parser_html5lib.summary,
            .parser_whatwg = parser_whatwg.summary,
            .parser_wpt = parser_wpt.summary,
            .nw_failures = sel.nw_failures,
            .qw_failures = sel.qw_failures,
            .parser_html5lib_failures = parser_html5lib.failures,
            .parser_whatwg_failures = parser_whatwg.failures,
            .parser_wpt_failures = parser_wpt.failures,
        });

        std.debug.print("Mode: {s}\n", .{mode});
        std.debug.print("  Selector suites:\n", .{});
        std.debug.print("    nwmatcher: {d}/{d} passed ({d} failed)\n", .{ sel.nw.passed, sel.nw.total, sel.nw.failed });
        std.debug.print("    qwery_contextual: {d}/{d} passed ({d} failed)\n", .{ sel.qw.passed, sel.qw.total, sel.qw.failed });
        std.debug.print("  Parser suites:\n", .{});
        std.debug.print("    html5lib tree-construction subset: {d}/{d} passed ({d} failed)\n", .{
            parser_html5lib.summary.passed,
            parser_html5lib.summary.total,
            parser_html5lib.summary.failed,
        });
        std.debug.print("    WHATWG HTML parsing (WPT html5lib_* corpus): {d}/{d} passed ({d} failed)\n", .{
            parser_whatwg.summary.passed,
            parser_whatwg.summary.total,
            parser_whatwg.summary.failed,
        });
        std.debug.print("    WPT HTML parsing (non-html5lib corpus): {d}/{d} passed ({d} failed)\n", .{
            parser_wpt.summary.passed,
            parser_wpt.summary.total,
            parser_wpt.summary.failed,
        });
    }

    var json_buf = std.ArrayList(u8).empty;
    defer json_buf.deinit(alloc);
    const jw = json_buf.writer(alloc);
    try jw.writeAll("{\"modes\":{");
    for (mode_reports.items, 0..) |mr, idx_mode| {
        if (idx_mode != 0) try jw.writeAll(",");
        try jw.print("\"{s}\":{{", .{mr.mode});
        try jw.print("\"selector_suites\":{{\"nwmatcher\":{{\"total\":{d},\"passed\":{d},\"failed\":{d}}},\"qwery_contextual\":{{\"total\":{d},\"passed\":{d},\"failed\":{d}}}}},", .{
            mr.nw.total,
            mr.nw.passed,
            mr.nw.failed,
            mr.qw.total,
            mr.qw.passed,
            mr.qw.failed,
        });
        try jw.print("\"parser_suites\":{{\"html5lib_subset\":{{\"total\":{d},\"passed\":{d},\"failed\":{d}}},\"whatwg_html_parsing\":{{\"total\":{d},\"passed\":{d},\"failed\":{d}}},\"wpt_html_parsing\":{{\"total\":{d},\"passed\":{d},\"failed\":{d}}}}}", .{
            mr.parser_html5lib.total,
            mr.parser_html5lib.passed,
            mr.parser_html5lib.failed,
            mr.parser_whatwg.total,
            mr.parser_whatwg.passed,
            mr.parser_whatwg.failed,
            mr.parser_wpt.total,
            mr.parser_wpt.passed,
            mr.parser_wpt.failed,
        });
        try jw.writeAll("}");
    }
    try jw.writeAll("}}");
    try common.writeFile(json_out, json_buf.items);
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
                .wpt_html_parsing = mr.parser_wpt_failures,
            },
        });
    }

    const failure_json_out: ExternalFailuresOut = .{
        .modes = failure_modes.items,
    };
    var failure_json_writer: std.io.Writer.Allocating = .init(alloc);
    defer failure_json_writer.deinit();
    var failure_json_stream: std.json.Stringify = .{
        .writer = &failure_json_writer.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try failure_json_stream.write(failure_json_out);
    try common.writeFile(failures_out, failure_json_writer.written());
    std.debug.print("Wrote failures: {s}\n", .{failures_out});

    if (std.mem.eql(u8, json_out, "bench/results/external_suite_report.json")) {
        try updateReadmeAutoSummary(alloc);
    }
}

fn cmpStringSlice(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn collectMarkdownFiles(alloc: std.mem.Allocator) ![][]const u8 {
    var files = std.ArrayList([]const u8).empty;
    errdefer files.deinit(alloc);

    const root_docs = [_][]const u8{
        "README.md",
        "DOCUMENTATION.md",
        "CONTRIBUTING.md",
        "SECURITY.md",
        "CHANGELOG.md",
        "bench/README.md",
    };
    for (root_docs) |p| {
        if (common.fileExists(p)) {
            try files.append(alloc, try alloc.dupe(u8, p));
        }
    }

    if (common.fileExists("docs")) {
        var docs_dir = try std.fs.cwd().openDir("docs", .{ .iterate = true });
        defer docs_dir.close();
        var walker = try docs_dir.walk(alloc);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".md")) continue;
            const joined = try std.fs.path.join(alloc, &[_][]const u8{ "docs", entry.path });
            try files.append(alloc, joined);
        }
    }

    std.mem.sort([]const u8, files.items, {}, cmpStringSlice);
    return files.toOwnedSlice(alloc);
}

fn collectExampleFiles(alloc: std.mem.Allocator) ![][]const u8 {
    var files = std.ArrayList([]const u8).empty;
    errdefer files.deinit(alloc);

    var examples_dir = try std.fs.cwd().openDir("examples", .{ .iterate = true });
    defer examples_dir.close();
    var walker = try examples_dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const joined = try std.fs.path.join(alloc, &[_][]const u8{ "examples", entry.path });
        try files.append(alloc, joined);
    }

    std.mem.sort([]const u8, files.items, {}, cmpStringSlice);
    return files.toOwnedSlice(alloc);
}

fn loadBuildStepSet(alloc: std.mem.Allocator) !std.StringHashMap(void) {
    const out = try common.runCaptureStdout(alloc, &[_][]const u8{ "zig", "build", "--list-steps" }, REPO_ROOT);
    defer alloc.free(out);

    var set = std.StringHashMap(void).init(alloc);
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        const first_ws = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        const step = line[0..first_ws];
        if (step.len == 0) continue;
        try set.put(try alloc.dupe(u8, step), {});
    }
    return set;
}

fn trimMarkdownLinkTarget(raw: []const u8) []const u8 {
    var target = std.mem.trim(u8, raw, " \t\r");
    if (target.len >= 2 and target[0] == '<' and target[target.len - 1] == '>') {
        target = target[1 .. target.len - 1];
    }
    if (target.len == 0) return target;
    if (target[0] != '<') {
        const ws_idx = std.mem.indexOfAny(u8, target, " \t\r") orelse target.len;
        target = target[0..ws_idx];
    }
    return target;
}

fn sliceBeforeFirstAny(haystack: []const u8, chars: []const u8) []const u8 {
    const idx = std.mem.indexOfAny(u8, haystack, chars) orelse haystack.len;
    return haystack[0..idx];
}

fn isRemoteLink(target: []const u8) bool {
    if (std.mem.startsWith(u8, target, "http://")) return true;
    if (std.mem.startsWith(u8, target, "https://")) return true;
    if (std.mem.startsWith(u8, target, "mailto:")) return true;
    if (std.mem.startsWith(u8, target, "tel:")) return true;
    return std.mem.indexOf(u8, target, "://") != null;
}

fn validateMarkdownLink(alloc: std.mem.Allocator, md_path: []const u8, line_no: usize, target_raw: []const u8, ok: *bool) !void {
    const target = trimMarkdownLinkTarget(target_raw);
    if (target.len == 0) return;
    if (target[0] == '#') return;
    if (isRemoteLink(target)) return;

    const path_only = sliceBeforeFirstAny(target, "#?");
    if (path_only.len == 0) return;

    if (std.mem.startsWith(u8, path_only, "/")) {
        std.debug.print("docs-check: {s}:{d}: absolute markdown path is not allowed: {s}\n", .{ md_path, line_no, target });
        ok.* = false;
        return;
    }

    const base_dir = std.fs.path.dirname(md_path) orelse ".";
    const resolved = try std.fs.path.join(alloc, &[_][]const u8{ base_dir, path_only });
    defer alloc.free(resolved);

    if (common.fileExists(resolved)) return;

    if (std.mem.endsWith(u8, path_only, "/")) {
        const with_readme = try std.fs.path.join(alloc, &[_][]const u8{ resolved, "README.md" });
        defer alloc.free(with_readme);
        if (common.fileExists(with_readme)) return;
    }

    std.debug.print("docs-check: {s}:{d}: unresolved markdown link: {s}\n", .{ md_path, line_no, target });
    ok.* = false;
}

fn checkMarkdownLinks(alloc: std.mem.Allocator, md_path: []const u8, content: []const u8, ok: *bool) !void {
    var in_fence = false;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        line_no += 1;
        const line = std.mem.trimRight(u8, line_raw, "\r");
        const trimmed = std.mem.trimLeft(u8, line, " \t");
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
            try validateMarkdownLink(alloc, md_path, line_no, line[close + 2 .. end], ok);
            i = end + 1;
        }
    }
}

fn checkLocalAbsolutePaths(md_path: []const u8, content: []const u8, ok: *bool) void {
    if (std.mem.indexOf(u8, content, "/home/") != null or
        std.mem.indexOf(u8, content, "/Users/") != null or
        std.mem.indexOf(u8, content, "C:\\Users\\") != null)
    {
        std.debug.print("docs-check: {s}: contains machine-local absolute path\n", .{md_path});
        ok.* = false;
    }
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

fn checkDocumentedBuildCommands(md_path: []const u8, content: []const u8, step_set: *const std.StringHashMap(void), ok: *bool) void {
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
            ok.* = false;
        }
        pos = found + 1;
    }
}

fn checkChangelogCompatibilityLabels(content: []const u8, ok: *bool) void {
    const header = "## [Unreleased]";
    const start = std.mem.indexOf(u8, content, header) orelse {
        std.debug.print("docs-check: CHANGELOG.md: missing '## [Unreleased]' section\n", .{});
        ok.* = false;
        return;
    };

    const after = content[start + header.len ..];
    const end_rel = std.mem.indexOf(u8, after, "\n## [") orelse after.len;
    const section = after[0..end_rel];

    const required = [_][]const u8{
        "Impact:",
        "Migration:",
        "Downstream scope:",
    };
    for (required) |needle| {
        if (std.mem.indexOf(u8, section, needle) == null) {
            std.debug.print("docs-check: CHANGELOG.md: Unreleased section missing compatibility label '{s}'\n", .{needle});
            ok.* = false;
        }
    }
}

fn runDocsCheck(alloc: std.mem.Allocator) !void {
    const markdown_files = try collectMarkdownFiles(alloc);
    defer alloc.free(markdown_files);
    var step_set = try loadBuildStepSet(alloc);
    defer step_set.deinit();

    var ok = true;
    var checked: usize = 0;
    for (markdown_files) |md_path| {
        const content = try common.readFileAlloc(alloc, md_path);
        defer alloc.free(content);
        checked += 1;

        checkLocalAbsolutePaths(md_path, content, &ok);
        try checkMarkdownLinks(alloc, md_path, content, &ok);
        checkDocumentedBuildCommands(md_path, content, &step_set, &ok);
        if (std.mem.eql(u8, md_path, "CHANGELOG.md")) {
            checkChangelogCompatibilityLabels(content, &ok);
        }
    }

    if (!ok) return error.DocsCheckFailed;
    std.debug.print("docs-check: OK ({d} markdown files)\n", .{checked});
}

fn runExamplesCheck(alloc: std.mem.Allocator) !void {
    const example_files = try collectExampleFiles(alloc);
    defer alloc.free(example_files);
    if (example_files.len == 0) return error.NoExamplesFound;

    for (example_files) |example_path| {
        std.debug.print("examples-check: zig test {s}\n", .{example_path});
        const root_mod = try std.fmt.allocPrint(alloc, "-Mroot={s}", .{example_path});
        const html_mod = "-Mhtmlparser=src/root.zig";
        const argv = [_][]const u8{
            "zig",
            "test",
            "--dep",
            "htmlparser",
            root_mod,
            html_mod,
        };
        try common.runInherit(alloc, &argv, REPO_ROOT);
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
        \\  htmlparser-tools run-external-suites [--mode strictest|fastest|both] [--max-html5lib-cases N] [--max-whatwg-cases N] [--max-wpt-cases N] [--json-out path] [--failures-out path]
        \\  htmlparser-tools docs-check
        \\  htmlparser-tools examples-check
        \\
    , .{});
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len < 2) {
        usage();
        return;
    }
    const cmd = args[1];
    const rest = args[2..];

    if (std.mem.eql(u8, cmd, "setup-parsers")) {
        try setupParsers(alloc);
        return;
    }
    if (std.mem.eql(u8, cmd, "setup-fixtures")) {
        var refresh = false;
        if (rest.len > 0) {
            if (rest.len == 1 and std.mem.eql(u8, rest[0], "--refresh")) {
                refresh = true;
            } else return error.InvalidArgument;
        }
        try setupFixtures(alloc, refresh);
        return;
    }
    if (std.mem.eql(u8, cmd, "run-benchmarks")) {
        try runBenchmarks(alloc, rest);
        return;
    }
    if (std.mem.eql(u8, cmd, "sync-docs-bench")) {
        if (rest.len != 0) return error.InvalidArgument;
        try updateDocumentationBenchmarkSnapshot(alloc);
        try updateReadmeAutoSummary(alloc);
        return;
    }
    if (std.mem.eql(u8, cmd, "run-external-suites")) {
        try runExternalSuites(alloc, rest);
        return;
    }
    if (std.mem.eql(u8, cmd, "docs-check")) {
        try runDocsCheck(alloc);
        return;
    }
    if (std.mem.eql(u8, cmd, "examples-check")) {
        try runExamplesCheck(alloc);
        return;
    }

    usage();
    return error.InvalidCommand;
}
