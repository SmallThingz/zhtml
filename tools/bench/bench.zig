const std = @import("std");
const root = @import("html");
const parse_mode = @import("parse_mode");
const ParseMode = parse_mode.ParseMode;

const StreamBenchCtx = struct {
    events: u64 = 0,
    checksum: u64 = 0,

    fn cb(self: *@This(), event: root.StreamingParser.Event) !bool {
        self.events +%= 1;
        self.checksum +%= @as(u64, @intFromEnum(event.kind)) + 1;
        self.checksum +%= @as(u64, event.depth);
        self.checksum +%= @as(u64, event.name.start) + @as(u64, event.name.len);
        self.checksum +%= @as(u64, event.value.start) + @as(u64, event.value.len);
        self.checksum +%= @as(u64, event.attrs.start) + @as(u64, event.attrs.len);
        self.checksum +%= @as(u64, event.token.start) + @as(u64, event.token.len);
        self.checksum +%= @intFromBool(event.self_closing);
        self.checksum +%= @intFromBool(event.implicit);
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
    break :blk it.next() catch unreachable;
}) {
    var it = iter;
    defer it.deinit();
    return it.next() catch unreachable;
}

fn timeQueryAll(io: std.Io, doc: anytype, comptime selector: []const u8, iterations: usize) !i96 {
    var matched: usize = 0;
    const start = nowNs(io);
    for (0..iterations) |_| {
        var it = doc.query(selector);
        defer it.deinit();
        while (try it.next()) |_| matched += 1;
    }
    const elapsed = nowNs(io) - start;
    std.mem.doNotOptimizeAway(matched);
    return elapsed;
}

fn runForwardQueryScaling(io: std.Io, allocator: std.mem.Allocator, sibling_count: usize, iterations: usize) !void {
    var source_writer: std.Io.Writer.Allocating = .init(allocator);
    defer source_writer.deinit();
    try source_writer.writer.writeAll("<div><span class=a></span>");
    for (1..sibling_count) |_| try source_writer.writer.writeAll("<span></span>");
    try source_writer.writer.writeAll("</div>");
    const source = try source_writer.toOwnedSlice();
    defer allocator.free(source);

    const options: root.ParseOptions = .{};
    var doc = try options.parse(allocator, source);
    defer doc.deinit();
    inline for (.{
        ".a + span",
        ".a ~ span",
        "span:first-child",
        "span:nth-child(50000)",
        "span:nth-child(2n+1)",
        "span",
        ".a",
        "#missing",
        "span[class]",
    }) |selector| {
        const elapsed = try timeQueryAll(io, &doc, selector, iterations);
        std.debug.print("forward-wide\t{s}\tnodes={}\titerations={}\tns={}\n", .{ selector, sibling_count, iterations, elapsed });
    }

    inline for (.{ 10, 100, 1000 }) |depth| {
        var deep_writer: std.Io.Writer.Allocating = .init(allocator);
        defer deep_writer.deinit();
        for (0..depth) |i| try deep_writer.writer.writeAll(if (i % 4 == 0) "<div class=a>" else if (i % 4 == 3) "<div class=d>" else "<div>");
        for (0..depth) |_| try deep_writer.writer.writeAll("</div>");
        const deep_source = try deep_writer.toOwnedSlice();
        defer allocator.free(deep_source);
        var deep_doc = try options.parse(allocator, deep_source);
        defer deep_doc.deinit();
        inline for (.{ ".a .d", ".a > div", ".a div div .d" }) |selector| {
            const elapsed = try timeQueryAll(io, &deep_doc, selector, iterations);
            std.debug.print("forward-deep\t{s}\tdepth={}\titerations={}\tns={}\n", .{ selector, depth, iterations, elapsed });
        }
    }
}

