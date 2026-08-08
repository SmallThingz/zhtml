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
const open_tag_index = @import("open_tag_index.zig");

pub const Span = common.Span;

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

pub const Attribute = attr.RawAttribute;
pub const AttributeIterator = attr.RawIterator;

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

const ParserOptions = Options;
const ParserEvent = Event;
const ParserEventKind = EventKind;
const ParserAttribute = Attribute;
const ParserAttributeIterator = AttributeIterator;

pub const Parser = struct {
    /// Configuration and callback types are namespaced under the parser API.
    pub const Options = ParserOptions;
    pub const Event = ParserEvent;
    pub const EventKind = ParserEventKind;
    pub const Attribute = ParserAttribute;
    pub const AttributeIterator = ParserAttributeIterator;

    options: ParserOptions = .{},

    pub fn parse(self: @This(), allocator: std.mem.Allocator, source: []const u8, ctx: anytype, comptime callback: anytype) !void {
        if (!common.lenFits(source.len)) return error.InputTooLarge;

        if (!self.options.emit_start_tags and
            !self.options.emit_text and
            !self.options.emit_end_tags and
            !self.options.include_comments and
            !self.options.include_doctype and
            !self.options.include_processing_instructions)
        {
            // No event kind is enabled: nothing to scan or emit, and no parser
            // state to construct.
            return;
        }

        var p = State(@TypeOf(ctx), callback){
            .allocator = allocator,
            .source = source,
            .ctx = ctx,
            .options = self.options,
        };
        if (self.options.track_nesting) try p.stack.append(allocator, .{ .name = .{}, .key = 0, .depth = 0 });
        defer p.stack.deinit(allocator);
        defer p.tag_index.deinit(allocator);
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
    prev_same: open_tag_index.StackPos = open_tag_index.no_stack_pos,

    pub fn sig(self: *const @This()) open_tag_index.TagSig {
        return open_tag_index.signature(self.key, self.name.len);
    }
};

fn State(comptime Ctx: type, comptime callback: anytype) type {
    return struct {
        allocator: std.mem.Allocator,
        source: []const u8,
        ctx: Ctx,
        options: Options,
        i: usize = 0,
        stack: std.ArrayList(OpenTag) = .empty,
        tag_index: open_tag_index.LiveIndex(OpenTag) = .{},

        const Self = @This();

        fn run(self: *Self) !void {
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
                    const open = self.popOpen();
                    try self.emitEnd(open, self.i, self.i, true);
                }
            }
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
            const name_span: Span = .{ .start = @intCast(tag.start), .len = @intCast(tag.end - tag.start) };
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

            if (self.options.emit_start_tags) {
                const ev = Event{
                    .source = self.source,
                    .kind = .start_tag,
                    .depth = depth,
                    .name = name_span,
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
            }

            if (closes_immediately) return;

            if (!foreign_element and tags.isPlainTextTagWithKey(tag_name, tag.key)) {
                if (self.options.emit_text and self.i < self.source.len) try self.emitText(self.i, self.source.len);
                self.i = self.source.len;
                return;
            }

            if (!foreign_element and tags.isTextOnlyTagWithKey(tag_name, tag.key)) {
                try self.parseRawText(tag, depth, token_start);
                return;
            }

            if (self.options.track_nesting) try self.pushOpen(.{ .name = name_span, .key = tag.key, .depth = depth, .foreign = foreign_element });
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
            const tag = self.scanTagName(self.i);
            self.i = tag.end;
            const token_end = if (self.findTagEnd(self.i)) |end| end + 1 else self.source.len;
            self.i = token_end;
            const name_span: Span = .{ .start = @intCast(tag.start), .len = @intCast(tag.end - tag.start) };

            if (!self.options.track_nesting) {
                if (self.options.emit_end_tags and tag.end != tag.start) {
                    _ = try callback(self.ctx, .{
                        .source = self.source,
                        .kind = .end_tag,
                        .depth = 0,
                        .name = name_span,
                        .token = .{ .start = @intCast(token_start), .len = @intCast(token_end - token_start) },
                    });
                }
                return;
            }

            if (tag.end == tag.start or self.stack.items.len <= 1) return;

            const top_pos = self.stack.items.len - 1;
            const top = self.stack.items[top_pos];
            if (self.openMatches(top, tag)) {
                const popped = self.popOpen();
                try self.emitEnd(popped, token_start, token_end, false);
                return;
            }

            if (try self.findOpenForSlowClose(tag)) |found_pos| {
                const pos: usize = @intCast(found_pos);
                while (self.stack.items.len - 1 >= pos) {
                    const implicit = self.stack.items.len - 1 != pos;
                    const popped = self.popOpen();
                    try self.emitEnd(popped, token_start, token_end, implicit);
                }
                return;
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
            const name_span: Span = .{ .start = @intCast(tag.start), .len = @intCast(tag.end - tag.start) };
            if (self.findRawTextClose(self.source[tag.start..tag.end], tag.key, self.i)) |close| {
                if (close.content_end > content_start) try self.emitText(content_start, close.content_end);
                const open = OpenTag{ .name = name_span, .key = tag.key, .depth = depth };
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
                const popped = self.popOpen();
                if (self.options.emit_implicit_end_tags) try self.emitEnd(popped, pos, pos, true);
            }
        }

        fn pushOpen(self: *Self, open_value: OpenTag) !void {
            var open = open_value;
            try self.tag_index.preparePush(self.allocator, &open);
            try self.stack.append(self.allocator, open);
            self.tag_index.commitPush(&self.stack.items[self.stack.items.len - 1], self.stack.items.len);
        }

        fn popOpen(self: *Self) OpenTag {
            const pos = self.stack.items.len - 1;
            const open = self.stack.pop().?;
            std.debug.assert(open.name.len != 0);
            self.tag_index.pop(&open, pos + 1);
            self.tag_index.maybeDeactivate(self.allocator, self.stack.items.len);
            return open;
        }

        fn findOpenForSlowClose(self: *Self, close: TagScan) !?open_tag_index.StackPos {
            const close_name = self.source[close.start..close.end];
            if (!self.tag_index.active) {
                // Covers the top of the stack (index len-1) down to index 1;
                // index 0 is the pseudo-root sentinel and is never matched.
                var pos = self.stack.items.len - 1;
                while (pos >= 1) {
                    if (self.openMatchesName(self.stack.items[pos], close_name, close.key)) return @intCast(pos);
                    pos -= 1;
                }
                try self.tag_index.activate(self.allocator, self.stack.items);
                return null;
            }

            var pos = self.tag_index.find(close.key, close_name.len) orelse return null;
            while (pos != open_tag_index.no_stack_pos) {
                const open = self.stack.items[@intCast(pos)];
                if (self.openMatchesName(open, close_name, close.key)) return pos;
                pos = open.prev_same;
            }
            return null;
        }

        inline fn openMatchesName(self: *const Self, open: OpenTag, close_name: []const u8, close_key: u64) bool {
            if (open.name.len != close_name.len or open.key != close_key) return false;
            if (close_name.len <= 8) return true;
            return std.ascii.eqlIgnoreCase(open.name.slice(self.source)[8..], close_name[8..]);
        }

        fn scanTagName(self: *Self, start: usize) TagScan {
            return scanner.scanTagName(self.source, start, false);
        }

        fn currentDepth(self: *Self) u32 {
            return if (self.options.track_nesting) @intCast(self.stack.items.len - 1) else 0;
        }

        fn findTagEnd(self: *Self, start: usize) ?usize {
            if (self.options.assume_no_gt_in_attribute_values) return std.mem.indexOfScalarPos(u8, self.source, start, '>');
            return scanner.findTagEnd(self.source, start);
        }

        fn findBangEnd(self: *Self, start: usize) usize {
            if (self.options.assume_no_gt_in_attribute_values) return (std.mem.indexOfScalarPos(u8, self.source, start, '>') orelse (self.source.len - 1)) + 1;
            return if (scanner.findDeclarationEnd(self.source, start)) |end| end + 1 else self.source.len;
        }

        fn findRawTextClose(self: *Self, name: []const u8, key: u64, start: usize) ?RawClose {
            return scanner.findRawTextClose(self.source, name, key, start, false);
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
                try std.testing.expectEqualStrings("a", id.valueRaw().?);
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
            try std.testing.expect(hidden.valueRaw() == null);

            const id = it.next() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("id", id.nameSlice());
            try std.testing.expectEqualStrings("x", id.valueRaw().?);

            const class = it.next() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("class", class.nameSlice());
            try std.testing.expectEqualStrings("a b", class.valueRaw().?);

            const tail = it.next() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("tail", tail.nameSlice());
            try std.testing.expect(tail.valueRaw() == null);
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
            try std.testing.expectEqualStrings("x", id.valueRaw().?);
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
                try std.testing.expectEqualStrings("x", item.valueRaw().?);
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

test "streaming end-tag token respects quoted greater-than" {
    const Ctx = struct {
        saw_div_close: bool = false,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .end_tag and std.mem.eql(u8, ev.nameSlice(), "div")) {
                try std.testing.expectEqualStrings("</div data-x=\"a>b\">", ev.token.slice(ev.source));
                self.saw_div_close = true;
            }
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<div></div data-x=\"a>b\"><p></p>", &ctx, Ctx.cb);
    try std.testing.expect(ctx.saw_div_close);
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

test "streaming closing-tag index maintains previous duplicate links" {
    const Ctx = struct {
        implicit_c: bool = false,
        closed_outer_a: bool = false,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind != .end_tag) return true;
            if (ev.implicit and std.mem.eql(u8, ev.nameSlice(), "c")) self.implicit_c = true;
            if (!ev.implicit and std.ascii.eqlIgnoreCase(ev.nameSlice(), "a") and ev.depth == 0) self.closed_outer_a = true;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<A><b><a></A><c></A>", &ctx, Ctx.cb);
    try std.testing.expect(ctx.implicit_c);
    try std.testing.expect(ctx.closed_outer_a);
}

test "streaming lazy closing snapshot handles stale reuse dirty suffix and long collisions" {
    const Ctx = struct {
        implicit_y: bool = false,
        explicit_x: bool = false,
        implicit_long_y: bool = false,
        explicit_long_x: bool = false,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind != .end_tag) return true;
            if (ev.implicit and std.ascii.eqlIgnoreCase(ev.nameSlice(), "y")) self.implicit_y = true;
            if (!ev.implicit and std.ascii.eqlIgnoreCase(ev.nameSlice(), "x")) self.explicit_x = true;
            if (ev.implicit and std.ascii.eqlIgnoreCase(ev.nameSlice(), "abcdefghY1")) self.implicit_long_y = true;
            if (!ev.implicit and std.ascii.eqlIgnoreCase(ev.nameSlice(), "abcdefghX1")) self.explicit_long_x = true;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(
        std.testing.allocator,
        "<a><b><c></missing></c></b><x><y></x></a>" ++
            "<abcdefghX1><abcdefghY1></missing2></ABCDEFGHx1>",
        &ctx,
        Ctx.cb,
    );
    try std.testing.expect(ctx.implicit_y);
    try std.testing.expect(ctx.explicit_x);
    try std.testing.expect(ctx.implicit_long_y);
    try std.testing.expect(ctx.explicit_long_x);
}
