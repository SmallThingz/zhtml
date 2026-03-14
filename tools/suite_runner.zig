const std = @import("std");
const html = @import("htmlparser");
const default_options: html.ParseOptions = .{};
const Document = default_options.GetDocument();
const parse_mode = @import("parse_mode.zig");
const ParseMode = parse_mode.ParseMode;

const ParsedFixture = struct {
    doc: Document,
    working: []u8,

    fn deinit(self: *ParsedFixture, alloc: std.mem.Allocator) void {
        self.doc.deinit();
        alloc.free(self.working);
    }
};

fn parseFixtureDoc(io: std.Io, alloc: std.mem.Allocator, mode: ParseMode, fixture_path: []const u8) !ParsedFixture {
    const input = try std.Io.Dir.cwd().readFileAlloc(io, fixture_path, alloc, .unlimited);
    defer alloc.free(input);

    const working = try alloc.dupe(u8, input);
    errdefer alloc.free(working);

    var doc = Document.init(alloc);
    errdefer doc.deinit();

    try parse_mode.parseDoc(&doc, working, mode);
    return .{ .doc = doc, .working = working };
}

fn jsonEscape(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{X:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn printJsonStringArray(writer: anytype, items: []const []const u8) !void {
    try writer.writeByte('[');
    for (items, 0..) |it, i| {
        if (i != 0) try writer.writeByte(',');
        try jsonEscape(writer, it);
    }
    try writer.writeByte(']');
}

fn runSelectorIds(io: std.Io, alloc: std.mem.Allocator, mode: ParseMode, fixture_path: []const u8, selector: []const u8) !void {
    var parsed = try parseFixtureDoc(io, alloc, mode, fixture_path);
    defer parsed.deinit(alloc);

    var out_ids = std.ArrayList([]const u8).empty;
    defer out_ids.deinit(alloc);

    var it = try parsed.doc.queryAllRuntime(selector);
    while (it.next()) |node| {
        if (node.getAttributeValue("id")) |id| {
            try out_ids.append(alloc, id);
        }
    }

    var out_buf: std.Io.Writer.Allocating = .init(alloc);
    defer out_buf.deinit();
    try printJsonStringArray(&out_buf.writer, out_ids.items);
    try out_buf.writer.writeByte('\n');
    try std.Io.File.stdout().writeStreamingAll(io, out_buf.written());
}

fn runSelectorCount(io: std.Io, alloc: std.mem.Allocator, mode: ParseMode, fixture_path: []const u8, selector: []const u8) !void {
    var parsed = try parseFixtureDoc(io, alloc, mode, fixture_path);
    defer parsed.deinit(alloc);

    var count: usize = 0;
    var it = try parsed.doc.queryAllRuntime(selector);
    while (it.next()) |_| {
        count += 1;
    }

    var out_buf: std.Io.Writer.Allocating = .init(alloc);
    defer out_buf.deinit();
    try out_buf.writer.print("{d}\n", .{count});
    try std.Io.File.stdout().writeStreamingAll(io, out_buf.written());
}

fn runSelectorCountScopeTag(io: std.Io, alloc: std.mem.Allocator, mode: ParseMode, fixture_path: []const u8, scope_tag: []const u8, selector: []const u8) !void {
    var parsed = try parseFixtureDoc(io, alloc, mode, fixture_path);
    defer parsed.deinit(alloc);

    var count: usize = 0;
    if (parsed.doc.findFirstTag(scope_tag)) |scope| {
        var it = try scope.queryAllRuntime(selector);
        while (it.next()) |_| {
            count += 1;
        }
    }

    var out_buf: std.Io.Writer.Allocating = .init(alloc);
    defer out_buf.deinit();
    try out_buf.writer.print("{d}\n", .{count});
    try std.Io.File.stdout().writeStreamingAll(io, out_buf.written());
}

fn runParseTagsFile(io: std.Io, alloc: std.mem.Allocator, mode: ParseMode, fixture_path: []const u8) !void {
    var parsed = try parseFixtureDoc(io, alloc, mode, fixture_path);
    defer parsed.deinit(alloc);

    var tags = std.ArrayList([]const u8).empty;
    defer tags.deinit(alloc);

    for (parsed.doc.nodes.items) |*n| {
        if (n.kind != .element) continue;
        try tags.append(alloc, n.name_or_text.slice(parsed.doc.source));
    }

    var out_buf: std.Io.Writer.Allocating = .init(alloc);
    defer out_buf.deinit();
    try printJsonStringArray(&out_buf.writer, tags.items);
    try out_buf.writer.writeByte('\n');
    try std.Io.File.stdout().writeStreamingAll(io, out_buf.written());
}

fn usage() noreturn {
    std.debug.print(
        "usage:\n  suite_runner selector-ids <strictest|fastest> <fixture.html> <selector>\n  suite_runner selector-count <strictest|fastest> <fixture.html> <selector>\n  suite_runner selector-count-scope-tag <strictest|fastest> <fixture.html> <scope-tag> <selector>\n  suite_runner parse-tags-file <strictest|fastest> <fixture.html>\n",
        .{},
    );
    std.process.exit(2);
}

/// CLI entrypoint used by external-suite tooling to execute selector/parser probes.
pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) usage();

    if (std.mem.eql(u8, args[1], "selector-ids")) {
        if (args.len != 5) usage();
        const mode = parse_mode.parseMode(args[2]) orelse usage();
        try runSelectorIds(io, alloc, mode, args[3], args[4]);
        return;
    }

    if (std.mem.eql(u8, args[1], "selector-count")) {
        if (args.len != 5) usage();
        const mode = parse_mode.parseMode(args[2]) orelse usage();
        try runSelectorCount(io, alloc, mode, args[3], args[4]);
        return;
    }

    if (std.mem.eql(u8, args[1], "selector-count-scope-tag")) {
        if (args.len != 6) usage();
        const mode = parse_mode.parseMode(args[2]) orelse usage();
        try runSelectorCountScopeTag(io, alloc, mode, args[3], args[4], args[5]);
        return;
    }

    if (std.mem.eql(u8, args[1], "parse-tags-file")) {
        if (args.len != 4) usage();
        const mode = parse_mode.parseMode(args[2]) orelse usage();
        try runParseTagsFile(io, alloc, mode, args[3]);
        return;
    }

    usage();
}
