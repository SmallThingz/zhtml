const std = @import("std");
const declaration_testing = @import("../testing.zig");
const ast = @import("ast.zig");
const forward = @import("forward.zig");
const execution_plan = @import("execution_plan.zig");

test {
    declaration_testing.refAllDeclsRecursive(@This());
}

/// Owned runtime selector plus its immutable forward execution program.
///
/// Use this when the same runtime selector is queried repeatedly. Query
/// iterators borrow the compiled program, so this value must outlive them.
pub const PreparedSelector = struct {
    allocator: std.mem.Allocator,
    selector: ast.Selector,
    compact_plan: forward.Plan,
    execution_plan: execution_plan.Plan,

    /// Parses and fully prepares a runtime selector once.
    pub fn compile(allocator: std.mem.Allocator, source: []const u8) !@This() {
        var selector = try ast.Selector.compileRuntime(allocator, source);
        errdefer selector.deinit(allocator);
        var exec_plan = try execution_plan.Plan.init(allocator, selector);
        errdefer exec_plan.deinit(allocator);
        return .{
            .allocator = allocator,
            .selector = selector,
            .compact_plan = forward.buildPlan(selector),
            .execution_plan = exec_plan,
        };
    }

    /// Releases the selector AST and immutable execution program.
    pub fn deinit(self: *@This()) void {
        self.execution_plan.deinit(self.allocator);
        self.selector.deinit(self.allocator);
        self.* = undefined;
    }
};

test "prepared selector owns selector and execution plan" {
    const alloc = std.testing.allocator;
    var prepared = try PreparedSelector.compile(alloc, "main div > span.x");
    defer prepared.deinit();
    try std.testing.expectEqualStrings("main div > span.x", prepared.selector.source);
    try std.testing.expect(prepared.execution_plan.state_count != 0);
}

test "prepared selector cleans up every partial allocation failure" {
    const alloc = std.testing.allocator;
    const source =
        "div div div div div div div div, " ++
        "x0, x1, x2, x3, x4, x5, x6, x7, " ++
        ".a0, .a1, .a2, .a3, .a4, .a5, .a6, .a7";

    const Case = struct {
        fn run(allocator: std.mem.Allocator, selector_source: []const u8) !void {
            var prepared = try PreparedSelector.compile(allocator, selector_source);
            defer prepared.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(alloc, Case.run, .{source});
}
