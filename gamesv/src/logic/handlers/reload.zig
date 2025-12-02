const std = @import("std");
const Io = std.Io;
const proto = @import("proto");
const pb = proto.pb;
const Assets = @import("../../data/Assets.zig");
const Memory = @import("../../network/State.zig").Memory;
const EventQueue = @import("../EventQueue.zig");
const PlayerBasicComponent = @import("../component/player/PlayerBasicComponent.zig");
const PlayerItemComponent = @import("../component/player/PlayerItemComponent.zig");
const PlayerAvatarComponent = @import("../component/player/PlayerAvatarComponent.zig");
const PlayerBuddyComponent = @import("../component/player/PlayerBuddyComponent.zig");
const PlayerHallComponent = @import("../component/player/PlayerHallComponent.zig");
const PlayerHadalZoneComponent = @import("../component/player/PlayerHadalZoneComponent.zig");
const comp_util = @import("../component/comp_util.zig");
const file_util = @import("../../fs/file_util.zig");
const Avatar = @import("../../fs/Avatar.zig");
const Weapon = @import("../../fs/Weapon.zig");
const Equip = @import("../../fs/Equip.zig");
const Buddy = @import("../../fs/Buddy.zig");
const Hall = @import("../../fs/Hall.zig");
const FileSystem = @import("common").FileSystem;
const Connection = @import("../../network/Connection.zig");

pub fn onStateFileModified(event: EventQueue.Dequeue(.state_file_modified), events: *EventQueue) !void {
    if (std.mem.eql(u8, event.data.path, "info")) {
        try events.enqueue(.reload_basic_info, .{ .content = event.data.content });
    } else if (std.mem.eql(u8, event.data.path, "hadal_zone/info")) {
        try events.enqueue(.reload_hadal_zone, .{ .content = event.data.content });
    } else if (std.mem.eql(u8, event.data.path, "hall/info")) {
        try events.enqueue(.reload_hall_info, .{ .content = event.data.content });
    } else if (std.mem.startsWith(u8, event.data.path, "avatar/")) {
        const unique_id = std.fmt.parseInt(u32, event.data.basename(), 10) catch return;
        try events.enqueue(.reload_avatar_data, .{
            .content = event.data.content,
            .avatar_id = unique_id,
        });
    } else if (std.mem.startsWith(u8, event.data.path, "weapon/")) {
        const unique_id = std.fmt.parseInt(u32, event.data.basename(), 10) catch return;
        try events.enqueue(.reload_weapon_data, .{
            .content = event.data.content,
            .weapon_uid = unique_id,
        });
    } else if (std.mem.startsWith(u8, event.data.path, "equip/")) {
        const unique_id = std.fmt.parseInt(u32, event.data.basename(), 10) catch return;
        try events.enqueue(.reload_equip_data, .{
            .content = event.data.content,
            .equip_uid = unique_id,
        });
    } else if (std.mem.startsWith(u8, event.data.path, "buddy/")) {
        const unique_id = std.fmt.parseInt(u32, event.data.basename(), 10) catch return;
        try events.enqueue(.reload_buddy_data, .{
            .content = event.data.content,
            .buddy_id = unique_id,
        });
    }
}

pub fn reloadBasicInfo(
    event: EventQueue.Dequeue(.reload_basic_info),
    events: *EventQueue,
    mem: Memory,
    basic_comp: *PlayerBasicComponent,
) !void {
    try basic_comp.reload(mem.gpa, event.data.content);
    try events.enqueue(.basic_info_modified, .{});
}

pub fn reloadHadalZone(
    event: EventQueue.Dequeue(.reload_hadal_zone),
    events: *EventQueue,
    mem: Memory,
    hadal_comp: *PlayerHadalZoneComponent,
) !void {
    try hadal_comp.reload(mem.gpa, event.data.content);
    try events.enqueue(.hadal_zone_modified, .{});
}

