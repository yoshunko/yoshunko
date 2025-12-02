const Dungeon = @This();
const std = @import("std");
const AvatarUnit = @import("AvatarUnit.zig");
const BuddyUnit = @import("BuddyUnit.zig");
const Allocator = std.mem.Allocator;

avatar_units: std.AutoArrayHashMapUnmanaged(u32, AvatarUnit) = .empty,
buddy_units: std.AutoArrayHashMapUnmanaged(u32, BuddyUnit) = .empty,
quest_type: u32,
quest_id: u32,

pub fn deinit(dungeon: *Dungeon, gpa: Allocator) void {
    dungeon.avatar_units.deinit(gpa);
    dungeon.buddy_units.deinit(gpa);
}
