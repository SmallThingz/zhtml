const std = @import("std");

pub const none: u32 = std.math.maxInt(u32);

const AsciiCaseInsensitiveWyhash = struct {
    pub fn hash(_: @This(), name: []const u8) u64 {
        var lowered: [64]u8 = undefined;
        if (name.len <= lowered.len) {
            _ = std.ascii.lowerString(lowered[0..name.len], name);
            return std.hash.Wyhash.hash(0, lowered[0..name.len]);
        }

        var hasher = std.hash.Wyhash.init(0);
        var start: usize = 0;
        while (start < name.len) {
            const len = @min(lowered.len, name.len - start);
            _ = std.ascii.lowerString(lowered[0..len], name[start .. start + len]);
            hasher.update(lowered[0..len]);
            start += len;
        }
        return hasher.final();
    }

    pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }
};

pub const Map = std.HashMapUnmanaged([]const u8, u32, AsciiCaseInsensitiveWyhash, std.hash_map.default_max_load_percentage);
