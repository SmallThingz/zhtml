const std = @import("std");
const root = @import("html");
const parse_mode = @import("parse_mode");
const ParseMode = parse_mode.ParseMode;

const StreamBenchCtx = struct {
    fn cb(_: *@This(), _: root.StreamingEvent) !bool {
        return true;
    }
};

fn elapsedNs(start: i96, finish: i96) u64 {
    if (finish <= start) return 0;
    return @intCast(finish - start);
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).toNanoseconds();
}

fn firstQuery(iter: anytype) @TypeOf(blk: {
    var it = iter;
    break :blk it.next();
}) {
    var it = iter;
    return it.next();
}

/// Runs a built-in synthetic parse/query workload and prints elapsed ns.
pub fn runSynthetic(io: std.Io) !void {
    const alloc = std.heap.smp_allocator;
    const options: root.ParseOptions = .{};
    var src = "<html><body><ul><li class='x'>1</li><li class='x'>2</li><li>3</li></ul></body></html>".*;
    var doc = try options.parse(alloc, &src);
    defer doc.deinit();

    const parse_start = nowNs(io);
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        doc.deinit();
        doc = try options.parse(alloc, &src);
    }
    const parse_end = nowNs(io);

    const query_start = nowNs(io);
    i = 0;
    while (i < 100_000) : (i += 1) {
        _ = firstQuery(doc.query("li.x"));
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
            switch (mode) {
                .strictest => {
                    const options: root.ParseOptions = .{ .drop_whitespace_text_nodes = .none };
                    const working = working_opt.?;
                    @memcpy(working, input);
                    var doc = try options.parse(iter_alloc, working);
                    defer doc.deinit();
                },
                .fastest => {
                    const options: root.ParseOptions = .{};
                    var doc = try options.parse(iter_alloc, input);
                    defer doc.deinit();
                },
                .full => {
                    const options: root.ParseOptions = .{
                        .store_last_child = true,
                        .store_prev_sibling = true,
                    };
                    var doc = try options.parse(iter_alloc, input);
                    defer doc.deinit();
                },
            }
        }
        _ = parse_arena.reset(.retain_capacity);
    }
    const end = nowNs(io);

    return elapsedNs(start, end);
}

