const std = @import("std");
const data = @import("data.zig");

const Lookup = *const fn ([]const u8) ?[]const u8;
var std_full: std.StringHashMapUnmanaged(u16) = .empty;
var std_sharded: [33]std.StringHashMapUnmanaged(u16) = @splat(.empty);

fn entryName(index: u16) []const u8 {
    const entry = data.entries[index];
    return data.names[entry.name_start..][0..entry.name_len];
}

fn entryValue(index: u16) []const u8 {
    const entry = data.entries[index];
    return data.values[entry.value_start..][0..entry.value_len];
}

fn hash(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0, name);
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

pub fn lookupHashFull(name: []const u8) ?[]const u8 {
    var pos: u16 = @intCast(hash(name) & data.full_hash_mask);
    while (true) : (pos = (pos + 1) & data.full_hash_mask) {
        const index = data.full_hash_slots[pos];
        if (index == data.empty) return null;
        if (std.mem.eql(u8, entryName(index), name)) return entryValue(index);
    }
}

fn lookupStdFull(name: []const u8) ?[]const u8 {
    return entryValue(std_full.get(name) orelse return null);
}

fn lookupStdSharded(name: []const u8) ?[]const u8 {
    if (name.len >= std_sharded.len) return null;
    return entryValue(std_sharded[name.len].get(name) orelse return null);
}

fn lookupStaticStd(name: []const u8) ?[]const u8 {
    const value_hash = std.hash.Wyhash.hash(0, name);
    const raw_fingerprint: u8 = @intCast(value_hash >> 56);
    const fingerprint = if (raw_fingerprint == 0) 1 else raw_fingerprint;
    var pos: u16 = @intCast(value_hash & data.std_hash_mask);
    while (data.std_meta[pos] != 0) : (pos = (pos + 1) & data.std_hash_mask) {
        if (data.std_meta[pos] != fingerprint) continue;
        const index = data.std_slots[pos];
        if (std.mem.eql(u8, entryName(index), name)) return entryValue(index);
    }
    return null;
}

fn verify() !void {
    for (data.entries, 0..) |_, i| {
        const index: u16 = @intCast(i);
        const name = entryName(index);
        const expected = entryValue(index);
        inline for (.{ lookupHash, lookupHashFull, lookupStdSharded, lookupStdFull, lookupStaticStd }) |lookup| {
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

fn runLongestPrefixCase(io: std.Io, label: []const u8, lookup: Lookup, queries: []const []const u8, iterations: usize) void {
    var checksum: usize = 0;
    const start = nowNs(io);
    for (0..iterations) |i| {
        const rem = queries[i % queries.len];
        var len = @min(rem.len, 32);
        while (len >= 2) : (len -= 1) {
            if (lookup(rem[0..len])) |value| {
                checksum +%= value.len + value[0] + len;
                break;
            }
        }
    }
    const elapsed: u64 = @intCast(nowNs(io) - start);
    std.mem.doNotOptimizeAway(checksum);
    std.debug.print("{s}: {d:.3} ns/input ({d} inputs, checksum={d})\n", .{
        label,
        @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations)),
        iterations,
        checksum,
    });
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    defer std_full.deinit(allocator);
    defer for (&std_sharded) |*map| map.deinit(allocator);
    for (data.entries, 0..) |_, i| {
        const index: u16 = @intCast(i);
        const name = entryName(index);
        try std_full.put(allocator, name, index);
        try std_sharded[name.len].put(allocator, name, index);
    }
    try verify();
    const common = [_][]const u8{ "amp;", "lt;", "gt;", "quot;", "nbsp;", "copy;", "reg;", "mdash;", "ndash;", "hellip;" };
    const uncommon = [_][]const u8{ "CounterClockwiseContourIntegral;", "NotNestedGreaterGreater;", "nparsl;", "gesles;", "fjlig;", "Aopf;" };
    const prefix_miss = [_][]const u8{ "CounterClockwiseContourIntegralz", "NotNestedGreaterGreaterx", "mdashx", "nbspp", "ThickSpacex" };
    const random_miss = [_][]const u8{ "zzzzzz;", "entityDoesNotExist;", "Q1x9;", "abcdefghi;", "Nope;" };
    const prefix_inputs = [_][]const u8{ "amp;tail", "nbsp;tail", "CounterClockwiseContourIntegral;tail", "NotNestedGreaterGreater;tail", "entityDoesNotExist;tail", "zzzzzz;tail" };
    const iterations = 5_000_000;
    inline for (.{
        .{ "wyhash-sharded", lookupHash },
        .{ "wyhash-unsharded", lookupHashFull },
        .{ "std-sharded", lookupStdSharded },
        .{ "std-unsharded", lookupStdFull },
        .{ "static-std-unsharded", lookupStaticStd },
    }) |variant| {
        runCase(init.io, variant[0] ++ "/common", variant[1], &common, iterations);
        runCase(init.io, variant[0] ++ "/uncommon", variant[1], &uncommon, iterations);
        runCase(init.io, variant[0] ++ "/prefix-miss", variant[1], &prefix_miss, iterations);
        runCase(init.io, variant[0] ++ "/random-miss", variant[1], &random_miss, iterations);
        runLongestPrefixCase(init.io, variant[0] ++ "/longest-prefix", variant[1], &prefix_inputs, iterations / 5);
    }
}
