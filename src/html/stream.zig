const std = @import("std");
const declaration_testing = @import("../testing.zig");

test {
    declaration_testing.refAllDeclsRecursive(@This());
}
const attr = @import("attr.zig");
const common = @import("../common.zig");
const scanner = @import("scanner.zig");
const tables = @import("tables.zig");
const tags = @import("tags.zig");

const IndexInt = common.IndexInt;

const RawClose = scanner.RawTextClose;
const TagScan = scanner.TagName;

fn findGtScanOnly(source: []const u8, start: usize) usize {
    var i = start;
    const limit = @min(start + 32, source.len);
    while (i < limit) : (i += 1) {
        if (source[i] == '>') return i + 1;
    }
    return (std.mem.indexOfScalarPos(u8, source, i, '>') orelse (source.len - 1)) + 1;
}

fn scanOnly(source: []const u8) void {
    var i: usize = 0;
    while (i < source.len) {
        if (source[i] != '<') {
            i += 1;
            continue;
        }

        const lt = i;
        if (lt + 1 >= source.len) return;

        switch (source[lt + 1]) {
            '/' => i = findGtScanOnly(source, lt + 2),
            '!' => {
                if (lt + 3 < source.len and source[lt + 2] == '-' and source[lt + 3] == '-') {
                    i = if (std.mem.indexOfPos(u8, source, lt + 4, "-->")) |end| end + 3 else source.len;
                } else {
                    i = findGtScanOnly(source, lt + 2);
                }
            },
            '?' => i = findGtScanOnly(source, lt + 2),
            else => |c| {
                if (!tables.TagNameCharTable[c]) {
                    i = lt + 1;
                    continue;
                }
                i = (std.mem.indexOfScalarPos(u8, source, lt + 2, '>') orelse (source.len - 1)) + 1;

                const lower = std.ascii.toLower(c);
                if (lower != 's' and lower != 't' and lower != 'p') continue;
                if (lower == 's' and !scanner.startsWithIgnoreCase(source, lt + 1, "script") and !scanner.startsWithIgnoreCase(source, lt + 1, "style")) continue;
                if (lower == 't' and !scanner.startsWithIgnoreCase(source, lt + 1, "title") and !scanner.startsWithIgnoreCase(source, lt + 1, "textarea")) continue;
                if (lower == 'p' and !scanner.startsWithIgnoreCase(source, lt + 1, "plaintext")) continue;

                const tag = scanOnlyTagName(source, lt + 1);
                const name = source[tag.start..tag.end];
                if (lower == 'p' and tags.isPlainTextTagWithKey(name, tag.key)) return;
                if ((lower == 's' or lower == 't') and tags.isTextOnlyTagWithKey(name, tag.key)) {
                    if (scanOnlyFindRawTextClose(source, name, tag.key, i)) |close| {
                        i = close.close_end;
                    } else {
                        return;
                    }
                }
            },
        }
    }
}

inline fn scanOnlyTagName(source: []const u8, start: usize) TagScan {
    return scanner.scanTagName(source, start, false);
}

fn scanOnlyFindRawTextClose(source: []const u8, name: []const u8, key: u64, start: usize) ?RawClose {
    return scanner.findRawTextClose(source, name, key, start, false);
}

inline fn findTagEndRespectQuotes(source: []const u8, start: usize) ?usize {
    return scanner.findTagEnd(source, start);
}

pub const Span = struct {
    start: IndexInt = 0,
    len: IndexInt = 0,

    pub inline fn end(self: @This()) IndexInt {
        return self.start + self.len;
    }

    pub inline fn slice(self: @This(), source: []const u8) []const u8 {
        return source[self.start..self.end()];
    }
};

pub const EventKind = enum(u8) {
    start_tag,
    end_tag,
    text,
    comment,
    doctype,
    processing_instruction,
};

pub const Options = struct {
    drop_whitespace_text_nodes: bool = false,
    include_comments: bool = false,
    include_doctype: bool = false,
    include_processing_instructions: bool = false,
    emit_start_tags: bool = true,
    emit_text: bool = true,
    emit_end_tags: bool = true,
    emit_implicit_end_tags: bool = true,
    track_nesting: bool = true,
    assume_no_gt_in_attribute_values: bool = false,
};

