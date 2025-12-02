const std = @import("std");
const pb = @import("proto").pb;
const network = @import("../network.zig");
const State = @import("../network/State.zig");
const Memory = State.Memory;
const PlayerBuddyComponent = @import("../logic/component/player/PlayerBuddyComponent.zig");
const EventQueue = @import("../logic/EventQueue.zig");

pub fn onGetBuddyDataCsReq(
    txn: *network.Transaction(pb.GetBuddyDataCsReq),
    mem: Memory,
    buddy_comp: *PlayerBuddyComponent,
) !void {
    errdefer txn.respond(.{ .retcode = 1 }) catch {};

    const buddy_list = try mem.arena.alloc(pb.BuddyInfo, buddy_comp.buddy_map.count());
    var i: usize = 0;
    var iterator = buddy_comp.buddy_map.iterator();
    while (iterator.next()) |kv| : (i += 1) {
        buddy_list[i] = try kv.value_ptr.toProto(kv.key_ptr.*, mem.arena);
    }

    try txn.respond(.{ .buddy_list = .fromOwnedSlice(buddy_list) });
}

pub fn onBuddyFavoriteCsReq(
    txn: *network.Transaction(pb.BuddyFavoriteCsReq),
    events: *EventQueue,
    buddy_comp: *PlayerBuddyComponent,
) !void {
    var retcode: i32 = 1;
    defer txn.respond(.{ .retcode = retcode }) catch {};

    const buddy = buddy_comp.buddy_map.getPtr(txn.message.buddy_id) orelse return error.NoSuchBuddy;
    buddy.is_favorite = txn.message.is_favorite;

    try events.enqueue(.buddy_data_modified, .{ .buddy_id = txn.message.buddy_id });
    retcode = 0;
}
