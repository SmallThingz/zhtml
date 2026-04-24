const std = @import("std");
const html = @import("html");

const Hooks = struct {
    parse_start_calls: usize = 0,
    parse_end_calls: usize = 0,
    query_start_calls: usize = 0,
    query_end_calls: usize = 0,

    pub fn onParseStart(self: *@This(), _: usize) void {
        self.parse_start_calls += 1;
    }

    pub fn onParseEnd(self: *@This(), _: html.ParseInstrumentationStats) void {
        self.parse_end_calls += 1;
    }

    pub fn onQueryStart(self: *@This(), _: html.QueryInstrumentationKind, _: usize) void {
        self.query_start_calls += 1;
    }

    pub fn onQueryEnd(self: *@This(), _: html.QueryInstrumentationStats) void {
        self.query_end_calls += 1;
    }
};

pub fn run() !void {
    const options: html.ParseOptions = .{};
    var hooks: Hooks = .{};
    var input = "<div><span id='x'></span></div>".*;
    var doc = try options.parse(std.testing.allocator, &input);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 0), hooks.parse_start_calls);
    try std.testing.expectEqual(@as(usize, 0), hooks.parse_end_calls);

    _ = try html.queryOneRuntimeWithHooks(std.testing.io, &doc, std.testing.allocator, "span#x", &hooks);
    try std.testing.expectEqual(@as(usize, 1), hooks.query_start_calls);
    try std.testing.expectEqual(@as(usize, 1), hooks.query_end_calls);
}

test "instrumentation hook wrappers" {
    try run();
}
