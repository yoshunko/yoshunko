const std = @import("std");
const common = @import("common");
const http = @import("http.zig");
const native_os = @import("builtin").os.tag;

const Io = std.Io;
const ayo = common.ayo;
const Allocator = std.mem.Allocator;
const FileSystem = common.FileSystem;

const address = Io.net.IpAddress.parseLiteral("127.0.0.1:10100") catch unreachable;
const fs_root: []const u8 = "state";

fn init(gpa: Allocator, io: Io) u8 {
    const log = std.log.scoped(.init);
    common.printSplash();

    var fs = FileSystem.init(gpa, io, fs_root) catch |err| {
        log.err("failed to open filesystem at '{s}': {}", .{ fs_root, err });
        return 1;
    };

    defer fs.deinit();

    var server = address.listen(io, .{ .reuse_address = true }) catch |err| {
        log.err("failed to listen at {f}: {}", .{ address, err });
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
        log.err("failed to schedule accept routine: {}", .{err});
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
                fallible catch |err| log.err("client disconnect due to an error: {}", .{err});
            },
        }
    } else |err| {
        if (!io.cancelRequested())
            log.err("futures.wait failed: {}", .{err});
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
