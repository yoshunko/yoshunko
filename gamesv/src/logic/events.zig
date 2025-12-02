const std = @import("std");
const EventGraphCollection = @import("../data/EventGraphCollection.zig");

pub const Login = struct {};

pub const Logout = struct {};

pub const StateFileModified = struct {
    path: []const u8,
    content: []const u8,

    pub fn basename(e: *const StateFileModified) []const u8 {
        return if (std.mem.findScalarLast(u8, e.path, '/')) |last_segment_begin|
            e.path[last_segment_begin + 1 ..]
        else
            e.path;
    }
};

pub const ReloadBasicInfo = struct {
    content: []const u8,
};

pub const ReloadHadalZone = struct {
    content: []const u8,
};

pub const ReloadHallInfo = struct {
    content: []const u8,
};

pub const ReloadAvatarData = struct {
    avatar_id: u32,
    content: []const u8,
};

pub const ReloadWeaponData = struct {
    weapon_uid: u32,
    content: []const u8,
};

pub const ReloadEquipData = struct {
    equip_uid: u32,
    content: []const u8,
};

pub const ReloadBuddyData = struct {
    buddy_id: u32,
    content: []const u8,
};

pub const BasicInfoModified = struct {};

pub const AvatarUnlocked = struct {
    avatar_id: u32,
};

pub const AvatarDataModified = struct {
    avatar_id: u32,
};

pub const WeaponDataModified = struct {
    weapon_uid: u32,
};

pub const EquipDataModified = struct {
    equip_uid: u32,
};

pub const BuddyDataModified = struct {
	buddy_id: u32,
};

pub const MaterialsModified = struct {};

pub const HadalZoneModified = struct {};

pub const GameModeTransition = struct {};

pub const StartEventGraph = struct {
    pub const EventType = enum {
        on_enter,
        on_interact,
    };

    type: EventGraphCollection.EventGraphType,
    event_graph_id: u32,
    entry_event: EventType,
};

pub const HallSectionSwitch = struct {
    section_id: u32,
    transform: ?[]const u8 = null,
};

pub const NpcModified = struct {
    npc_tag_id: u32,
};

pub const HallPositionChanged = struct {};

pub const HallRefresh = struct {};
