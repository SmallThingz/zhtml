const std = @import("std");
const config = @import("config");

pub const IndexInt = switch (config.intlen) {
    .u16 => u16,
    .u32 => u32,
    .u64 => u64,
    .usize => usize,
};

/// Maximum input length representable by the configured index width.
pub const MaxLen: usize = if (@sizeOf(IndexInt) >= @sizeOf(usize))
    std.math.maxInt(usize)
else
    @as(usize, std.math.maxInt(IndexInt));

pub inline fn lenFits(len: usize) bool {
    return len <= MaxLen;
}

/// Sentinel for invalid node indexes in DOM/query paths.
pub const InvalidIndex: IndexInt = std.math.maxInt(IndexInt);
/// Sentinel for unset small integer fields in debug reports.
pub const InvalidSmall: u16 = std.math.maxInt(u16);

/// Maximum near-miss records captured per debug query run.
pub const MaxNearMisses: usize = 8;
/// Maximum selector groups tracked in debug counters.
pub const MaxSelectorGroups: usize = 8;

/// Classification of first-failure reason while matching a selector.
pub const DebugFailureKind = enum(u8) {
    none,
    parse,
    tag,
    id,
    class,
    attr,
    pseudo,
    not_simple,
    combinator,
    scope,

    /// Formats this failure kind for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(@tagName(self));
    }
};

/// First failing predicate metadata for a candidate node.
pub const Failure = struct {
    /// Category of the first failing selector predicate.
    kind: DebugFailureKind = .none,
    /// Comma-group index containing the first failure.
    group_index: u16 = InvalidSmall,
    /// Compound index inside the group containing the first failure.
    compound_index: u16 = InvalidSmall,
    /// Predicate index inside the compound causing the first failure.
    predicate_index: u16 = InvalidSmall,

    /// Returns true when this failure slot is unset.
    pub fn isNone(self: @This()) bool {
        return self.kind == .none;
    }

    /// Formats this failure record for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Failure{{kind={s}, group_index={}, compound_index={}, predicate_index={}}}", .{
            @tagName(self.kind),
            self.group_index,
            self.compound_index,
            self.predicate_index,
        });
    }
};

/// Single non-matching node with its first failure reason.
pub const NearMiss = struct {
    /// Candidate node that almost matched.
    node_index: IndexInt = InvalidIndex,
    /// Metadata describing the first predicate that rejected this node.
    reason: Failure = .{},

    /// Formats this near-miss record for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("NearMiss{{node_index={}, reason=", .{self.node_index});
        try self.reason.format(writer);
        try writer.writeAll("}");
    }
};

/// Fixed-capacity diagnostic report filled by debug query APIs.
pub const QueryDebugReport = struct {
    /// Original selector source string used for this query run.
    selector_source: []const u8 = "",
    /// Root index used for scoped matching, or `InvalidIndex` for whole-document queries.
    scope_root: IndexInt = InvalidIndex,
    /// Number of element candidates visited during matching.
    visited_elements: IndexInt = 0,
    /// First matching node index, or `InvalidIndex` when nothing matched.
    matched_index: IndexInt = InvalidIndex,
    /// Group index that matched, when a match was found.
    matched_group: u16 = InvalidSmall,
    /// True when runtime selector parsing failed before matching started.
    runtime_parse_error: bool = false,

    /// Number of comma-separated selector groups compiled from the query.
    group_count: u8 = 0,
    /// Candidate counts evaluated for each selector group.
    group_eval_counts: [MaxSelectorGroups]IndexInt = [_]IndexInt{0} ** MaxSelectorGroups,
    /// Match counts produced by each selector group.
    group_match_counts: [MaxSelectorGroups]IndexInt = [_]IndexInt{0} ** MaxSelectorGroups,

    /// Number of populated entries in `near_misses`.
    near_miss_len: u8 = 0,
    /// Sampled near-miss candidates retained for diagnostics.
    near_misses: [MaxNearMisses]NearMiss = [_]NearMiss{.{}} ** MaxNearMisses,

    /// Resets report state before a debug query run.
    pub fn reset(self: *@This(), selector_source: []const u8, scope_root: IndexInt, group_count: usize) void {
        self.* = .{
            .selector_source = selector_source,
            .scope_root = scope_root,
            .group_count = @intCast(@min(group_count, MaxSelectorGroups)),
        };
    }

    /// Marks runtime selector parse failure in this report.
    pub fn setRuntimeParseError(self: *@This()) void {
        self.runtime_parse_error = true;
    }

    /// Adds one near-miss entry if report capacity allows.
    pub fn pushNearMiss(self: *@This(), node_index: IndexInt, reason: Failure) void {
        if (self.near_miss_len >= MaxNearMisses) return;
        const idx: usize = @intCast(self.near_miss_len);
        self.near_misses[idx] = .{
            .node_index = node_index,
            .reason = reason,
        };
        self.near_miss_len += 1;
    }

    /// Formats summary debug report data for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            "QueryDebugReport{{selector_source=\"{s}\", scope_root={}, visited_elements={}, matched_index={}, matched_group={}, runtime_parse_error={}, group_count={}, near_miss_len={}}}",
            .{
                self.selector_source,
                self.scope_root,
                self.visited_elements,
                self.matched_index,
                self.matched_group,
                self.runtime_parse_error,
                self.group_count,
                self.near_miss_len,
            },
        );
    }
};

