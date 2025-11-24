const HadalZone = @This();
const std = @import("std");
const pb = @import("proto").pb;
const Assets = @import("../data/Assets.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const default: @This() = .{
    .entrances = &.{
        .{ .id = 2, .zone_id = 61001 },
        .{ .id = 3, .zone_id = 61002 },
        .{ .id = 1, .zone_id = 620381 },
        .{ .id = 9, .zone_id = 69025 },
    },
};

entrances: []const Entrance,
saved_rooms: []SavedRoom = &.{},

pub fn deinit(hz: HadalZone, gpa: Allocator) void {
    std.zon.parse.free(gpa, hz);
}

pub const Entrance = struct {
    const constant_entrances: []const u32 = &.{ 2, 3 };

    id: u32,
    zone_id: u32,

    pub fn entranceType(entrance: Entrance) pb.EntranceType {
        return if (std.mem.findScalar(u32, constant_entrances, entrance.id) != null)
            .constant
        else
            .scheduled;
    }
};

pub const SavedRoom = struct {
    zone_id: u32,
    layer_index: u32,
    avatar_id_list: []const u32 = &.{},
    buddy_id: u32 = 0,
    layer_item_id: u32 = 0,
};

pub fn getOrCreateSavedRoom(hz: *HadalZone, gpa: Allocator, zone_id: u32, layer_index: u32) !*SavedRoom {
    for (hz.saved_rooms) |*room| {
        if (room.zone_id == zone_id and room.layer_index == layer_index)
            return room;
    } else {
        const new_list = try gpa.alloc(SavedRoom, hz.saved_rooms.len + 1);
        @memcpy(new_list[0..hz.saved_rooms.len], hz.saved_rooms);
        gpa.free(hz.saved_rooms);

        hz.saved_rooms = new_list;
        hz.saved_rooms[hz.saved_rooms.len - 1] = .{
            .zone_id = zone_id,
            .layer_index = layer_index,
        };

        return &hz.saved_rooms[hz.saved_rooms.len - 1];
    }
}

pub fn buildZoneRecord(
    hz: *const HadalZone,
    io: Io,
    arena: Allocator,
    assets: *const Assets,
    entrance_type: pb.EntranceType,
    zone_id: u32,
) !pb.ZoneRecord {
    var layer_record_list: std.ArrayList(pb.LayerRecord) = .empty;

    for (assets.templates.zone_info_template_tb.payload.data) |zone_template| {
        if (zone_template.zone_id != zone_id) continue;

        var layer_record: pb.LayerRecord = .{
            .layer_index = @intCast(zone_template.layer_index),
            .status = @enumFromInt(4),
        };

        for (hz.saved_rooms) |room| {
            if (room.zone_id == zone_id and room.layer_index == zone_template.layer_index) {
                layer_record.avatar_id_list = try arena.dupe(u32, room.avatar_id_list);
                layer_record.buddy_id = room.buddy_id;
                layer_record.layer_item_id = room.layer_item_id;
                break;
            }
        }

        try layer_record_list.append(arena, layer_record);
    }

    const timestamp = (try std.Io.Clock.real.now(io)).toSeconds();
    return .{
        .zone_id = zone_id,
        .layer_record_list = layer_record_list.items,
        .begin_timestamp = if (entrance_type == .scheduled)
            timestamp - (3600 * 24)
        else
            0,
        .end_timestamp = if (entrance_type == .scheduled)
            timestamp + (3600 * 24 * 14)
        else
            0,
    };
}
