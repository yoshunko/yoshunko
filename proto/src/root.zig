pub const pb = @import("pb.zig");
pub const pb_desc = @import("nap_generated.zig");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const WireType = enum(u32) {
    var_int = 0,
    int64 = 1,
    length_prefixed = 2,
    int32 = 5,

    pub fn of(comptime T: type) WireType {
        if (T == []const u8) return .length_prefixed;

        return switch (@typeInfo(T)) {
            .int, .bool, .@"enum" => .var_int,
            .float => |float| return switch (float.bits) {
                32 => .int32,
                64 => .int64,
                else => @compileError("only f32 and f64 are supported"),
            },
            .optional, .pointer => |container| of(container.child),
            .@"struct" => .length_prefixed,
            else => @compileError("unsupported type: " ++ @typeName(T)),
        };
    }
};

pub fn encodeMessage(w: *Io.Writer, message: anytype, comptime desc_namespace: type) !void {
    const Message = @TypeOf(message);
    const message_name = @typeName(Message)[3..];
    const message_desc = blk: {
        if (!@hasDecl(desc_namespace, message_name)) {
            if (@hasDecl(Message, "map_entry")) break :blk Message else return;
        } else break :blk @field(desc_namespace, message_name);
    };

    inline for (comptime std.meta.fields(Message)) |field| {
        if (@hasDecl(message_desc, field.name ++ "_field_desc")) {
            try encodeField(w, @field(message, field.name), @field(message_desc, field.name ++ "_field_desc"), desc_namespace);
        }
    }
}

pub fn encodingLength(message: anytype, comptime desc_namespace: type) usize {
    var prober = Io.Writer.Discarding.init("");
    encodeMessage(&prober.writer, message, desc_namespace) catch unreachable;
    return prober.fullCount();
}

fn encodeField(w: *Io.Writer, value: anytype, comptime desc: struct { u32, u32 }, comptime desc_namespace: type) !void {
    const Value = @TypeOf(value);
    const number, const xor = desc;
    if (comptime isRepeated(Value)) {
        for (value) |item| try encodeField(w, item, desc, desc_namespace);
    } else if (comptime isOptional(Value)) {
        if (value) |item| try encodeField(w, item, desc, desc_namespace);
    } else {
        try writeVarInt(w, comptime wireTag(number, .of(Value)));
        if (Value == []const u8) try writeBytes(w, value) else switch (@typeInfo(Value)) {
            .int => {
                const xor_const: Value = @intCast(xor);
                try writeVarInt(w, value ^ xor_const);
            },
            .bool => try writeVarInt(w, @as(u8, if (value) 1 else 0)),
            .float => |float| {
                const BackingInt = if (float.bits == 32) u32 else if (float.bits == 64) u64 else @compileError("encountered invalid float type: " ++ @typeName(Value));
                try w.writeInt(BackingInt, @bitCast(value), .little);
            },
            .@"enum" => try writeVarInt(w, @intFromEnum(value)),
            .@"struct" => {
                try writeVarInt(w, encodingLength(value, desc_namespace));
                try encodeMessage(w, value, desc_namespace);
            },
            else => @compileError("unsupported type: " ++ @typeName(Value)),
        }
    }
}

fn writeBytes(w: *Io.Writer, bytes: []const u8) !void {
    try writeVarInt(w, bytes.len);
    try w.writeAll(bytes);
}

fn isRepeated(comptime T: type) bool {
    return T != []const u8 and (comptime std.meta.activeTag(@typeInfo(T))) == .pointer;
}

fn isOptional(comptime T: type) bool {
    return (comptime std.meta.activeTag(@typeInfo(T))) == .optional;
}

inline fn wireTag(comptime field_number: u32, comptime wire_type: WireType) u32 {
    return (field_number << 3) | @intFromEnum(wire_type);
}

fn writeVarInt(w: *Io.Writer, value: anytype) !void {
    var v = value;
    while (v >= 0x80) : (v >>= 7) {
        try w.writeByte(@intCast(0x80 | (v & 0x7F)));
    } else try w.writeByte(@intCast(v & 0x7F));
}