/// Parent element index for `node_index`, excluding root-document index 0.
pub fn parentElement(doc: anytype, node_index: IndexInt) ?IndexInt {
    const p = doc.parentIndex(node_index);
    if (p == InvalidIndex or p == 0) return null;
    return p;
}

/// Previous element sibling index for `node_index`.
pub fn prevElementSibling(doc: anytype, node_index: IndexInt) ?IndexInt {
    var prev = doc.nodes[node_index].prev_sibling;
    while (prev != InvalidIndex) : (prev = doc.nodes[prev].prev_sibling) {
        if (doc.isElementIndex(prev)) return prev;
    }
    return null;
}

/// Next element sibling index for `node_index`.
pub fn nextElementSibling(doc: anytype, node_index: IndexInt) ?IndexInt {
    const next = doc.nextElementSiblingIndex(node_index);
    if (next == InvalidIndex) return null;
    return next;
}

/// Scope-anchor predicate shared by selector matcher and debug matcher.
pub fn matchesScopeAnchor(doc: anytype, combinator: anytype, node_index: IndexInt, scope_root: IndexInt) bool {
    if (combinator == .none) return true;

    const anchor: IndexInt = if (scope_root == InvalidIndex) 0 else scope_root;
    switch (combinator) {
        .child => {
            const p = doc.parentIndex(node_index);
            return p != InvalidIndex and p == anchor;
        },
        .descendant => {
            var p = doc.parentIndex(node_index);
            while (p != InvalidIndex) {
                if (p == anchor) return true;
                if (p == 0) break;
                p = doc.parentIndex(p);
            }
            return false;
        },
        .adjacent => {
            return prevElementSibling(doc, node_index) == anchor;
        },
        .sibling => {
            var prev = prevElementSibling(doc, node_index);
            while (prev) |idx| {
                if (idx == anchor) return true;
                prev = prevElementSibling(doc, idx);
            }
            return false;
        },
        .none => return true,
    }
}

test "format debug report types" {
    const alloc = std.testing.allocator;

    const kind_out = try std.fmt.allocPrint(alloc, "{f}", .{DebugFailureKind.attr});
    defer alloc.free(kind_out);
    try std.testing.expectEqualStrings("attr", kind_out);

    const failure: Failure = .{
        .kind = .class,
        .group_index = 1,
        .compound_index = 2,
        .predicate_index = 3,
    };
    const failure_out = try std.fmt.allocPrint(alloc, "{f}", .{failure});
    defer alloc.free(failure_out);
    try std.testing.expectEqualStrings(
        "Failure{kind=class, group_index=1, compound_index=2, predicate_index=3}",
        failure_out,
    );

    const near: NearMiss = .{
        .node_index = 42,
        .reason = failure,
    };
    const near_out = try std.fmt.allocPrint(alloc, "{f}", .{near});
    defer alloc.free(near_out);
    try std.testing.expectEqualStrings(
        "NearMiss{node_index=42, reason=Failure{kind=class, group_index=1, compound_index=2, predicate_index=3}}",
        near_out,
    );

    var report: QueryDebugReport = .{};
    report.selector_source = "div";
    report.scope_root = 7;
    report.visited_elements = 3;
    report.matched_index = 9;
    report.matched_group = 1;
    report.runtime_parse_error = true;
    report.group_count = 2;
    report.near_miss_len = 1;

    const report_out = try std.fmt.allocPrint(alloc, "{f}", .{report});
    defer alloc.free(report_out);
    try std.testing.expectEqualStrings(
        "QueryDebugReport{selector_source=\"div\", scope_root=7, visited_elements=3, matched_index=9, matched_group=1, runtime_parse_error=true, group_count=2, near_miss_len=1}",
        report_out,
    );
}
