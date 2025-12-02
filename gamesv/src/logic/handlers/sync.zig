const std = @import("std");
const Io = std.Io;
const pb = @import("proto").pb;
const Assets = @import("../../data/Assets.zig");
const Memory = @import("../../network/State.zig").Memory;
const EventQueue = @import("../EventQueue.zig");
const Connection = @import("../../network/Connection.zig");
const PlayerBasicComponent = @import("../component/player/PlayerBasicComponent.zig");
const PlayerAvatarComponent = @import("../component/player/PlayerAvatarComponent.zig");
const PlayerBuddyComponent = @import("../component/player/PlayerBuddyComponent.zig");
const PlayerItemComponent = @import("../component/player/PlayerItemComponent.zig");
const PlayerHadalZoneComponent = @import("../component/player/PlayerHadalZoneComponent.zig");

pub fn syncBasicInfo(
    _: EventQueue.Dequeue(.basic_info_modified),
    mem: Memory,
    basic_comp: *PlayerBasicComponent,
    notify: *pb.PlayerSyncScNotify,
) !void {
    notify.self_basic_info = try basic_comp.info.toProto(mem.arena);
}

pub fn syncAvatarData(
    event: EventQueue.Dequeue(.avatar_data_modified),
    mem: Memory,
    avatar_comp: *PlayerAvatarComponent,
    notify: *pb.PlayerSyncScNotify,
) !void {
    const avatar_sync = if (notify.avatar) |*sync| sync else blk: {
        notify.avatar = .{};
        break :blk &notify.avatar.?;
    };

    const avatar_id = event.data.avatar_id;
    const avatar = avatar_comp.avatar_map.getPtr(avatar_id) orelse return;
    try avatar_sync.avatar_list.append(mem.arena, try avatar.toProto(avatar_id, mem.arena));
}

pub fn syncBuddyData(
    event: EventQueue.Dequeue(.buddy_data_modified),
    mem: Memory,
    buddy_comp: *PlayerBuddyComponent,
    notify: *pb.PlayerSyncScNotify,
) !void {
    const buddy_sync = if (notify.buddy) |*sync| sync else blk: {
        notify.buddy = .{};
        break :blk &notify.buddy.?;
    };

    const buddy_id = event.data.buddy_id;
    const buddy = buddy_comp.buddy_map.getPtr(buddy_id) orelse return;
    try buddy_sync.buddy_list.append(mem.arena, try buddy.toProto(buddy_id, mem.arena));
}

pub fn sendAddAvatar(
    event: EventQueue.Dequeue(.avatar_unlocked),
    conn: *Connection,
) !void {
    conn.write(pb.AddAvatarScNotify{
        .avatar_id = event.data.avatar_id,
        .perform_type = 2,
    }, 0) catch {};
}

pub fn syncWeaponData(
    event: EventQueue.Dequeue(.weapon_data_modified),
    mem: Memory,
    item_comp: *PlayerItemComponent,
    notify: *pb.PlayerSyncScNotify,
) !void {
    const item_sync = if (notify.item) |*sync| sync else blk: {
        notify.item = .{};
        break :blk &notify.item.?;
    };

    const weapon_uid = event.data.weapon_uid;
    const weapon = item_comp.weapon_map.getPtr(weapon_uid) orelse return;
    try item_sync.weapon_list.append(mem.arena, try weapon.toProto(weapon_uid, mem.arena));
}

pub fn syncEquipData(
    event: EventQueue.Dequeue(.equip_data_modified),
    mem: Memory,
    item_comp: *PlayerItemComponent,
    notify: *pb.PlayerSyncScNotify,
) !void {
    const item_sync = if (notify.item) |*sync| sync else blk: {
        notify.item = .{};
        break :blk &notify.item.?;
    };

    const equip_uid = event.data.equip_uid;
    const equip = item_comp.equip_map.getPtr(equip_uid) orelse return;
    try item_sync.equip_list.append(mem.arena, try equip.toProto(equip_uid, mem.arena));
}

pub fn syncMaterialData(
    _: EventQueue.Dequeue(.materials_modified),
    mem: Memory,
    item_comp: *PlayerItemComponent,
    notify: *pb.PlayerSyncScNotify,
) !void {
    const item_sync = if (notify.item) |*sync| sync else blk: {
        notify.item = .{};
        break :blk &notify.item.?;
    };

    var material_list = try mem.arena.alloc(pb.MaterialInfo, item_comp.material_map.count());
    var i: usize = 0;
    var iterator = item_comp.material_map.iterator();

    while (iterator.next()) |kv| : (i += 1) {
        material_list[i] = .{
            .id = kv.key_ptr.*,
            .count = kv.value_ptr.*,
        };
    }

    item_sync.material_list = .fromOwnedSlice(material_list);
}

pub fn syncHadalZone(
    _: EventQueue.Dequeue(.hadal_zone_modified),
    mem: Memory,
    io: Io,
    assets: *const Assets,
    hadal_comp: *PlayerHadalZoneComponent,
    notify: *pb.PlayerSyncScNotify,
) !void {
    var entrance_list = try std.ArrayList(pb.HadalEntranceSync).initCapacity(mem.arena, hadal_comp.info.entrances.len);
    for (hadal_comp.info.entrances) |entrance| {
        const entrance_type = entrance.entranceType();
        entrance_list.appendAssumeCapacity(.{
            .entrance_id = entrance.id,
            .state = @enumFromInt(3), // :three:
            .cur_zone_record_sync = try hadal_comp.info.buildZoneRecord(
                io,
                mem.arena,
                assets,
                entrance_type,
                entrance.zone_id,
            ),
        });
    }

    notify.hadal_zone = .{ .sync_entrance_list = entrance_list };
}
