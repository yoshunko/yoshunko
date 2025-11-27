const std = @import("std");
const common = @import("common");
const http = @import("http.zig");
const native_os = @import("builtin").os.tag;

const Io = std.Io;
const ayo = common.ayo;
const Allocator = std.mem.Allocator;
const FileSystem = common.FileSystem;

const Args = struct {
    state_dir: []const u8 = "state",
    listen_address: []const u8 = "127.0.0.1:10100",
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

    const address = Io.net.IpAddress.parseLiteral(args.listen_address) catch |err| {
        log.err("invalid listen address specified: {t}", .{err});
        return 1;
    };

    var fs = FileSystem.init(gpa, io, args.state_dir) catch |err| {
        log.err("failed to open filesystem at '{s}': {t}", .{ args.state_dir, err });
        return 1;
    };

    defer fs.deinit();

    var server = address.listen(io, .{ .reuse_address = true }) catch |err| {
        log.err("failed to listen at {f}: {t}", .{ address, err });
        if (err == error.AddressInUse) log.err("another instance of this service might be already running", .{});
        return 1;
    };

    defer server.deinit(io);

    log.info("dispatch server is listening at {f}", .{address});

    var futures: ayo.ConcurrentSelect(.{
        .accept = Io.net.Server.accept,
        .close = http.processConnection,
    }) = .init;

    defer futures.cancel(io, gpa);

    futures.concurrent(gpa, io, .accept, Io.net.Server.accept, .{ &server, io }) catch |err| {
        // TODO: fallback to io.async calls if ConcurrencyUnavailable
        log.err("failed to schedule accept routine: {t}", .{err});
        return 1;
    };

    while (futures.wait(io)) |result| {
        switch (result) {
            .accept => |fallible| {
                futures.concurrent(gpa, io, .accept, Io.net.Server.accept, .{ &server, io }) catch
                    unreachable; // errors shouldn't be possible since first of all concurrency IS available and the space for future was freed by previous call.

                const stream = fallible catch continue;
                futures.concurrent(gpa, io, .close, http.processConnection, .{ gpa, io, &fs, stream }) catch |err| {
                    switch (err) {
                        error.OutOfMemory => stream.close(io),
                        error.ConcurrencyUnavailable => unreachable, // not possible at this point
                    }
                };
            },
            .close => |fallible| {
                fallible catch |err| log.err("client disconnect due to an error: {t}", .{err});
            },
        }
    } else |err| {
        if (!io.cancelRequested())
            log.err("futures.wait failed: {t}", .{err});
    }

    return 0;
}

pub fn main() u8 {
    if (native_os == .windows) @compileError("Here's a nickel, kid. Get yourself a real OS.");

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);

    var threaded = Io.Threaded.init(debug_allocator.allocator());
    defer threaded.deinit();

    return init(debug_allocator.allocator(), threaded.io());
}
