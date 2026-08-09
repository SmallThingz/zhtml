const std = @import("std");
const declaration_testing = @import("../testing.zig");
const ast = @import("ast.zig");
const common = @import("../common.zig");

test {
    declaration_testing.refAllDeclsRecursive(@This());
}

const IndexInt = common.IndexInt;
const NoPredicate = std.math.maxInt(IndexInt);

pub const WordUse = struct {
    word_index: IndexInt,
    mask: u64,
};

pub const UseRange = struct {
    start: usize,
    len: usize,
};

/// Interns semantically identical local compounds and records only selector
/// words that actually contain a use of each predicate. Combinators are not
/// part of local predicate identity; they are structural transition state.
pub const Plan = struct {
    /// Absolute AST compound index -> PredicateId.
    state_ids: []IndexInt = &.{},
    /// PredicateId -> representative absolute AST compound index.
    representatives: []IndexInt = &.{},
    /// PredicateId -> range inside `uses`.
    use_ranges: []UseRange = &.{},
    /// Sparse selector-word masks. Total entries are <= compound count.
    uses: []WordUse = &.{},
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, selector: ast.Selector) !@This() {
        var self: @This() = .{};
        errdefer self.deinit(allocator);

        const compound_count = selector.compounds.len;
        if (compound_count == 0) return self;
        if (compound_count > std.math.maxInt(IndexInt)) return error.OutOfMemory;

        self.state_ids = try allocator.alloc(IndexInt, compound_count);
        self.representatives = try allocator.alloc(IndexInt, compound_count);

        var hash_heads: std.AutoHashMapUnmanaged(u64, IndexInt) = .empty;
        defer hash_heads.deinit(allocator);
        const next_same_hash = try allocator.alloc(IndexInt, compound_count);
        defer allocator.free(next_same_hash);
        @memset(next_same_hash, NoPredicate);

        for (selector.compounds, 0..) |comp, absolute| {
            const hash = compoundHash(selector, comp);
            const old_head = hash_heads.get(hash) orelse NoPredicate;
            var predicate_id = old_head;
            while (predicate_id != NoPredicate) {
                const representative: usize = @intCast(self.representatives[predicate_id]);
                if (compoundsEquivalent(selector, selector.compounds[representative], comp)) break;
                predicate_id = next_same_hash[predicate_id];
            }

            if (predicate_id == NoPredicate) {
                predicate_id = @intCast(self.count);
                self.representatives[self.count] = @intCast(absolute);
                next_same_hash[self.count] = old_head;
                try hash_heads.put(allocator, hash, predicate_id);
                self.count += 1;
            }
            self.state_ids[absolute] = predicate_id;
        }

        self.use_ranges = try allocator.alloc(UseRange, self.count);
        @memset(self.use_ranges, .{ .start = 0, .len = 0 });
        if (self.count == 0) return self;

        const use_counts = try allocator.alloc(usize, self.count);
        defer allocator.free(use_counts);
        @memset(use_counts, 0);
        const last_word = try allocator.alloc(usize, self.count);
        defer allocator.free(last_word);
        @memset(last_word, std.math.maxInt(usize));

        for (self.state_ids, 0..) |predicate_id_raw, absolute| {
            const predicate_id: usize = @intCast(predicate_id_raw);
            const word = absolute / 64;
            if (last_word[predicate_id] != word) {
                last_word[predicate_id] = word;
                use_counts[predicate_id] += 1;
            }
        }

        var total_uses: usize = 0;
        for (use_counts, 0..) |count, predicate_id| {
            self.use_ranges[predicate_id] = .{ .start = total_uses, .len = count };
            total_uses = std.math.add(usize, total_uses, count) catch return error.OutOfMemory;
        }
        std.debug.assert(total_uses <= compound_count);
        self.uses = try allocator.alloc(WordUse, total_uses);

        const cursors = try allocator.alloc(usize, self.count);
        defer allocator.free(cursors);
        for (self.use_ranges, 0..) |range, predicate_id| cursors[predicate_id] = range.start;
        @memset(last_word, std.math.maxInt(usize));

        for (self.state_ids, 0..) |predicate_id_raw, absolute| {
            const predicate_id: usize = @intCast(predicate_id_raw);
            const word = absolute / 64;
            const mask = @as(u64, 1) << @intCast(absolute % 64);
            if (last_word[predicate_id] != word) {
                const cursor = cursors[predicate_id];
                self.uses[cursor] = .{ .word_index = @intCast(word), .mask = mask };
                cursors[predicate_id] += 1;
                last_word[predicate_id] = word;
            } else {
                self.uses[cursors[predicate_id] - 1].mask |= mask;
            }
        }
        std.debug.assert(self.uses.len <= selector.compounds.len);
        return self;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.state_ids.len != 0) allocator.free(self.state_ids);
        if (self.representatives.len != 0) allocator.free(self.representatives);
        if (self.use_ranges.len != 0) allocator.free(self.use_ranges);
        if (self.uses.len != 0) allocator.free(self.uses);
        self.* = .{};
    }

    pub fn usesFor(self: *const @This(), predicate_id: usize) []const WordUse {
        const range = self.use_ranges[predicate_id];
        return self.uses[range.start .. range.start + range.len];
    }
};

