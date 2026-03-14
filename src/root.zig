const std = @import("std");

/// Parse-time configuration and type factory for `Document`, `Node`, and iterators.
pub const ParseOptions = @import("html/document.zig").ParseOptions;
/// Options controlling whitespace normalization behavior in text extraction APIs.
pub const TextOptions = @import("html/document.zig").TextOptions;
/// Compiled selector representation shared by comptime/runtime query paths.
pub const Selector = @import("selector/ast.zig").Selector;
/// Structured query-debug output populated by `queryOneDebug` APIs.
pub const QueryDebugReport = @import("common.zig").QueryDebugReport;
/// Enumerates first-failure categories recorded by debug query reporting.
pub const DebugFailureKind = @import("common.zig").DebugFailureKind;
/// Single near-miss record used by query diagnostics.
pub const NearMiss = @import("common.zig").NearMiss;
/// Parse instrumentation payload emitted by hook wrappers.
pub const ParseInstrumentationStats = @import("debug/instrumentation.zig").ParseInstrumentationStats;
/// Query instrumentation payload emitted by hook wrappers.
pub const QueryInstrumentationStats = @import("debug/instrumentation.zig").QueryInstrumentationStats;
/// Kind of query operation measured by instrumentation wrappers.
pub const QueryInstrumentationKind = @import("debug/instrumentation.zig").QueryInstrumentationKind;

/// Parses a document and invokes optional start/end hook callbacks.
pub const parseWithHooks = @import("debug/instrumentation.zig").parseWithHooks;
/// Executes `queryOneRuntime` and reports timing through hook callbacks.
pub const queryOneRuntimeWithHooks = @import("debug/instrumentation.zig").queryOneRuntimeWithHooks;
/// Executes `queryOneCached` and reports timing through hook callbacks.
pub const queryOneCachedWithHooks = @import("debug/instrumentation.zig").queryOneCachedWithHooks;
/// Executes `queryAllRuntime` and reports timing through hook callbacks.
pub const queryAllRuntimeWithHooks = @import("debug/instrumentation.zig").queryAllRuntimeWithHooks;
/// Executes `queryAllCached` and reports timing through hook callbacks.
pub const queryAllCachedWithHooks = @import("debug/instrumentation.zig").queryAllCachedWithHooks;

/// Returns the `Document` type specialized for `options`.
pub fn GetDocument(comptime options: ParseOptions) type {
    return options.GetDocument();
}

/// Returns the node-wrapper type specialized for `options`.
pub fn GetNode(comptime options: ParseOptions) type {
    return options.GetNode();
}

/// Returns the raw node storage type specialized for `options`.
pub fn GetNodeRaw(comptime options: ParseOptions) type {
    return options.GetNodeRaw();
}

/// Returns the query iterator type specialized for `options`.
pub fn GetQueryIter(comptime options: ParseOptions) type {
    return options.QueryIter();
}

test "smoke parse/query" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{};
    const Document = opts.GetDocument();

    var doc = Document.init(alloc);
    defer doc.deinit();

    var src = "<div id='a'><span class='k'>v</span></div>".*;
    try doc.parse(&src, .{});

    try std.testing.expect(doc.queryOne("div#a") != null);
    try std.testing.expect((try doc.queryOneRuntime("span")) != null);
    const span = (try doc.queryOneRuntime("span.k")) orelse return error.TestUnexpectedResult;
    const parent = span.parentNode() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("div", parent.tagName());
    try std.testing.expect(doc.queryOne("div > span.k") != null);
}

test "tag-name state keeps < inside malformed start tag name" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{};
    const Document = opts.GetDocument();

    var doc = Document.init(alloc);
    defer doc.deinit();

    var src = "<div<div>".*;
    try doc.parse(&src, .{});

    const first = doc.nodeAt(1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("div<div", first.tagName());
}

test "writeHtml serializes node subtree" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{};
    const Document = opts.GetDocument();

    var doc = Document.init(alloc);
    defer doc.deinit();

    var src = "<div id='a'><span>v</span></div>".*;
    try doc.parse(&src, .{});

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
    try doc.parse(&src, .{});

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
    try doc.parse(&src, .{});

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
    try doc.parse(&src, .{ .drop_whitespace_text_nodes = true });

    const div = doc.queryOne("div") orelse return error.TestUnexpectedResult;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try div.writeHtml(&out.writer);
    try std.testing.expectEqualStrings("<div> a <span> b </span> c </div>", out.written());
}

test "writeHtml parses and prints complex document" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{};
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
    try doc.parse(src, .{ .drop_whitespace_text_nodes = false });

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
    try doc.parse(&src, .{});

    const div = doc.queryOne("div") orelse return error.TestUnexpectedResult;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try div.writeHtmlSelf(&out.writer);
    try std.testing.expectEqualStrings("<div id='a'>", out.written());
}
