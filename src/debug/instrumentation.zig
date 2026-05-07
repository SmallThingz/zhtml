const std = @import("std");
const ast = @import("../selector/ast.zig");
/// Query operation kind passed to instrumentation hooks.
pub const QueryInstrumentationKind = enum(u8) {
    query,
    query_runtime,

    /// Formats this query kind for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(@tagName(self));
    }
};

/// Timing/count payload emitted after parse instrumentation.
pub const ParseInstrumentationStats = struct {
    /// End-to-end parse duration in nanoseconds.
    elapsed_ns: u64,
    /// Input byte length passed to the instrumented parse.
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

/// Parses `input` through `options.parse` and invokes optional parse hooks when provided.
pub fn parseWithHooks(io: std.Io, comptime options: anytype, allocator: std.mem.Allocator, input: anytype, hooks: anytype) @TypeOf(options.parse(allocator, input)) {
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onParseStart")) {
        hooks.onParseStart(input.len);
    }

    const start = std.Io.Timestamp.now(io, .awake);
    const doc = try options.parse(allocator, input);
    const stats: ParseInstrumentationStats = .{
        .elapsed_ns = elapsedNs(start, std.Io.Timestamp.now(io, .awake)),
        .input_len = input.len,
        .node_count = doc.nodes.len,
    };

    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onParseEnd")) {
        hooks.onParseEnd(stats);
    }
    return doc;
}

/// Executes comptime `query` and emits query timing hooks.
pub fn queryWithHooks(io: std.Io, doc: anytype, comptime selector: []const u8, hooks: anytype) @TypeOf(doc.query(selector)) {
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryStart")) {
        hooks.onQueryStart(.query, selector.len);
    }

    const start = std.Io.Timestamp.now(io, .awake);
    const iter = doc.query(selector);
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryEnd")) {
        hooks.onQueryEnd(QueryInstrumentationStats{
            .elapsed_ns = elapsedNs(start, std.Io.Timestamp.now(io, .awake)),
            .selector_len = selector.len,
            .kind = .query,
            .matched = null,
        });
    }
    return iter;
}

/// Executes `queryRuntime` and emits query timing hooks.
pub fn queryRuntimeWithHooks(io: std.Io, doc: anytype, sel: ast.Selector, hooks: anytype) @TypeOf(doc.queryRuntime(sel)) {
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryStart")) {
        hooks.onQueryStart(.query_runtime, sel.source.len);
    }

    const start = std.Io.Timestamp.now(io, .awake);
    const iter = doc.queryRuntime(sel);
    if (comptime @hasDecl(HookDeclType(@TypeOf(hooks)), "onQueryEnd")) {
        hooks.onQueryEnd(QueryInstrumentationStats{
            .elapsed_ns = elapsedNs(start, std.Io.Timestamp.now(io, .awake)),
            .selector_len = sel.source.len,
            .kind = .query_runtime,
            .matched = null,
        });
    }
    return iter;
}

test "format instrumentation stats" {
    const alloc = std.testing.allocator;

    const kind_out = try std.fmt.allocPrint(alloc, "{f}", .{QueryInstrumentationKind.query_runtime});
    defer alloc.free(kind_out);
    try std.testing.expectEqualStrings("query_runtime", kind_out);

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
        .kind = .query_runtime,
        .matched = true,
    };
    const query_out = try std.fmt.allocPrint(alloc, "{f}", .{query_stats});
    defer alloc.free(query_out);
    try std.testing.expectEqualStrings(
        "QueryInstrumentationStats{elapsed_ns=456, selector_len=7, kind=query_runtime, matched=true}",
        query_out,
    );
}
