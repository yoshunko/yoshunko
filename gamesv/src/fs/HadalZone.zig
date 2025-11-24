const HadalZone = @This();
const std = @import("std");
const pb = @import("proto").pb;
const templates = @import("../data/templates.zig");

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