pub const Attribute = struct {
    source: []const u8,
    name: Span,
    raw_value: Span = .{},
    kind: attr.RawKind = .empty,

    pub inline fn nameSlice(self: @This()) []const u8 {
        return self.name.slice(self.source);
    }

    pub inline fn valueRaw(self: @This()) []const u8 {
        return self.raw_value.slice(self.source);
    }
};

pub const AttributeIterator = struct {
    source: []const u8,
    cursor: usize,
    end: usize,

    pub fn next(self: *@This()) ?Attribute {
        while (self.cursor < self.end) {
            const scan = attr.scanAttrNameOrSkip(self.source, self.end, self.cursor);
            self.cursor = scan.next_start;
            const name = scan.name orelse return null;
            // Empty name: non-name byte skipped by the scanner (e.g. whitespace
            // after the tag name). Not a real attribute.
            if (name.len == 0) continue;
            // Name at the very end of the attribute span: bare attribute with
            // no value, e.g. `<div id>`. parseRawValue requires eq_index < end.
            const delim_index = attr.valueDelimiterIndex(self.source, self.end, self.cursor);
            const raw = if (delim_index < self.end and self.source[delim_index] == '=')
                attr.parseRawValue(self.source, self.end, delim_index)
            else
                attr.RawValue{ .kind = .empty, .start = delim_index, .end = delim_index, .next_start = delim_index };
            self.cursor = raw.next_start;
            return .{
                .source = self.source,
                .name = makeSpan(name.ptr, name.len, self.source),
                .raw_value = .{ .start = @intCast(raw.start), .len = @intCast(raw.end - raw.start) },
                .kind = raw.kind,
            };
        }
        return null;
    }
};

pub const Event = struct {
    source: []const u8,
    kind: EventKind,
    depth: u32,
    name: Span = .{},
    value: Span = .{},
    attrs: Span = .{},
    token: Span = .{},
    self_closing: bool = false,
    implicit: bool = false,

    pub inline fn nameSlice(self: @This()) []const u8 {
        return self.name.slice(self.source);
    }

    pub inline fn valueSlice(self: @This()) []const u8 {
        return self.value.slice(self.source);
    }

    pub inline fn attributes(self: @This()) AttributeIterator {
        return .{ .source = self.source, .cursor = self.attrs.start, .end = self.attrs.end() };
    }
};

pub const Parser = struct {
    options: Options = .{},

    pub fn parse(self: @This(), allocator: std.mem.Allocator, source: []const u8, ctx: anytype, comptime callback: anytype) !void {
        if (!common.lenFits(source.len)) return error.InputTooLarge;

        var p = State(@TypeOf(ctx), callback){
            .allocator = allocator,
            .source = source,
            .ctx = ctx,
            .options = self.options,
        };
        if (self.options.track_nesting) try p.stack.append(allocator, .{ .name = .{}, .key = 0, .depth = 0 });
        defer p.stack.deinit(allocator);
        try p.run();
    }
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8, ctx: anytype, comptime callback: anytype) !void {
    try (Parser{}).parse(allocator, source, ctx, callback);
}

const OpenTag = struct {
    name: Span,
    key: u64,
    depth: u32,
    foreign: bool = false,
};

