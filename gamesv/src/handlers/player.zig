const std = @import("std");
const pb = @import("proto").pb;
const common = @import("common");
const network = @import("../network.zig");
const Account = @import("../fs/Account.zig");
const Player = @import("../fs/Player.zig");

const rsa = common.rsa;
const base64 = std.base64.standard;

pub fn onPlayerGetTokenCsReq(context: *network.Context, request: pb.PlayerGetTokenCsReq) !void {
    const log = std.log.scoped(.player_get_token);
    errdefer context.respond(pb.PlayerGetTokenScRsp{
        .retcode = 1,
    }) catch {};

    if (context.connection.player_uid != null) return error.RepeatedLogin;

    var response: pb.PlayerGetTokenScRsp = .default;
    const rand_key = try genRandKey(context, &request, &response);

    log.debug("account_uid: {s}, token: {s}", .{ request.account_uid, request.token });

    const account = Account.loadOrCreate(context.arena, context.fs, request.account_uid) catch |err| {
        log.err("failed to load or create data for account with UID '{s}': {t}", .{ request.account_uid, err });
        return error.AccountLoadFailed;
    };

    try context.connection.setPlayerUID(account.player_uid);
    response.uid = account.player_uid;

    context.respond(response) catch {};
    common.random.getMtDecryptVector(
        rand_key,
        context.connection.xorpad,
    );
}

fn genRandKey(context: *network.Context, request: *const pb.PlayerGetTokenCsReq, response: *pb.PlayerGetTokenScRsp) !u64 {
    const client_public_key = try context.fs.readFile(context.arena, try std.fmt.allocPrint(
        context.arena,
        "rsa/{}/client_public_key.der",
        .{request.rsa_ver},
    )) orelse return error.MissingRsaVersionRequested;

    const server_private_key = try context.fs.readFile(context.arena, try std.fmt.allocPrint(
        context.arena,
        "rsa/{}/server_private_key.der",
        .{request.rsa_ver},
    )) orelse return error.MissingRsaVersionRequested;

    var rand_key_buffer: [64]u8 = undefined;
    var decrypt_buffer: [64]u8 = undefined;

    const ciphertext_size = try base64.Decoder.calcSizeForSlice(request.client_rand_key);
    if (ciphertext_size > rand_key_buffer.len) return error.RandKeyCiphertextTooLong;

    try base64.Decoder.decode(&rand_key_buffer, request.client_rand_key);

    const client_rand_key = try rsa.decrypt(server_private_key, &rand_key_buffer, &decrypt_buffer);
    if (client_rand_key.len != 8) return error.InvalidRandKeySize;

    var server_rand_key: [8]u8 = undefined;
    std.crypto.random.bytes(&server_rand_key);

    var server_rand_key_ciphertext: [rsa.paddedLength(server_rand_key.len)]u8 = undefined;
    var sign: [rsa.sign_size]u8 = undefined;

    try rsa.encrypt(client_public_key, &server_rand_key, &server_rand_key_ciphertext);
    try rsa.sign(server_private_key, &server_rand_key, &sign);

    response.server_rand_key = try std.fmt.allocPrint(context.arena, "{b64}", .{server_rand_key_ciphertext});
    response.sign = try std.fmt.allocPrint(context.arena, "{b64}", .{sign});

    return std.mem.readInt(u64, client_rand_key[0..8], .little) ^ std.mem.readInt(u64, &server_rand_key, .little);
}

pub fn onPlayerLoginCsReq(context: *network.Context, _: pb.PlayerLoginCsReq) !void {
    if (context.connection.player != null) return error.RepeatedLogin;

    const player = try Player.loadOrCreate(
        context.gpa,
        context.fs,
        context.connection.assets,
        context.connection.player_uid orelse return error.Unauthenticated,
    );

    context.connection.player = player;
    context.respond(pb.PlayerLoginScRsp{}) catch {};
}

pub fn onGetSelfBasicInfoCsReq(context: *network.Context, _: pb.GetSelfBasicInfoCsReq) !void {
    errdefer context.respond(pb.GetSelfBasicInfoScRsp{ .retcode = 1 }) catch {};
    const player = try context.connection.getPlayer();

    try context.respond(pb.GetSelfBasicInfoScRsp{
        .self_basic_info = try player.buildBasicInfoProto(context.arena),
    });
}

pub fn onGetServerTimestampCsReq(context: *network.Context, _: pb.GetServerTimestampCsReq) !void {
    try context.respond(pb.GetServerTimestampScRsp{
        .timestamp = @intCast((try std.Io.Clock.real.now(context.io)).toMilliseconds()),
        .utc_offset = 3,
    });
}

pub fn onModAvatarCsReq(context: *network.Context, request: pb.ModAvatarCsReq) !void {
    var retcode: i32 = 1;
    defer context.respond(pb.ModAvatarScRsp{ .retcode = retcode }) catch {};
    defer if (retcode == 0) context.connection.flushSync(context.arena, context.io) catch {};

    const player = try context.connection.getPlayer();

    player.basic_info.avatar_id = request.avatar_id;
    player.basic_info.control_avatar_id = request.control_avatar_id;
    player.basic_info.control_guise_avatar_id = request.control_guise_avatar_id;
    player.sync.basic_info_changed = true;
    retcode = 0;
}

pub fn onKeepAliveNotify(_: *network.Context, _: pb.KeepAliveNotify) !void {
    // stub
}

pub fn onPlayerLogoutCsReq(context: *network.Context, _: pb.PlayerLogoutCsReq) !void {
    context.connection.logout_requested = true;
}
