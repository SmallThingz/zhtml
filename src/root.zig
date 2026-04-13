const std = @import("std");
pub const ParseInt = @import("common.zig").IndexInt;

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
    try doc.parse(&src);

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
    try doc.parse(&src);

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

test "u16 parse rejects oversized input" {
    if (ParseInt != u16) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{};
    const Document = opts.GetDocument();

    var doc = Document.init(alloc);
    defer doc.deinit();

    const max_len: usize = if (@sizeOf(ParseInt) >= @sizeOf(usize))
        std.math.maxInt(usize)
    else
        @as(usize, std.math.maxInt(ParseInt));
    const src = try alloc.alloc(u8, max_len + 1);
    defer alloc.free(src);
    @memset(src, 'a');
    src[0] = '<';
    src[1] = 'p';
    src[2] = '>';

    try std.testing.expectError(error.InputTooLarge, doc.parse(src));
}

test "u64 parse accepts sparse 8 GiB plaintext input" {
    if (ParseInt != u64) return error.SkipZigTest;
    if (@sizeOf(usize) < @sizeOf(u64)) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const opts: ParseOptions = .{};
    const Document = opts.GetDocument();
    var rand_src: std.Random.IoSource = .{ .io = io };
    const path = try std.fmt.allocPrint(alloc, "/tmp/html-u64-8g-{x}.html", .{rand_src.interface().int(u64)});
    defer alloc.free(path);

    const file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = true,
        .exclusive = true,
    });
    defer {
        file.close(io);
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    }

    const len = 8 * 1024 * 1024 * 1024;
    try file.setLength(io, len);

    var mapped = try std.Io.File.MemoryMap.create(io, file, .{
        .len = len,
        .populate = false,
        .undefined_contents = false,
        .protection = .{ .read = true, .write = true },
    });
    defer mapped.destroy(io);

    const tag = "<plaintext>";
    @memcpy(mapped.memory[0..tag.len], tag);

    var doc = Document.init(alloc);
    defer doc.deinit();
    try doc.parse(mapped.memory);

    try std.testing.expectEqual(@as(usize, 3), doc.nodes.items.len);
    const plaintext = doc.nodeAt(1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("plaintext", plaintext.tagName());

    const text = doc.nodeAt(2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(ParseInt, @intCast(tag.len)), text.raw().name_or_text.start);
    try std.testing.expectEqual(@as(ParseInt, @intCast(len)), text.raw().name_or_text.end);
}

test "non-destructive parse supports file-backed memory maps without changing bytes" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const opts: ParseOptions = .{ .non_destructive = true };
    const Document = opts.GetDocument();
    var rand_src: std.Random.IoSource = .{ .io = io };
    const path = try std.fmt.allocPrint(alloc, "/tmp/html-nondestructive-mmap-{x}.html", .{rand_src.interface().int(u64)});
    defer alloc.free(path);

    const html = "<div id='x' data-v='a&amp;b'> hi &amp; bye </div>";
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = true,
        .exclusive = true,
    });
    defer {
        file.close(io);
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    }

    try file.setLength(io, html.len);

    var init_map = try std.Io.File.MemoryMap.create(io, file, .{
        .len = html.len,
        .populate = false,
        .undefined_contents = false,
        .protection = .{ .read = true, .write = true },
    });
    @memcpy(init_map.memory[0..html.len], html);
    init_map.destroy(io);

    var mapped = try std.Io.File.MemoryMap.create(io, file, .{
        .len = html.len,
        .populate = false,
        .undefined_contents = false,
        .protection = .{ .read = true, .write = false },
    });
    defer mapped.destroy(io);

    var doc = Document.init(alloc);
    defer doc.deinit();
    try doc.parse(mapped.memory);

    const node = doc.queryOne("div#x") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a&b", node.getAttributeValue("data-v").?);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try std.testing.expectEqualStrings("hi & bye", try node.innerText(arena.allocator()));

    try std.testing.expectEqualStrings(html, mapped.memory);

    const rendered = try std.fmt.allocPrint(alloc, "{f}", .{doc});
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings(html, rendered);
}