/// Benchmarks streaming parse throughput for one fixture; returns total elapsed ns.
pub fn runStreamParseFile(io: std.Io, path: []const u8, iterations: usize) !u64 {
    const alloc = std.heap.smp_allocator;

    const input = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
    defer alloc.free(input);

    var parse_arena = std.heap.ArenaAllocator.init(alloc);
    defer parse_arena.deinit();

    var ctx: StreamBenchCtx = .{};
    const parser: root.StreamingParser = .{ .options = .{
        .emit_text = false,
        .emit_start_tags = false,
        .emit_end_tags = false,
        .emit_implicit_end_tags = false,
        .track_nesting = false,
        .assume_no_gt_in_attribute_values = true,
    } };

    const start = nowNs(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        try parser.parse(parse_arena.allocator(), input, &ctx, StreamBenchCtx.cb);
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

    var sel_arena = std.heap.ArenaAllocator.init(alloc);
    defer sel_arena.deinit();
    const sel = try root.Selector.compileRuntime(sel_arena.allocator(), selector);

    return switch (mode) {
        .strictest => blk: {
            const options: root.ParseOptions = .{ .drop_whitespace_text_nodes = .none };
            var doc = try options.parse(alloc, working);
            defer doc.deinit();

            const start = nowNs(io);
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                _ = firstQuery(doc.queryRuntime(sel));
            }
            break :blk elapsedNs(start, nowNs(io));
        },
        .fastest => blk: {
            const options: root.ParseOptions = .{};
            var doc = try options.parse(alloc, working);
            defer doc.deinit();

            const start = nowNs(io);
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                _ = firstQuery(doc.queryRuntime(sel));
            }
            break :blk elapsedNs(start, nowNs(io));
        },
        .full => blk: {
            const options: root.ParseOptions = .{
                .store_last_child = true,
                .store_prev_sibling = true,
            };
            var doc = try options.parse(alloc, working);
            defer doc.deinit();

            const start = nowNs(io);
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                _ = firstQuery(doc.queryRuntime(sel));
            }
            break :blk elapsedNs(start, nowNs(io));
        },
    };
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

    return switch (mode) {
        .strictest => blk: {
            const options: root.ParseOptions = .{ .drop_whitespace_text_nodes = .none };
            var doc = try options.parse(alloc, working);
            defer doc.deinit();

            const start = nowNs(io);
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                _ = firstQuery(doc.queryRuntime(sel));
            }
            break :blk elapsedNs(start, nowNs(io));
        },
        .fastest => blk: {
            const options: root.ParseOptions = .{};
            var doc = try options.parse(alloc, working);
            defer doc.deinit();

            const start = nowNs(io);
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                _ = firstQuery(doc.queryRuntime(sel));
            }
            break :blk elapsedNs(start, nowNs(io));
        },
        .full => blk: {
            const options: root.ParseOptions = .{
                .store_last_child = true,
                .store_prev_sibling = true,
            };
            var doc = try options.parse(alloc, working);
            defer doc.deinit();

            const start = nowNs(io);
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                _ = firstQuery(doc.queryRuntime(sel));
            }
            break :blk elapsedNs(start, nowNs(io));
        },
    };
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
        if (std.mem.eql(u8, args[2], "stream")) {
            const iterations = try std.fmt.parseInt(usize, args[4], 10);
            const total_ns = try runStreamParseFile(io, args[3], iterations);
            std.debug.print("{d}\n", .{total_ns});
            return;
        }
        const mode = parse_mode.parseMode(args[2]) orelse return error.InvalidBenchMode;
        const iterations = try std.fmt.parseInt(usize, args[4], 10);
        const total_ns = try runParseFile(io, args[3], iterations, mode);
        std.debug.print("{d}\n", .{total_ns});
        return;
    }

    if (args.len != 3) {
        std.debug.print(
            "usage:\n  {s} <html-file> <iterations>\n  {s} parse <strictest|fastest|full|stream> <html-file> <iterations>\n  {s} query-parse <selector> <iterations>\n  {s} query-match <html-file> <selector> <iterations>\n  {s} query-match <strictest|fastest|full> <html-file> <selector> <iterations>\n  {s} query-cached <html-file> <selector> <iterations>\n  {s} query-cached <strictest|fastest|full> <html-file> <selector> <iterations>\n",
            .{ args[0], args[0], args[0], args[0], args[0], args[0], args[0] },
        );
        std.process.exit(2);
    }

    const iterations = try std.fmt.parseInt(usize, args[2], 10);
    const total_ns = try runParseFile(io, args[1], iterations, .fastest);
    std.debug.print("{d}\n", .{total_ns});
}

test "bench smoke uses parse_mode module for both parse modes" {
    const alloc = std.testing.allocator;
    const fastest_options: root.ParseOptions = .{};
    const full_options: root.ParseOptions = .{ .store_last_child = true, .store_prev_sibling = true };
    const strictest_options: root.ParseOptions = .{ .drop_whitespace_text_nodes = .none };

    var fastest_html = "<div><span id='x'>ok</span></div>".*;
    var fastest_doc = try fastest_options.parse(alloc, &fastest_html);
    defer fastest_doc.deinit();
    try std.testing.expect(firstQuery(fastest_doc.query("span#x")) != null);

    var strict_html = "<div>\n  <span id='y'>ok</span>\n</div>".*;
    var strict_doc = try strictest_options.parse(alloc, &strict_html);
    defer strict_doc.deinit();
    try std.testing.expect(firstQuery(strict_doc.query("span#y")) != null);

    var full_html = "<div><span id='z'>ok</span></div>".*;
    var full_doc = try full_options.parse(alloc, &full_html);
    defer full_doc.deinit();
    try std.testing.expect(firstQuery(full_doc.query("span#z")) != null);
}
