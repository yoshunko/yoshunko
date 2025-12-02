const std = @import("std");
const pb = @import("proto").pb;
const network = @import("../network.zig");
const property_util = @import("../logic/property_util.zig");
const PlayerAvatarComponent = @import("../logic/component/player/PlayerAvatarComponent.zig");
const PlayerItemComponent = @import("../logic/component/player/PlayerItemComponent.zig");
const PlayerBuddyComponent = @import("../logic/component/player/PlayerBuddyComponent.zig");
const Dungeon = @import("../logic/battle/Dungeon.zig");
const AvatarUnit = @import("../logic/battle/AvatarUnit.zig");
const BuddyUnit = @import("../logic/battle/BuddyUnit.zig");
const ModeManager = @import("../logic/mode.zig").ModeManager;
const HollowMode = @import("../logic/mode/HollowMode.zig");
const Memory = @import("../network/State.zig").Memory;
const EventQueue = @import("../logic/EventQueue.zig");
const Assets = @import("../data/Assets.zig");
const Allocator = std.mem.Allocator;

pub fn onStartTrainingQuestCsReq(
    txn: *network.Transaction(pb.StartTrainingQuestCsReq),
    events: *EventQueue,
    cur_dungeon: *?Dungeon,
    mode_mgr: *ModeManager,
    mem: Memory,
) !void {
    var retcode: i32 = 1;
    defer txn.respond(.{ .retcode = retcode }) catch {};

    if (cur_dungeon.* != null) return error.AlreadyInDungeon;
    cur_dungeon.* = .{ .quest_id = 12254000, .quest_type = 0 };

    var buddy_id_list: std.ArrayList(u32) = .empty;
    defer buddy_id_list.deinit(mem.gpa);

    if (txn.message.buddy_id != 0) try buddy_id_list.append(mem.gpa, txn.message.buddy_id);

    mode_mgr.change(mem.gpa, .hollow, .{
        .battle_event_id = 19800014,
        .play_type = .training_room,
        .scene_data = .{ .fight = .{} },
        .avatar_ids = try mem.gpa.dupe(
            []const u32,
            &.{try mem.gpa.dupe(u32, txn.message.avatar_id_list.items)},
        ),
        .buddy_ids = try buddy_id_list.toOwnedSlice(mem.gpa),
    });

    try events.enqueue(.game_mode_transition, .{});
    retcode = 0;
}

const hadal_static_zone_group: u32 = 61;
const hadal_periodic_zone_group: u32 = 62;
const hadal_periodic_zone_id: u32 = 62001;
const hadal_periodic_with_rooms_zone_id: u32 = 62010;
const hadal_zone_bosschallenge_zone_id: u32 = 69001;
const hadal_zone_alivecount_zone_id: u32 = 61002;
const hadal_zone_bosschallenge_zone_group: u32 = 69;
const hadal_zone_enemy_property_scale: u32 = 19;
const hadal_zone_bosschallenge_enemy_property_scale: u32 = 33;
const hadal_zone_impact_battle_enemy_property_scale: u32 = 61;

