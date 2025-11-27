const std = @import("std");
const common = @import("common");
const network = @import("network.zig");
const Assets = @import("data/Assets.zig");
const native_os = @import("builtin").os.tag;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const FileSystem = common.FileSystem;

const Args = struct {
    gateway_name: []const u8 = "yoshunko",
    state_dir: []const u8 = "state",
};

fn init(gpa: Allocator, io: Io) u8 {
    const log = std.log.scoped(.init);
    common.printSplash();

    const cmd_args = std.process.argsAlloc(gpa) catch @panic("early OOM");
    defer std.process.argsFree(gpa, cmd_args);

    const args = common.args.parse(Args, cmd_args[1..]) orelse {
        common.args.printUsage(Args, cmd_args[0]);
        return 1;
    };

    var fs = FileSystem.init(gpa, io, args.state_dir) catch |err| {
        log.err("failed to open filesystem at '{s}': {}", .{ args.state_dir, err });
        return 1;
    };

    defer fs.deinit();

    const bind_address = (getBindAddress(gpa, &fs, args.gateway_name) catch null) orelse return 1;

    var watcher_task = io.concurrent(FileSystem.watch, .{&fs}) catch blk: {
        log.warn("FileSystem.watch: concurrency is not available", .{});
        break :blk null;
    };

    defer if (watcher_task) |*task| task.cancel(io) catch {};

    var assets = Assets.init(gpa, io) catch |err| {
        log.err("failed to load assets: {t}", .{err});
        return 1;
    };

    defer assets.deinit(gpa);

    var server = bind_address.listen(io, .{ .reuse_address = true }) catch |err| {
        log.err("failed to listen at {f}: {}", .{ bind_address, err });
        if (err == error.AddressInUse) log.err("another instance of this service might be already running", .{});
        return 1;
    };

    defer server.deinit(io);

    log.info("game server is listening at {f}", .{bind_address});

    var client_group: Io.Group = .init;
    defer client_group.cancel(io);

    while (!io.cancelRequested()) {
        const stream = server.accept(io) catch continue;

        const client_args = .{ gpa, io, &fs, &assets, stream };
        client_group.concurrent(io, network.onConnect, client_args) catch
            client_group.async(io, network.onConnect, client_args);
    }

    return 0;
}

fn getBindAddress(gpa: Allocator, fs: *FileSystem, gateway_name: []const u8) !?Io.net.IpAddress {
    const log = std.log.scoped(.gateway);

    var temp_allocator = std.heap.ArenaAllocator.init(gpa);
    defer temp_allocator.deinit();
    const arena = temp_allocator.allocator();

    const gateway_content = try fs.readFile(arena, try std.fmt.allocPrint(arena, "gateway/{s}", .{gateway_name})) orelse {
        log.err("gateway '{s}' is not defined", .{gateway_name});
        return null;
    };

    const gateway_var_set = try common.var_set.readVarSet(common.Gateway, arena, gateway_content) orelse {
        log.err("gateway config for '{s}' is malformed", .{gateway_name});
        return null;
    };

    const gateway = gateway_var_set.data;

    return Io.net.IpAddress.parseIp4(gateway.ip, gateway.port) catch |err| {
        log.err("gateway '{s}' has a malformed ip address: {t} ({s})", .{ gateway_name, err, gateway.ip });
        return null;
    };
}

pub fn main() u8 {
    if (native_os == .windows) @compileError("Here's a nickel, kid. Get yourself a real OS.");

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);

    var threaded = Io.Threaded.init(debug_allocator.allocator());
    defer threaded.deinit();

    return init(debug_allocator.allocator(), threaded.io());
}
