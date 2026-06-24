const std = @import("std");
const attr = @import("attr.zig");
const common = @import("../common.zig");
const tables = @import("tables.zig");
const tags = @import("tags.zig");

const IndexInt = common.IndexInt;

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
    emit_implicit_end_tags: bool = true,
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
            const name = scan.name orelse continue;
            const raw = attr.parseRawValue(self.source, self.end, self.cursor);
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

        var p = State(@TypeOf(ctx), @TypeOf(callback)){
            .allocator = allocator,
            .source = source,
            .ctx = ctx,
            .callback = callback,
            .options = self.options,
        };
        try p.stack.append(allocator, .{ .name = .{}, .key = 0, .depth = 0 });
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
};

const TagScan = struct {
    start: usize,
    end: usize,
    key: u64,
};

fn State(comptime Ctx: type, comptime Callback: type) type {
    return struct {
        allocator: std.mem.Allocator,
        source: []const u8,
        ctx: Ctx,
        callback: Callback,
        options: Options,
        i: usize = 0,
        stack: std.ArrayList(OpenTag) = .empty,

        const Self = @This();

        fn run(self: *Self) !void {
            while (self.i < self.source.len) {
                const lt = std.mem.indexOfScalarPos(u8, self.source, self.i, '<') orelse self.source.len;
                if (lt > self.i) try self.emitText(self.i, lt);
                if (lt >= self.source.len) break;
                self.i = lt;
                if (self.i + 1 >= self.source.len) {
                    try self.emitText(self.i, self.source.len);
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

            if (self.options.emit_implicit_end_tags) {
                while (self.stack.items.len > 1) {
                    const open = self.stack.pop().?;
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

            if (self.stack.items.len > 1 and tags.mayTriggerImplicitCloseWithKey(tag_name, tag.key)) {
                try self.applyImplicitClosures(tag_name, tag.key, token_start);
            }

            const depth: u32 = @intCast(self.stack.items.len - 1);
            const attrs_start = tag.end;
            const attrs_end = if (self_closing and tag_end > attrs_start) tag_end - 1 else tag_end;
            const ev = Event{
                .source = self.source,
                .kind = .start_tag,
                .depth = depth,
                .name = .{ .start = @intCast(tag.start), .len = @intCast(tag.end - tag.start) },
                .attrs = .{ .start = @intCast(attrs_start), .len = @intCast(attrs_end - attrs_start) },
                .token = .{ .start = @intCast(token_start), .len = @intCast(tag_end + 1 - token_start) },
                .self_closing = self_closing,
            };
            self.i = tag_end + 1;

            const descend = try self.callback(self.ctx, ev);
            if (!descend) {
                if (!self_closing and !tags.isVoidTagWithKey(tag_name, tag.key)) self.i = self.skipSubtree(tag_name, tag.key, self.i);
                return;
            }

            if (self_closing or tags.isVoidTagWithKey(tag_name, tag.key)) return;

            if (tags.isPlainTextTagWithKey(tag_name, tag.key)) {
                if (self.i < self.source.len) try self.emitText(self.i, self.source.len);
                self.i = self.source.len;
                return;
            }

            if (tags.isRawTextTagWithKey(tag_name, tag.key)) {
                try self.parseRawText(tag, depth, token_start);
                return;
            }

            try self.stack.append(self.allocator, .{ .name = ev.name, .key = tag.key, .depth = depth });
        }

        fn parseEndTag(self: *Self) !void {
            const token_start = self.i;
            self.i += 2;
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
                    _ = try self.callback(self.ctx, .{
                        .source = self.source,
                        .kind = .comment,
                        .depth = @intCast(self.stack.items.len - 1),
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
                _ = try self.callback(self.ctx, .{
                    .source = self.source,
                    .kind = .doctype,
                    .depth = @intCast(self.stack.items.len - 1),
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
                _ = try self.callback(self.ctx, .{
                    .source = self.source,
                    .kind = .processing_instruction,
                    .depth = @intCast(self.stack.items.len - 1),
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
            if (start >= end) return;
            if (self.options.drop_whitespace_text_nodes) {
                var i = start;
                while (i < end and tables.WhitespaceTable[self.source[i]]) : (i += 1) {}
                if (i == end) return;
            }
            _ = try self.callback(self.ctx, .{
                .source = self.source,
                .kind = .text,
                .depth = @intCast(self.stack.items.len - 1),
                .value = .{ .start = @intCast(start), .len = @intCast(end - start) },
                .token = .{ .start = @intCast(start), .len = @intCast(end - start) },
            });
        }

        fn emitEnd(self: *Self, open: OpenTag, token_start: usize, token_end: usize, implicit: bool) !void {
            _ = try self.callback(self.ctx, .{
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
            var i = start;
            var key: u64 = 0;
            while (i < self.source.len and tables.TagNameCharTable[self.source[i]]) : (i += 1) {
                const off = i - start;
                if (off < 8) std.mem.asBytes(&key)[off] = std.ascii.toLower(self.source[i]);
            }
            return .{ .start = start, .end = i, .key = key };
        }

        fn findTagEnd(self: *Self, start: usize) ?usize {
            var i = start;
            while (i < self.source.len) : (i += 1) {
                switch (self.source[i]) {
                    '>' => return i,
                    '\'', '"' => |quote| {
                        i += 1;
                        while (i < self.source.len and self.source[i] != quote) : (i += 1) {}
                    },
                    else => {},
                }
            }
            return null;
        }

        fn findBangEnd(self: *Self, start: usize) usize {
            var i = start;
            while (i < self.source.len) : (i += 1) {
                switch (self.source[i]) {
                    '>' => return i + 1,
                    '\'', '"' => |quote| {
                        i += 1;
                        while (i < self.source.len and self.source[i] != quote) : (i += 1) {}
                    },
                    else => {},
                }
            }
            return self.source.len;
        }

        const RawClose = struct { content_end: usize, close_start: usize, close_end: usize };

        fn findRawTextClose(self: *Self, name: []const u8, key: u64, start: usize) ?RawClose {
            var search = start;
            while (std.mem.indexOfScalarPos(u8, self.source, search, '<')) |lt| {
                search = lt + 1;
                if (lt + 2 >= self.source.len or self.source[lt + 1] != '/') continue;
                const close = self.scanTagName(lt + 2);
                if (!tags.equalByLenAndKeyIgnoreCase(self.source[close.start..close.end], close.key, name, key)) continue;
                var end = close.end;
                while (end < self.source.len and tables.WhitespaceTable[self.source[end]]) : (end += 1) {}
                if (end < self.source.len and self.source[end] == '>') return .{ .content_end = lt, .close_start = lt, .close_end = end + 1 };
            }
            return null;
        }

        fn skipSubtree(self: *Self, name: []const u8, key: u64, start: usize) usize {
            var depth: usize = 1;
            var i = start;
            while (std.mem.indexOfScalarPos(u8, self.source, i, '<')) |lt| {
                if (lt + 1 >= self.source.len) return self.source.len;
                if (self.source[lt + 1] == '/') {
                    const close = self.scanTagName(lt + 2);
                    if (tags.equalByLenAndKeyIgnoreCase(self.source[close.start..close.end], close.key, name, key)) {
                        depth -= 1;
                        const end = (std.mem.indexOfScalarPos(u8, self.source, close.end, '>') orelse (self.source.len - 1)) + 1;
                        if (depth == 0) return end;
                        i = end;
                        continue;
                    }
                } else if (tables.TagNameCharTable[self.source[lt + 1]]) {
                    const child = self.scanTagName(lt + 1);
                    if (tags.equalByLenAndKeyIgnoreCase(self.source[child.start..child.end], child.key, name, key)) depth += 1;
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
