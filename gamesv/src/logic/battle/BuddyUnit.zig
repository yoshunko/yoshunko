const BuddyUnit = @This();
const std = @import("std");
const property_util = @import("../property_util.zig");
const PropertyType = property_util.PropertyType;
const Allocator = std.mem.Allocator;
const pb = @import("proto").pb;

pub const assisting_buddy_id: u32 = 50001;

type: pb.BuddyUnitType,
properties: std.AutoArrayHashMapUnmanaged(PropertyType, i32) = .empty,

pub fn deinit(unit: *BuddyUnit, gpa: Allocator) void {
    unit.properties.deinit(gpa);
}

pub fn toProto(unit: *const BuddyUnit, arena: Allocator, id: u32) !pb.BuddyUnitInfo {
    var info: pb.BuddyUnitInfo = .{
        .buddy_id = id,
        .type = unit.type,
    };

    var properties = unit.properties.iterator();
    while (properties.next()) |kv| {
        try info.properties.append(arena, .{
            .key = @intFromEnum(kv.key_ptr.*),
            .value = kv.value_ptr.*,
        });
    }

    return info;
}