fn State(comptime Ctx: type, comptime callback: anytype) type {
    return struct {
        allocator: std.mem.Allocator,
        source: []const u8,
        ctx: Ctx,
        options: Options,
        i: usize = 0,
        stack: std.ArrayList(OpenTag) = .empty,

        const Self = @This();

        fn run(self: *Self) !void {
            if (!self.options.emit_start_tags and
                !self.options.emit_text and
                !self.options.emit_end_tags and
                !self.options.track_nesting and
                self.options.assume_no_gt_in_attribute_values and
                !self.options.include_comments and
                !self.options.include_doctype and
                !self.options.include_processing_instructions)
            {
                self.runScanOnly();
                return;
            }

            while (self.i < self.source.len) {
                const lt = std.mem.indexOfScalarPos(u8, self.source, self.i, '<') orelse self.source.len;
                if (lt > self.i and self.options.emit_text) try self.emitText(self.i, lt);
                if (lt >= self.source.len) break;
                self.i = lt;
                if (self.i + 1 >= self.source.len) {
                    if (self.options.emit_text) try self.emitText(self.i, self.source.len);
                    self.i = self.source.len;
                    break;
                }

                switch (self.source[self.i + 1]) {
                    '/' => try self.parseEndTag(),
                    '!' => try self.parseBang(),
                    '?' => try self.parsePi(),
                    else => try self.parseStartTag(),
                }
            }

            if (self.options.track_nesting and self.options.emit_implicit_end_tags) {
                while (self.stack.items.len > 1) {
                    const open = self.stack.pop().?;
                    try self.emitEnd(open, self.i, self.i, true);
                }
            }
        }

        fn runScanOnly(self: *Self) void {
            scanOnly(self.source);
            self.i = self.source.len;
        }

        fn parseStartTag(self: *Self) !void {
            const token_start = self.i;
            self.i += 1;

            const tag = self.scanTagName(self.i);
            if (tag.end == tag.start) {
                self.i = token_start + 1;
                return;
            }
            self.i = tag.end;

            const tag_end = self.findTagEnd(self.i) orelse {
                try self.emitText(token_start, self.source.len);
                self.i = self.source.len;
                return;
            };
            const self_closing = tag_end > tag.start and self.source[tag_end - 1] == '/';
            const tag_name = self.source[tag.start..tag.end];
            const foreign_element = self.currentForeignContext() or tags.isSvgWithKey(tag_name, tag.key) or tags.isMathWithKey(tag_name, tag.key);
            const void_element = !foreign_element and tags.isVoidTagWithKey(tag_name, tag.key);
            const closes_immediately = void_element or (foreign_element and self_closing);

            if (self.options.track_nesting and !foreign_element and self.stack.items.len > 1 and tags.mayTriggerImplicitCloseWithKey(tag_name, tag.key)) {
                try self.applyImplicitClosures(tag_name, tag.key, token_start);
            }

            const depth = self.currentDepth();
            const attrs_start = tag.end;
            const attrs_end = if (self_closing and tag_end > attrs_start) tag_end - 1 else tag_end;
            self.i = tag_end + 1;

            if (!self.options.emit_start_tags) {
                if (!foreign_element and tags.isPlainTextTagWithKey(tag_name, tag.key)) {
                    if (self.options.emit_text and self.i < self.source.len) try self.emitText(self.i, self.source.len);
                    self.i = self.source.len;
                    return;
                }

                if (!foreign_element and tags.isTextOnlyTagWithKey(tag_name, tag.key)) {
                    try self.parseRawText(tag, depth, token_start);
                    return;
                }

                if (self.options.track_nesting and !closes_immediately) {
                    try self.stack.append(self.allocator, .{ .name = .{ .start = @intCast(tag.start), .len = @intCast(tag.end - tag.start) }, .key = tag.key, .depth = depth, .foreign = foreign_element });
                }
                return;
            }

            const ev = Event{
                .source = self.source,
                .kind = .start_tag,
                .depth = depth,
                .name = .{ .start = @intCast(tag.start), .len = @intCast(tag.end - tag.start) },
                .attrs = .{ .start = @intCast(attrs_start), .len = @intCast(attrs_end - attrs_start) },
                .token = .{ .start = @intCast(token_start), .len = @intCast(tag_end + 1 - token_start) },
                .self_closing = self_closing,
            };

            const descend = try callback(self.ctx, ev);
            if (!descend) {
                if (!foreign_element and tags.isPlainTextTagWithKey(tag_name, tag.key)) {
                    self.i = self.source.len;
                } else if (!foreign_element and tags.isTextOnlyTagWithKey(tag_name, tag.key)) {
                    self.i = if (self.findRawTextClose(tag_name, tag.key, self.i)) |close| close.close_end else self.source.len;
                } else if (!closes_immediately) {
                    self.i = self.skipSubtree(tag_name, tag.key, self.i, foreign_element);
                }
                return;
            }

            if (closes_immediately) return;

            if (!foreign_element and tags.isPlainTextTagWithKey(tag_name, tag.key)) {
                if (self.i < self.source.len) try self.emitText(self.i, self.source.len);
                self.i = self.source.len;
                return;
            }

            if (!foreign_element and tags.isTextOnlyTagWithKey(tag_name, tag.key)) {
                try self.parseRawText(tag, depth, token_start);
                return;
            }

            if (self.options.track_nesting) try self.stack.append(self.allocator, .{ .name = ev.name, .key = tag.key, .depth = depth, .foreign = foreign_element });
        }

        /// Returns whether a new start tag is parsed in foreign content. SVG's
        /// `foreignObject` is an HTML integration point for its children.
        fn currentForeignContext(self: *const Self) bool {
            if (!self.options.track_nesting or self.stack.items.len <= 1) return false;
            const open = self.stack.items[self.stack.items.len - 1];
            if (!open.foreign) return false;
            const name = open.name.slice(self.source);
            return !(name.len == 13 and std.ascii.eqlIgnoreCase(name, "foreignObject"));
        }

        fn parseEndTag(self: *Self) !void {
            const token_start = self.i;
            self.i += 2;
            if (!self.options.track_nesting) {
                const tag = self.scanTagName(self.i);
                const token_end = (std.mem.indexOfScalarPos(u8, self.source, tag.end, '>') orelse (self.source.len - 1)) + 1;
                self.i = token_end;
                if (self.options.emit_end_tags and tag.end != tag.start) {
                    _ = try callback(self.ctx, .{
                        .source = self.source,
                        .kind = .end_tag,
                        .depth = 0,
                        .name = .{ .start = @intCast(tag.start), .len = @intCast(tag.end - tag.start) },
                        .token = .{ .start = @intCast(token_start), .len = @intCast(token_end - token_start) },
                    });
                }
                return;
            }
            const tag = self.scanTagName(self.i);
            self.i = tag.end;
            const token_end = (std.mem.indexOfScalarPos(u8, self.source, self.i, '>') orelse (self.source.len - 1)) + 1;
            self.i = token_end;
            if (tag.end == tag.start or self.stack.items.len <= 1) return;

            var pos = self.stack.items.len - 1;
            while (pos > 0) : (pos -= 1) {
                const open = self.stack.items[pos];
                if (self.openMatches(open, tag)) {
                    while (self.stack.items.len - 1 >= pos) {
                        const implicit = self.stack.items.len - 1 != pos;
                        const popped = self.stack.pop().?;
                        try self.emitEnd(popped, token_start, token_end, implicit);
                    }
                    return;
                }
            }
        }

        fn parseBang(self: *Self) !void {
            if (self.i + 3 < self.source.len and self.source[self.i + 2] == '-' and self.source[self.i + 3] == '-') {
                const start = self.i;
                const content_start = self.i + 4;
                const end_marker = std.mem.indexOfPos(u8, self.source, content_start, "-->") orelse self.source.len;
                const token_end = if (end_marker < self.source.len) end_marker + 3 else self.source.len;
                self.i = token_end;
                if (self.options.include_comments) {
                    _ = try callback(self.ctx, .{
                        .source = self.source,
                        .kind = .comment,
                        .depth = self.currentDepth(),
                        .value = .{ .start = @intCast(content_start), .len = @intCast(end_marker - content_start) },
                        .token = .{ .start = @intCast(start), .len = @intCast(token_end - start) },
                    });
                }
                return;
            }

            const start = self.i;
            const token_end = self.findBangEnd(self.i + 2);
            const value_end = if (token_end > start and self.source[token_end - 1] == '>') token_end - 1 else token_end;
            self.i = token_end;
            if (self.options.include_doctype) {
                _ = try callback(self.ctx, .{
                    .source = self.source,
                    .kind = .doctype,
                    .depth = self.currentDepth(),
                    .value = .{ .start = @intCast(start + 2), .len = @intCast(value_end - (start + 2)) },
                    .token = .{ .start = @intCast(start), .len = @intCast(token_end - start) },
                });
            }
        }

        fn parsePi(self: *Self) !void {
            const start = self.i;
            const content_start = self.i + 2;
            const close = std.mem.indexOfPos(u8, self.source, content_start, "?>") orelse std.mem.indexOfScalarPos(u8, self.source, content_start, '>') orelse self.source.len;
            const token_end = if (close < self.source.len and self.source[close] == '?') close + 2 else @min(close + 1, self.source.len);
            self.i = token_end;
            if (self.options.include_processing_instructions) {
                _ = try callback(self.ctx, .{
                    .source = self.source,
                    .kind = .processing_instruction,
                    .depth = self.currentDepth(),
                    .value = .{ .start = @intCast(content_start), .len = @intCast(close - content_start) },
                    .token = .{ .start = @intCast(start), .len = @intCast(token_end - start) },
                });
            }
        }

        fn parseRawText(self: *Self, tag: TagScan, depth: u32, open_start: usize) !void {
            _ = open_start;
            const content_start = self.i;
            if (self.findRawTextClose(self.source[tag.start..tag.end], tag.key, self.i)) |close| {
                if (close.content_end > content_start) try self.emitText(content_start, close.content_end);
                const open = OpenTag{ .name = .{ .start = @intCast(tag.start), .len = @intCast(tag.end - tag.start) }, .key = tag.key, .depth = depth };
                try self.emitEnd(open, close.close_start, close.close_end, false);
                self.i = close.close_end;
            } else {
                if (content_start < self.source.len) try self.emitText(content_start, self.source.len);
                self.i = self.source.len;
            }
        }

        fn emitText(self: *Self, start: usize, end: usize) !void {
            if (!self.options.emit_text) return;
            if (start >= end) return;
            if (self.options.drop_whitespace_text_nodes) {
                var i = start;
                while (i < end and tables.WhitespaceTable[self.source[i]]) : (i += 1) {}
                if (i == end) return;
            }
            _ = try callback(self.ctx, .{
                .source = self.source,
                .kind = .text,
                .depth = self.currentDepth(),
                .value = .{ .start = @intCast(start), .len = @intCast(end - start) },
                .token = .{ .start = @intCast(start), .len = @intCast(end - start) },
            });
        }

        fn emitEnd(self: *Self, open: OpenTag, token_start: usize, token_end: usize, implicit: bool) !void {
            if (!self.options.emit_end_tags) return;
            _ = try callback(self.ctx, .{
                .source = self.source,
                .kind = .end_tag,
                .depth = open.depth,
                .name = open.name,
                .token = .{ .start = @intCast(token_start), .len = @intCast(token_end - token_start) },
                .implicit = implicit,
            });
        }

        fn applyImplicitClosures(self: *Self, new_tag: []const u8, new_key: u64, pos: usize) !void {
            while (self.stack.items.len > 1) {
                const top = self.stack.items[self.stack.items.len - 1];
                if (!tags.isImplicitCloseSourceWithLenAndKey(top.name.len, top.key)) break;
                if (!tags.shouldImplicitlyCloseWithLenAndKey(top.name.len, top.key, new_tag, new_key)) break;
                const popped = self.stack.pop().?;
                if (self.options.emit_implicit_end_tags) try self.emitEnd(popped, pos, pos, true);
            }
        }

        fn scanTagName(self: *Self, start: usize) TagScan {
            return scanOnlyTagName(self.source, start);
        }

        fn currentDepth(self: *Self) u32 {
            return if (self.options.track_nesting) @intCast(self.stack.items.len - 1) else 0;
        }

        fn findTagEnd(self: *Self, start: usize) ?usize {
            if (self.options.assume_no_gt_in_attribute_values) return std.mem.indexOfScalarPos(u8, self.source, start, '>');
            return findTagEndRespectQuotes(self.source, start);
        }

        fn findBangEnd(self: *Self, start: usize) usize {
            if (self.options.assume_no_gt_in_attribute_values) return (std.mem.indexOfScalarPos(u8, self.source, start, '>') orelse (self.source.len - 1)) + 1;
            return if (scanner.findDeclarationEnd(self.source, start)) |end| end + 1 else self.source.len;
        }

        fn findRawTextClose(self: *Self, name: []const u8, key: u64, start: usize) ?RawClose {
            return scanOnlyFindRawTextClose(self.source, name, key, start);
        }

        fn skipSubtree(self: *Self, name: []const u8, key: u64, start: usize, foreign_content: bool) usize {
            var depth: usize = 1;
            var i = start;
            while (std.mem.indexOfScalarPos(u8, self.source, i, '<')) |lt| {
                if (lt + 1 >= self.source.len) return self.source.len;

                if (std.mem.startsWith(u8, self.source[lt..], "<!--")) {
                    i = if (std.mem.indexOfPos(u8, self.source, lt + 4, "-->")) |end| end + 3 else self.source.len;
                    continue;
                }

                if (self.source[lt + 1] == '!') {
                    i = self.findBangEnd(lt + 2);
                    continue;
                }

                if (self.source[lt + 1] == '?') {
                    i = (std.mem.indexOfScalarPos(u8, self.source, lt + 2, '>') orelse (self.source.len - 1)) + 1;
                    continue;
                }

                if (self.source[lt + 1] == '/') {
                    const close = self.scanTagName(lt + 2);
                    if (close.end == close.start) {
                        i = lt + 1;
                        continue;
                    }
                    const end = if (self.findTagEnd(close.end)) |tag_end| tag_end + 1 else self.source.len;
                    if (tags.equalByLenAndKeyIgnoreCase(self.source[close.start..close.end], close.key, name, key)) {
                        depth -= 1;
                        if (depth == 0) return end;
                    }
                    i = end;
                    continue;
                } else if (tables.TagNameCharTable[self.source[lt + 1]]) {
                    const child = self.scanTagName(lt + 1);
                    const end_pos = self.findTagEnd(child.end) orelse return self.source.len;
                    const child_name = self.source[child.start..child.end];
                    const self_closing = end_pos > child.end and self.source[end_pos - 1] == '/';
                    i = end_pos + 1;

                    const closes_immediately = if (foreign_content) self_closing else tags.isVoidTagWithKey(child_name, child.key);
                    if (!closes_immediately) {
                        if (tags.equalByLenAndKeyIgnoreCase(child_name, child.key, name, key)) depth += 1;
                        if (!foreign_content and tags.isPlainTextTagWithKey(child_name, child.key)) return self.source.len;
                        if (!foreign_content and tags.isTextOnlyTagWithKey(child_name, child.key)) {
                            i = if (self.findRawTextClose(child_name, child.key, i)) |raw_close| raw_close.close_end else self.source.len;
                        }
                    }
                    continue;
                }
                i = lt + 1;
            }
            return self.source.len;
        }

        fn openMatches(self: *Self, open: OpenTag, close: TagScan) bool {
            const open_name = open.name.slice(self.source);
            const close_name = self.source[close.start..close.end];
            return tags.equalByLenAndKeyIgnoreCase(open_name, open.key, close_name, close.key);
        }
    };
}

