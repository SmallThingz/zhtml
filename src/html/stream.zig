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
    depth: IndexInt,
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
            return;
        }

        var stack_buffer: [32]OpenTag = undefined;
        var p = State(@TypeOf(ctx), callback){
            .allocator = allocator,
            .source = source,
            .ctx = ctx,
            .options = self.options,
            .stack = .initBuffer(&stack_buffer),
        };
        if (self.options.track_nesting) p.stack.appendAssumeCapacity(.{ .name = .{}, .key = 0 });
        defer if (p.stack_heap) p.stack.deinit(allocator);
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
    foreign: bool = false,
    implicit_source: u8 = 0,
    implicit_boundary: u8 = 0,

    pub inline fn keyValue(self: *const @This()) u64 {
        return self.key;
    }
};

const SkipOpenTag = struct {
    name: []const u8,
    key: u64,
    foreign: bool = false,
};

const SkipResult = struct {
    pos: usize,
    resume_parent_foreign: ?bool = null,
};

fn State(comptime Ctx: type, comptime callback: anytype) type {
    return struct {
        allocator: std.mem.Allocator,
        source: []const u8,
        ctx: Ctx,
        options: Options,
        i: usize = 0,
        stack: std.ArrayList(OpenTag) = .empty,
        stack_heap: bool = false,
        tag_index: open_tag_index.LiveIndex(OpenTag) = .{},
        implicit_source_mask: u8 = 0,
        implicit_source_counts: [8]IndexInt = .{0} ** 8,
        slow_close_misses: u8 = 0,

        const Self = @This();

        fn run(self: *Self) !void {
            while (self.i < self.source.len) {
                const lt = scanner.findBytePosOrEnd(self.source, self.i, '<');
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

            if (self.options.track_nesting) {
                while (self.stack.items.len > 1) {
                    const open = self.popOpen();
                    try self.emitEnd(open, self.i, self.i, true);
                }
            }
        }

        fn parseStartTag(self: *Self) !void {
            var resume_parent_foreign: ?bool = null;
            try self.parseStartTagImpl(false, false, &resume_parent_foreign);
            if (resume_parent_foreign) |parent_foreign| try self.parseResumedStartTags(parent_foreign);
        }

        noinline fn parseResumedStartTags(self: *Self, initial_parent_foreign: bool) !void {
            var parent_foreign = initial_parent_foreign;
            while (true) {
                var resume_parent_foreign: ?bool = null;
                try self.parseStartTagImpl(true, parent_foreign, &resume_parent_foreign);
                parent_foreign = resume_parent_foreign orelse return;
            }
        }

        fn parseStartTagImpl(
            self: *Self,
            comptime has_parent_override: bool,
            parent_override: bool,
            resume_parent_foreign: *?bool,
        ) !void {
            const token_start = self.i;
            self.i += 1;

            const tag = self.scanTagName(self.i);
            if (tag.end == tag.start) {
                // HTML's data-state `<` is emitted as text when the following
                // byte cannot start a tag, then that byte is reconsumed.
                if (self.options.emit_text) try self.emitText(token_start, token_start + 1);
                self.i = token_start + 1;
                return;
            }
            self.i = tag.end;

            const tag_end = self.findTagEnd(self.i) orelse {
                self.i = self.source.len;
                return;
            };
            const self_closing = self.source[tag_end - 1] == '/' and scanner.isSelfClosingStartTag(self.source, tag.end, tag_end);
            const tag_name = self.source[tag.start..tag.end];
            const name_span: Span = .{ .start = @intCast(tag.start), .len = @intCast(tag.end - tag.start) };
            const parent_foreign = if (comptime has_parent_override) parent_override else self.currentForeignContext();
            const foreign_element = parent_foreign or tags.isSvgWithKey(tag_name, tag.key) or tags.isMathWithKey(tag_name, tag.key);
            const void_element = !foreign_element and tags.isVoidTagWithKey(tag_name, tag.key);
            const closes_immediately = void_element or (foreign_element and self_closing);

            const implicit_meta = if (self.options.track_nesting and !foreign_element) tags.implicitCloseMeta(tag_name, tag.key) else 0;
            const implicit_source: u8 = @truncate(implicit_meta);
            const implicit_trigger: u8 = @truncate(implicit_meta >> 8);
            if (self.stack.items.len > 1 and self.implicit_source_mask & implicit_trigger != 0) {
                try self.applyImplicitClosures(implicit_trigger, token_start);
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
                        const skipped = try self.skipSubtree(tag_name, tag.key, self.i, foreign_element);
                        self.i = skipped.pos;
                        resume_parent_foreign.* = skipped.resume_parent_foreign;
                    }
                    return;
                }
            }

            if (closes_immediately) return;

            if (!foreign_element and tags.isPlainTextTagWithKey(tag_name, tag.key)) {
                const text_depth = if (self.options.track_nesting) depth + 1 else 0;
                if (self.options.emit_text and self.i < self.source.len) try self.emitTextAtDepth(self.i, self.source.len, text_depth);
                self.i = self.source.len;
                if (self.options.track_nesting) {
                    const open = OpenTag{ .name = name_span, .key = tag.key };
                    try self.emitEnd(open, self.i, self.i, true);
                }
                return;
            }

            if (!foreign_element and tags.isTextOnlyTagWithKey(tag_name, tag.key)) {
                try self.parseRawText(tag, depth);
                return;
            }

            if (self.options.track_nesting) try self.pushOpen(.{
                .name = name_span,
                .key = tag.key,
                .foreign = foreign_element,
                .implicit_source = implicit_source,
                .implicit_boundary = if (self.implicit_source_mask != 0)
                    if (foreign_element)
                        foreignRegularScopeBoundary(tag_name, true)
                    else
                        tags.implicitCloseBoundaryMask(tag_name.len, tag.key)
                else
                    0,
            });
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
            const tag_end = self.findTagEnd(self.i) orelse {
                // HTML tokenizer eof-in-tag: an unfinished end-tag token is
                // discarded rather than emitted or applied to the open stack.
                self.i = self.source.len;
                return;
            };
            const token_end = tag_end + 1;
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
                const close = scanner.findCommentClose(self.source, content_start);
                self.i = close.token_end;
                if (self.options.include_comments) {
                    _ = try callback(self.ctx, .{
                        .source = self.source,
                        .kind = .comment,
                        .depth = self.currentDepth(),
                        .value = .{ .start = @intCast(content_start), .len = @intCast(close.content_end - content_start) },
                        .token = .{ .start = @intCast(start), .len = @intCast(close.token_end - start) },
                    });
                }
                return;
            }

            if (self.i + 9 <= self.source.len and self.source[self.i + 2] == '[' and
                std.mem.startsWith(u8, self.source[self.i..], "<![CDATA[") and self.currentForeignContext())
            {
                const content_start = self.i + 9;
                const token_end = scanner.findCdataEnd(self.source, content_start);
                const content_end = if (token_end >= 3 and std.mem.endsWith(u8, self.source[self.i..token_end], "]]>")) token_end - 3 else token_end;
                self.i = token_end;
                try self.emitTextAtDepth(content_start, content_end, self.currentDepth());
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

        noinline fn parsePi(self: *Self) !void {
            const start = self.i;
            const content_start = self.i + 2;
            const close = scanner.findBytePosOrEnd(self.source, content_start, '>');
            const value_end = if (close > content_start and close < self.source.len and self.source[close - 1] == '?') close - 1 else close;
            const token_end = @min(close + 1, self.source.len);
            self.i = token_end;
            if (self.options.include_processing_instructions) {
                _ = try callback(self.ctx, .{
                    .source = self.source,
                    .kind = .processing_instruction,
                    .depth = self.currentDepth(),
                    .value = .{ .start = @intCast(content_start), .len = @intCast(value_end - content_start) },
                    .token = .{ .start = @intCast(start), .len = @intCast(token_end - start) },
                });
            }
        }

        fn parseRawText(self: *Self, tag: TagScan, depth: IndexInt) !void {
            const content_start = self.i;
            const name_span: Span = .{ .start = @intCast(tag.start), .len = @intCast(tag.end - tag.start) };
            const text_depth = if (self.options.track_nesting) depth + 1 else 0;
            const open = OpenTag{ .name = name_span, .key = tag.key };
            if (self.findRawTextClose(self.source[tag.start..tag.end], tag.key, self.i)) |close| {
                if (close.content_end > content_start) try self.emitTextAtDepth(content_start, close.content_end, text_depth);
                try self.emitEnd(open, close.close_start, close.close_end, false);
                self.i = close.close_end;
            } else {
                if (content_start < self.source.len) try self.emitTextAtDepth(content_start, self.source.len, text_depth);
                self.i = self.source.len;
                if (self.options.track_nesting) try self.emitEnd(open, self.i, self.i, true);
            }
        }

        fn emitText(self: *Self, start: usize, end: usize) !void {
            try self.emitTextAtDepth(start, end, self.currentDepth());
        }

        fn emitTextAtDepth(self: *Self, start: usize, end: usize, depth: IndexInt) !void {
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
                .depth = depth,
                .value = .{ .start = @intCast(start), .len = @intCast(end - start) },
                .token = .{ .start = @intCast(start), .len = @intCast(end - start) },
            });
        }

        fn emitEnd(self: *Self, open: OpenTag, token_start: usize, token_end: usize, implicit: bool) !void {
            if (!self.options.emit_end_tags) return;
            if (implicit and !self.options.emit_implicit_end_tags) return;
            _ = try callback(self.ctx, .{
                .source = self.source,
                .kind = .end_tag,
                .depth = self.currentDepth(),
                .name = open.name,
                .token = .{ .start = @intCast(token_start), .len = @intCast(token_end - token_start) },
                .implicit = implicit,
            });
        }

        fn applyImplicitClosures(self: *Self, trigger: u8, pos: usize) !void {
            while (self.implicit_source_mask & trigger != 0) {
                var stack_pos = self.stack.items.len;
                var found: ?usize = null;
                var scope: u8 = 0;
                const B = tags.ImplicitCloseBoundaryMask;
                while (stack_pos > 1) {
                    stack_pos -= 1;
                    const open = self.stack.items[stack_pos];
                    if (open.implicit_source & trigger != 0) {
                        const blockers: u8 = switch (open.implicit_source) {
                            tags.ImplicitCloseMask.p => B.regular | B.button,
                            tags.ImplicitCloseMask.li => B.regular | B.list_item,
                            tags.ImplicitCloseMask.dt_dd, tags.ImplicitCloseMask.head => B.regular,
                            tags.ImplicitCloseMask.tr, tags.ImplicitCloseMask.td_th => B.table,
                            tags.ImplicitCloseMask.option, tags.ImplicitCloseMask.optgroup => B.select,
                            else => 0,
                        };
                        if (scope & blockers == 0) {
                            found = stack_pos;
                            break;
                        }
                    }
                    scope |= open.implicit_boundary;
                }

                const found_pos = found orelse break;
                while (self.stack.items.len > found_pos) {
                    const popped = self.popOpen();
                    try self.emitEnd(popped, pos, pos, true);
                }
            }
        }

        fn pushOpen(self: *Self, open: OpenTag) !void {
            if (self.tag_index.active) return self.pushOpenIndexed(open);
            if (self.stack.items.len == self.stack.capacity) try self.growOpenStack();
            self.stack.appendAssumeCapacity(open);
            if (open.implicit_source != 0) {
                const source_index: usize = @ctz(open.implicit_source);
                self.implicit_source_counts[source_index] += 1;
                self.implicit_source_mask |= open.implicit_source;
            }
        }

        noinline fn pushOpenIndexed(self: *Self, open_value: OpenTag) !void {
            var open = open_value;
            try self.tag_index.preparePush(self.allocator, &open);
            if (self.stack.items.len == self.stack.capacity) try self.growOpenStack();
            self.stack.appendAssumeCapacity(open);
            self.tag_index.commitPush(&self.stack.items[self.stack.items.len - 1], self.stack.items.len);
            if (open.implicit_source != 0) {
                const source_index: usize = @ctz(open.implicit_source);
                self.implicit_source_counts[source_index] += 1;
                self.implicit_source_mask |= open.implicit_source;
            }
        }

        noinline fn growOpenStack(self: *Self) !void {
            if (self.stack_heap) {
                try self.stack.ensureUnusedCapacity(self.allocator, 1);
                return;
            }
            const old_items = self.stack.items;
            const new_capacity = std.ArrayList(OpenTag).growCapacity(old_items.len + 1);
            const new_memory = try self.allocator.alloc(OpenTag, new_capacity);
            @memcpy(new_memory[0..old_items.len], old_items);
            self.stack.items = new_memory[0..old_items.len];
            self.stack.capacity = new_memory.len;
            self.stack_heap = true;
        }

        fn popOpen(self: *Self) OpenTag {
            if (self.tag_index.active) return self.popOpenIndexed();
            const open = self.stack.pop().?;
            std.debug.assert(open.name.len != 0);
            if (open.implicit_source != 0) {
                const source_index: usize = @ctz(open.implicit_source);
                self.implicit_source_counts[source_index] -= 1;
                if (self.implicit_source_counts[source_index] == 0) self.implicit_source_mask &= ~open.implicit_source;
            }
            return open;
        }

        noinline fn popOpenIndexed(self: *Self) OpenTag {
            const pos = self.stack.items.len - 1;
            const open = self.stack.pop().?;
            std.debug.assert(open.name.len != 0);
            self.tag_index.pop(&open, pos + 1);
            self.tag_index.maybeDeactivate(self.allocator, self.stack.items.len);
            if (!self.tag_index.active) self.slow_close_misses = 0;
            if (open.implicit_source != 0) {
                const source_index: usize = @ctz(open.implicit_source);
                self.implicit_source_counts[source_index] -= 1;
                if (self.implicit_source_counts[source_index] == 0) self.implicit_source_mask &= ~open.implicit_source;
            }
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
                if (self.slow_close_misses < 15) {
                    self.slow_close_misses += 1;
                    return null;
                }
                try self.activateTagIndex();
                return null;
            }

            var pos = self.tag_index.find(close.key) orelse return null;
            while (pos != open_tag_index.no_stack_pos) {
                const open = self.stack.items[@intCast(pos)];
                if (self.openMatchesName(open, close_name, close.key)) return pos;
                pos = self.tag_index.previous(pos);
            }
            return null;
        }

        noinline fn activateTagIndex(self: *Self) !void {
            @branchHint(.cold);
            try self.tag_index.activate(self.allocator, self.stack.items);
        }

        inline fn openMatchesName(self: *const Self, open: OpenTag, close_name: []const u8, close_key: u64) bool {
            if (open.name.len != close_name.len or open.key != close_key) return false;
            if (close_name.len <= 8) return true;
            return std.ascii.eqlIgnoreCase(open.name.slice(self.source)[8..], close_name[8..]);
        }

        inline fn scanTagName(self: *Self, start: usize) TagScan {
            return scanner.scanTagName(self.source, start, false);
        }

        fn currentDepth(self: *Self) IndexInt {
            return if (self.options.track_nesting) @intCast(self.stack.items.len - 1) else 0;
        }

        fn findTagEnd(self: *Self, start: usize) ?usize {
            if (start >= self.source.len) return null;
            if (self.source[start] == '>') return start;
            if (self.options.assume_no_gt_in_attribute_values) {
                const end = scanner.findBytePosOrEnd(self.source, start, '>');
                return if (end == self.source.len) null else end;
            }
            return self.findTagEndQuoted(start);
        }

        noinline fn findTagEndQuoted(self: *Self, start: usize) ?usize {
            return scanner.findTagEnd(self.source, start);
        }

        fn findBangEnd(self: *Self, start: usize) usize {
            if (self.options.assume_no_gt_in_attribute_values) {
                const end = scanner.findBytePosOrEnd(self.source, start, '>');
                return @min(end + 1, self.source.len);
            }
            return if (scanner.findDeclarationEnd(self.source, start)) |end| end + 1 else self.source.len;
        }

        fn findRawTextClose(self: *Self, name: []const u8, key: u64, start: usize) ?RawClose {
            return scanner.findRawTextClose(self.source, name, key, start);
        }

        fn skipSubtree(self: *Self, name: []const u8, key: u64, start: usize, foreign_content: bool) !SkipResult {
            // Keep the skipped root and the parser's live ancestors out of the
            // temporary list. Most skipped subtrees are leaves or shallow, so
            // this avoids both copying the live stack and allocating at all
            // until an actual nested non-void child is encountered.
            const ancestor_count = if (self.options.track_nesting) self.stack.items.len - 1 else 0;
            const root_pos = ancestor_count;
            const root = SkipOpenTag{ .name = name, .key = key, .foreign = foreign_content };
            var descendants: std.ArrayList(SkipOpenTag) = .empty;
            defer descendants.deinit(self.allocator);

            var i = start;
            while (true) {
                const lt = scanner.findBytePosOrEnd(self.source, i, '<');
                if (lt == self.source.len) return .{ .pos = self.source.len };
                if (lt + 1 >= self.source.len) return .{ .pos = self.source.len };

                if (std.mem.startsWith(u8, self.source[lt..], "<!--")) {
                    i = scanner.findCommentClose(self.source, lt + 4).token_end;
                    continue;
                }

                if (self.source[lt + 1] == '!') {
                    if (skipForeignContext(root, descendants.items) and std.mem.startsWith(u8, self.source[lt..], "<![CDATA[")) {
                        i = scanner.findCdataEnd(self.source, lt + 9);
                    } else {
                        i = self.findBangEnd(lt + 2);
                    }
                    continue;
                }

                if (self.source[lt + 1] == '?') {
                    const end = scanner.findBytePosOrEnd(self.source, lt + 2, '>');
                    i = @min(end + 1, self.source.len);
                    continue;
                }

                if (self.source[lt + 1] == '/') {
                    const close = self.scanTagName(lt + 2);
                    if (close.end == close.start) {
                        i = lt + 1;
                        continue;
                    }
                    const token_end = if (self.findTagEnd(close.end)) |tag_end| tag_end + 1 else self.source.len;
                    const close_name = self.source[close.start..close.end];
                    var pos = ancestor_count + 1 + descendants.items.len;
                    while (pos > 0) {
                        pos -= 1;
                        const open = self.skipOpenAt(ancestor_count, root, descendants.items, pos);
                        if (!tags.equalByLenAndKeyIgnoreCase(open.name, open.key, close_name, close.key)) continue;
                        if (pos < root_pos) return .{ .pos = lt };
                        if (pos == root_pos) return .{ .pos = token_end };
                        descendants.items.len = pos - root_pos - 1;
                        break;
                    }
                    i = token_end;
                    continue;
                } else if (tables.TagNameCharTable[self.source[lt + 1]]) {
                    const child = self.scanTagName(lt + 1);
                    const end_pos = self.findTagEnd(child.end) orelse return .{ .pos = self.source.len };
                    const child_name = self.source[child.start..child.end];
                    const self_closing = self.source[end_pos - 1] == '/' and scanner.isSelfClosingStartTag(self.source, child.end, end_pos);
                    const parent_foreign = skipForeignContext(root, descendants.items);
                    const child_foreign = parent_foreign or tags.isSvgWithKey(child_name, child.key) or tags.isMathWithKey(child_name, child.key);

                    if (!child_foreign and tags.implicitCloseTriggerMask(child_name, child.key) != 0) {
                        while (true) {
                            var pos = ancestor_count + 1 + descendants.items.len;
                            var found: ?usize = null;
                            var scope: tags.ImplicitCloseScope = .{};
                            while (pos > 0) {
                                pos -= 1;
                                const open = self.skipOpenAt(ancestor_count, root, descendants.items, pos);
                                if (!open.foreign and tags.isImplicitCloseSourceWithLenAndKey(open.name.len, open.key) and
                                    tags.shouldImplicitlyCloseWithLenAndKey(open.name.len, open.key, child_name, child.key) and
                                    scope.permits(open.name.len, open.key))
                                {
                                    found = pos;
                                    break;
                                }
                                if (open.foreign) {
                                    scope.regular = scope.regular or foreignRegularScopeBoundary(open.name, true) != 0;
                                } else {
                                    scope.observe(open.name.len, open.key);
                                }
                            }
                            const found_pos = found orelse break;
                            if (found_pos <= root_pos) {
                                // The triggering start tag belongs outside the skipped subtree,
                                // but HTML-vs-foreign classification is determined before its
                                // implicit closes. Preserve the skipped top-of-stack context for
                                // exactly this reconsumed start tag.
                                return .{ .pos = lt, .resume_parent_foreign = parent_foreign };
                            }
                            descendants.items.len = found_pos - root_pos - 1;
                        }
                    }

                    i = end_pos + 1;
                    const closes_immediately = if (child_foreign) self_closing else tags.isVoidTagWithKey(child_name, child.key);
                    if (!closes_immediately) {
                        if (!child_foreign and tags.isPlainTextTagWithKey(child_name, child.key)) return .{ .pos = self.source.len };
                        if (!child_foreign and tags.isTextOnlyTagWithKey(child_name, child.key)) {
                            i = if (self.findRawTextClose(child_name, child.key, i)) |raw_close| raw_close.close_end else self.source.len;
                        } else {
                            try descendants.append(self.allocator, .{ .name = child_name, .key = child.key, .foreign = child_foreign });
                        }
                    }
                    continue;
                }
                i = lt + 1;
            }
            return .{ .pos = self.source.len };
        }

        fn skipOpenAt(
            self: *const Self,
            ancestor_count: usize,
            root: SkipOpenTag,
            descendants: []const SkipOpenTag,
            pos: usize,
        ) SkipOpenTag {
            if (pos < ancestor_count) {
                const open = self.stack.items[pos + 1];
                return .{
                    .name = open.name.slice(self.source),
                    .key = open.key,
                    .foreign = open.foreign,
                };
            }
            if (pos == ancestor_count) return root;
            return descendants[pos - ancestor_count - 1];
        }

        fn skipForeignContext(root: SkipOpenTag, descendants: []const SkipOpenTag) bool {
            const open = if (descendants.len != 0) descendants[descendants.len - 1] else root;
            if (!open.foreign) return false;
            return !(open.name.len == 13 and std.ascii.eqlIgnoreCase(open.name, "foreignObject"));
        }

        /// SVG `foreignObject` is both an HTML integration point and a regular
        /// HTML scope boundary. A block start inside it must not reach through
        /// the foreign subtree and implicitly close an HTML ancestor outside it.
        fn foreignRegularScopeBoundary(name: []const u8, foreign: bool) u8 {
            if (!foreign or name.len != 13 or !std.ascii.eqlIgnoreCase(name, "foreignObject")) return 0;
            return tags.ImplicitCloseBoundaryMask.regular;
        }

        fn openMatches(self: *Self, open: OpenTag, close: TagScan) bool {
            const open_name = open.name.slice(self.source);
            const close_name = self.source[close.start..close.end];
            return tags.equalByLenAndKeyIgnoreCase(open_name, open.key, close_name, close.key);
        }
    };
}

