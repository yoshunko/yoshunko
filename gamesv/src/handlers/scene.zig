const std = @import("std");
const pb = @import("proto").pb;
const network = @import("../network.zig");
const Connection = @import("../network/Connection.zig");
const EventQueue = @import("../logic/EventQueue.zig");
const PlayerHallComponent = @import("../logic/component/player/PlayerHallComponent.zig");
const State = @import("../network/State.zig");
const Memory = State.Memory;
const Hall = @import("../fs/Hall.zig");
const HallMode = @import("../logic/mode/HallMode.zig");
const Assets = @import("../data/Assets.zig");
const FileSystem = @import("common").FileSystem;
const ModeManager = @import("../logic/mode.zig").ModeManager;
const Dungeon = @import("../logic/battle/Dungeon.zig");

pub fn onEnterWorldCsReq(
    txn: *network.Transaction(pb.EnterWorldCsReq),
    events: *EventQueue,
    hall_comp: *PlayerHallComponent,
) !void {
    var retcode: i32 = 1;
    defer txn.respond(.{ .retcode = retcode }) catch {};

    try events.enqueue(.hall_section_switch, .{ .section_id = hall_comp.info.section_id });
    retcode = 0;
}

pub fn onEnterSectionCompleteCsReq(txn: *network.Transaction(pb.EnterSectionCompleteCsReq)) !void {
    try txn.respond(.{});
}

pub fn onLeaveCurSceneCsReq(
    txn: *network.Transaction(pb.LeaveCurSceneCsReq),
    events: *EventQueue,
    hall_comp: *PlayerHallComponent,
    cur_dungeon: *?Dungeon,
    mem: Memory,
) !void {
    var retcode: i32 = 1;
    defer txn.respond(.{ .retcode = retcode }) catch {};

    if (cur_dungeon.*) |*dungeon| dungeon.deinit(mem.gpa);
    cur_dungeon.* = null;

    try events.enqueue(.hall_section_switch, .{ .section_id = hall_comp.info.section_id });
    retcode = 0;
}

pub fn onEnterSectionCsReq(
    txn: *network.Transaction(pb.EnterSectionCsReq),
    events: *EventQueue,
) !void {
    var retcode: i32 = 1;
    defer txn.respond(.{ .retcode = retcode }) catch {};

    try events.enqueue(.hall_section_switch, .{
        .section_id = txn.message.section_id,
        .transform = txn.message.transform_id,
    });

    retcode = 0;
}

pub fn onSavePosInMainCityCsReq(
    txn: *network.Transaction(pb.SavePosInMainCityCsReq),
    events: *EventQueue,
    hall: *HallMode,
    mem: Memory,
) !void {
    var retcode: i32 = 1;
    defer txn.respond(.{ .retcode = retcode }) catch {};

    if (txn.message.real_save and hall.section_id == txn.message.section_id) {
        const transform = try Hall.Transform.fromProto(txn.message.position orelse return error.NoPositionSpecified);

        hall.section_info.position.deinit(mem.gpa);
        hall.section_info.position = .{ .custom = transform };
    }

    try events.enqueue(.hall_position_changed, .{});
    retcode = 0;
}

pub fn onInteractWithUnitCsReq(
    txn: *network.Transaction(pb.InteractWithUnitCsReq),
    events: *EventQueue,
    hall_mode: *HallMode,
) !void {
    const log = std.log.scoped(.interact_with_unit);

    var retcode: i32 = 1;
    defer txn.respond(.{ .retcode = retcode }) catch {};

    const interaction_type: pb.InteractTarget = txn.message.type orelse @enumFromInt(0);
    if (interaction_type == .none) return error.InvalidInteractType;

    const interact_index: usize = @intCast(@intFromEnum(interaction_type) - 1);

    const npc = hall_mode.npcs.getPtr(@intCast(txn.message.npc_tag_id)) orelse {
        log.warn("npc with tag {} doesn't exist", .{txn.message.npc_tag_id});
        return error.NpcTagNotExist;
    };

    if (npc.interacts[interact_index] == null or npc.interacts[interact_index].?.id != txn.message.interact_id) {
        log.warn(
            "invalid interaction {}:{t}:{}",
            .{ txn.message.npc_tag_id, interaction_type, txn.message.interact_id },
        );
        return error.InvalidInteractID;
    }

    try events.enqueue(.start_event_graph, .{
        .type = .interact,
        .entry_event = .on_interact,
        .event_graph_id = @intCast(txn.message.interact_id),
    });

    retcode = 0;
}

pub fn onSectionRefreshCsReq(
    txn: *network.Transaction(pb.SectionRefreshCsReq),
    _: *HallMode, // just for the sake of mode check
) !void {
    try txn.respond(.{ .retcode = 0 });
}