fn makeSpan(ptr: [*]const u8, len: usize, source: []const u8) Span {
    if (len == 0) return .{};
    const start = @intFromPtr(ptr) - @intFromPtr(source.ptr);
    return .{ .start = @intCast(start), .len = @intCast(len) };
}

test "streaming parser emits element text and attrs" {
    const Ctx = struct {
        seen_div: bool = false,
        seen_text: bool = false,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .start_tag and std.ascii.eqlIgnoreCase(ev.nameSlice(), "div")) {
                self.seen_div = true;
                var it = ev.attributes();
                const id = it.next() orelse return error.TestUnexpectedResult;
                try std.testing.expectEqualStrings("id", id.nameSlice());
                try std.testing.expectEqualStrings("a", id.valueRaw());
            }
            if (ev.kind == .text and std.mem.eql(u8, ev.valueSlice(), "hello")) self.seen_text = true;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<div id='a'>hello</div>", &ctx, Ctx.cb);
    try std.testing.expect(ctx.seen_div);
    try std.testing.expect(ctx.seen_text);
}

test "streaming attribute iterator handles whitespace around equals and booleans" {
    const Ctx = struct {
        checked: bool = false,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind != .start_tag or !std.mem.eql(u8, ev.nameSlice(), "div")) return true;
            var it = ev.attributes();

            const hidden = it.next() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("hidden", hidden.nameSlice());
            try std.testing.expectEqualStrings("", hidden.valueRaw());
            try std.testing.expectEqual(attr.RawKind.empty, hidden.kind);

            const id = it.next() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("id", id.nameSlice());
            try std.testing.expectEqualStrings("x", id.valueRaw());

            const class = it.next() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("class", class.nameSlice());
            try std.testing.expectEqualStrings("a b", class.valueRaw());

            const tail = it.next() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("tail", tail.nameSlice());
            try std.testing.expectEqualStrings("", tail.valueRaw());
            try std.testing.expect(it.next() == null);
            self.checked = true;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<div hidden id \n = x class= \"a b\" tail></div>", &ctx, Ctx.cb);
    try std.testing.expect(ctx.checked);
}

