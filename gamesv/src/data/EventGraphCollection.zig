const EventGraphCollection = @This();
const std = @import("std");
const pb = @import("proto").pb;
pub const templates = @import("templates.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.graph_collection);

const level_process_dir = "assets/LevelProcess/";
const main_city_config_path = level_process_dir ++ "MainCity/MainCity.zon";
const interact_config_path = level_process_dir ++ "MainCity/Interact";

main_city: MainCity,
interacts: std.AutoArrayHashMapUnmanaged(u32, EventGraph),

pub const MainCity = struct {
    sections: []const EventGraph,
};

pub const EventGraph = struct {
    id: u32,
    on_enter: []const u32 = &.{},
    on_interact: []const u32 = &.{},
    events: []const EventConfig = &.{},
};

pub const EventConfig = struct {
    id: u32,
    actions: []const EventActionConfig,
};

pub const EventActionConfig = struct {
    id: u32,
    action: ActionConfig,
    predicates: []const PredicateConfig = &.{},
};

pub const ActionType = enum(i32) {
    open_ui = 5,
    switch_section = 6,
    create_npc = 3001,
    change_interact = 3003,
};

pub const ActionConfig = union(ActionType) {
    pub const OpenUI = struct {
        ui: []const u8,
        store_template_id: i32,

        pub fn toProto(action: OpenUI, _: Allocator) !pb.ActionOpenUI {
            return .{
                .ui = action.ui,
                .store_template_id = action.store_template_id,
            };
        }
    };

    pub const SwitchSection = struct {
        section_id: u32,
        transform_id: []const u8,
        camera_x: u32 = 0,
        camera_y: u32 = 0,

        pub fn toProto(action: SwitchSection, _: Allocator) !pb.ActionSwitchSection {
            return .{
                .section_id = action.section_id,
                .transform_id = action.transform_id,
                .camera_x = action.camera_x,
                .camera_y = action.camera_y,
            };
        }
    };

    pub const CreateNpc = struct {
        tag_id: u32,
    };

    pub const ChangeInteract = struct {
        tag_ids: []const u32,
        interact_id: u32,
    };

    open_ui: OpenUI,
    switch_section: SwitchSection,
    create_npc: CreateNpc,
    change_interact: ChangeInteract,
};

pub const PredicateConfig = union(enum) {
    pub const ByMainCharacter = struct {
        character_id: u32,
    };

    by_main_character: ByMainCharacter,
};

pub fn load(gpa: Allocator, io: Io) !EventGraphCollection {
    return .{
        .main_city = try readAndParse(MainCity, io, gpa, Io.Dir.cwd(), main_city_config_path),
        .interacts = try readDirAsMap(EventGraph, io, gpa, interact_config_path),
    };
}

pub fn deinit(collection: *EventGraphCollection, gpa: Allocator) void {
    std.zon.parse.free(gpa, collection.main_city);
}

fn readAndParse(comptime T: type, io: Io, gpa: Allocator, dir: Io.Dir, sub_path: []const u8) !T {
    var file = try dir.openFile(io, sub_path, .{});
    defer file.close(io);

    var reader = file.reader(io, "");
    const content = try reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(content);

    var diagnostics: std.zon.parse.Diagnostics = .{};
    defer diagnostics.deinit(gpa);

    return std.zon.parse.fromSliceAlloc(T, gpa, @ptrCast(content), &diagnostics, .{}) catch {
        log.err("failed to parse {s}:\n{f}", .{ @typeName(T), diagnostics });
        return error.ParseFailed;
    };
}

fn readDirAsMap(comptime T: type, io: Io, gpa: Allocator, path: []const u8) !std.AutoArrayHashMapUnmanaged(u32, T) {
    const dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    const deprecated_dir = std.fs.Dir.adaptFromNewApi(dir);
    var walker = try deprecated_dir.walk(gpa);
    defer walker.deinit();

    var map: std.AutoArrayHashMapUnmanaged(u32, T) = .empty;
    errdefer {
        var iterator = map.iterator();
        while (iterator.next()) |kv| std.zon.parse.free(gpa, kv.value_ptr.*);
        map.deinit(gpa);
    }

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const item = readAndParse(T, io, gpa, dir, entry.path) catch continue;
        errdefer std.zon.parse.free(gpa, item);

        try map.put(gpa, item.id, item);
    }

    return map;
}
