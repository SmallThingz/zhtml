const std = @import("std");
const html = @import("html");
const options: html.ParseOptions = .{ .non_destructive = true };
const Document = options.GetDocument();

pub fn run() !void {
    try runBufferCase();
    try runMappedFileCase();
}

fn runBufferCase() !void {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<div id='x' data-v='a&amp;b'> hi &amp; bye </div>".*;
    const original = input;
    try doc.parse(&input);

    const node = doc.queryOne("div#x") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a&b", node.getAttributeValue("data-v").?);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("hi & bye", try node.innerText(arena.allocator()));

    try std.testing.expectEqualSlices(u8, original[0..], input[0..]);

    const rendered = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{doc});
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(original[0..], rendered);
}

fn runMappedFileCase() !void {
    const io = std.testing.io;
    var rand_src: std.Random.IoSource = .{ .io = io };
    const path = try std.fmt.allocPrint(std.testing.allocator, "/tmp/htmlparser-example-nondestructive-{x}.html", .{
        rand_src.interface().int(u64),
    });
    defer std.testing.allocator.free(path);

    const html_bytes = "<section id='mapped'>a &amp; b</section>";
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = true,
        .exclusive = true,
    });
    defer {
        file.close(io);
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    }

    try file.setLength(io, html_bytes.len);

    var init_map = try std.Io.File.MemoryMap.create(io, file, .{
        .len = html_bytes.len,
        .populate = false,
        .undefined_contents = false,
        .protection = .{ .read = true, .write = true },
    });
    @memcpy(init_map.memory[0..html_bytes.len], html_bytes);
    init_map.destroy(io);

    var mapped = try std.Io.File.MemoryMap.create(io, file, .{
        .len = html_bytes.len,
        .populate = false,
        .undefined_contents = false,
        .protection = .{ .read = true, .write = false },
    });
    defer mapped.destroy(io);

    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();
    try doc.parse(mapped.memory);

    const node = doc.queryOne("section#mapped") orelse return error.TestUnexpectedResult;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a & b", try node.innerText(arena.allocator()));
    try std.testing.expectEqualStrings(html_bytes, mapped.memory);
    const rendered = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{doc});
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(html_bytes, rendered);
}

test "non-destructive parse preserves original bytes for buffers and mapped files" {
    try run();
}
