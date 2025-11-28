const Player = @This();
const std = @import("std");
const proto = @import("proto");
const pb = proto.pb;
const common = @import("common");
const uid = @import("uid.zig");
const file_util = @import("file_util.zig");
const Assets = @import("../data/Assets.zig");

const Avatar = @import("Avatar.zig");
const Weapon = @import("Weapon.zig");
const Equip = @import("Equip.zig");
const Material = @import("Material.zig");
const Hall = @import("Hall.zig");
const HadalZone = @import("HadalZone.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const FileSystem = common.FileSystem;

const EventConfig = Assets.EventGraphCollection.EventConfig;

const log = std.log.scoped(.player);

pub const BasicInfo = struct {
    pub const default: @This() = .{};
    nickname: []const u8 = "ReversedRooms",
    level: u32 = 60,
    exp: u32 = 0,
    avatar_id: u32 = 2011,
    control_avatar_id: u32 = 2011,
    control_guise_avatar_id: u32 = 1431,

    pub fn deinit(info: BasicInfo, gpa: Allocator) void {
        std.zon.parse.free(gpa, info);
    }
};

pub const item_containers = .{
    .{ Avatar, .avatar_map },
    .{ Weapon, .weapon_map },
    .{ Equip, .equip_map },
};

sync: Sync = .{},
player_uid: u32,
basic_info: BasicInfo,
avatar_map: std.AutoArrayHashMapUnmanaged(u32, Avatar),
weapon_map: std.AutoArrayHashMapUnmanaged(u32, Weapon),
equip_map: std.AutoArrayHashMapUnmanaged(u32, Equip),
material_map: std.AutoArrayHashMapUnmanaged(u32, i32),
hall: Hall,
cur_section: ?Hall.Section = null,
active_npcs: std.AutoArrayHashMapUnmanaged(u32, Hall.Npc) = .empty,
hadal_zone: HadalZone,

pub const Sync = struct {
    fn HashSet(comptime T: type) type {
        return std.AutoHashMapUnmanaged(T, void);
    }

    pub const change_sets = .{
        .{ Avatar, .changed_avatars },
        .{ Weapon, .changed_weapons },
        .{ Equip, .changed_equips },
    };

    pub const ClientEvent = struct {
        arena: std.heap.ArenaAllocator,
        actions: std.ArrayList(pb.ActionInfo) = .empty,

        pub fn init(gpa: Allocator) ClientEvent {
            return .{ .arena = .init(gpa) };
        }

        pub fn deinit(event: *ClientEvent) void {
            event.arena.deinit();
        }

        pub fn add(event: *ClientEvent, id: u32, action_type: pb.ActionType, action: anytype) !void {
            const allocator = event.arena.allocator();

            const data = try action.toProto(allocator);
            var allocating = Io.Writer.Allocating.init(allocator);
            errdefer allocating.deinit();
            try proto.encodeMessage(&allocating.writer, data, proto.pb.desc_action);

            try event.actions.append(allocator, .{
                .action_id = id,
                .action_type = action_type,
                .body = allocating.written(),
            });
        }
    };

    basic_info_changed: bool = false,
    changed_avatars: HashSet(u32) = .empty,
    new_avatars: HashSet(u32) = .empty,
    changed_weapons: HashSet(u32) = .empty,
    changed_equips: HashSet(u32) = .empty,
    materials_changed: bool = false,
    in_scene_transition: bool = false,
    hall_refresh: bool = false,
    save_pos_in_main_city: bool = false,
    client_events: std.ArrayList(ClientEvent) = .empty,
    hadal_zone_changed: bool = false,

    pub fn reset(sync: *Sync) void {
        sync.basic_info_changed = false;
        sync.changed_avatars.clearRetainingCapacity();
        sync.new_avatars.clearRetainingCapacity();
        sync.changed_weapons.clearRetainingCapacity();
        sync.changed_equips.clearRetainingCapacity();
        sync.materials_changed = false;
        sync.in_scene_transition = false;
        sync.hall_refresh = false;
        sync.save_pos_in_main_city = false;
        sync.hadal_zone_changed = false;

        for (sync.client_events.items) |*event| event.deinit();
        sync.client_events.clearRetainingCapacity();
    }

    pub fn setChanges(sync: *Sync, comptime T: type, gpa: Allocator, unique_id: u32) !void {
        inline for (Sync.change_sets) |chg| {
            const Type, const set_field = chg;
            if (T == Type) {
                try @field(sync, @tagName(set_field)).put(gpa, unique_id, {});
                break;
            }
        }
    }
};

pub fn save(player: *const Player, arena: Allocator, fs: *FileSystem) !void {
    try player.saveStruct(player.sync.basic_info_changed, player.basic_info, "info", fs, arena);
    try player.saveStruct(player.sync.hadal_zone_changed, player.hadal_zone, "hadal_zone/info", fs, arena);
    try player.saveStruct(player.sync.in_scene_transition or player.sync.hall_refresh, player.hall, "hall/info", fs, arena);

    inline for (Player.item_containers, Sync.change_sets) |pair, chg| {
        const Type, const container_field = pair;
        _, const set_field = chg;
        if (chg.@"0" != Type) @compileError("Player.item_containers and Player.Sync.change_sets are out of order!");

        const change_set = &@field(player.sync, @tagName(set_field));
        if (change_set.count() != 0) {
            var ids = change_set.keyIterator();
            while (ids.next()) |id| {
                const item = @field(player, @tagName(container_field)).get(id.*) orelse continue;
                const item_zon = try file_util.serializeZon(arena, item);
                const save_path = try std.fmt.allocPrint(
                    arena,
                    "player/{}/{s}/{}",
                    .{ player.player_uid, Type.data_dir, id.* },
                );
                try fs.writeFile(save_path, item_zon);
            }
        }
    }

    if (player.sync.materials_changed) {
        try Material.saveAll(arena, fs, player.player_uid, &player.material_map);
    }

    if (player.sync.save_pos_in_main_city) {
        try player.saveHallSection(arena, fs);
    }
}

fn saveStruct(
    player: *const Player,
    condition: bool,
    data: anytype,
    comptime path: []const u8,
    fs: *FileSystem,
    arena: Allocator,
) !void {
    if (!condition) return;

    const serialized = try file_util.serializeZon(arena, data);
    const save_path = try std.fmt.allocPrint(arena, "player/{}/" ++ path, .{player.player_uid});
    try fs.writeFile(save_path, serialized);
}

pub fn reloadFile(
    player: *Player,
    gpa: Allocator,
    arena: Allocator,
    assets: *const Assets,
    fs: *FileSystem,
    file: FileSystem.Changes.File,
    base_dir: []const u8,
) !void {
    const content = try fs.readFile(arena, file.path) orelse return;
    const path = file.path[base_dir.len..];

    inline for (Player.item_containers) |pair| {
        const Type, const container_field = pair;

        if (std.mem.startsWith(u8, path, Type.data_dir ++ "/")) {
            const unique_id = std.fmt.parseInt(u32, file.basename(), 10) catch return;
            const new_value = try file_util.parseZon(Type, gpa, content);
            errdefer new_value.deinit(gpa);

            try player.sync.setChanges(Type, gpa, unique_id);

            const container = &@field(player, @tagName(container_field));
            if (container.getPtr(unique_id)) |ptr| {
                ptr.*.deinit(gpa);
                ptr.* = new_value;
            } else {
                try container.put(gpa, unique_id, new_value);

                if (Type == Avatar) try player.sync.new_avatars.put(gpa, unique_id, {});
            }

            break;
        }
    } else if (std.mem.eql(u8, path, "info")) {
        const new_basic_info = file_util.parseZon(BasicInfo, gpa, content) catch return;
        player.basic_info.deinit(gpa);
        player.basic_info = new_basic_info;
        player.sync.basic_info_changed = true;
    } else if (std.mem.eql(u8, path, "materials")) {
        const new_materials = try Material.loadAll(gpa, fs, null, player.player_uid);
        player.material_map.deinit(gpa);
        player.material_map = new_materials;
        player.sync.materials_changed = true;
    } else if (std.mem.eql(u8, path, "hall/info")) {
        var new_hall = try file_util.parseZon(Hall, gpa, content);

        if (new_hall.section_id != player.hall.section_id) {
            try player.triggerSwitchSection(gpa, assets, new_hall.section_id);
            new_hall.section_id = player.hall.section_id;
        } else player.sync.hall_refresh = true;

        player.hall.deinit(gpa);
        player.hall = new_hall;
    } else if (std.mem.startsWith(u8, path, "hall/")) {
        var base_path = std.mem.tokenizeScalar(u8, path["hall/".len..], '/');
        const section_id = std.fmt.parseInt(u32, base_path.next() orelse return, 10) catch return;
        if (player.hall.section_id != section_id) return;

        const npc_id = std.fmt.parseInt(u32, base_path.next() orelse return, 10) catch return;
        const new_npc = try file_util.parseZon(Hall.Npc, gpa, content);

        if (player.active_npcs.fetchSwapRemove(npc_id)) |*old_npc| {
            old_npc.value.deinit(gpa);
        }

        try player.active_npcs.put(gpa, npc_id, new_npc);
        player.sync.hall_refresh = true;
    } else if (std.mem.eql(u8, path, "hadal_zone/info")) {
        const new_hz = try file_util.parseZon(HadalZone, gpa, content);

        player.hadal_zone.deinit(gpa);
        player.hadal_zone = new_hz;
        player.sync.hadal_zone_changed = true;
    }
}

fn triggerSwitchSection(player: *Player, gpa: Allocator, assets: *const Assets, id: u32) !void {
    var client_event = Sync.ClientEvent.init(gpa);
    errdefer client_event.deinit();

    const transform_id = assets.templates.getSectionDefaultTransform(id) orelse {
        log.err("section with id {} doesn't exist", .{id});
        return;
    };

    try client_event.add(100, .switch_section, Assets.EventGraphCollection.ActionConfig.SwitchSection{
        .section_id = id,
        .transform_id = transform_id,
    });

    try player.sync.client_events.append(gpa, client_event);
}

pub fn loadOrCreate(gpa: Allocator, fs: *FileSystem, assets: *const Assets, player_uid: u32) !Player {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const basic_info = try file_util.loadOrCreateZon(BasicInfo, gpa, arena.allocator(), fs, "player/{}/info", .{player_uid});
    const avatar_map = try loadItems(Avatar, gpa, fs, assets, player_uid, false);
    const weapon_map = try loadItems(Weapon, gpa, fs, assets, player_uid, true);
    const equip_map = try loadItems(Equip, gpa, fs, assets, player_uid, true);
    const material_map = try Material.loadAll(gpa, fs, assets, player_uid);
    const hall = try file_util.loadOrCreateZon(Hall, gpa, arena.allocator(), fs, "player/{}/hall/info", .{player_uid});
    const hadal_zone = try file_util.loadOrCreateZon(HadalZone, gpa, arena.allocator(), fs, "player/{}/hadal_zone/info", .{player_uid});

    return .{
        .player_uid = player_uid,
        .basic_info = basic_info,
        .avatar_map = avatar_map,
        .weapon_map = weapon_map,
        .equip_map = equip_map,
        .material_map = material_map,
        .hall = hall,
        .hadal_zone = hadal_zone,
    };
}

pub fn performHallTransition(player: *Player, gpa: Allocator, fs: *FileSystem, assets: *const Assets) !void {
    const section = try player.getOrCreateHallSection(gpa, fs, assets, player.hall.section_id);

    if (player.cur_section) |prev_section| prev_section.deinit(gpa);
    player.cur_section = section;

    const new_npcs = try loadNpcs(gpa, fs, player.player_uid, player.hall.section_id);
    freeMap(gpa, &player.active_npcs);
    player.active_npcs = new_npcs;

    for (assets.graphs.main_city.sections) |section_cfg| {
        if (section_cfg.id != player.hall.section_id) continue;

        for (section_cfg.events) |event| {
            if (std.mem.findScalar(u32, section_cfg.on_enter, event.id) != null) {
                try player.runEvent(gpa, fs, assets, &event);
            }
        }

        break;
    }

    player.sync.in_scene_transition = true;
}

fn getOrCreateHallSection(player: *Player, gpa: Allocator, fs: *FileSystem, assets: *const Assets, id: u32) !Hall.Section {
    var temp_allocator = std.heap.ArenaAllocator.init(gpa);
    defer temp_allocator.deinit();
    const arena = temp_allocator.allocator();

    const section_path = try sectionPath(arena, player.player_uid, id);

    if (try fs.readFile(arena, section_path)) |content|
        return try file_util.parseZon(Hall.Section, gpa, content)
    else {
        const section_template = assets.templates.getConfigByKey(
            .section_config_template_tb,
            player.hall.section_id,
        ) orelse return error.InvalidSectionID;

        const section = try Hall.Section.createDefault(gpa, section_template);
        try fs.writeFile(section_path, try file_util.serializeZon(arena, section));

        return section;
    }
}

fn sectionPath(gpa: Allocator, player_uid: u32, section_id: u32) ![]u8 {
    return std.fmt.allocPrint(gpa, "player/{}/hall/{}/info", .{ player_uid, section_id });
}

fn saveHallSection(player: *const Player, arena: Allocator, fs: *FileSystem) !void {
    const section = player.cur_section orelse return;
    const section_path = try sectionPath(arena, player.player_uid, player.hall.section_id);
    try fs.writeFile(section_path, try file_util.serializeZon(arena, section));
}

pub fn interactWithUnit(player: *Player, gpa: Allocator, fs: *FileSystem, assets: *const Assets, npc_id: u32, interact_id: u32) !void {
    const npc = player.active_npcs.getPtr(npc_id) orelse return error.NoSuchUnit;
    if (npc.interacts[1] == null or npc.interacts[1].?.id != interact_id) return error.NoSuchInteract;
    const interact_graph = assets.graphs.interacts.get(interact_id) orelse return error.MissingInteractGraph;

    for (interact_graph.events) |event| {
        if (std.mem.findScalar(u32, interact_graph.on_interact, event.id) != null) {
            try player.runEvent(gpa, fs, assets, &event);
        }
    }
}

// TODO: move this somewhere out of Player?
pub fn runEvent(player: *Player, gpa: Allocator, fs: *FileSystem, assets: *const Assets, event: *const EventConfig) !void {
    var temp_allocator = std.heap.ArenaAllocator.init(gpa);
    defer temp_allocator.deinit();
    const arena = temp_allocator.allocator();

    for (event.actions) |action| {
        switch (action.action) {
            .create_npc => |config| {
                const template = assets.templates.getConfigByKey(.main_city_object_template_tb, config.tag_id) orelse {
                    log.err("missing config for npc with tag {}", .{config.tag_id});
                    continue;
                };

                var npc: Hall.Npc = .{};

                if (template.default_interact_ids.len != 0) {
                    const participators = try gpa.alloc(Hall.Interact.Participator, 1);
                    participators[0] = .{ .id = 102201, .name = try gpa.dupe(u8, "A") };
                    npc.interacts[1] = .{
                        .name = try gpa.dupe(u8, template.interact_name),
                        .scale = @splat(1),
                        .tag_id = config.tag_id,
                        .participators = participators,
                        .id = template.default_interact_ids[0],
                    };
                }

                try saveNpc(arena, fs, player.player_uid, player.hall.section_id, config.tag_id, npc);
                try player.active_npcs.put(gpa, config.tag_id, npc);
            },
            .change_interact => |config| {
                for (config.tag_ids) |tag_id| {
                    const npc = player.active_npcs.getPtr(tag_id) orelse continue;
                    const template = assets.templates.getConfigByKey(.main_city_object_template_tb, tag_id) orelse {
                        log.err("missing config for npc with tag {}", .{tag_id});
                        continue;
                    };

                    if (npc.interacts[1]) |*interact| interact.deinit(gpa);

                    const participators = try gpa.alloc(Hall.Interact.Participator, 1);
                    participators[0] = .{ .id = 102201, .name = try gpa.dupe(u8, "A") };
                    npc.interacts[1] = .{
                        .name = try gpa.dupe(u8, template.interact_name),
                        .scale = @splat(1),
                        .tag_id = tag_id,
                        .participators = participators,
                        .id = config.interact_id,
                    };

                    try saveNpc(arena, fs, player.player_uid, player.hall.section_id, tag_id, npc.*);
                }
            },
            else => {},
        }

        switch (action.action) {
            inline else => |config| {
                if (@hasDecl(@TypeOf(config), "toProto")) {
                    var client_event = Sync.ClientEvent.init(gpa);
                    errdefer client_event.deinit();

                    try client_event.add(action.id, @enumFromInt(@intFromEnum(action.action)), config);
                    try player.sync.client_events.append(gpa, client_event);
                }
            },
        }
    }
}

fn saveNpc(arena: Allocator, fs: *FileSystem, player_uid: u32, section_id: u32, npc_id: u32, npc: Hall.Npc) !void {
    const npc_zon = try file_util.serializeZon(arena, npc);
    const npc_path = try std.fmt.allocPrint(
        arena,
        "player/{}/hall/{}/{}",
        .{ player_uid, section_id, npc_id },
    );
    try fs.writeFile(npc_path, npc_zon);
}

fn loadNpcs(gpa: Allocator, fs: *FileSystem, player_uid: u32, section_id: u32) !std.AutoArrayHashMapUnmanaged(u32, Hall.Npc) {
    var temp_allocator = std.heap.ArenaAllocator.init(gpa);
    defer temp_allocator.deinit();
    const arena = temp_allocator.allocator();

    var map: std.AutoArrayHashMapUnmanaged(u32, Hall.Npc) = .empty;
    errdefer freeMap(gpa, &map);

    const section_dir = try std.fmt.allocPrint(arena, "player/{}/hall/{}", .{ player_uid, section_id });
    if (try fs.readDir(section_dir)) |dir| {
        defer dir.deinit();

        for (dir.entries) |entry| if (entry.kind == .file) {
            const tag_id = std.fmt.parseInt(u32, entry.basename(), 10) catch continue;
            const npc = file_util.loadZon(Hall.Npc, gpa, arena, fs, "player/{}/hall/{}/{}", .{ player_uid, section_id, tag_id }) catch {
                log.err("failed to load NPC with id {} from section {}", .{ tag_id, section_id });
                continue;
            } orelse continue;

            try map.put(gpa, tag_id, npc);
        };
    }

    return map;
}

fn loadItems(
    comptime Item: type,
    gpa: Allocator,
    fs: *FileSystem,
    assets: *const Assets,
    player_uid: u32,
    comptime uses_incr_uid: bool,
) !std.AutoArrayHashMapUnmanaged(u32, Item) {
    var map: std.AutoArrayHashMapUnmanaged(u32, Item) = .empty;
    errdefer freeMap(gpa, &map);

    var temp_allocator = std.heap.ArenaAllocator.init(gpa);
    defer temp_allocator.deinit();
    const arena = temp_allocator.allocator();

    const data_dir_path = try std.fmt.allocPrint(arena, "player/{}/{s}", .{ player_uid, Item.data_dir });
    if (try fs.readDir(data_dir_path)) |dir| {
        defer dir.deinit();

        for (dir.entries) |entry| if (entry.kind == .file) {
            const unique_id = std.fmt.parseInt(u32, entry.basename(), 10) catch continue;
            const item = file_util.loadZon(Item, gpa, arena, fs, "player/{}/{s}/{}", .{ player_uid, Item.data_dir, unique_id }) catch {
                log.err("failed to load {s} with id {}", .{ @typeName(Item), unique_id });
                continue;
            } orelse continue;

            try map.put(gpa, unique_id, item);
        };
    } else {
        try Item.addDefaults(gpa, assets, &map);

        var iterator = map.iterator();
        var highest_uid: u32 = 0;
        while (iterator.next()) |kv| {
            highest_uid = @max(kv.key_ptr.*, highest_uid);

            try fs.writeFile(
                try std.fmt.allocPrint(arena, "player/{}/{s}/{}", .{ player_uid, Item.data_dir, kv.key_ptr.* }),
                try file_util.serializeZon(arena, kv.value_ptr.*),
            );
        }

        if (uses_incr_uid) {
            const counter_path = try std.fmt.allocPrint(arena, "player/{}/{s}/next", .{ player_uid, Item.data_dir });

            var print_buf: [32]u8 = undefined;
            try fs.writeFile(counter_path, try std.fmt.bufPrint(print_buf[0..], "{}", .{highest_uid + 1}));
        }
    }

    return map;
}

pub fn deinit(player: *Player, gpa: Allocator) void {
    player.basic_info.deinit(gpa);
    freeMap(gpa, &player.avatar_map);
    freeMap(gpa, &player.weapon_map);
    freeMap(gpa, &player.equip_map);
    player.material_map.deinit(gpa);
    freeMap(gpa, &player.active_npcs);
}

fn freeMap(gpa: Allocator, map: anytype) void {
    var iterator = map.iterator();
    while (iterator.next()) |kv| {
        kv.value_ptr.deinit(gpa);
    }

    map.deinit(gpa);
}

pub fn buildBasicInfoProto(player: *const Player, arena: Allocator) !pb.SelfBasicInfo {
    return .{
        .level = player.basic_info.level,
        .nick_name = try arena.dupe(u8, player.basic_info.nickname),
        .avatar_id = player.basic_info.avatar_id,
        .control_avatar_id = player.basic_info.control_avatar_id,
        .control_guise_avatar_id = player.basic_info.control_guise_avatar_id,
        .name_change_times = 1, // TODO
    };
}
