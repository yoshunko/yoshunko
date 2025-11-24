const std = @import("std");
const pb = @import("proto").pb;
const network = @import("../network.zig");
const Player = @import("../fs/Player.zig");
const Hall = @import("../fs/Hall.zig");

pub fn onGetHadalZoneDataCsReq(context: *network.Context, _: pb.GetHadalZoneDataCsReq) !void {
    errdefer context.respond(pb.GetHadalZoneDataScRsp{ .retcode = 1 }) catch {};
    const player = try context.connection.getPlayer();

    const entrance_list = try context.arena.alloc(pb.HadalEntranceInfo, player.hadal_zone.entrances.len);
    for (player.hadal_zone.entrances, 0..) |entrance, i| {
        const entrance_type = entrance.entranceType();
        entrance_list[i] = .{
            .entrance_type = entrance_type,
            .entrance_id = entrance.id,
            .state = @enumFromInt(3), // :three:
            .cur_zone_record = try player.hadal_zone.buildZoneRecord(
                context.io,
                context.arena,
                context.connection.assets,
                entrance_type,
                entrance.zone_id,
            ),
        };
    }

    try context.respond(pb.GetHadalZoneDataScRsp{
        .retcode = 0,
        .hadal_entrance_list = entrance_list,
    });
}

pub fn onSetupHadalZoneRoomCsReq(context: *network.Context, request: pb.SetupHadalZoneRoomCsReq) !void {
    var retcode: i32 = 1;
    defer context.respond(pb.SetupHadalZoneRoomScRsp{ .retcode = retcode }) catch {};
    defer if (retcode == 0) context.connection.flushSync(context.arena, context.io) catch {};
    const player = try context.connection.getPlayer();

    for (request.layer_setup_list) |setup| {
        const room = try player.hadal_zone.getOrCreateSavedRoom(context.gpa, request.zone_id, setup.layer_index);

        if (setup.layer_item_id != 0) {
            room.layer_item_id = setup.layer_item_id;
        }

        const new_avatar_list = try context.gpa.dupe(u32, setup.avatar_id_list);
        context.gpa.free(room.avatar_id_list);
        room.avatar_id_list = new_avatar_list;
        room.buddy_id = setup.buddy_id;
    }

    player.sync.hadal_zone_changed = true;
    retcode = 0;
}
