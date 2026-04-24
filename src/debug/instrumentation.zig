const std = @import("std");
const ast = @import("../selector/ast.zig");
/// Query operation kind passed to instrumentation hooks.
pub const QueryInstrumentationKind = enum(u8) {
    one_runtime,
    one_cached,
    all_runtime,
    all_cached,

    /// Formats this query kind for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(@tagName(self));
    }
};

/// Timing/count payload emitted after `parseWithHooks`.
pub const ParseInstrumentationStats = struct {
    /// End-to-end parse duration in nanoseconds.
    elapsed_ns: u64,
    /// Input byte length passed to `parseWithHooks`.
    input_len: usize,
    /// Total node count produced by the parse.
    node_count: usize,

    /// Formats parse timing statistics for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("ParseInstrumentationStats{{elapsed_ns={}, input_len={}, node_count={}}}", .{
            self.elapsed_ns,
            self.input_len,
            self.node_count,
        });
    }
};

/// Timing payload emitted after query hook wrappers.
pub const QueryInstrumentationStats = struct {
    /// End-to-end query duration in nanoseconds.
    elapsed_ns: u64,
    /// Selector source length in bytes.
    selector_len: usize,
    /// Query operation kind that was measured.
    kind: QueryInstrumentationKind,
    /// Match result when the wrapper returns an immediate optional result.
    matched: ?bool = null,

    /// Formats query timing statistics for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("QueryInstrumentationStats{{elapsed_ns={}, selector_len={}, kind={s}, matched={?}}}", .{
            self.elapsed_ns,
            self.selector_len,
            @tagName(self.kind),
            self.matched,
        });
    }
};

fn elapsedNs(start: std.Io.Timestamp, finish: std.Io.Timestamp) u64 {
    const diff = start.durationTo(finish).toNanoseconds();
    if (diff <= 0) return 0;
    return @intCast(diff);
}

fn HookDeclType(comptime H: type) type {
    return switch (@typeInfo(H)) {
        .pointer => |p| p.child,
        else => H,
    };
}

fn matchedFromValue(value: anytype) ?bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => value != null,
        else => true,
    };
}

/// Parses `input` and invokes optional parse hooks when provided.
pub fn parseWithHooks(io: std.Io, doc: anytype, input: anytype, hooks: anytype) !void {
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onParseStart")) {
        hooks.onParseStart(input.len);
    }

    const start = std.Io.Timestamp.now(io, .awake);
    try doc.parse(input);
    const stats: ParseInstrumentationStats = .{
        .elapsed_ns = elapsedNs(start, std.Io.Timestamp.now(io, .awake)),
        .input_len = input.len,
        .node_count = doc.nodes.len,
    };

    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onParseEnd")) {
        hooks.onParseEnd(stats);
    }
}

/// Executes `queryOneRuntime` and emits query timing hooks.
pub fn queryOneRuntimeWithHooks(
    io: std.Io,
    doc: anytype,
    allocator: std.mem.Allocator,
    selector: []const u8,
    hooks: anytype,
) @TypeOf(doc.queryOneRuntime(allocator, selector)) {
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryStart")) {
        hooks.onQueryStart(.one_runtime, selector.len);
    }

    const start = std.Io.Timestamp.now(io, .awake);
    const out = doc.queryOneRuntime(allocator, selector);
    if (out) |value| {
        if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryEnd")) {
            hooks.onQueryEnd(QueryInstrumentationStats{
                .elapsed_ns = elapsedNs(start, std.Io.Timestamp.now(io, .awake)),
                .selector_len = selector.len,
                .kind = .one_runtime,
                .matched = matchedFromValue(value),
            });
        }
        return value;
    } else |err| {
        if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryEnd")) {
            hooks.onQueryEnd(QueryInstrumentationStats{
                .elapsed_ns = elapsedNs(start, std.Io.Timestamp.now(io, .awake)),
                .selector_len = selector.len,
                .kind = .one_runtime,
                .matched = null,
            });
        }
        return err;
    }
}