test "streaming attribute iterator stops at self-closing slash" {
    const Ctx = struct {
        checked: bool = false,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind != .start_tag or !std.mem.eql(u8, ev.nameSlice(), "img")) return true;
            var it = ev.attributes();
            const id = it.next() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("id", id.nameSlice());
            try std.testing.expectEqualStrings("x", id.valueRaw());
            try std.testing.expect(it.next() == null);
            self.checked = true;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<img id = x />", &ctx, Ctx.cb);
    try std.testing.expect(ctx.checked);
}

test "trailing slash does not close non-void HTML elements" {
    const Ctx = struct {
        text_depth: ?usize = null,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .text and std.mem.eql(u8, ev.valueSlice(), "x")) self.text_depth = ev.depth;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<div/>x</div>", &ctx, Ctx.cb);
    try std.testing.expectEqual(@as(?usize, 1), ctx.text_depth);
}

test "streaming self-closing syntax closes SVG and MathML elements" {
    const Ctx = struct {
        svg_text_depth: ?usize = null,
        math_text_depth: ?usize = null,
        implicit_g_end: bool = false,
        implicit_mrow_end: bool = false,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .text and std.mem.eql(u8, ev.valueSlice(), "svg-text")) self.svg_text_depth = ev.depth;
            if (ev.kind == .text and std.mem.eql(u8, ev.valueSlice(), "math-text")) self.math_text_depth = ev.depth;
            if (ev.kind == .end_tag and ev.implicit and std.mem.eql(u8, ev.nameSlice(), "g")) self.implicit_g_end = true;
            if (ev.kind == .end_tag and ev.implicit and std.mem.eql(u8, ev.nameSlice(), "mrow")) self.implicit_mrow_end = true;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<svg><g/>svg-text</svg><math><mrow/>math-text</math>", &ctx, Ctx.cb);
    try std.testing.expectEqual(@as(?usize, 1), ctx.svg_text_depth);
    try std.testing.expectEqual(@as(?usize, 1), ctx.math_text_depth);
    try std.testing.expect(!ctx.implicit_g_end);
    try std.testing.expect(!ctx.implicit_mrow_end);
}

