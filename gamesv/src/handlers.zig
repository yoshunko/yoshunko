const std = @import("std");
const proto = @import("proto");
const network = @import("network.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const namespaces: []const type = &.{
    @import("handlers/player.zig"),
    @import("handlers/item.zig"),
    @import("handlers/avatar.zig"),
    @import("handlers/quest.zig"),
    @import("handlers/archive.zig"),
    @import("handlers/hollow.zig"),
    @import("handlers/misc.zig"),
    @import("handlers/scene.zig"),
    @import("handlers/battle.zig"),
    @import("handlers/hadal_zone.zig"),
};

pub const Handler = struct {
    namespace: type,
    Message: type,
    name: []const u8,

    pub inline fn invoke(
        comptime handler: Handler,
        context: *network.Context,
        message: handler.Message,
    ) !void {
        return try @field(handler.namespace, handler.name)(context, message);
    }
};

const CmdId = build_enum: {
    var fields: []const std.builtin.Type.EnumField = &.{};

    for (namespaces) |namespace| {
        for (std.meta.declarations(namespace)) |decl| {
            switch (@typeInfo(@TypeOf(@field(namespace, decl.name)))) {
                .@"fn" => |fn_info| {
                    if (fn_info.params.len != 2) continue;

                    const Message = fn_info.params[1].type.?;
                    const message_name = @typeName(Message)[3..];
                    if (!@hasDecl(proto.pb_desc, message_name)) continue;

                    const message_desc = @field(proto.pb_desc, message_name);
                    if (!@hasDecl(message_desc, "cmd_id")) continue;

                    fields = fields ++ .{std.builtin.Type.EnumField{
                        .name = @typeName(Message),
                        .value = message_desc.cmd_id,
                    }};
                },
                else => {},
            }
        }
    }

    break :build_enum @Type(.{ .@"enum" = .{
        .decls = &.{},
        .tag_type = u16,
        .fields = fields,
        .is_exhaustive = true,
    } });
};

pub fn dispatchPacket(
    context: *network.Context,
    packet: *const network.Packet,
) !void {
    const log = std.log.scoped(.packet_processing);
    const cmd_id = std.meta.intToEnum(CmdId, packet.cmd_id) catch return error.HandlerNotFound;

    switch (cmd_id) {
        inline else => |id| {
            const handler = getHandler(id);

            var reader = Io.Reader.fixed(packet.body);
            const message = proto.decodeMessage(&reader, context.arena, handler.Message, proto.pb_desc) catch |err| {
                log.err("failed to decode message of type {s}: {}", .{ @typeName(handler.Message), err });
                return;
            };

            handler.invoke(context, message) catch |err| {
                log.err("failed to handle message of type {s}: {}", .{ @typeName(handler.Message), err });
                return;
            };

            log.debug("handled message of type {s}", .{@typeName(handler.Message)});
        },
    }
}

pub inline fn getHandler(comptime cmd_id: CmdId) Handler {
    @setEvalBranchQuota(100_000);

    inline for (namespaces) |namespace| {
        inline for (comptime std.meta.declarations(namespace)) |decl| {
            switch (@typeInfo(@TypeOf(@field(namespace, decl.name)))) {
                .@"fn" => |fn_info| {
                    if (fn_info.params.len != 2) continue;

                    const Message = fn_info.params[1].type.?;
                    const message_name = @typeName(Message)[3..];
                    if (!@hasDecl(proto.pb_desc, message_name)) continue;

                    const message_desc = @field(proto.pb_desc, message_name);
                    if (!@hasDecl(message_desc, "cmd_id")) continue;

                    const handler_cmd_id: CmdId = @enumFromInt(message_desc.cmd_id);

                    if (cmd_id == handler_cmd_id) {
                        return .{
                            .namespace = namespace,
                            .Message = Message,
                            .name = decl.name,
                        };
                    }
                },
                else => {},
            }
        }
    }
}
