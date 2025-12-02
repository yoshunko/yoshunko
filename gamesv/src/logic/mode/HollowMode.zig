const HollowMode = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

battle_event_id: u32,
enemy_property_scale: u32 = 0,
play_type: LocalPlayType,
avatar_ids: []const []const u32,
buddy_ids: []const u32,
scene_data: SceneData,

pub fn deinit(mode: *HollowMode, gpa: Allocator) void {
    for (mode.avatar_ids) |list| gpa.free(list);
    gpa.free(mode.avatar_ids);
    gpa.free(mode.buddy_ids);
}

pub const SceneData = union(enum) {
    fight: FightScene,
    hadal_zone: HadalZoneScene,
};

pub const FightScene = struct {};

pub const HadalZoneScene = struct {
    zone_id: u32,
    room_index: u32,
    layer_index: u32,
    layer_item_id: u32,
};

pub const LocalPlayType = enum(u32) {
    unkown = 0,
    archive_battle = 201,
    chess_board_battle = 202,
    guide_special = 203,
    chess_board_longfihgt_battle = 204,
    level_zero = 205,
    daily_challenge = 206,
    rally_long_fight = 207,
    dual_elite = 208,
    hadal_zone = 209,
    boss_battle = 210,
    big_boss_battle = 211,
    archive_long_fight = 212,
    avatar_demo_trial = 213,
    mp_big_boss_battle = 214,
    boss_little_battle_longfight = 215,
    operation_beta_demo = 216,
    big_boss_battle_longfight = 217,
    boss_rush_battle = 218,
    operation_team_coop = 219,
    boss_nest_hard_battle = 220,
    side_scrolling_thegun_battle = 221,
    hadal_zone_alivecount = 222,
    babel_tower = 223,
    hadal_zone_bosschallenge = 224,
    s2_rogue_battle = 226,
    buddy_towerdefense_battle = 227,
    mini_scape_battle = 228,
    mini_scape_short_battle = 229,
    activity_combat_pause = 230,
    coin_brushing_battle = 231,
    turn_based_battle = 232,
    bangboo_royale = 240,
    side_scrolling_captain = 241,
    smash_bro = 242,
    pure_hollow_battle = 280,
    pure_hollow_battle_longhfight = 281,
    pure_hollow_battle_hardmode = 282,
    training_room = 290,
    map_challenge_battle = 291,
    training_root_tactics = 292,
    bangboo_dream_rogue_battle = 293,
    target_shooting_battle = 294,
    bangboo_autobattle = 295,
    mechboo_battle = 296,
    summer_surfing = 297,
    summer_shooting = 298,
    void_front_battle_boss = 299,
    void_front_battle = 300,
    void_front_buff_battle = 301,
    activity_combat_pause_annihilate = 302,
    hadal_zone_impact_battle = 303,
    mechboo_battlev2 = 304,
    operation_team_coop_stylish = 305,
};