test "SVG foreignObject children use HTML self-closing rules" {
    const Ctx = struct {
        text_depth: ?usize = null,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .text and std.mem.eql(u8, ev.valueSlice(), "x")) self.text_depth = ev.depth;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<svg><foreignObject><div/>x</div></foreignObject></svg>", &ctx, Ctx.cb);
    try std.testing.expectEqual(@as(?usize, 3), ctx.text_depth);
}

test "skipping SVG honors nested self-closing foreign elements" {
    const Ctx = struct {
        saw_after: bool = false,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind != .start_tag) return true;
            if (std.mem.eql(u8, ev.nameSlice(), "svg")) return false;
            if (std.mem.eql(u8, ev.nameSlice(), "div")) self.saw_after = true;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<svg><svg/></svg><div></div>", &ctx, Ctx.cb);
    try std.testing.expect(ctx.saw_after);
}

test "streaming attribute iterator accepts framework attribute names" {
    const Ctx = struct {
        checked: bool = false,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind != .start_tag) return true;
            var it = ev.attributes();
            const expected = [_][]const u8{ "@click", "*ngIf", "(change)", "[value]", "v-on:click", "x-on:keydown", "data-foo.bar" };
            for (expected) |name| {
                const item = it.next() orelse return error.TestUnexpectedResult;
                try std.testing.expectEqualStrings(name, item.nameSlice());
                try std.testing.expectEqualStrings("x", item.valueRaw());
            }
            try std.testing.expect(it.next() == null);
            self.checked = true;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<div @click=x *ngIf=x (change)=x [value]=x v-on:click=x x-on:keydown=x data-foo.bar=x>", &ctx, Ctx.cb);
    try std.testing.expect(ctx.checked);
}

