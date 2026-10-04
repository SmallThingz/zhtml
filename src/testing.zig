const std = @import("std");

test {
    refAllDeclsRecursive(@This());
}

fn ArgsTuple(comptime Function: type) ?type {
    @setEvalBranchQuota(1000_000);
    const info = @typeInfo(Function);
    if (info != .@"fn") @compileError("ArgsTuple expects a function type");

    const function_info = info.@"fn";
    if (function_info.attrs.varargs) return null;

    var argument_field_list: [function_info.param_types.len]type = undefined;
    inline for (function_info.param_types, 0..) |arg, i| {
        const T = arg orelse return null;
        if (T == type or @typeInfo(T) == .@"fn") return null;
        argument_field_list[i] = T;
    }

    return @Tuple(&argument_field_list);
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
        .@"struct" => |si| inline for (si.field_names, si.field_types, si.field_attrs) |field_name, field_type, field_attrs| {
            @field(retval, field_name) = if (field_attrs.defaultValue(field_type)) |v| v else comptime initType(field_type);
        },
        .comptime_float => return 0.0,
        .comptime_int => return 0,
        .undefined => unreachable,
        .null, .optional => return null,
        .error_union => |eu| return initType(eu.payload),
        .error_set => |es_| if (es_.error_names) |es| {
            if (es.len == 0) return undefined;
            return @field(T, es[0]);
        } else error.AnyError,
        .@"enum" => |ei| if (ei.field_names.len != 0) {
            retval = @field(T, ei.field_names[0]);
        } else return undefined,
        .@"union" => |ui| if (ui.field_names.len != 0) {
            retval = @unionInit(T, ui.field_names[0], initType(ui.field_types[0]));
        },
        .@"fn" => return undefined,
        .@"opaque", .frame, .@"anyframe", .spirv => unreachable,
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
    inline for (comptime std.meta.declarations(T)) |decl_name| {
        const field = @field(T, decl_name);
        _ = &field;

        if (@TypeOf(field) == type) {
            switch (@typeInfo(@field(T, decl_name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl_name)),
                else => {},
            }
        } else if (@typeInfo(@TypeOf(field)) == .@"fn") {
            // Comptime compile APIs intentionally reject fabricated input and
            // are covered by focused tests with meaningful source strings.
            if (should_run and !comptime std.mem.startsWith(u8, decl_name, "compile")) {
                if (ArgsTuple(@TypeOf(field))) |Args| {
                    _ = &@call(.auto, field, comptime initType(Args));
                }
            }
        }
    }
}