pub fn reloadHallInfo(
    event: EventQueue.Dequeue(.reload_hall_info),
    events: *EventQueue,
    hall_comp: *PlayerHallComponent,
    mem: Memory,
    conn: *Connection,
    assets: *const Assets,
) !void {
    const new_hall_info = file_util.parseZon(Hall, mem.gpa, event.data.content) catch return;
    errdefer new_hall_info.deinit(mem.gpa);

    if (new_hall_info.section_id != hall_comp.info.section_id) {
        // TODO: remove this hack once we implement a stateful 'LevelEventGraphManager'
        var actions_buf: [1]pb.ActionInfo = undefined;
        var actions = std.ArrayList(pb.ActionInfo).initBuffer(actions_buf[0..]);

        const transform_id = assets.templates.getSectionDefaultTransform(
            new_hall_info.section_id,
        ) orelse return error.InvalidSectionID;

        var allocating = std.Io.Writer.Allocating.init(mem.arena);
        try proto.encodeMessage(&allocating.writer, pb.ActionSwitchSection{
            .section_id = new_hall_info.section_id,
            .transform_id = transform_id,
        }, proto.pb.desc_action);

        actions.appendAssumeCapacity(.{
            .action_type = .switch_section,
            .body = allocating.written(),
        });

        conn.write(pb.SectionEventScNotify{
            .section_id = hall_comp.info.section_id,
            .action_list = actions,
        }, 0) catch {};
    } else {
        try events.enqueue(.hall_refresh, .{});
    }

    hall_comp.info.deinit(mem.gpa);
    hall_comp.info = new_hall_info;
}

pub fn reloadAvatarData(
    event: EventQueue.Dequeue(.reload_avatar_data),
    events: *EventQueue,
    mem: Memory,
    avatar_comp: *PlayerAvatarComponent,
) !void {
    const new_avatar = file_util.parseZon(Avatar, mem.gpa, event.data.content) catch return;
    if (avatar_comp.avatar_map.getPtr(event.data.avatar_id)) |avatar| {
        avatar.*.deinit(mem.gpa);
        avatar.* = new_avatar;
    } else {
        try avatar_comp.avatar_map.put(mem.gpa, event.data.avatar_id, new_avatar);
        try events.enqueue(.avatar_unlocked, .{ .avatar_id = event.data.avatar_id });
    }

    try events.enqueue(.avatar_data_modified, .{ .avatar_id = event.data.avatar_id });
}

pub fn reloadBuddyData(
    event: EventQueue.Dequeue(.reload_buddy_data),
    events: *EventQueue,
    mem: Memory,
    buddy_comp: *PlayerBuddyComponent,
) !void {
    const new_buddy = file_util.parseZon(Buddy, mem.gpa, event.data.content) catch return;
    if (buddy_comp.buddy_map.getPtr(event.data.buddy_id)) |buddy| {
        buddy.*.deinit(mem.gpa);
        buddy.* = new_buddy;
    } else try buddy_comp.buddy_map.put(mem.gpa, event.data.buddy_id, new_buddy);

    try events.enqueue(.buddy_data_modified, .{ .buddy_id = event.data.buddy_id });
}

pub fn reloadWeaponData(
    event: EventQueue.Dequeue(.reload_weapon_data),
    events: *EventQueue,
    mem: Memory,
    item_comp: *PlayerItemComponent,
) !void {
    const new_weapon = file_util.parseZon(Weapon, mem.gpa, event.data.content) catch return;
    if (item_comp.weapon_map.getPtr(event.data.weapon_uid)) |weapon| {
        weapon.*.deinit(mem.gpa);
        weapon.* = new_weapon;
    } else {
        try item_comp.weapon_map.put(mem.gpa, event.data.weapon_uid, new_weapon);
    }

    try events.enqueue(.weapon_data_modified, .{ .weapon_uid = event.data.weapon_uid });
}

pub fn reloadEquipData(
    event: EventQueue.Dequeue(.reload_equip_data),
    events: *EventQueue,
    mem: Memory,
    item_comp: *PlayerItemComponent,
) !void {
    const new_equip = file_util.parseZon(Equip, mem.gpa, event.data.content) catch return;
    if (item_comp.equip_map.getPtr(event.data.equip_uid)) |equip| {
        equip.*.deinit(mem.gpa);
        equip.* = new_equip;
    } else {
        try item_comp.equip_map.put(mem.gpa, event.data.equip_uid, new_equip);
    }

    try events.enqueue(.equip_data_modified, .{ .equip_uid = event.data.equip_uid });
}
