const std = @import("std");

pub fn parse(comptime Args: type, args: [][:0]u8) ?Args {
    const fields = comptime std.meta.fields(Args);
    const ArgField = comptime std.meta.FieldEnum(Args);
    const Flag = comptime blk: {
        const field_names = std.meta.fieldNames(ArgField);
        var flags: [field_names.len]u8 = undefined;

        for (field_names, 0..) |name, i| {
            flags[i] = name[0];
        }

        break :blk @Enum(u8, .exhaustive, field_names, &flags);
    };

    var result: Args = .{};

    var arg_stack_buffer: [fields.len]Flag = undefined;
    var arg_stack = std.ArrayList(Flag).initBuffer(arg_stack_buffer[0..]);

    for (args) |arg| {
        if (arg[0] == '-') {
            for (arg[1..]) |flag| {
                if (arg_stack.items.len == fields.len) return null;
                arg_stack.appendAssumeCapacity(std.meta.intToEnum(Flag, flag) catch return null);
            }
        } else {
            if (arg_stack.items.len == 0) return null;
            switch (arg_stack.swapRemove(0)) {
                inline else => |flag| @field(result, @tagName(flag)) = arg,
            }
        }
    }

    return if (arg_stack.items.len == 0) result else null;
}

pub fn printUsage(comptime Args: type, program_name: []const u8) void {
    const usage_string = comptime blk: {
        var fmt: []const u8 = "Usage: {s} [-";
        for (std.meta.fields(Args)) |field| {
            fmt = fmt ++ .{field.name[0]};
        }

        fmt = fmt ++ "] ";

        for (std.meta.fields(Args)) |field| {
            fmt = fmt ++ "[" ++ field.name ++ "] ";
        }

        break :blk fmt ++ "\n";
    };

    std.debug.print(usage_string, .{program_name});
}