fn hashBytes(hash: *u64, bytes: []const u8) void {
    var h = hash.*;
    for (bytes) |byte| {
        h ^= byte;
        h *%= 0x100000001b3;
    }
    hash.* = h;
}

fn hashU64(hash: *u64, value: u64) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    hashBytes(hash, &buf);
}

fn hashRange(hash: *u64, source: []const u8, range: ast.Range) void {
    hashU64(hash, range.len);
    hashBytes(hash, range.slice(source));
}

fn compoundHash(selector: ast.Selector, comp: ast.Compound) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    hashRange(&hash, selector.source, comp.tag);
    hashRange(&hash, selector.source, comp.id);

    hashU64(&hash, comp.class_len);
    var i: IndexInt = 0;
    while (i < comp.class_len) : (i += 1) hashRange(&hash, selector.source, selector.classes[comp.class_start + i]);

    hashU64(&hash, comp.attr_len);
    i = 0;
    while (i < comp.attr_len) : (i += 1) {
        const item = selector.attrs[comp.attr_start + i];
        hashU64(&hash, @intFromEnum(item.op));
        hashU64(&hash, @intFromEnum(item.case));
        hashRange(&hash, selector.source, item.name);
        hashRange(&hash, selector.source, item.value);
    }

    hashU64(&hash, comp.pseudo_len);
    i = 0;
    while (i < comp.pseudo_len) : (i += 1) {
        const item = selector.pseudos[comp.pseudo_start + i];
        hashU64(&hash, @intFromEnum(item.kind));
        hashU64(&hash, @bitCast(@as(i64, item.nth.a)));
        hashU64(&hash, @bitCast(@as(i64, item.nth.b)));
    }

    hashU64(&hash, comp.not_len);
    i = 0;
    while (i < comp.not_len) : (i += 1) {
        const item = selector.not_items[comp.not_start + i];
        hashU64(&hash, @intFromEnum(item.kind));
        switch (item.kind) {
            .tag, .id, .class => hashRange(&hash, selector.source, item.text),
            .attr => {
                hashU64(&hash, @intFromEnum(item.attr.op));
                hashU64(&hash, @intFromEnum(item.attr.case));
                hashRange(&hash, selector.source, item.attr.name);
                hashRange(&hash, selector.source, item.attr.value);
            },
        }
    }
    return hash;
}

fn compoundsEquivalent(selector: ast.Selector, a: ast.Compound, b: ast.Compound) bool {
    if (!rangeEqual(selector.source, a.tag, b.tag) or !rangeEqual(selector.source, a.id, b.id)) return false;
    if (a.class_len != b.class_len or a.attr_len != b.attr_len or a.pseudo_len != b.pseudo_len or a.not_len != b.not_len) return false;

    var i: IndexInt = 0;
    while (i < a.class_len) : (i += 1) {
        if (!rangeEqual(selector.source, selector.classes[a.class_start + i], selector.classes[b.class_start + i])) return false;
    }
    i = 0;
    while (i < a.attr_len) : (i += 1) {
        if (!attrSelectorsEqual(selector.source, selector.attrs[a.attr_start + i], selector.attrs[b.attr_start + i])) return false;
    }
    i = 0;
    while (i < a.pseudo_len) : (i += 1) {
        const lhs = selector.pseudos[a.pseudo_start + i];
        const rhs = selector.pseudos[b.pseudo_start + i];
        if (lhs.kind != rhs.kind or lhs.nth.a != rhs.nth.a or lhs.nth.b != rhs.nth.b) return false;
    }
    i = 0;
    while (i < a.not_len) : (i += 1) {
        const lhs = selector.not_items[a.not_start + i];
        const rhs = selector.not_items[b.not_start + i];
        if (lhs.kind != rhs.kind) return false;
        switch (lhs.kind) {
            .tag, .id, .class => if (!rangeEqual(selector.source, lhs.text, rhs.text)) return false,
            .attr => if (!attrSelectorsEqual(selector.source, lhs.attr, rhs.attr)) return false,
        }
    }
    return true;
}

fn attrSelectorsEqual(source: []const u8, a: ast.AttrSelector, b: ast.AttrSelector) bool {
    return a.op == b.op and a.case == b.case and rangeEqual(source, a.name, b.name) and rangeEqual(source, a.value, b.value);
}

fn rangeEqual(source: []const u8, a: ast.Range, b: ast.Range) bool {
    return std.mem.eql(u8, a.slice(source), b.slice(source));
}

test "sparse predicate uses never exceed compound count" {
    const alloc = std.testing.allocator;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(alloc);
    for (0..4096) |i| {
        if (i != 0) try source.appendSlice(alloc, ",");
        var name_buf: [24]u8 = undefined;
        try source.appendSlice(alloc, try std.fmt.bufPrint(&name_buf, ".c{}", .{i}));
    }
    var selector = try ast.Selector.compileRuntime(alloc, source.items);
    defer selector.deinit(alloc);
    var plan = try Plan.init(alloc, selector);
    defer plan.deinit(alloc);
    try std.testing.expect(plan.uses.len <= selector.compounds.len);
    try std.testing.expectEqual(selector.compounds.len, plan.count);
}
