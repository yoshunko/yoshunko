const PlayerBuddyComponent = @This();
const std = @import("std");
const comp_util = @import("../comp_util.zig");
const Buddy = @import("../../../fs/Buddy.zig");
const Assets = @import("../../../data/Assets.zig");
const Allocator = std.mem.Allocator;
const FileSystem = @import("common").FileSystem;

player_uid: u32,
buddy_map: std.AutoArrayHashMapUnmanaged(u32, Buddy) = .empty,

pub fn init(gpa: Allocator, fs: *FileSystem, assets: *const Assets, player_uid: u32) !PlayerBuddyComponent {
    return .{
        .player_uid = player_uid,
        .buddy_map = try comp_util.loadItems(Buddy, gpa, fs, assets, player_uid, false),
    };
}

pub fn deinit(comp: *PlayerBuddyComponent, gpa: Allocator) void {
    comp_util.freeMap(gpa, &comp.buddy_map);
}