pub fn decodeMessage(r: *Io.Reader, allocator: Allocator, comptime Message: type, comptime desc_namespace: type) !Message {
    const message_name = @typeName(Message)[3..];
    if (std.meta.fields(Message).len == 0) return Message.default;
    const message_desc = blk: {
        if (!@hasDecl(desc_namespace, message_name)) {
            if (@hasDecl(Message, "map_entry")) break :blk Message else return;
        } else break :blk @field(desc_namespace, message_name);
    };

    const FieldEnum = comptime blk: {
        var fields: []const std.builtin.Type.EnumField = &.{};
        for (std.meta.fields(Message)) |field| {
            if (@hasDecl(message_desc, field.name ++ "_field_desc")) {
                fields = fields ++ .{std.builtin.Type.EnumField{
                    .name = field.name,
                    .value = @field(message_desc, field.name ++ "_field_desc").@"0",
                }};
            }
        }
        break :blk @Type(.{ .@"enum" = .{
            .tag_type = u32,
            .fields = fields,
            .decls = &.{},
            .is_exhaustive = true,
        } });
    };

    const has_fields = comptime std.meta.fields(FieldEnum).len != 0;
    var message = Message.default;
    while (readVarInt(r, u32) catch null) |wire_tag| {
        const wire_type = std.meta.intToEnum(WireType, wire_tag & 7) catch return error.InvalidWireType;
        if (!has_fields) {
            try skipField(r, wire_type);
            continue;
        }

        const field_variant = std.meta.intToEnum(FieldEnum, wire_tag >> 3) catch {
            try skipField(r, wire_type);
            continue;
        };

        if (has_fields) {
            switch (field_variant) {
                inline else => |variant| {
                    const field = comptime std.meta.fieldInfo(Message, std.meta.stringToEnum(std.meta.FieldEnum(Message), @tagName(variant)).?);
                    const xor = @field(message_desc, field.name ++ "_field_desc").@"1";

                    if (comptime isRepeated(field.type)) {
                        const slice = try decodeField(r, allocator, field.type, wire_type, xor, desc_namespace);
                        const old_slice = @field(message, field.name);
                        const new_slice = try allocator.alloc(std.meta.Child(field.type), old_slice.len + slice.len);
                        @memcpy(new_slice[0..old_slice.len], old_slice);
                        @memcpy(new_slice[old_slice.len..], slice);
                        @field(message, field.name) = new_slice;
                    } else {
                        @field(message, field.name) = try decodeField(r, allocator, field.type, wire_type, xor, desc_namespace);
                    }
                },
            }
        }
    }

    return message;
}

fn decodeField(r: *Io.Reader, allocator: Allocator, comptime T: type, wire_type: WireType, xor: u32, comptime desc_namespace: type) !T {
    if (comptime isRepeated(T)) {
        const Child = std.meta.Child(T);
        var list: std.ArrayList(Child) = try .initCapacity(allocator, 1);
        if ((comptime WireType.of(Child) != .length_prefixed) and wire_type == .length_prefixed) {
            const length = try readVarInt(r, usize); // packed list of scalar values
            var reader = Io.Reader.fixed(try r.take(length));
            while (decodeField(&reader, allocator, Child, .of(Child), xor, desc_namespace) catch null) |value| {
                try list.append(allocator, value);
            }
        } else list.appendAssumeCapacity(try decodeField(r, allocator, Child, wire_type, xor, desc_namespace));
        return list.items;
    } else if (comptime isOptional(T))
        return try decodeField(r, allocator, std.meta.Child(T), wire_type, xor, desc_namespace)
    else if (T == []const u8)
        return try r.readAlloc(allocator, try readVarInt(r, usize))
    else switch (@typeInfo(T)) {
        .int => {
            const xor_const: T = @intCast(xor);
            return try readVarInt(r, T) ^ xor_const;
        },
        .bool => return (try readVarInt(r, u8)) != 0,
        .float => |float| {
            const BackingInt = if (float.bits == 32) u32 else if (float.bits == 64) u64 else @compileError("encountered invalid float type: " ++ @typeName(T));
            return @bitCast(try r.takeInt(BackingInt, .little));
        },
        .@"enum" => return std.meta.intToEnum(T, try readVarInt(r, i32)) catch @enumFromInt(0),
        .@"struct" => {
            var reader = Io.Reader.fixed(try r.take(try readVarInt(r, usize)));
            return try decodeMessage(&reader, allocator, T, desc_namespace);
        },
        else => @compileError("unsupported type: " ++ @typeName(T)),
    }
}

fn readVarInt(r: *Io.Reader, comptime T: type) !T {
    var shift: std.math.Log2Int(T) = 0;
    var result: T = 0;

    while (true) : (shift += 7) {
        const byte = try r.takeByte();
        result |= @as(T, @intCast(byte & 0x7F)) << shift;
        if ((byte & 0x80) != 0x80) return result;
        if (shift >= @bitSizeOf(T) - 7) return error.InvalidVarInt;
    }
}

fn skipField(r: *Io.Reader, wire_type: WireType) !void {
    switch (wire_type) {
        .var_int => _ = try readVarInt(r, u64),
        .int32 => try r.discardAll(4),
        .int64 => try r.discardAll(8),
        .length_prefixed => {
            const length = try readVarInt(r, usize);
            try r.discardAll(length);
        },
    }
}
