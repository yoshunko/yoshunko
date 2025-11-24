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
        var layer_record_list: std.ArrayList(pb.LayerRecord) = .empty;

        for (context.connection.assets.templates.zone_info_template_tb.payload.data) |zone_template| {
            if (zone_template.zone_id != entrance.zone_id) continue;

            try layer_record_list.append(context.arena, .{
                .layer_index = @intCast(zone_template.layer_index),
                .status = @enumFromInt(4),
            });
        }

        const timestamp = (try std.Io.Clock.real.now(context.io)).toSeconds();
        const entrance_type = entrance.entranceType();
        entrance_list[i] = .{
            .entrance_type = entrance_type,
            .entrance_id = entrance.id,
            .state = @enumFromInt(3), // :three:
            .cur_zone_record = .{
                .zone_id = entrance.zone_id,
                .layer_record_list = layer_record_list.items,
                .begin_timestamp = if (entrance_type == .scheduled)
                    timestamp - (3600 * 24)
                else
                    0,
                .end_timestamp = if (entrance_type == .scheduled)
                    timestamp + (3600 * 24 * 14)
                else
                    0,
            },
        };
    }

    try context.respond(pb.GetHadalZoneDataScRsp{
        .retcode = 0,
        .hadal_entrance_list = entrance_list,
    });
}
