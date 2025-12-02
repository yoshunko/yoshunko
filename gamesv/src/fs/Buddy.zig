const Buddy = @This();
const std = @import("std");
const pb = @import("proto").pb;
const Assets = @import("../data/Assets.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const max_level: u32 = 60;
pub const max_rank: u32 = 6;

pub const data_dir: []const u8 = "buddy";
pub const default: Buddy = .{};
level: u32 = max_level,
exp: u32 = 0,
rank: u32 = max_rank,
star: u32 = 1,
skill_type_level: [SkillLevel.Type.count]SkillLevel = init_skills: {
    var skills: [SkillLevel.Type.count]SkillLevel = undefined;
    for (0..SkillLevel.Type.count, 2..) |i, t| {
        skills[i] = .init(@enumFromInt(t));
    }

    break :init_skills skills;
},
is_favorite: bool = false,

pub fn deinit(buddy: Buddy, gpa: Allocator) void {
    std.zon.parse.free(gpa, buddy);
}

pub fn toProto(buddy: *const Buddy, id: u32, allocator: Allocator) !pb.BuddyInfo {
    var buddy_info: pb.BuddyInfo = .{
        .id = id,
        .level = buddy.level,
        .exp = buddy.exp,
        .rank = buddy.rank,
        .star = buddy.star,
        .is_favorite = buddy.is_favorite,
    };

    try buddy_info.skill_type_level.ensureTotalCapacity(allocator, buddy.skill_type_level.len);
    for (buddy.skill_type_level) |skill| {
        buddy_info.skill_type_level.appendAssumeCapacity(.{
            .skill_type = @intFromEnum(skill.type),
            .level = skill.level,
        });
    }

    return buddy_info;
}

pub const SkillLevel = struct {
    type: Type,
    level: u32,

    pub fn init(ty: Type) SkillLevel {
        return .{
            .type = ty,
            .level = ty.getMaxLevel(),
        };
    }

    pub const Type = enum(u32) {
        pub const count: usize = @typeInfo(@This()).@"enum".fields.len;

        manual = 2,
        passive = 3,
        qte = 4,
        aid = 5,

        pub fn getMaxLevel(self: @This()) u32 {
            return switch (self) {
                .passive => 5,
                else => 8,
            };
        }
    };
};

pub fn addDefaults(gpa: Allocator, assets: *const Assets, map: *std.AutoArrayHashMapUnmanaged(u32, Buddy)) !void {
    for (assets.templates.buddy_base_template_tb.payload.data) |template| {
        if (template.id < 55_000) try map.put(gpa, template.id, .default);
    }
}