fn runCloseIndexScaling(io: std.Io, allocator: std.mem.Allocator, shape: []const u8, depth: usize, misses: usize, iterations: usize) !i96 {
    var source_writer: std.Io.Writer.Allocating = .init(allocator);
    defer source_writer.deinit();
    if (std.mem.eql(u8, shape, "valid") or std.mem.eql(u8, shape, "miss")) {
        for (0..depth) |_| try source_writer.writer.writeAll("<a>");
        if (std.mem.eql(u8, shape, "miss")) for (0..misses) |_| try source_writer.writer.writeAll("</missing>");
        for (0..depth) |_| try source_writer.writer.writeAll("</a>");
    } else if (std.mem.eql(u8, shape, "recover")) {
        for (0..depth) |i| try source_writer.writer.print("<x{}>", .{i});
        try source_writer.writer.writeAll("</x0>");
    } else return error.InvalidBenchMode;

    const source = try source_writer.toOwnedSlice();
    defer allocator.free(source);
    const options: root.ParseOptions = .{};
    const start = nowNs(io);
    for (0..iterations) |_| {
        var doc = try options.parse(allocator, source);
        doc.deinit();
    }
    return nowNs(io) - start;
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

    const working = try alloc.alloc(u8, input.len);
    defer alloc.free(working);

    var parse_arena = std.heap.ArenaAllocator.init(alloc);
    defer parse_arena.deinit();

    var total_ns: u64 = 0;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // Destructive modes must see identical bytes on every iteration. Keep
        // restoration and arena maintenance outside the timed parse region.
        @memcpy(working, input);
        const iter_alloc = parse_arena.allocator();
        const start = nowNs(io);
        {
            switch (mode) {
                .strictest => {
                    const options: root.ParseOptions = .{ .drop_whitespace_text_nodes = .none };
                    var doc = try options.parse(iter_alloc, working);
                    defer doc.deinit();
                },
                .fastest => {
                    const options: root.ParseOptions = .{};
                    var doc = try options.parse(iter_alloc, working);
                    defer doc.deinit();
                },
                .full => {
                    const options: root.ParseOptions = .{
                        .store_last_child = true,
                        .store_prev_sibling = true,
                    };
                    var doc = try options.parse(iter_alloc, working);
                    defer doc.deinit();
                },
            }
        }
        total_ns += elapsedNs(start, nowNs(io));
        _ = parse_arena.reset(.retain_capacity);
    }
    return total_ns;
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
        .emit_text = true,
        .emit_start_tags = true,
        .emit_end_tags = true,
        .emit_implicit_end_tags = true,
        .include_comments = true,
        .include_doctype = true,
        .include_processing_instructions = true,
        .track_nesting = true,
        .assume_no_gt_in_attribute_values = true,
    } };

    const start = nowNs(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        try parser.parse(parse_arena.allocator(), input, &ctx, StreamBenchCtx.cb);
        _ = parse_arena.reset(.retain_capacity);
    }
    const end = nowNs(io);

    std.mem.doNotOptimizeAway(ctx.events);
    std.mem.doNotOptimizeAway(ctx.checksum);
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

/// Benchmarks point matching with a parsed selector over one preselected node.
pub fn runPointMatchesCached(io: std.Io, path: []const u8, target_selector: []const u8, selector: []const u8, iterations: usize) !u64 {
    const alloc = std.heap.smp_allocator;
    const input = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
    defer alloc.free(input);
    const working = try alloc.dupe(u8, input);
    defer alloc.free(working);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const target_sel = try root.Selector.compileRuntime(arena.allocator(), target_selector);
    const sel = try root.Selector.compileRuntime(arena.allocator(), selector);
    const options: root.ParseOptions = .{};
    var doc = try options.parse(alloc, working);
    defer doc.deinit();
    const target = firstQuery(doc.queryRuntime(target_sel)) orelse return error.BenchTargetNotFound;

    const start = nowNs(io);
    for (0..iterations) |_| std.mem.doNotOptimizeAway(try target.matchesRuntime(sel));
    return elapsedNs(start, nowNs(io));
}