test "streaming no-event config short-circuits without allocating" {
    const Ctx = struct {
        calls: usize = 0,

        fn cb(self: *@This(), ev: Event) !bool {
            _ = ev;
            self.calls += 1;
            return true;
        }
    };

    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    for (0..64) |_| try source.writer.writeAll("<div>");

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var ctx: Ctx = .{};
    try (Parser{ .options = .{
        .emit_start_tags = false,
        .emit_text = false,
        .emit_end_tags = false,
        .include_comments = false,
        .include_doctype = false,
        .include_processing_instructions = false,
    } }).parse(failing.allocator(), source.written(), &ctx, Ctx.cb);
    try std.testing.expectEqual(@as(usize, 0), ctx.calls);
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

test "slash in unquoted foreign attribute value is not self-closing syntax" {
    const Ctx = struct {
        attr_ok: bool = false,
        text_depth: ?IndexInt = null,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .start_tag and std.mem.eql(u8, ev.nameSlice(), "g")) {
                var it = ev.attributes();
                const item = it.next() orelse return error.TestUnexpectedResult;
                try std.testing.expectEqualStrings("data", item.nameSlice());
                try std.testing.expectEqualStrings("x/", item.valueRaw().?);
                self.attr_ok = true;
            }
            if (ev.kind == .text and std.mem.eql(u8, ev.valueSlice(), "inside")) self.text_depth = ev.depth;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<svg><g data=x/>inside</g></svg>", &ctx, Ctx.cb);
    try std.testing.expect(ctx.attr_ok);
    try std.testing.expectEqual(@as(?IndexInt, 2), ctx.text_depth);
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

test "streaming SVG CDATA is opaque text" {
    const Ctx = struct {
        saw_cdata: bool = false,
        saw_fake_svg: bool = false,
        saw_tail: bool = false,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .text and std.mem.eql(u8, ev.valueSlice(), "x > <svg>")) self.saw_cdata = true;
            if (ev.kind == .start_tag and std.mem.eql(u8, ev.nameSlice(), "svg") and ev.depth != 0) self.saw_fake_svg = true;
            if (ev.kind == .start_tag and std.mem.eql(u8, ev.nameSlice(), "div")) self.saw_tail = true;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<svg><![CDATA[x > <svg>]]></svg><div></div>", &ctx, Ctx.cb);
    try std.testing.expect(ctx.saw_cdata);
    try std.testing.expect(!ctx.saw_fake_svg);
    try std.testing.expect(ctx.saw_tail);
}

test "skipping SVG treats CDATA as opaque" {
    const Ctx = struct {
        saw_tail: bool = false,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind != .start_tag) return true;
            if (std.mem.eql(u8, ev.nameSlice(), "svg")) return false;
            if (std.mem.eql(u8, ev.nameSlice(), "div")) self.saw_tail = true;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<svg><![CDATA[x > <svg>]]></svg><div></div>", &ctx, Ctx.cb);
    try std.testing.expect(ctx.saw_tail);
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

test "streaming malformed comment closes preserve payload and following tags" {
    const Ctx = struct {
        expected_comment: []const u8,
        saw_comment: bool = false,
        saw_div: bool = false,

        fn cb(self: *@This(), ev: Event) !bool {
            switch (ev.kind) {
                .comment => {
                    try std.testing.expectEqualStrings(self.expected_comment, ev.valueSlice());
                    self.saw_comment = true;
                },
                .start_tag => if (std.mem.eql(u8, ev.nameSlice(), "div")) {
                    self.saw_div = true;
                },
                else => {},
            }
            return true;
        }
    };

    const cases = [_]struct { source: []const u8, comment: []const u8 }{
        .{ .source = "<!--><div></div>", .comment = "" },
        .{ .source = "<!---><div></div>", .comment = "" },
        .{ .source = "<!--x--!><div></div>", .comment = "x" },
    };
    for (cases) |case| {
        var ctx = Ctx{ .expected_comment = case.comment };
        try (Parser{ .options = .{ .include_comments = true } }).parse(std.testing.allocator, case.source, &ctx, Ctx.cb);
        try std.testing.expect(ctx.saw_comment);
        try std.testing.expect(ctx.saw_div);
    }
}

test "streaming invalid start-tag opener reconsumes as text" {
    const Ctx = struct {
        text: std.ArrayList(u8) = .empty,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .text) try self.text.appendSlice(std.testing.allocator, ev.valueSlice());
            return true;
        }
    };

    var ctx: Ctx = .{};
    defer ctx.text.deinit(std.testing.allocator);
    try parse(std.testing.allocator, "< foo", &ctx, Ctx.cb);
    try std.testing.expectEqualStrings("< foo", ctx.text.items);
}

test "streaming attribute iterator preserves parse-error name bytes" {
    const Ctx = struct {
        checked: bool = false,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind != .start_tag) return true;
            var it = ev.attributes();
            const quoted = it.next() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("a\"b", quoted.nameSlice());
            try std.testing.expectEqualStrings("x", quoted.valueRaw().?);
            const leading_equal = it.next() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("=lead", leading_equal.nameSlice());
            try std.testing.expectEqualStrings("y", leading_equal.valueRaw().?);
            try std.testing.expect(it.next() == null);
            self.checked = true;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<div a\"b=x =lead=y>", &ctx, Ctx.cb);
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

test "streaming unterminated start tag is discarded at EOF" {
    const Ctx = struct {
        events: usize = 0,

        fn cb(self: *@This(), ev: Event) !bool {
            _ = ev;
            self.events += 1;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<div id=x", &ctx, Ctx.cb);
    try std.testing.expectEqual(@as(usize, 0), ctx.events);
}

test "streaming processing instruction ends at first greater-than" {
    const Ctx = struct {
        pi_ok: bool = false,
        saw_div: bool = false,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .processing_instruction) {
                try std.testing.expectEqualStrings("<?x >", ev.token.slice(ev.source));
                try std.testing.expectEqualStrings("x ", ev.valueSlice());
                self.pi_ok = true;
            }
            if (ev.kind == .start_tag and std.mem.eql(u8, ev.nameSlice(), "div")) self.saw_div = true;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try (Parser{ .options = .{ .include_processing_instructions = true } }).parse(
        std.testing.allocator,
        "<?x > trailing ?><div></div>",
        &ctx,
        Ctx.cb,
    );
    try std.testing.expect(ctx.pi_ok);
    try std.testing.expect(ctx.saw_div);
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

test "streaming text-only and plaintext content has child depth" {
    const Ctx = struct {
        script_depth: ?IndexInt = null,
        title_depth: ?IndexInt = null,
        plaintext_depth: ?IndexInt = null,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind != .text) return true;
            if (std.mem.eql(u8, ev.valueSlice(), "script-text")) self.script_depth = ev.depth;
            if (std.mem.eql(u8, ev.valueSlice(), "title-text")) self.title_depth = ev.depth;
            if (std.mem.eql(u8, ev.valueSlice(), "plain-text")) self.plaintext_depth = ev.depth;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(
        std.testing.allocator,
        "<main><script>script-text</script><title>title-text</title></main><plaintext>plain-text",
        &ctx,
        Ctx.cb,
    );
    try std.testing.expectEqual(@as(?IndexInt, 2), ctx.script_depth);
    try std.testing.expectEqual(@as(?IndexInt, 2), ctx.title_depth);
    try std.testing.expectEqual(@as(?IndexInt, 1), ctx.plaintext_depth);
}

test "streaming unterminated text-only elements emit configurable implicit EOF ends" {
    const Ctx = struct {
        implicit_script_ends: usize = 0,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .end_tag and ev.implicit and std.mem.eql(u8, ev.nameSlice(), "script")) {
                self.implicit_script_ends += 1;
            }
            return true;
        }
    };

    var enabled: Ctx = .{};
    try parse(std.testing.allocator, "<script>x", &enabled, Ctx.cb);
    try std.testing.expectEqual(@as(usize, 1), enabled.implicit_script_ends);

    var disabled: Ctx = .{};
    try (Parser{ .options = .{ .emit_implicit_end_tags = false } }).parse(
        std.testing.allocator,
        "<script>x",
        &disabled,
        Ctx.cb,
    );
    try std.testing.expectEqual(@as(usize, 0), disabled.implicit_script_ends);
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

test "streaming leaf subtree skip does not allocate when nesting is disabled" {
    const Ctx = struct {
        fn cb(_: *@This(), ev: Event) !bool {
            return ev.kind != .start_tag;
        }
    };

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var ctx: Ctx = .{};
    try (Parser{ .options = .{ .track_nesting = false } }).parse(
        failing.allocator(),
        "<section>skip</section>",
        &ctx,
        Ctx.cb,
    );
}

test "streaming subtree skip ends at an implicit optional close" {
    const Ctx = struct {
        saw_div: bool = false,
        saw_keep: bool = false,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .start_tag and std.mem.eql(u8, ev.nameSlice(), "p")) return false;
            if (ev.kind == .start_tag and std.mem.eql(u8, ev.nameSlice(), "div")) self.saw_div = true;
            if (ev.kind == .text and std.mem.eql(u8, ev.valueSlice(), "keep")) self.saw_keep = true;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<main><p>skip<span>x</span><div>keep</div></main>", &ctx, Ctx.cb);
    try std.testing.expect(ctx.saw_div);
    try std.testing.expect(ctx.saw_keep);
}

test "streaming subtree skip ends when an ancestor is implicitly or explicitly closed" {
    const Ctx = struct {
        span_starts: usize = 0,
        div_starts: usize = 0,
        section_ends: usize = 0,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .start_tag and std.mem.eql(u8, ev.nameSlice(), "span")) {
                self.span_starts += 1;
                return false;
            }
            if (ev.kind == .start_tag and std.mem.eql(u8, ev.nameSlice(), "div")) self.div_starts += 1;
            if (ev.kind == .end_tag and !ev.implicit and std.mem.eql(u8, ev.nameSlice(), "section")) self.section_ends += 1;
            return true;
        }
    };

    var implicit_ctx: Ctx = .{};
    try parse(std.testing.allocator, "<p><span>skip<div>keep</div>", &implicit_ctx, Ctx.cb);
    try std.testing.expectEqual(@as(usize, 1), implicit_ctx.span_starts);
    try std.testing.expectEqual(@as(usize, 1), implicit_ctx.div_starts);

    var explicit_ctx: Ctx = .{};
    try parse(std.testing.allocator, "<section><span>skip</section><div>keep</div>", &explicit_ctx, Ctx.cb);
    try std.testing.expectEqual(@as(usize, 1), explicit_ctx.span_starts);
    try std.testing.expectEqual(@as(usize, 1), explicit_ctx.section_ends);
    try std.testing.expectEqual(@as(usize, 1), explicit_ctx.div_starts);
}

test "streaming subtree skip preserves integration-point context for resume tag" {
    const Ctx = struct {
        skip_option: bool,
        option_starts: usize = 0,
        hr_depth: ?IndexInt = null,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind != .start_tag) return true;
            if (std.mem.eql(u8, ev.nameSlice(), "option")) {
                self.option_starts += 1;
                if (self.skip_option) return false;
            }
            if (std.mem.eql(u8, ev.nameSlice(), "hr")) self.hr_depth = ev.depth;
            return true;
        }
    };

    const source = "<optgroup><svg><option><foreignObject><section><hr>";
    var full: Ctx = .{ .skip_option = false };
    try parse(std.testing.allocator, source, &full, Ctx.cb);
    var skipped: Ctx = .{ .skip_option = true };
    try parse(std.testing.allocator, source, &skipped, Ctx.cb);

    try std.testing.expectEqual(@as(?IndexInt, 0), full.hr_depth);
    try std.testing.expectEqual(full.hr_depth, skipped.hr_depth);
}

