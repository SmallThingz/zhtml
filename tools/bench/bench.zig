const std = @import("std");
const root = @import("htmlparser");
const default_options: root.ParseOptions = .{};
const Document = default_options.GetDocument();
const parse_mode = @import("../parse_mode.zig");
const ParseMode = parse_mode.ParseMode;

fn elapsedNs(start: i96, finish: i96) u64 {
    if (finish <= start) return 0;
    return @intCast(finish - start);
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).toNanoseconds();
}

/// Runs a built-in synthetic parse/query workload and prints elapsed ns.
pub fn runSynthetic(io: std.Io) !void {
    const alloc = std.heap.smp_allocator;

    var doc = Document.init(alloc);
    defer doc.deinit();

    var src = "<html><body><ul><li class='x'>1</li><li class='x'>2</li><li>3</li></ul></body></html>".*;

    const parse_start = nowNs(io);
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        try doc.parse(&src, .{});
    }
    const parse_end = nowNs(io);

    const query_start = nowNs(io);
    i = 0;
    while (i < 100_000) : (i += 1) {
        _ = doc.queryOne("li.x");
    }
    const query_end = nowNs(io);

    std.debug.print("parse ns: {d}\n", .{elapsedNs(parse_start, parse_end)});
    std.debug.print("query ns: {d}\n", .{elapsedNs(query_start, query_end)});
}

/// Benchmarks parse throughput for one fixture and mode; returns total elapsed ns.
pub fn runParseFile(io: std.Io, path: []const u8, iterations: usize, mode: ParseMode) !u64 {
    const alloc = std.heap.smp_allocator;

    const input = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
    defer alloc.free(input);

    var working_opt: ?[]u8 = null;
    if (mode == .strictest) {
        working_opt = try alloc.alloc(u8, input.len);
    }
    defer if (working_opt) |working| alloc.free(working);

    var parse_arena = std.heap.ArenaAllocator.init(alloc);
    defer parse_arena.deinit();

    const start = nowNs(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const iter_alloc = parse_arena.allocator();
        {
            var doc = Document.init(iter_alloc);
            defer doc.deinit();
            if (working_opt) |working| {
                @memcpy(working, input);
                try parse_mode.parseDoc(&doc, working, mode);
            } else {
                try parse_mode.parseDoc(&doc, input, mode);
            }
        }
        _ = parse_arena.reset(.retain_capacity);
    }
    const end = nowNs(io);

    return elapsedNs(start, end);
}

/// Benchmarks runtime selector parse cost; returns total elapsed ns.
pub fn runQueryParse(io: std.Io, selector: []const u8, iterations: usize) !u64 {
    const alloc = std.heap.smp_allocator;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const start = nowNs(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = arena.reset(.retain_capacity);
        _ = try root.Selector.compileRuntime(arena.allocator(), selector);
    }
    const end = nowNs(io);

    return elapsedNs(start, end);
}

/// Benchmarks runtime query execution over a pre-parsed document.
pub fn runQueryMatch(io: std.Io, path: []const u8, selector: []const u8, iterations: usize, mode: ParseMode) !u64 {
    const alloc = std.heap.smp_allocator;

    const input = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
    defer alloc.free(input);

    const working = try alloc.dupe(u8, input);
    defer alloc.free(working);

    var doc = Document.init(alloc);
    defer doc.deinit();
    try parse_mode.parseDoc(&doc, working, mode);

    const start = nowNs(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = doc.queryOneRuntime(selector) catch null;
    }
    const end = nowNs(io);

    return elapsedNs(start, end);
}

/// Benchmarks cached-selector query execution over a pre-parsed document.
pub fn runQueryCached(io: std.Io, path: []const u8, selector: []const u8, iterations: usize, mode: ParseMode) !u64 {
    const alloc = std.heap.smp_allocator;

    const input = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
    defer alloc.free(input);

    const working = try alloc.dupe(u8, input);
    defer alloc.free(working);

    var sel_arena = std.heap.ArenaAllocator.init(alloc);
    defer sel_arena.deinit();

    const sel = try root.Selector.compileRuntime(sel_arena.allocator(), selector);

    var doc = Document.init(alloc);
    defer doc.deinit();
    try parse_mode.parseDoc(&doc, working, mode);

    const start = nowNs(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = doc.queryOneCached(&sel);
    }
    const end = nowNs(io);

    return elapsedNs(start, end);
}

/// CLI entrypoint for parser/query benchmarking utilities.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len == 1) {
        try runSynthetic(io);
        return;
    }

    if (args.len == 4 and std.mem.eql(u8, args[1], "query-parse")) {
        const iterations = try std.fmt.parseInt(usize, args[3], 10);
        const total_ns = try runQueryParse(io, args[2], iterations);
        std.debug.print("{d}\n", .{total_ns});
        return;
    }

    if (args.len == 5 and std.mem.eql(u8, args[1], "query-match")) {
        const iterations = try std.fmt.parseInt(usize, args[4], 10);
        const total_ns = try runQueryMatch(io, args[2], args[3], iterations, .fastest);
        std.debug.print("{d}\n", .{total_ns});
        return;
    }

    if (args.len == 6 and std.mem.eql(u8, args[1], "query-match")) {
        const mode = parse_mode.parseMode(args[2]) orelse return error.InvalidBenchMode;
        const iterations = try std.fmt.parseInt(usize, args[5], 10);
        const total_ns = try runQueryMatch(io, args[3], args[4], iterations, mode);
        std.debug.print("{d}\n", .{total_ns});
        return;
    }

    if (args.len == 5 and std.mem.eql(u8, args[1], "query-cached")) {
        const iterations = try std.fmt.parseInt(usize, args[4], 10);
        const total_ns = try runQueryCached(io, args[2], args[3], iterations, .fastest);
        std.debug.print("{d}\n", .{total_ns});
        return;
    }

    if (args.len == 6 and std.mem.eql(u8, args[1], "query-cached")) {
        const mode = parse_mode.parseMode(args[2]) orelse return error.InvalidBenchMode;
        const iterations = try std.fmt.parseInt(usize, args[5], 10);
        const total_ns = try runQueryCached(io, args[3], args[4], iterations, mode);
        std.debug.print("{d}\n", .{total_ns});
        return;
    }

    if (args.len == 5 and std.mem.eql(u8, args[1], "parse")) {
        const mode = parse_mode.parseMode(args[2]) orelse return error.InvalidBenchMode;
        const iterations = try std.fmt.parseInt(usize, args[4], 10);
        const total_ns = try runParseFile(io, args[3], iterations, mode);
        std.debug.print("{d}\n", .{total_ns});
        return;
    }

    if (args.len != 3) {
        std.debug.print(
            "usage:\n  {s} <html-file> <iterations>\n  {s} parse <strictest|fastest> <html-file> <iterations>\n  {s} query-parse <selector> <iterations>\n  {s} query-match <html-file> <selector> <iterations>\n  {s} query-match <strictest|fastest> <html-file> <selector> <iterations>\n  {s} query-cached <html-file> <selector> <iterations>\n  {s} query-cached <strictest|fastest> <html-file> <selector> <iterations>\n",
            .{ args[0], args[0], args[0], args[0], args[0], args[0], args[0] },
        );
        std.process.exit(2);
    }

    const iterations = try std.fmt.parseInt(usize, args[2], 10);
    const total_ns = try runParseFile(io, args[1], iterations, .fastest);
    std.debug.print("{d}\n", .{total_ns});
}