/// Benchmarks point matching while borrowing a prepared immutable selector program.
pub fn runPointMatchesPrepared(io: std.Io, path: []const u8, target_selector: []const u8, selector: []const u8, iterations: usize) !u64 {
    const alloc = std.heap.smp_allocator;
    const input = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
    defer alloc.free(input);
    const working = try alloc.dupe(u8, input);
    defer alloc.free(working);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const target_sel = try root.Selector.compileRuntime(arena.allocator(), target_selector);
    var prepared = try root.PreparedSelector.compile(alloc, selector);
    defer prepared.deinit();
    const options: root.ParseOptions = .{};
    var doc = try options.parse(alloc, working);
    defer doc.deinit();
    const target = firstQuery(doc.queryRuntime(target_sel)) orelse return error.BenchTargetNotFound;

    const start = nowNs(io);
    for (0..iterations) |_| std.mem.doNotOptimizeAway(try target.matchesPrepared(&prepared));
    return elapsedNs(start, nowNs(io));
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

/// Benchmarks a fully prepared runtime selector over a pre-parsed document.
pub fn runQueryPrepared(io: std.Io, path: []const u8, selector: []const u8, iterations: usize, mode: ParseMode) !u64 {
    const alloc = std.heap.smp_allocator;

    const input = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
    defer alloc.free(input);

    const working = try alloc.dupe(u8, input);
    defer alloc.free(working);

    var prepared = try root.PreparedSelector.compile(alloc, selector);
    defer prepared.deinit();

    return switch (mode) {
        .strictest => blk: {
            const options: root.ParseOptions = .{ .drop_whitespace_text_nodes = .none };
            var doc = try options.parse(alloc, working);
            defer doc.deinit();
            const start = nowNs(io);
            for (0..iterations) |_| _ = firstQuery(doc.queryPrepared(&prepared));
            break :blk elapsedNs(start, nowNs(io));
        },
        .fastest => blk: {
            const options: root.ParseOptions = .{};
            var doc = try options.parse(alloc, working);
            defer doc.deinit();
            const start = nowNs(io);
            for (0..iterations) |_| _ = firstQuery(doc.queryPrepared(&prepared));
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
            for (0..iterations) |_| _ = firstQuery(doc.queryPrepared(&prepared));
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

    if (args.len == 2 and std.mem.eql(u8, args[1], "protocol")) {
        std.debug.print("2\n", .{});
        return;
    }

    if (args.len == 4 and std.mem.eql(u8, args[1], "forward-query")) {
        const sibling_count = try std.fmt.parseInt(usize, args[2], 10);
        const iterations = try std.fmt.parseInt(usize, args[3], 10);
        try runForwardQueryScaling(io, init.arena.allocator(), sibling_count, iterations);
        return;
    }

    if (args.len == 6 and std.mem.eql(u8, args[1], "close-index")) {
        const depth = try std.fmt.parseInt(usize, args[3], 10);
        const misses = try std.fmt.parseInt(usize, args[4], 10);
        const iterations = try std.fmt.parseInt(usize, args[5], 10);
        const elapsed = try runCloseIndexScaling(io, init.arena.allocator(), args[2], depth, misses, iterations);
        std.debug.print("close-index\t{s}\tdepth={}\tmisses={}\titerations={}\tns={}\n", .{ args[2], depth, misses, iterations, elapsed });
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

    if (args.len == 6 and std.mem.eql(u8, args[1], "point-cached")) {
        const iterations = try std.fmt.parseInt(usize, args[5], 10);
        const total_ns = try runPointMatchesCached(io, args[2], args[3], args[4], iterations);
        std.debug.print("{d}\n", .{total_ns});
        return;
    }

    if (args.len == 6 and std.mem.eql(u8, args[1], "point-prepared")) {
        const iterations = try std.fmt.parseInt(usize, args[5], 10);
        const total_ns = try runPointMatchesPrepared(io, args[2], args[3], args[4], iterations);
        std.debug.print("{d}\n", .{total_ns});
        return;
    }

    if (args.len == 5 and std.mem.eql(u8, args[1], "query-cached")) {
        const iterations = try std.fmt.parseInt(usize, args[4], 10);
        const total_ns = try runQueryCached(io, args[2], args[3], iterations, .fastest);
        std.debug.print("{d}\n", .{total_ns});
        return;
    }

    if (args.len == 5 and std.mem.eql(u8, args[1], "query-prepared")) {
        const iterations = try std.fmt.parseInt(usize, args[4], 10);
        const total_ns = try runQueryPrepared(io, args[2], args[3], iterations, .fastest);
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
            "usage:\n  {s} protocol\n  {s} forward-query <siblings> <iterations>\n  {s} close-index <valid|recover|miss> <depth> <misses> <iterations>\n  {s} <html-file> <iterations>\n  {s} parse <strictest|fastest|full|stream> <html-file> <iterations>\n  {s} query-parse <selector> <iterations>\n  {s} query-match <html-file> <selector> <iterations>\n  {s} query-match <strictest|fastest|full> <html-file> <selector> <iterations>\n  {s} query-cached <html-file> <selector> <iterations>\n  {s} query-prepared <html-file> <selector> <iterations>\n  {s} point-cached <html-file> <target-selector> <selector> <iterations>\n  {s} point-prepared <html-file> <target-selector> <selector> <iterations>\n  {s} query-cached <strictest|fastest|full> <html-file> <selector> <iterations>\n",
            .{ args[0], args[0], args[0], args[0], args[0], args[0], args[0], args[0], args[0], args[0], args[0], args[0], args[0] },
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
