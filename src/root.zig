const std = @import("std");
const common = @import("common.zig");
const instrumentation = @import("debug/instrumentation.zig");
const document = @import("html/document.zig");
const stream = @import("html/stream.zig");
const selector_ast = @import("selector/ast.zig");

pub const ParseInt = common.IndexInt;

/// Parse-time configuration and type factory for `Document`, `Node`, and iterators.
pub const ParseOptions = document.ParseOptions;
/// Options controlling whitespace normalization behavior in text extraction APIs.
pub const TextOptions = document.TextOptions;
/// Allocation-free event parser for streaming-style HTML scans.
pub const StreamingParser = stream.Parser;
pub const StreamingEvent = stream.Event;
pub const StreamingEventKind = stream.EventKind;
pub const StreamingAttribute = stream.Attribute;
pub const StreamingAttributeIterator = stream.AttributeIterator;
/// Compiled selector representation shared by comptime/runtime query paths.
pub const Selector = selector_ast.Selector;
/// Structured query-debug output populated by debug query internals.
pub const QueryDebugReport = common.QueryDebugReport;
/// Enumerates first-failure categories recorded by debug query reporting.
pub const DebugFailureKind = common.DebugFailureKind;
/// Single near-miss record used by query diagnostics.
pub const NearMiss = common.NearMiss;
/// Parse instrumentation payload emitted by hook wrappers.
pub const ParseInstrumentationStats = instrumentation.ParseInstrumentationStats;
/// Query instrumentation payload emitted by hook wrappers.
pub const QueryInstrumentationStats = instrumentation.QueryInstrumentationStats;
/// Kind of query operation measured by instrumentation wrappers.
pub const QueryInstrumentationKind = instrumentation.QueryInstrumentationKind;

/// Executes `query` and reports timing through hook callbacks.
pub const queryWithHooks = instrumentation.queryWithHooks;
/// Executes `queryRuntime` and reports timing through hook callbacks.
pub const queryRuntimeWithHooks = instrumentation.queryRuntimeWithHooks;

fn firstQuery(iter: anytype) @TypeOf(blk: {
    var it = iter;
    break :blk it.next();
}) {
    var it = iter;
    return it.next();
}

fn runtimeFirst(scope: anytype, allocator: std.mem.Allocator, selector: []const u8) !@TypeOf(firstQuery(scope.query("*"))) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const sel = try Selector.compileRuntime(arena.allocator(), selector);
    return firstQuery(scope.queryRuntime(sel));
}

test "smoke parse/query" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{};
    var src = "<div id='a'><span class='k'>v</span></div>".*;
    var doc = try opts.parse(alloc, &src);
    defer doc.deinit();

    try std.testing.expect(firstQuery(doc.query("div#a")) != null);
    try std.testing.expect((try runtimeFirst(&doc, alloc, "span")) != null);
    const span = (try runtimeFirst(&doc, alloc, "span.k")) orelse return error.TestUnexpectedResult;
    const parent = span.parentNode() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("div", parent.tagName());
    try std.testing.expect(firstQuery(doc.query("div > span.k")) != null);
}

test "parse options helper parses directly" {
    const alloc = std.testing.allocator;

    {
        const opts: ParseOptions = .{};
        var src = "<div id='a'><span>v</span></div>".*;
        var doc = try opts.parse(alloc, &src);
        defer doc.deinit();

        try std.testing.expect(firstQuery(doc.query("div#a > span")) != null);
    }

    {
        const opts: ParseOptions = .{ .non_destructive = true };
        const src = "<div id='b' data-v='x&amp;y'>v</div>";
        var doc = try opts.parse(alloc, src);
        defer doc.deinit();
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        const div = firstQuery(doc.query("div#b")) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("x&y", (try div.getAttributeValue(arena.allocator(), "data-v")).?.value);
    }
}

test "writeHtml serializes node subtree" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{};
    var src = "<div id='a'><span>v</span></div>".*;
    var doc = try opts.parse(alloc, &src);
    defer doc.deinit();

    const div = firstQuery(doc.query("div")) orelse return error.TestUnexpectedResult;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try div.writeHtml(&out.writer);
    try std.testing.expectEqualStrings("<div id='a'><span>v</span></div>", out.written());
}

