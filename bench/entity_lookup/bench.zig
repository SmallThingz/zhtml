const std = @import("std");
const data = @import("data.zig");

const Lookup = *const fn ([]const u8) ?[]const u8;

fn entryName(index: u16) []const u8 {
    const entry = data.entries[index];
    return data.names[entry.name_start..][0..entry.name_len];
}

fn entryValue(index: u16) []const u8 {
    const entry = data.entries[index];
    return data.values[entry.value_start..][0..entry.value_len];
}

fn hash(name: []const u8) u32 {
    var h: u32 = 2166136261;
    for (name) |byte| h = (h ^ byte) *% 16777619;
    return h;
}

pub fn lookupHash(name: []const u8) ?[]const u8 {
    if (name.len >= data.shards.len) return null;
    const shard = data.shards[name.len];
    if (shard.cap == 0) return null;
    var pos: u16 = @intCast(hash(name) & shard.mask);
    while (true) : (pos = (pos + 1) & shard.mask) {
        const index = data.slots[shard.start + pos];
        if (index == data.empty) return null;
        if (std.mem.eql(u8, entryName(index), name)) return entryValue(index);
    }
}

fn lookupTrie(name: []const u8, roots: []const u16, nodes: []const data.Node, edges: []const data.Edge, sharded: bool) ?[]const u8 {
    if (sharded and name.len >= roots.len) return null;
    var node_index: u16 = if (sharded) roots[name.len] else roots[0];
    for (name) |byte| {
        const node = nodes[node_index];
        var lo: usize = node.edge_start;
        var hi: usize = lo + node.edge_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const edge = edges[mid];
            if (edge.byte < byte) lo = mid + 1 else hi = mid;
        }
        if (lo >= node.edge_start + node.edge_count or edges[lo].byte != byte) return null;
        node_index = edges[lo].child;
    }
    const value = nodes[node_index].value;
    return if (value == data.empty) null else entryValue(value);
}

pub fn lookupShardedTrie(name: []const u8) ?[]const u8 {
    return lookupTrie(name, &data.sharded_roots, &data.sharded_nodes, &data.sharded_edges, true);
}

pub fn lookupFullTrie(name: []const u8) ?[]const u8 {
    return lookupTrie(name, &data.full_roots, &data.full_nodes, &data.full_edges, false);
}

fn verify() !void {
    for (data.entries, 0..) |_, i| {
        const index: u16 = @intCast(i);
        const name = entryName(index);
        const expected = entryValue(index);
        inline for (.{ lookupHash, lookupShardedTrie, lookupFullTrie }) |lookup| {
            const actual = lookup(name) orelse return error.MissingEntity;
            if (!std.mem.eql(u8, expected, actual)) return error.WrongEntity;
        }
    }
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).toNanoseconds();
}

fn runCase(io: std.Io, label: []const u8, lookup: Lookup, queries: []const []const u8, iterations: usize) void {
    var checksum: usize = 0;
    const start = nowNs(io);
    for (0..iterations) |i| {
        if (lookup(queries[i % queries.len])) |value| checksum +%= value.len + value[0];
    }
    const elapsed: u64 = @intCast(nowNs(io) - start);
    std.mem.doNotOptimizeAway(checksum);
    std.debug.print("{s}: {d:.3} ns/lookup ({d} lookups, checksum={d})\n", .{
        label,
        @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations)),
        iterations,
        checksum,
    });
}

pub fn main(init: std.process.Init) !void {
    try verify();
    const common = [_][]const u8{ "amp;", "lt;", "gt;", "quot;", "nbsp;", "copy;", "reg;", "mdash;", "ndash;", "hellip;" };
    const uncommon = [_][]const u8{ "CounterClockwiseContourIntegral;", "NotNestedGreaterGreater;", "nparsl;", "gesles;", "fjlig;", "Aopf;" };
    const prefix_miss = [_][]const u8{ "CounterClockwiseContourIntegralz", "NotNestedGreaterGreaterx", "mdashx", "nbspp", "ThickSpacex" };
    const random_miss = [_][]const u8{ "zzzzzz;", "entityDoesNotExist;", "Q1x9;", "abcdefghi;", "Nope;" };
    const iterations = 5_000_000;
    inline for (.{ .{ "hash", lookupHash }, .{ "sharded-trie", lookupShardedTrie }, .{ "full-trie", lookupFullTrie } }) |variant| {
        runCase(init.io, variant[0] ++ "/common", variant[1], &common, iterations);
        runCase(init.io, variant[0] ++ "/uncommon", variant[1], &uncommon, iterations);
        runCase(init.io, variant[0] ++ "/prefix-miss", variant[1], &prefix_miss, iterations);
        runCase(init.io, variant[0] ++ "/random-miss", variant[1], &random_miss, iterations);
    }
}
