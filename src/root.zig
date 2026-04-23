const std = @import("std");
const common = @import("common.zig");
const instrumentation = @import("debug/instrumentation.zig");
const document = @import("html/document.zig");
const selector_ast = @import("selector/ast.zig");

pub const ParseInt = common.IndexInt;

/// Parse-time configuration and type factory for `Document`, `Node`, and iterators.
pub const ParseOptions = document.ParseOptions;
/// Options controlling whitespace normalization behavior in text extraction APIs.
pub const TextOptions = document.TextOptions;
/// Compiled selector representation shared by comptime/runtime query paths.
pub const Selector = selector_ast.Selector;
/// Structured query-debug output populated by `queryOneDebug` APIs.
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

/// Parses a document and invokes optional start/end hook callbacks.
pub const parseWithHooks = instrumentation.parseWithHooks;
/// Executes `queryOneRuntime` and reports timing through hook callbacks.
pub const queryOneRuntimeWithHooks = instrumentation.queryOneRuntimeWithHooks;
/// Executes `queryOneCached` and reports timing through hook callbacks.
pub const queryOneCachedWithHooks = instrumentation.queryOneCachedWithHooks;
/// Executes `queryAllRuntime` and reports timing through hook callbacks.
pub const queryAllRuntimeWithHooks = instrumentation.queryAllRuntimeWithHooks;
/// Executes `queryAllCached` and reports timing through hook callbacks.
pub const queryAllCachedWithHooks = instrumentation.queryAllCachedWithHooks;

/// Parses `input` into a freshly initialized document and returns it.
/// The returned document borrows `input`, so `input` must outlive the document.
pub fn parse(comptime options: ParseOptions, allocator: std.mem.Allocator, input: options.GetInput()) !options.GetDocument() {
    return options.Parser().parse(allocator, input);
}

test "smoke parse/query" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{};
    const Document = opts.GetDocument();

    var doc = Document.init(alloc);
    defer doc.deinit();

    var src = "<div id='a'><span class='k'>v</span></div>".*;
    try doc.parse(&src);

    try std.testing.expect(doc.queryOne("div#a") != null);
    try std.testing.expect((try doc.queryOneRuntime(alloc, "span")) != null);
    const span = (try doc.queryOneRuntime(alloc, "span.k")) orelse return error.TestUnexpectedResult;
    const parent = span.parentNode() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("div", parent.tagName());
    try std.testing.expect(doc.queryOne("div > span.k") != null);
}

test "top-level parse helper (destructive)" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{};

    var src = "<div id='a'><span>v</span></div>".*;
    var doc = try parse(opts, alloc, &src);
    defer doc.deinit();

    try std.testing.expect(doc.queryOne("div#a > span") != null);
}

test "top-level parse helper (non-destructive)" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{ .non_destructive = true };

    const src = "<div id='a' data-v='x&amp;y'>x</div>";
    var doc = try parse(opts, alloc, src);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const div = doc.queryOne("div#a") orelse return error.TestUnexpectedResult;
    const v = div.getAttributeValueAlloc(arena.allocator(), "data-v") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("x&y", v);
}

test "writeHtml serializes node subtree" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{};
    const Document = opts.GetDocument();

    var doc = Document.init(alloc);
    defer doc.deinit();

    var src = "<div id='a'><span>v</span></div>".*;
    try doc.parse(&src);

    const div = doc.queryOne("div") orelse return error.TestUnexpectedResult;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try div.writeHtml(&out.writer);
    try std.testing.expectEqualStrings("<div id='a'><span>v</span></div>", out.written());
}

test "writeHtml respects in-place attr parsing and void tags" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{};
    const Document = opts.GetDocument();

    var doc = Document.init(alloc);
    defer doc.deinit();

    var src = "<img id='i' class='x' data-q='1>2'/>".*;
    try doc.parse(&src);

    const img = doc.queryOne("img#i") orelse return error.TestUnexpectedResult;
    _ = img.getAttributeValue("class") orelse return error.TestUnexpectedResult;
    _ = img.getAttributeValue("data-q") orelse return error.TestUnexpectedResult;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try img.writeHtml(&out.writer);
    try std.testing.expectEqualStrings("<img id=\"i\" class=\"x\" data-q=\"1>2\">", out.written());
}

test "writeHtml reflects in-place text decoding" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{};
    const Document = opts.GetDocument();

    var doc = Document.init(alloc);
    defer doc.deinit();

    var src = "<p>&amp; &lt;</p>".*;
    try doc.parse(&src);

    const p = doc.queryOne("p") orelse return error.TestUnexpectedResult;
    _ = try p.innerText(alloc);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try p.writeHtml(&out.writer);
    try std.testing.expectEqualStrings("<p>& <</p>", out.written());
}

test "writeHtml drops whitespace-only text nodes when configured" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{};
    const Document = opts.GetDocument();

    var doc = Document.init(alloc);
    defer doc.deinit();

    var src = "<div> a <span> b </span> c </div>".*;
    try doc.parse(&src);

    const div = doc.queryOne("div") orelse return error.TestUnexpectedResult;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try div.writeHtml(&out.writer);
    try std.testing.expectEqualStrings("<div> a <span> b </span> c </div>", out.written());
}

test "writeHtml parses and prints complex document" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{ .drop_whitespace_text_nodes = false };
    const Document = opts.GetDocument();

    var doc = Document.init(alloc);
    defer doc.deinit();

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
    try doc.parse(src);

    const html = doc.html() orelse return error.TestUnexpectedResult;

    // at index 6 is the meta node; here is why
    // +1 = head
    // +2 = `\n` [text node]
    // +3 = title
    //   +4 = `Title` [text node]
    // +5 = `\n` [text node]
    try std.testing.expectEqualStrings("utf-8", doc.nodeAt(html.index + 6).?.getAttributeValue("charset").?);
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
    const Document = opts.GetDocument();

    var doc = Document.init(alloc);
    defer doc.deinit();

    var src = "<div id='a'><span>v</span></div>".*;
    try doc.parse(&src);

    const div = doc.queryOne("div") orelse return error.TestUnexpectedResult;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try div.writeHtmlSelf(&out.writer);
    try std.testing.expectEqualStrings("<div id='a'>", out.written());
}
