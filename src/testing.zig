const std = @import("std");

fn ArgsTuple(comptime Function: type) ?type {
    @setEvalBranchQuota(1000_000);
    const info = @typeInfo(Function);
    if (info != .@"fn") @compileError("ArgsTuple expects a function type");

    const function_info = info.@"fn";
    if (function_info.is_var_args) return null;

    var argument_field_list: [function_info.params.len]type = undefined;
    inline for (function_info.params, 0..) |arg, i| {
        const T = arg.type orelse return null;
        if (T == type or @typeInfo(T) == .@"fn") return null;
        argument_field_list[i] = T;
    }

    return std.meta.Tuple(&argument_field_list);
}

fn initType(comptime T: type) T {
    @setEvalBranchQuota(1000_000);
    comptime var retval: T = undefined;
    switch (@typeInfo(T)) {
        .type => return void,
        .void => return undefined,
        .bool => return false,
        .noreturn => unreachable,
        .int => return 0,
        .float => return 0.0,
        .pointer => return @ptrCast(@alignCast(@constCast(&.{}))),
        .array => |ai| inline for (0..ai.len) |i| {
            retval[i] = initType(ai.child);
        },
        .@"struct" => |si| inline for (si.fields) |field| {
            @field(retval, field.name) = if (field.defaultValue()) |v| v else comptime initType(@FieldType(T, field.name));
        },
        .comptime_float => return 0.0,
        .comptime_int => return 0,
        .undefined => unreachable,
        .null, .optional => return null,
        .error_union => |eu| return initType(eu.payload),
        .error_set => |es_| if (es_) |es| {
            if (es.len == 0) return undefined;
            return @field(T, es[0].name);
        } else error.AnyError,
        .@"enum" => |ei| if (ei.fields.len != 0) {
            retval = @field(T, ei.fields[0].name);
        } else return undefined,
        .@"union" => |ui| if (ui.fields.len != 0) {
            retval = @unionInit(T, ui.fields[0].name, initType(ui.fields[0].type));
        },
        .@"fn" => return undefined,
        .@"opaque", .frame, .@"anyframe" => unreachable,
        .vector => |vi| inline for (vi.len) |i| {
            @field(retval, i) = initType(vi.child);
        },
        .enum_literal => return undefined,
    }
    return retval;
}

pub fn refAllDeclsRecursive(comptime T: type) void {
    var should_run: bool = false;
    std.mem.doNotOptimizeAway(&should_run);
    inline for (comptime std.meta.declarations(T)) |decl| {
        const field = @field(T, decl.name);
        _ = &field;

        if (@TypeOf(field) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        } else if (@typeInfo(@TypeOf(field)) == .@"fn") {
            if (should_run) {
                if (ArgsTuple(@TypeOf(field))) |Args| {
                    _ = &@call(.auto, field, comptime initType(Args));
                }
            }
        }
    }
}