pub fn onStartHadalZoneBattleCsReq(
    txn: *network.Transaction(pb.StartHadalZoneBattleCsReq),
    events: *EventQueue,
    cur_dungeon: *?Dungeon,
    mode_mgr: *ModeManager,
    avatar_comp: *PlayerAvatarComponent,
    item_comp: *PlayerItemComponent,
    buddy_comp: *PlayerBuddyComponent,
    assets: *const Assets,
    mem: Memory,
) !void {
    var retcode: i32 = 1;
    defer txn.respond(.{ .retcode = retcode }) catch {};

    if (cur_dungeon.* != null) return error.AlreadyInDungeon;

    const avatar_vec: []const []const u32 = try mem.gpa.dupe([]const u32, &.{
        try mem.gpa.dupe(u32, txn.message.first_room_avatar_id_list.items),
        try mem.gpa.dupe(u32, txn.message.second_room_avatar_id_list.items),
    });

    var buddy_id_list: std.ArrayList(u32) = .empty;
    defer buddy_id_list.deinit(mem.gpa);
    if (txn.message.first_room_buddy_id != 0) try buddy_id_list.append(mem.gpa, txn.message.first_room_buddy_id);
    if (txn.message.second_room_buddy_id != 0) try buddy_id_list.append(mem.gpa, txn.message.second_room_buddy_id);
    const buddy_ids = try buddy_id_list.toOwnedSlice(mem.gpa);

    var zone_group = txn.message.zone_id;
    while ((zone_group / 100) > 0) zone_group /= 10;

    const layer_id: u32 = switch (zone_group) {
        hadal_static_zone_group => (txn.message.zone_id * 100) + txn.message.layer_index,
        hadal_periodic_zone_group => switch (txn.message.room_index) {
            0 => (hadal_periodic_zone_id * 100) + txn.message.layer_index,
            else => (hadal_periodic_with_rooms_zone_id * 100) + (txn.message.layer_index * 10) + txn.message.room_index,
        },
        hadal_zone_bosschallenge_zone_group => hadal_zone_bosschallenge_zone_id * 100 + txn.message.layer_index,
        else => return error.InvalidZoneID,
    };

    const hadal_zone_quest_template = assets.templates.getConfigByKey(.hadal_zone_quest_template_tb, layer_id) orelse return error.MissingQuestForLayer;
    const quest_config_template = assets.templates.getConfigByKey(.quest_config_template_tb, hadal_zone_quest_template.quest_id) orelse return error.MissingQuestForLayer;

    cur_dungeon.* = .{
        .quest_type = quest_config_template.quest_type,
        .quest_id = @intCast(hadal_zone_quest_template.quest_id),
        .avatar_units = try makeAvatarUnits(mem.gpa, avatar_comp, item_comp, assets, avatar_vec),
        .buddy_units = try makeBuddyUnits(mem.gpa, buddy_comp, assets, buddy_ids),
    };

    const play_type = getHadalZonePlayType(txn.message.zone_id, txn.message.room_index);

    mode_mgr.change(mem.gpa, .hollow, .{
        .battle_event_id = layer_id,
        .play_type = play_type,
        .scene_data = .{ .hadal_zone = .{
            .zone_id = txn.message.zone_id,
            .layer_index = txn.message.layer_index,
            .room_index = txn.message.room_index,
            .layer_item_id = txn.message.layer_item_id,
        } },
        .avatar_ids = avatar_vec,
        .buddy_ids = buddy_ids,
        .enemy_property_scale = switch (play_type) {
            .hadal_zone_bosschallenge => hadal_zone_bosschallenge_enemy_property_scale,
            .hadal_zone_impact_battle => hadal_zone_impact_battle_enemy_property_scale,
            else => hadal_zone_enemy_property_scale,
        },
    });

    try events.enqueue(.game_mode_transition, .{});
    retcode = 0;
}

fn getHadalZonePlayType(zone_id: u32, room_index: u32) HollowMode.LocalPlayType {
    if (zone_id == hadal_zone_alivecount_zone_id) return .hadal_zone_alivecount;

    var zone_group = zone_id;
    while ((zone_group / 100) > 0) zone_group /= 10;

    if (zone_group == hadal_zone_bosschallenge_zone_group) return .hadal_zone_bosschallenge;

    return switch (room_index) {
        0 => .hadal_zone,
        else => .hadal_zone_impact_battle,
    };
}

pub fn onEndBattleCsReq(txn: *network.Transaction(pb.EndBattleCsReq)) !void {
    try txn.respond(.{ .fight_settle = .{} });
}

fn makeAvatarUnits(
    gpa: Allocator,
    avatar_comp: *const PlayerAvatarComponent,
    item_comp: *const PlayerItemComponent,
    assets: *const Assets,
    avatars: []const []const u32,
) !std.AutoArrayHashMapUnmanaged(u32, AvatarUnit) {
    var map: std.AutoArrayHashMapUnmanaged(u32, AvatarUnit) = .empty;

    for (avatars) |list| for (list) |avatar_id| {
        const properties = try property_util.makePropertyMap(avatar_comp, item_comp, gpa, assets, avatar_id);

        try map.put(gpa, avatar_id, .{
            .properties = properties,
        });
    };

    return map;
}

fn makeBuddyUnits(
    gpa: Allocator,
    buddy_comp: *const PlayerBuddyComponent,
    assets: *const Assets,
    buddy_ids: []const u32,
) !std.AutoArrayHashMapUnmanaged(u32, BuddyUnit) {
    _ = assets;
    _ = buddy_comp;

    var map: std.AutoArrayHashMapUnmanaged(u32, BuddyUnit) = .empty;
    try map.put(gpa, BuddyUnit.assisting_buddy_id, .{ .type = .assisting });

    for (buddy_ids) |buddy_id| {
        try map.put(gpa, buddy_id, .{
            .type = .fighting,
            .properties = .empty, // TODO: properties for BuddyUnits
        });
    }

    return map;
}