test "writeHtml respects in-place attr parsing and void tags" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{};
    var src = "<img id='i' class='x' data-q='1>2'/>".*;
    var doc = try opts.parse(alloc, &src);
    defer doc.deinit();

    const img = firstQuery(doc.query("img#i")) orelse return error.TestUnexpectedResult;
    _ = (try img.getAttributeValue(alloc, "class")) orelse return error.TestUnexpectedResult;
    _ = (try img.getAttributeValue(alloc, "data-q")) orelse return error.TestUnexpectedResult;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try img.writeHtml(&out.writer);
    try std.testing.expectEqualStrings("<img id=\"i\" class=\"x\" data-q=\"1>2\">", out.written());
}

test "writeHtml reflects in-place text decoding" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{};
    var src = "<p>&amp; &lt;</p>".*;
    var doc = try opts.parse(alloc, &src);
    defer doc.deinit();

    const p = firstQuery(doc.query("p")) orelse return error.TestUnexpectedResult;
    const text = try p.innerTextWithOptions(alloc, .{});
    defer text.free(&doc, alloc);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try p.writeHtml(&out.writer);
    try std.testing.expectEqualStrings("<p>& <</p>", out.written());
}

test "writeHtml drops whitespace-only text nodes when configured" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{};
    var src = "<div> a <span> b </span> c </div>".*;
    var doc = try opts.parse(alloc, &src);
    defer doc.deinit();

    const div = firstQuery(doc.query("div")) orelse return error.TestUnexpectedResult;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try div.writeHtml(&out.writer);
    try std.testing.expectEqualStrings("<div>a <span>b </span>c </div>", out.written());
}

test "writeHtml parses and prints complex document" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{ .drop_whitespace_text_nodes = .none };
    const src_const =
        \\<!DOCTYPE html>
        \\<html><head>
        \\<title>Title</title>
        \\<meta charset='utf-8'><!-- Single quotes are converted to double quotes when formatting -->
        \\<script>var x = 1 < 2;</script>
        \\</head><body>
        \\<div id='root' class='a b' data-q='1>2'>Hello&nbsp;<span>World</span></div>
        \\<img src='x.png' alt='hi'>
        \\<br>
        \\<ul><li>One</li><li>Two</li></ul>
        \\</body></html>
    ;
    const src = try alloc.dupe(u8, src_const);
    defer alloc.free(src);
    var doc = try opts.parse(alloc, src);
    defer doc.deinit();

    const html = doc.html() orelse return error.TestUnexpectedResult;

    // at index 6 is the meta node; here is why
    // +1 = head
    // +2 = `\n` [text node]
    // +3 = title
    //   +4 = `Title` [text node]
    // +5 = `\n` [text node]
    try std.testing.expectEqualStrings("utf-8", (try doc.nodeAt(html.index + 6).getAttributeValue(alloc, "charset")).?.value);
    const rendered = try std.fmt.allocPrint(alloc, "{f}", .{html});
    defer alloc.free(rendered);

    try std.testing.expectEqualStrings(
        \\<html><head>
        \\<title>Title</title>
        \\<meta charset="utf-8">
        \\<script>var x = 1 < 2;</script>
        \\</head><body>
        \\<div id='root' class='a b' data-q='1>2'>Hello&nbsp;<span>World</span></div>
        \\<img src='x.png' alt='hi'>
        \\<br>
        \\<ul><li>One</li><li>Two</li></ul>
        \\</body></html>
    ,
        rendered,
    );
}

test "writeHtmlSelf excludes children" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{};
    var src = "<div id='a'><span>v</span></div>".*;
    var doc = try opts.parse(alloc, &src);
    defer doc.deinit();

    const div = firstQuery(doc.query("div")) orelse return error.TestUnexpectedResult;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try div.writeSelfHtml(&out.writer);
    try std.testing.expectEqualStrings("<div id='a'>", out.written());
}
