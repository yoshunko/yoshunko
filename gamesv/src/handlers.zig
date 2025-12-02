const std = @import("std");
const proto = @import("proto");
const network = @import("network.zig");
const State = @import("network/State.zig");
const Packet = @import("network/Packet.zig");
const EventQueue = @import("logic/EventQueue.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.dispatcher);

const net_namespaces: []const type = &.{
    @import("handlers/player.zig"),
    @import("handlers/item.zig"),
    @import("handlers/avatar.zig"),
    @import("handlers/buddy.zig"),
    @import("handlers/quest.zig"),
    @import("handlers/archive.zig"),
    @import("handlers/hollow.zig"),
    @import("handlers/misc.zig"),
    @import("handlers/scene.zig"),
    @import("handlers/battle.zig"),
    @import("handlers/hadal_zone.zig"),
    @import("handlers/map.zig"),
};

const logic_namespaces: []const type = &.{
    @import("logic/handlers/reload.zig"),
    @import("logic/handlers/hall.zig"),
    @import("logic/handlers/event_graph.zig"),
    @import("logic/handlers/mode.zig"),
    @import("logic/handlers/sync.zig"),
    @import("logic/handlers/save.zig"),
};

pub const NetEventHandler = struct {
    namespace: type,
    Message: type,
    name: []const u8,

    pub inline fn invoke(
        comptime handler: NetEventHandler,
        state: *State,
        message: handler.Message,
        packet_id: u32,
    ) !void {
        const Txn = network.Transaction(handler.Message);
        var txn: Txn = .{
            .conn = state.conn,
            .message = message,
            .response = null,
        };

        var event_queue: EventQueue = .{ .arena = state.arena.allocator() };

        const target_fn = @field(handler.namespace, handler.name);
        const Args = std.meta.ArgsTuple(@TypeOf(target_fn));

        var args: Args = undefined;
        args[0] = &txn;

        inline for (comptime std.meta.fields(Args)[1..], 1..) |param, i| {
            if (param.type == *EventQueue)
                args[i] = &event_queue
            else
                args[i] = try state.extract(param.type);
        }

        try @call(.auto, target_fn, args);

        try drainEventQueue(&event_queue, state);

        if (Txn.Response != void) {
            if (txn.response) |response| {
                try state.conn.write(response, packet_id);
            } else log.err("response of type {s} is not set", .{@typeName(Txn.Response)});
        }
    }
};

pub fn drainEventQueue(event_queue: *EventQueue, state: *State) !void {
    while (event_queue.deque.popFront()) |event| {
        try dispatchLogicEvent(event_queue, event, state);
    }

    if (state.shouldSendPlayerSync()) {
        try state.conn.write(state.player_sync_notify, 0);
    }
}

const CmdId = build_enum: {
    var cmd_names: []const []const u8 = &.{};

    for (net_namespaces) |namespace| {
        for (std.meta.declarations(namespace)) |decl| {
            switch (@typeInfo(@TypeOf(@field(namespace, decl.name)))) {
                .@"fn" => |fn_info| {
                    if (fn_info.params.len == 0) continue;
                    const NetTransaction = std.meta.Child(fn_info.params[0].type.?);
                    if (!@hasDecl(NetTransaction, "MessageType")) continue;

                    const Message = NetTransaction.MessageType;
                    const message_name = @typeName(Message)[3..];
                    if (!@hasDecl(proto.pb_desc, message_name)) continue;

                    const message_desc = @field(proto.pb_desc, message_name);
                    if (!@hasDecl(message_desc, "cmd_id")) continue;

                    cmd_names = cmd_names ++ .{message_name};
                },
                else => {},
            }
        }
    }

    var cmd_ids: [cmd_names.len]u16 = undefined;
    for (cmd_names, 0..) |name, i| {
        cmd_ids[i] = @field(proto.pb_desc, name).cmd_id;
    }

    break :build_enum @Enum(u16, .exhaustive, cmd_names, &cmd_ids);
};

pub fn dispatchPacket(
    state: *State,
    head: proto.pb.PacketHead,
    packet: *const Packet,
) !void {
    const cmd_id = std.meta.intToEnum(CmdId, packet.cmd_id) catch return error.HandlerNotFound;

    switch (cmd_id) {
        inline else => |id| {
            const handler = getNetEventHandler(id);

            var reader = Io.Reader.fixed(packet.body);
            const message = proto.decodeMessage(&reader, state.arena.allocator(), handler.Message, proto.pb_desc) catch |err| {
                log.err("failed to decode message of type {s}: {}", .{ @typeName(handler.Message), err });
                return;
            };

            handler.invoke(state, message, head.packet_id) catch |err| {
                log.err("failed to handle message of type {s}: {}", .{ @typeName(handler.Message), err });
                return;
            };

            log.debug("handled message of type {s}", .{@typeName(handler.Message)});
        },
    }
}

fn dispatchLogicEvent(q: *EventQueue, e: EventQueue.Event, state: *State) !void {
    switch (e) {
        inline else => |event, tag| {
            inline for (logic_namespaces) |namespace| {
                inline for (comptime std.meta.declarations(namespace)) |decl| {
                    switch (@typeInfo(@TypeOf(@field(namespace, decl.name)))) {
                        .@"fn" => |fn_info| {
                            if (fn_info.params.len == 0) continue;

                            const EventDequeue = fn_info.params[0].type.?;
                            if (!@hasDecl(EventDequeue, "dequeue_event_tag")) continue;

                            if (EventDequeue.dequeue_event_tag != tag) continue;
                            try invokeEventHandler(q, event, state, @field(namespace, decl.name));
                        },
                        else => {},
                    }
                }
            }
        },
    }
}

fn invokeEventHandler(q: *EventQueue, e: anytype, state: *State, handler: anytype) !void {
    const Args = std.meta.ArgsTuple(@TypeOf(handler));

    var args: Args = undefined;
    args[0] = .{ .data = &e };

    inline for (comptime std.meta.fields(Args)[1..], 1..) |param, i| {
        if (param.type == *EventQueue)
            args[i] = q
        else
            args[i] = state.extract(param.type) catch return;
    }

    try @call(.auto, handler, args);
}

pub inline fn getNetEventHandler(comptime cmd_id: CmdId) NetEventHandler {
    @setEvalBranchQuota(100_000);

    inline for (net_namespaces) |namespace| {
        inline for (comptime std.meta.declarations(namespace)) |decl| {
            switch (@typeInfo(@TypeOf(@field(namespace, decl.name)))) {
                .@"fn" => |fn_info| {
                    if (fn_info.params.len == 0) continue;

                    const NetTransaction = std.meta.Child(fn_info.params[0].type.?);
                    if (!@hasDecl(NetTransaction, "MessageType")) continue;

                    const Message = NetTransaction.MessageType;
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
