const std = @import("std");
const ast = @import("ast.zig");
const runtime = @import("runtime.zig");
const test_helpers = @import("test_helpers.zig");

/// Allocator facade that allows selector compilation during comptime execution.
pub const ComptimeAllocator = struct {
    pub const interface: std.mem.Allocator = .{
        .ptr = undefined,
        .vtable = &.{
            .alloc = &alloc,
            .resize = &resize,
            .remap = &remap,
            .free = &free,
        },
    };

    const Alignment = std.mem.Alignment;

    /// Comptime-only allocation callback.
    pub fn alloc(_: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        if (!@inComptime()) return null;
        _ = ret_addr;

        comptime {
            var allocation: [len]u8 align(alignment.toByteUnits()) = undefined;
            return &allocation;
        }
    }

    /// Resize is disabled; callers fall back to allocate+copy.
    pub fn resize(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = .{ memory, alignment, new_len, ret_addr };
        return false;
    }

    /// Remap is disabled to keep deterministic comptime allocations.
    pub fn remap(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = .{ memory, alignment, new_len, ret_addr };
        return null;
    }

    /// No-op free for comptime allocator interface.
    pub fn free(_: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = .{ memory, alignment, ret_addr };
    }

    /// Formats this allocator marker for human-readable output.
    pub fn format(_: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("ComptimeAllocator{}");
    }
};

/// Compiles selector source at comptime into a fully materialized AST.
pub fn compileImpl(comptime source: []const u8) ast.Selector {
    const parsed = runtime.compileRuntimeImpl(ComptimeAllocator.interface, source) catch |err| {
        @compileError("invalid selector: " ++ source ++ " (" ++ @errorName(err) ++ ")");
    };

    const groups = materializeSlice(ast.Group, parsed.groups);
    const compounds = materializeSlice(ast.Compound, parsed.compounds);
    const classes = materializeSlice(ast.Range, parsed.classes);
    const attrs = materializeSlice(ast.AttrSelector, parsed.attrs);
    const pseudos = materializeSlice(ast.Pseudo, parsed.pseudos);
    const not_items = materializeSlice(ast.NotSimple, parsed.not_items);

    return .{
        .source = source,
        .groups = groups,
        .compounds = compounds,
        .classes = classes,
        .attrs = attrs,
        .pseudos = pseudos,
        .not_items = not_items,
    };
}

fn materializeSlice(comptime T: type, comptime src: []const T) []const T {
    const arr = src[0..src.len].*;
    return arr[0..];
}

test "compile-time parser" {
    const sel = comptime compileImpl("div#id.cls[attr^=x]:first-child, span + a");
    try std.testing.expectEqual(@as(usize, 2), sel.groups.len);
    try std.testing.expectEqual(@as(usize, 3), sel.compounds.len);
    try std.testing.expect(sel.compounds[2].combinator == .adjacent);
}

test "compile-time parser covers all attribute operators" {
    const sel = comptime compileImpl("div[a][b=v][c^=x][d$=y][e*=z][f~=m][g|=en]");
    try test_helpers.expectAllAttributeOps(sel);
}

test "compile-time parser tracks combinator chain and grouping" {
    const sel = comptime compileImpl("a b > c + d ~ e, #x");
    try test_helpers.expectCombinatorChain(sel);
}

test "compile-time parser supports leading combinator and nth-child variants" {
    const sel = comptime compileImpl("> #hsoob");
    try std.testing.expectEqual(@as(usize, 1), sel.compounds.len);
    try std.testing.expect(sel.compounds[0].combinator == .child);

    const nth = comptime compileImpl("#pseudos :nth-child(+3n-2)");
    try std.testing.expectEqual(@as(usize, 2), nth.compounds.len);
    try std.testing.expect(nth.compounds[1].combinator == .descendant);
    try std.testing.expectEqual(@as(ast.Int, 1), nth.compounds[1].pseudo_len);
}

test "format comptime allocator marker" {
    const alloc = std.testing.allocator;
    const rendered = try std.fmt.allocPrint(alloc, "{f}", .{ComptimeAllocator{}});
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings("ComptimeAllocator{}", rendered);
}
