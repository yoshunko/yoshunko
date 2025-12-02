const std = @import("std");
const pb = @import("proto").pb;
const State = @import("../../network/State.zig");
const Memory = State.Memory;
const HallMode = @import("../mode/HallMode.zig");
const HollowMode = @import("../mode/HollowMode.zig");
const EventQueue = @import("../EventQueue.zig");
const Connection = @import("../../network/Connection.zig");
const PlayerBasicComponent = @import("../component/player/PlayerBasicComponent.zig");
const PlayerAvatarComponent = @import("../component/player/PlayerAvatarComponent.zig");
const PlayerItemComponent = @import("../component/player/PlayerItemComponent.zig");
const PlayerBuddyComponent = @import("../component/player/PlayerBuddyComponent.zig");
const PlayerHallComponent = @import("../component/player/PlayerHallComponent.zig");
const Dungeon = @import("../battle/Dungeon.zig");
const Allocator = std.mem.Allocator;

pub fn onHallModeLoaded(
    _: EventQueue.Dequeue(.game_mode_transition),
    mode: *HallMode,
    basic_comp: *PlayerBasicComponent,
    hall_comp: *PlayerHallComponent,
    conn: *Connection,
    mem: Memory,
) !void {
    var hall_scene_data: pb.HallSceneData = .{
        .section_id = mode.section_id,
        .control_avatar_id = basic_comp.info.control_avatar_id,
        .control_guise_avatar_id = basic_comp.info.control_guise_avatar_id,
        .scene_time_in_minutes = hall_comp.info.time_in_minutes,
        .day_of_week = hall_comp.info.day_of_week,
    };

    switch (mode.section_info.position) {
        .born_transform => |name| {
            hall_scene_data.transform_id = try mem.arena.dupe(u8, name);
        },
        .custom => |transform| {
            hall_scene_data.position = try transform.toProto(mem.arena);
        },
    }

    const npc_list = try mem.arena.alloc(pb.NpcInfo, mode.npcs.count());
    var npcs = mode.npcs.iterator();
    var i: usize = 0;
    while (npcs.next()) |kv| : (i += 1) {
        npc_list[i] = try kv.value_ptr.toProto(mem.arena, kv.key_ptr.*);
    }

    hall_scene_data.npc_list = .fromOwnedSlice(npc_list);
    try conn.write(pb.EnterSceneScNotify{ .scene = .{
        .scene_type = 1,
        .hall_scene_data = hall_scene_data,
    } }, 0);
}

pub fn onHollowModeLoaded(
    _: EventQueue.Dequeue(.game_mode_transition),
    mode: *HollowMode,
    dungeon: *Dungeon,
    conn: *Connection,
    mem: Memory,
    avatar_comp: *PlayerAvatarComponent,
    item_comp: *PlayerItemComponent,
    buddy_comp: *PlayerBuddyComponent,
) !void {
    var scene: pb.SceneData = .{
        .scene_id = mode.battle_event_id,
        .enemy_property_scale = mode.enemy_property_scale,
        .play_type = @intFromEnum(mode.play_type),
    };

    switch (mode.scene_data) {
        .fight => {
            scene.scene_type = 3;
            scene.fight_scene_data = .{
                .scene_reward = .{},
                .scene_perform = .{},
            };
        },
        .hadal_zone => |data| {
            scene.scene_type = 9;
            scene.hadal_zone_scene_data = .{
                .zone_id = data.zone_id,
                .layer_index = data.layer_index,
                .room_index = data.room_index,
                .layer_item_id = data.layer_item_id,
                .first_room_avatar_id_list = if (mode.avatar_ids.len > 0)
                    .fromOwnedSlice(try mem.arena.dupe(u32, mode.avatar_ids[0]))
                else
                    .empty,
                .second_room_avatar_id_list = if (mode.avatar_ids.len > 1)
                    .fromOwnedSlice(try mem.arena.dupe(u32, mode.avatar_ids[1]))
                else
                    .empty,
                .first_room_buddy_id = if (mode.buddy_ids.len > 0) mode.buddy_ids[0] else 0,
                .second_room_buddy_id = if (mode.buddy_ids.len > 1) mode.buddy_ids[1] else 0,
            };
        },
    }

    var dungeon_info: pb.DungeonInfo = .{
        .quest_id = dungeon.quest_id,
        .quest_type = dungeon.quest_type,
        .dungeon_package_info = try makeDungeonPackage(mem.arena, avatar_comp, item_comp, buddy_comp, mode.avatar_ids, mode.buddy_ids),
    };

    var avatar_units = dungeon.avatar_units.iterator();
    while (avatar_units.next()) |kv| {
        try dungeon_info.avatar_list.append(
            mem.arena,
            try kv.value_ptr.toProto(mem.arena, kv.key_ptr.*),
        );
    }

    var buddy_units = dungeon.buddy_units.iterator();
    while (buddy_units.next()) |kv| {
        try dungeon_info.buddy_list.append(
            mem.arena,
            try kv.value_ptr.toProto(mem.arena, kv.key_ptr.*),
        );
    }

    try conn.write(pb.EnterSceneScNotify{
        .scene = scene,
        .dungeon = dungeon_info,
    }, 0);
}

fn makeDungeonPackage(
    arena: Allocator,
    avatar_comp: *PlayerAvatarComponent,
    item_comp: *PlayerItemComponent,
    buddy_comp: *PlayerBuddyComponent,
    avatar_vec: []const []const u32,
    buddy_ids: []const u32,
) !pb.DungeonPackageInfo {
    var avatar_list: std.ArrayList(pb.AvatarInfo) = .empty;
    var weapon_list: std.ArrayList(pb.WeaponInfo) = .empty;
    var equip_list: std.ArrayList(pb.EquipInfo) = .empty;
    var buddy_list: std.ArrayList(pb.BuddyInfo) = .empty;

    for (avatar_vec) |list| {
        for (list) |avatar_id| {
            const avatar = avatar_comp.avatar_map.getPtr(avatar_id) orelse return error.NoSuchAvatar;
            try avatar_list.append(arena, try avatar.toProto(avatar_id, arena));

            if (avatar.cur_weapon_uid != 0) {
                if (item_comp.weapon_map.getPtr(avatar.cur_weapon_uid)) |weapon| {
                    try weapon_list.append(arena, try weapon.toProto(avatar.cur_weapon_uid, arena));
                }
            }

            for (avatar.dressed_equip) |maybe_uid| {
                const uid = maybe_uid orelse continue;
                if (item_comp.equip_map.getPtr(uid)) |equip| {
                    try equip_list.append(arena, try equip.toProto(uid, arena));
                }
            }
        }
    }

    for (buddy_ids) |buddy_id| {
    	const buddy = buddy_comp.buddy_map.getPtr(buddy_id) orelse return error.NoSuchBuddy;
        try buddy_list.append(arena, try buddy.toProto(buddy_id, arena));
    }

    return .{
        .avatar_list = avatar_list,
        .weapon_list = weapon_list,
        .equip_list = equip_list,
        .buddy_list = buddy_list,
    };
}