/// Executes `queryOneCached` and emits query timing hooks.
pub fn queryOneCachedWithHooks(io: std.Io, doc: anytype, sel: ast.Selector, hooks: anytype) @TypeOf(doc.queryOneCached(sel)) {
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryStart")) {
        hooks.onQueryStart(.one_cached, sel.source.len);
    }

    const start = std.Io.Timestamp.now(io, .awake);
    const value = doc.queryOneCached(sel);
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryEnd")) {
        hooks.onQueryEnd(QueryInstrumentationStats{
            .elapsed_ns = elapsedNs(start, std.Io.Timestamp.now(io, .awake)),
            .selector_len = sel.source.len,
            .kind = .one_cached,
            .matched = matchedFromValue(value),
        });
    }
    return value;
}

/// Executes `queryAllRuntime` and emits query timing hooks.
pub fn queryAllRuntimeWithHooks(
    io: std.Io,
    doc: anytype,
    allocator: std.mem.Allocator,
    selector: []const u8,
    hooks: anytype,
) @TypeOf(doc.queryAllRuntime(allocator, selector)) {
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryStart")) {
        hooks.onQueryStart(.all_runtime, selector.len);
    }

    const start = std.Io.Timestamp.now(io, .awake);
    const out = doc.queryAllRuntime(allocator, selector);
    if (out) |iter| {
        if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryEnd")) {
            hooks.onQueryEnd(QueryInstrumentationStats{
                .elapsed_ns = elapsedNs(start, std.Io.Timestamp.now(io, .awake)),
                .selector_len = selector.len,
                .kind = .all_runtime,
                .matched = null,
            });
        }
        return iter;
    } else |err| {
        if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryEnd")) {
            hooks.onQueryEnd(QueryInstrumentationStats{
                .elapsed_ns = elapsedNs(start, std.Io.Timestamp.now(io, .awake)),
                .selector_len = selector.len,
                .kind = .all_runtime,
                .matched = null,
            });
        }
        return err;
    }
}

/// Executes `queryAllCached` and emits query timing hooks.
pub fn queryAllCachedWithHooks(io: std.Io, doc: anytype, sel: ast.Selector, hooks: anytype) @TypeOf(doc.queryAllCached(sel)) {
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryStart")) {
        hooks.onQueryStart(.all_cached, sel.source.len);
    }

    const start = std.Io.Timestamp.now(io, .awake);
    const iter = doc.queryAllCached(sel);
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryEnd")) {
        hooks.onQueryEnd(QueryInstrumentationStats{
            .elapsed_ns = elapsedNs(start, std.Io.Timestamp.now(io, .awake)),
            .selector_len = sel.source.len,
            .kind = .all_cached,
            .matched = null,
        });
    }
    return iter;
}

test "format instrumentation stats" {
    const alloc = std.testing.allocator;

    const kind_out = try std.fmt.allocPrint(alloc, "{f}", .{QueryInstrumentationKind.one_runtime});
    defer alloc.free(kind_out);
    try std.testing.expectEqualStrings("one_runtime", kind_out);

    const parse_stats: ParseInstrumentationStats = .{
        .elapsed_ns = 120,
        .input_len = 33,
        .node_count = 9,
    };
    const parse_out = try std.fmt.allocPrint(alloc, "{f}", .{parse_stats});
    defer alloc.free(parse_out);
    try std.testing.expectEqualStrings(
        "ParseInstrumentationStats{elapsed_ns=120, input_len=33, node_count=9}",
        parse_out,
    );

    const query_stats: QueryInstrumentationStats = .{
        .elapsed_ns = 456,
        .selector_len = 7,
        .kind = .all_cached,
        .matched = true,
    };
    const query_out = try std.fmt.allocPrint(alloc, "{f}", .{query_stats});
    defer alloc.free(query_out);
    try std.testing.expectEqualStrings(
        "QueryInstrumentationStats{elapsed_ns=456, selector_len=7, kind=all_cached, matched=true}",
        query_out,
    );
}