test "streaming subtree skip does not treat foreign optional-close names as sources" {
    const Ctx = struct {
        skip_option: bool,
        hr_starts: usize = 0,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind != .start_tag) return true;
            if (self.skip_option and std.mem.eql(u8, ev.nameSlice(), "option")) return false;
            if (std.mem.eql(u8, ev.nameSlice(), "hr")) self.hr_starts += 1;
            return true;
        }
    };

    // The option is an SVG foreign element, so the HTML <hr> inside the
    // integration-point section must not implicitly close it. A skipped option
    // therefore suppresses that hr event as part of its subtree.
    const source = "<svg><option><foreignObject><section><hr></section></foreignObject></option></svg>";
    var full: Ctx = .{ .skip_option = false };
    try parse(std.testing.allocator, source, &full, Ctx.cb);
    var skipped: Ctx = .{ .skip_option = true };
    try parse(std.testing.allocator, source, &skipped, Ctx.cb);

    try std.testing.expectEqual(@as(usize, 1), full.hr_starts);
    try std.testing.expectEqual(@as(usize, 0), skipped.hr_starts);
}

test "streaming subtree skip respects nested list scope" {
    const Ctx = struct {
        li_starts: usize = 0,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind != .start_tag or !std.mem.eql(u8, ev.nameSlice(), "li")) return true;
            self.li_starts += 1;
            return self.li_starts != 1;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<ul><li><ul><li>inner</li></ul>tail<li>next</ul>", &ctx, Ctx.cb);
    // Outer LI and its next sibling are visible; the nested LI stays skipped.
    try std.testing.expectEqual(@as(usize, 2), ctx.li_starts);
}

