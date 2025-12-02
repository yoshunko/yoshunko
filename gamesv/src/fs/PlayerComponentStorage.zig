const PlayerComponentStorage = @This();
const std = @import("std");
const common = @import("common");
const Assets = @import("../data/Assets.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const FileSystem = common.FileSystem;

pub const PlayerUID = struct { uid: u32 };

fs: *FileSystem,
uid: PlayerUID,
basic: @import("../logic/component/player/PlayerBasicComponent.zig"),
avatar: @import("../logic/component/player/PlayerAvatarComponent.zig"),
item: @import("../logic/component/player/PlayerItemComponent.zig"),
buddy: @import("../logic/component/player/PlayerBuddyComponent.zig"),
hall: @import("../logic/component/player/PlayerHallComponent.zig"),
hadal_zone: @import("../logic/component/player/PlayerHadalZoneComponent.zig"),

pub fn init(gpa: Allocator, fs: *FileSystem, assets: *const Assets, player_uid: u32) !@This() {
    return .{
        .fs = fs,
        .uid = .{ .uid = player_uid },
        .basic = try .init(gpa, fs, player_uid),
        .avatar = try .init(gpa, fs, assets, player_uid),
        .item = try .init(gpa, fs, assets, player_uid),
        .buddy = try .init(gpa, fs, assets, player_uid),
        .hall = try .init(gpa, fs, player_uid),
        .hadal_zone = try .init(gpa, fs, player_uid),
    };
}

pub fn deinit(pcs: *PlayerComponentStorage, gpa: Allocator) void {
    pcs.basic.deinit(gpa);
    pcs.avatar.deinit(gpa);
    pcs.item.deinit(gpa);
    pcs.buddy.deinit(gpa);
    pcs.hall.deinit(gpa);
    pcs.hadal_zone.deinit(gpa);
}

pub fn hasComponent(comptime Component: type) bool {
    if (comptime std.meta.activeTag(@typeInfo(Component)) != .pointer) return null;

    const ComponentType = comptime std.meta.Child(Component);
    inline for (comptime std.meta.fields(PlayerComponentStorage)) |field| {
        if (field.type == ComponentType) {
            return true;
        }
    }

    return false;
}

pub inline fn extract(pcs: *PlayerComponentStorage, comptime Component: type) Component {
    if (comptime std.meta.activeTag(@typeInfo(Component)) != .pointer) return null;

    const ComponentType = comptime std.meta.Child(Component);
    inline for (comptime std.meta.fields(PlayerComponentStorage)) |field| {
        if (field.type == ComponentType) {
            return &@field(pcs, field.name);
        }
    }

    @compileError("no component of type '" ++ @typeName(Component) ++ "' in PlayerComponentStorage");
}