test "streaming parser handles raw text comments and implicit closes" {
    const Ctx = struct {
        starts: usize = 0,
        ends: usize = 0,
        raw_text: bool = false,
        comments: usize = 0,

        fn cb(self: *@This(), ev: Event) !bool {
            switch (ev.kind) {
                .start_tag => self.starts += 1,
                .end_tag => self.ends += 1,
                .text => {
                    if (std.mem.eql(u8, ev.valueSlice(), "if (a < b) c();")) self.raw_text = true;
                },
                .comment => self.comments += 1,
                else => {},
            }
            return true;
        }
    };

    var ctx: Ctx = .{};
    try (Parser{ .options = .{ .include_comments = true } }).parse(std.testing.allocator, "<p>one<p>two<script>if (a < b) c();</script><!--x-->", &ctx, Ctx.cb);
    try std.testing.expectEqual(@as(usize, 3), ctx.starts);
    try std.testing.expect(ctx.ends >= 3);
    try std.testing.expect(ctx.raw_text);
    try std.testing.expectEqual(@as(usize, 1), ctx.comments);
}

test "streaming raw-text close respects attributes with spaced assignment" {
    const Ctx = struct {
        saw_after: bool = false,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .start_tag and std.mem.eql(u8, ev.nameSlice(), "div")) self.saw_after = true;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<script>x</script data-x = \"a>b\"><div></div>", &ctx, Ctx.cb);
    try std.testing.expect(ctx.saw_after);
}