test "streaming skipped subtree respects malformed comment close" {
    const Ctx = struct {
        saw_after: bool = false,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind != .start_tag) return true;
            if (std.mem.eql(u8, ev.nameSlice(), "skip")) return false;
            if (std.mem.eql(u8, ev.nameSlice(), "after")) self.saw_after = true;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<skip><!--x--!><i></i></skip><after></after>", &ctx, Ctx.cb);
    try std.testing.expect(ctx.saw_after);
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
                try std.testing.expectEqual(@as(IndexInt, 0), ev.depth);
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

test "streaming implicit end option suppresses mismatched-pop and optional-close events" {
    const Ctx = struct {
        implicit_count: usize = 0,
        explicit_a: usize = 0,
        div_depth: ?IndexInt = null,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .end_tag) {
                if (ev.implicit) self.implicit_count += 1;
                if (!ev.implicit and std.mem.eql(u8, ev.nameSlice(), "a")) self.explicit_a += 1;
            }
            if (ev.kind == .start_tag and std.mem.eql(u8, ev.nameSlice(), "div")) self.div_depth = ev.depth;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try (Parser{ .options = .{ .emit_implicit_end_tags = false } }).parse(
        std.testing.allocator,
        "<a><b></a><p><span>x<div></div>",
        &ctx,
        Ctx.cb,
    );
    try std.testing.expectEqual(@as(usize, 0), ctx.implicit_count);
    try std.testing.expectEqual(@as(usize, 1), ctx.explicit_a);
    try std.testing.expectEqual(@as(?IndexInt, 0), ctx.div_depth);
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

test "unterminated end tag is discarded instead of emitted" {
    const Ctx = struct {
        ends: usize = 0,
        implicit_ends: usize = 0,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .end_tag) {
                self.ends += 1;
                if (ev.implicit) self.implicit_ends += 1;
            }
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<div>x</div", &ctx, Ctx.cb);
    // The unfinished </div token is discarded; only EOF closes the open div.
    try std.testing.expectEqual(@as(usize, 1), ctx.ends);
    try std.testing.expectEqual(@as(usize, 1), ctx.implicit_ends);
}

test "plaintext start tag implicitly closes paragraph before text" {
    const Ctx = struct {
        text_depth: ?IndexInt = null,
        p_closed: bool = false,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .end_tag and ev.implicit and std.ascii.eqlIgnoreCase(ev.nameSlice(), "p")) self.p_closed = true;
            if (ev.kind == .text and std.mem.eql(u8, ev.valueSlice(), "after")) self.text_depth = ev.depth;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(std.testing.allocator, "<p>before<plaintext>after", &ctx, Ctx.cb);
    try std.testing.expect(ctx.p_closed);
    // <p> has closed, so plaintext is at depth 0 and its text is at depth 1.
    try std.testing.expectEqual(@as(?IndexInt, 1), ctx.text_depth);
}

test "streaming SVG integration point is an HTML scope boundary" {
    const Ctx = struct {
        div_depth: ?IndexInt = null,
        implicit_p_before_div: bool = false,
        saw_div: bool = false,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .end_tag and ev.implicit and std.ascii.eqlIgnoreCase(ev.nameSlice(), "p") and !self.saw_div) {
                self.implicit_p_before_div = true;
            }
            if (ev.kind == .start_tag and std.ascii.eqlIgnoreCase(ev.nameSlice(), "div")) {
                self.saw_div = true;
                self.div_depth = ev.depth;
            }
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(
        std.testing.allocator,
        "<p><svg><foreignObject><div>x</div></foreignObject></svg></p>",
        &ctx,
        Ctx.cb,
    );
    try std.testing.expect(!ctx.implicit_p_before_div);
    try std.testing.expectEqual(@as(?IndexInt, 3), ctx.div_depth);
}

test "streaming subtree skip respects SVG integration-point scope boundary" {
    const Ctx = struct {
        saw_div: bool = false,
        saw_tail: bool = false,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind == .start_tag and std.ascii.eqlIgnoreCase(ev.nameSlice(), "section")) return false;
            if (ev.kind == .start_tag and std.ascii.eqlIgnoreCase(ev.nameSlice(), "div")) self.saw_div = true;
            if (ev.kind == .start_tag and std.ascii.eqlIgnoreCase(ev.nameSlice(), "hr")) self.saw_tail = true;
            return true;
        }
    };

    var ctx: Ctx = .{};
    try parse(
        std.testing.allocator,
        "<p><svg><foreignObject><section><div>skip</div></section></foreignObject></svg></p><hr>",
        &ctx,
        Ctx.cb,
    );
    try std.testing.expect(!ctx.saw_div);
    try std.testing.expect(ctx.saw_tail);
}

