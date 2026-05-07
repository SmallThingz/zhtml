const std = @import("std");
const html = @import("html");
const default_options: html.ParseOptions = .{};
const Document = default_options.Document();

test "document helpers find html/head/body on full documents and return null for fragments" {
    var full = "<!doctype html><html><head><title>x</title></head><body><h1 id='t'>T</h1></body></html>".*;
    var doc = try default_options.parse(std.testing.allocator, &full);
    defer doc.deinit();

    try std.testing.expect(doc.html() != null);
    try std.testing.expect(doc.head() != null);
    try std.testing.expect(doc.body() != null);

    var fragment = "<section id='frag'><p>ok</p></section>".*;
    doc.deinit();
    doc = try default_options.parse(std.testing.allocator, &fragment);
    try std.testing.expect(doc.html() == null);
    try std.testing.expect(doc.head() == null);
    try std.testing.expect(doc.body() == null);
}

test "parent navigation uses in-node parent indexes" {
    var input = "<div id='root'><span id='child'></span></div>".*;
    var doc = try default_options.parse(std.testing.allocator, &input);
    defer doc.deinit();
    const child_before = doc.queryOne("span#child") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 1), child_before.raw().parent);

    const child = doc.queryOne("span#child") orelse return error.TestUnexpectedResult;
    const parent = child.parentNode() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("root", (try parent.getAttributeValue(std.testing.allocator, "id")).?.value);
    try std.testing.expectEqual(@as(u32, 1), child.raw().parent);

    const root = doc.queryOne("div#root") orelse return error.TestUnexpectedResult;
    try std.testing.expect(root.firstChild() != null);
    var child_it = root.children();
    var count: usize = 0;
    while (child_it.next() != null) count += 1;
    try std.testing.expect(count == 1);
}

test "queries that need ancestry work with in-node parent pointers" {
    var input = "<div id='a'><span id='b'><em id='c'></em></span></div>".*;
    var doc = try default_options.parse(std.testing.allocator, &input);
    defer doc.deinit();
    try std.testing.expectEqual(@as(u32, 2), (doc.queryOne("#c") orelse return error.TestUnexpectedResult).raw().parent);

    try std.testing.expect(doc.queryOne("#a #c") != null);
}

test "attr-only queries leave parent pointers unchanged" {
    var input = "<div id='a' class='x'></div>".*;
    var doc = try default_options.parse(std.testing.allocator, &input);
    defer doc.deinit();
    const node = doc.queryOne("#a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0), node.raw().parent);

    try std.testing.expect(doc.queryOne("div#a[class=x]") != null);
    try std.testing.expectEqual(@as(u32, 0), node.raw().parent);
}

test "queryAll yields matches in document preorder" {
    const input =
        "<div id='a'>" ++
        "<section id='b'><span id='c'></span></section>" ++
        "<p id='d'></p>" ++
        "</div>";
    var buf = input.*;
    var doc = try default_options.parse(std.testing.allocator, &buf);
    defer doc.deinit();

    var it = doc.queryAll("*[id]");
    const expected = [_][]const u8{ "a", "b", "c", "d" };
    var idx: usize = 0;
    while (it.next()) |node| {
        if (idx >= expected.len) return error.TestUnexpectedResult;
        const id = (try node.getAttributeValue(std.testing.allocator, "id")) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected[idx], id.value);
        idx += 1;
    }
    try std.testing.expectEqual(expected.len, idx);
}

test "element navigation skips text nodes for sibling/child helpers" {
    var input = "<div id='r'>hello<span id='s1'></span>world<b id='b1'></b><i id='i1'></i></div>".*;
    var doc = try default_options.parse(std.testing.allocator, &input);
    defer doc.deinit();

    const root = doc.queryOne("div#r") orelse return error.TestUnexpectedResult;
    const first = root.firstChild() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("s1", (try first.getAttributeValue(std.testing.allocator, "id")).?.value);

    const next = first.nextSibling() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("b1", (try next.getAttributeValue(std.testing.allocator, "id")).?.value);

    const last = root.lastChild() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("i1", (try last.getAttributeValue(std.testing.allocator, "id")).?.value);

    const prev = last.prevSibling() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("b1", (try prev.getAttributeValue(std.testing.allocator, "id")).?.value);
}

test "parser remains permissive on malformed nesting" {
    var input = "<div id='a'><span id='b'></div><p id='c'>tail".*;
    var doc = try default_options.parse(std.testing.allocator, &input);
    defer doc.deinit();

    try std.testing.expect(doc.queryOne("#a") != null);
    try std.testing.expect(doc.queryOne("#b") != null);
    try std.testing.expect(doc.queryOne("#c") != null);
}
