const std = @import("std");
const proto = @import("proto");
const pb = proto.pb;
const Player = @import("fs/Player.zig");
const Avatar = @import("fs/Avatar.zig");
const Weapon = @import("fs/Weapon.zig");
const Equip = @import("fs/Equip.zig");
const Connection = @import("network.zig").Connection;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const player_sync_fields = .{
    .{ Avatar, .{ .avatar, .avatar_list, pb.AvatarInfo } },
    .{ Weapon, .{ .item, .weapon_list, pb.WeaponInfo } },
    .{ Equip, .{ .item, .equip_list, pb.EquipInfo } },
};

pub fn send(connection: *Connection, arena: Allocator, io: Io) !void {
    const player = connection.getPlayer() catch return;
    var notify: pb.PlayerSyncScNotify = .default;

    if (player.sync.basic_info_changed) {
        notify.self_basic_info = try player.buildBasicInfoProto(arena);
    }

    try syncItems(arena, player, &notify);

    if (player.sync.hadal_zone_changed) {
        const entrance_list = try arena.alloc(pb.HadalEntranceSync, player.hadal_zone.entrances.len);
        for (player.hadal_zone.entrances, 0..) |entrance, i| {
            const entrance_type = entrance.entranceType();
            entrance_list[i] = .{
                .entrance_id = entrance.id,
                .state = @enumFromInt(3), // :three:
                .cur_zone_record_sync = try player.hadal_zone.buildZoneRecord(
                    io,
                    arena,
                    connection.assets,
                    entrance_type,
                    entrance.zone_id,
                ),
            };
        }

        notify.hadal_zone = .{ .sync_entrance_list = entrance_list };
    }

    connection.write(notify, 0) catch {};

    if (player.sync.new_avatars.count() != 0) {
        var ids = player.sync.new_avatars.keyIterator();
        while (ids.next()) |id| {
            connection.write(pb.AddAvatarScNotify{
                .avatar_id = id.*,
                .perform_type = 2,
            }, 0) catch {};
        }
    }

    if (player.sync.in_scene_transition) blk: {
        // TODO: only hall transitions are supported currently
        const section = &(player.cur_section orelse break :blk);

        var hall_scene_data: pb.HallSceneData = .{
            .section_id = player.hall.section_id,
            .control_avatar_id = player.basic_info.control_avatar_id,
            .control_guise_avatar_id = player.basic_info.control_guise_avatar_id,
            .scene_time_in_minutes = player.hall.time_in_minutes,
            .day_of_week = player.hall.day_of_week,
        };

        switch (section.position) {
            .born_transform => |name| {
                hall_scene_data.transform_id = try arena.dupe(u8, name);
            },
            .custom => |transform| {
                hall_scene_data.position = try transform.toProto(arena);
            },
        }

        const npc_list = try arena.alloc(pb.NpcInfo, player.active_npcs.count());
        var npcs = player.active_npcs.iterator();
        var i: usize = 0;
        while (npcs.next()) |kv| : (i += 1) {
            npc_list[i] = try kv.value_ptr.toProto(arena, kv.key_ptr.*);
        }

        hall_scene_data.npc_list = npc_list;
        connection.write(pb.EnterSceneScNotify{ .scene = .{
            .scene_type = 1,
            .hall_scene_data = hall_scene_data,
        } }, 0) catch {};
    }

    for (player.sync.client_events.items) |client_event| {
        connection.write(pb.SectionEventScNotify{
            .section_id = player.hall.section_id,
            .action_list = client_event.actions.items,
        }, 0) catch {};
    }

    if (player.sync.hall_refresh) {
        const npc_list = try arena.alloc(pb.NpcInfo, player.active_npcs.count());
        var npcs = player.active_npcs.iterator();
        var i: usize = 0;
        while (npcs.next()) |kv| : (i += 1) {
            npc_list[i] = try kv.value_ptr.toProto(arena, kv.key_ptr.*);
        }

        connection.write(pb.HallRefreshScNotify{
            .force_refresh = true,
            .section_id = player.hall.section_id,
            .control_avatar_id = player.basic_info.control_avatar_id,
            .control_guise_avatar_id = player.basic_info.control_guise_avatar_id,
            .scene_time_in_minutes = player.hall.time_in_minutes,
            .day_of_week = player.hall.day_of_week,
            .npc_list = npc_list,
        }, 0) catch {};
    }
}

fn syncItems(arena: Allocator, player: *Player, notify: *pb.PlayerSyncScNotify) !void {
    inline for (Player.item_containers, Player.Sync.change_sets, player_sync_fields) |pair, chg, field| {
        const Type, const container_field = pair;
        _, const set_field = chg;
        _, const notify_fields = field;
        const notify_container, const notify_list, const PbItem = notify_fields;
        if (chg.@"0" != Type or field.@"0" != Type)
            @compileError("Player.item_containers, Player.Sync.change_sets, player_sync_fields are out of order!");

        const change_set = &@field(player.sync, @tagName(set_field));
        if (change_set.count() != 0) blk: {
            var ids = change_set.keyIterator();
            var list = try arena.alloc(PbItem, change_set.count());
            var i: usize = 0;
            while (ids.next()) |id| : (i += 1) {
                const item = @field(player, @tagName(container_field)).get(id.*) orelse break :blk;
                list[i] = try item.toProto(id.*, arena);
            }

            const container = &@field(notify, @tagName(notify_container));
            if (container.* == null) container.* = .default;
            @field(container.*.?, @tagName(notify_list)) = list;
        }
    }

    if (player.sync.materials_changed) {
        var material_list = try arena.alloc(pb.MaterialInfo, player.material_map.count());
        var i: usize = 0;
        var iterator = player.material_map.iterator();

        while (iterator.next()) |kv| : (i += 1) {
            material_list[i] = .{
                .id = kv.key_ptr.*,
                .count = kv.value_ptr.*,
            };
        }
        if (notify.item == null) {
            notify.item = .default;
        }
        notify.item.?.material_list = material_list;
    }
}