test "streaming foreign tag names do not create HTML optional-close scope boundaries" {
    const Ctx = struct {
        tr_count: usize = 0,
        second_tr_depth: ?IndexInt = null,
        option_count: usize = 0,
        second_option_depth: ?IndexInt = null,

        fn cb(self: *@This(), ev: Event) !bool {
            if (ev.kind != .start_tag) return true;
            if (std.ascii.eqlIgnoreCase(ev.nameSlice(), "tr")) {
                self.tr_count += 1;
                if (self.tr_count == 2) self.second_tr_depth = ev.depth;
            }
            if (std.ascii.eqlIgnoreCase(ev.nameSlice(), "option")) {
                self.option_count += 1;
                if (self.option_count == 2) self.second_option_depth = ev.depth;
            }
            return true;
        }
    };

    var table_ctx: Ctx = .{};
    try parse(
        std.testing.allocator,
        "<tr><svg><table><foreignObject><tr></tr></foreignObject></table></svg></tr>",
        &table_ctx,
        Ctx.cb,
    );
    try std.testing.expectEqual(@as(?IndexInt, 0), table_ctx.second_tr_depth);

    var select_ctx: Ctx = .{};
    try parse(
        std.testing.allocator,
        "<option><svg><select><foreignObject><option></option></foreignObject></select></svg></option>",
        &select_ctx,
        Ctx.cb,
    );
    try std.testing.expectEqual(@as(?IndexInt, 0), select_ctx.second_option_depth);
}
