const std = @import("std");
const pb = @import("proto").pb;
const network = @import("../network.zig");
const Player = @import("../fs/Player.zig");
const Hall = @import("../fs/Hall.zig");

pub fn onEnterWorldCsReq(context: *network.Context, _: pb.EnterWorldCsReq) !void {
    var retcode: i32 = 1;
    defer context.respond(pb.EnterWorldScRsp{ .retcode = retcode }) catch {};
    defer if (retcode == 0) context.connection.flushSync(context.arena, context.io) catch {};

    const player = try context.connection.getPlayer();
    try switchSection(context, player);

    retcode = 0;
}

pub fn onEnterSectionCompleteCsReq(context: *network.Context, _: pb.EnterSectionCompleteCsReq) !void {
    try context.respond(pb.EnterSectionCompleteScRsp{});
}

pub fn onLeaveCurSceneCsReq(context: *network.Context, _: pb.LeaveCurSceneCsReq) !void {
    var retcode: i32 = 1;
    defer context.respond(pb.LeaveCurSceneScRsp{ .retcode = retcode }) catch {};
    defer if (retcode == 0) context.connection.flushSync(context.arena, context.io) catch {};

    const player = try context.connection.getPlayer();
    try switchSection(context, player);

    retcode = 0;
}

pub fn onEnterSectionCsReq(context: *network.Context, request: pb.EnterSectionCsReq) !void {
    var retcode: i32 = 1;
    defer context.respond(pb.EnterSectionScRsp{ .retcode = retcode }) catch {};
    defer if (retcode == 0) context.connection.flushSync(context.arena, context.io) catch {};

    const player = try context.connection.getPlayer();
    player.hall.section_id = request.section_id;

    try switchSection(context, player);
    retcode = 0;
}

fn switchSection(context: *network.Context, player: *Player) !void {
    const log = std.log.scoped(.section_switch);

    player.performHallTransition(context.gpa, context.fs, context.connection.assets) catch |err| switch (err) {
        error.InvalidSectionID => {
            log.err(
                "section id {} is invalid, falling back to default section ({})",
                .{ player.hall.section_id, Hall.default_section_id },
            );
            player.hall.section_id = Hall.default_section_id;
            try player.performHallTransition(context.gpa, context.fs, context.connection.assets);
        },
        else => return err,
    };
}

pub fn onInteractWithUnitCsReq(context: *network.Context, request: pb.InteractWithUnitCsReq) !void {
    var retcode: i32 = 1;
    defer context.respond(pb.InteractWithUnitScRsp{ .retcode = retcode }) catch {};
    defer if (retcode == 0) context.connection.flushSync(context.arena, context.io) catch {};

    const player = try context.connection.getPlayer();
    try player.interactWithUnit(
        context.gpa,
        context.fs,
        context.connection.assets,
        @intCast(request.npc_tag_id),
        @intCast(request.interact_id),
    );

    retcode = 0;
}