test "streaming parser keeps raw and escapable raw tag contents opaque" {
    const Ctx = struct {
        script_text: bool = false,
        title_text: bool = false,
        nested_b: bool = false,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .start_tag and std.mem.eql(u8, ev.nameSlice(), "b")) self.nested_b = true;
            if (ev.kind == .text and std.mem.eql(u8, ev.valueSlice(), "a&amp;<b>")) self.script_text = true;
            if (ev.kind == .text and std.mem.eql(u8, ev.valueSlice(), "c&amp;<b>")) self.title_text = true;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<script>a&amp;<b></script><title>c&amp;<b></title>", &ctx, Ctx.cb);
    try std.testing.expect(ctx.script_text);
    try std.testing.expect(ctx.title_text);
    try std.testing.expect(!ctx.nested_b);
}

test "streaming parser callback can skip subtree" {
    const Ctx = struct {
        text_count: usize = 0,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .start_tag and std.mem.eql(u8, ev.nameSlice(), "section")) return false;
            if (ev.kind == .text) self.text_count += 1;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<main>a<section>skip<span>x</span></section>b</main>", &ctx, Ctx.cb);
    try std.testing.expectEqual(@as(usize, 2), ctx.text_count);
}

test "streaming parser skip subtree treats raw text as opaque" {
    const Ctx = struct {
        text_count: usize = 0,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .start_tag and std.mem.eql(u8, ev.nameSlice(), "script")) return false;
            if (ev.kind == .text) self.text_count += 1;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<main>a<script>var s = \"<div>\";</script>b</main>", &ctx, Ctx.cb);
    try std.testing.expectEqual(@as(usize, 2), ctx.text_count);
}

test "streaming parser skip ancestor ignores fake closes in opaque syntax" {
    const Ctx = struct {
        text: std.ArrayList(u8) = .empty,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .start_tag and std.mem.eql(u8, ev.nameSlice(), "section")) return false;
            if (ev.kind == .text) try self.text.appendSlice(std.testing.allocator, ev.valueSlice());
            return true;
        }
    };

    var ctx: Ctx = .{};
    defer ctx.text.deinit(std.testing.allocator);
    const input =
        "a<section><!-- </section> --><div title='</section>'></div>" ++
        "<script>\"</section>\"</script><p>skip</p></section>b";
    try parse(std.testing.allocator, input, &ctx, Ctx.cb);
    try std.testing.expectEqualStrings("ab", ctx.text.items);
}

test "streaming parser emits syntactic end tags without nesting" {
    const Ctx = struct {
        names: std.ArrayList(u8) = .empty,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .end_tag) {
                if (self.names.items.len != 0) try self.names.append(std.testing.allocator, ',');
                try self.names.appendSlice(std.testing.allocator, ev.nameSlice());
                try std.testing.expectEqual(@as(u32, 0), ev.depth);
            }
            return true;
        }
    };

    var ctx: Ctx = .{};
    defer ctx.names.deinit(std.testing.allocator);
    try (Parser{ .options = .{ .track_nesting = false, .emit_end_tags = true } }).parse(
        std.testing.allocator,
        "<a></a><b></b>",
        &ctx,
        Ctx.cb,
    );
    try std.testing.expectEqualStrings("a,b", ctx.names.items);
}
