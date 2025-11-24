const std = @import("std");
const proto = @import("proto");
const common = @import("common");
const handlers = @import("handlers.zig");
const Player = @import("fs/Player.zig");
const sync = @import("sync.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const FileSystem = common.FileSystem;
const Assets = @import("data/Assets.zig");

const xorpad_len: usize = 4096;

pub fn processConnection(gpa: Allocator, io: Io, fs: *FileSystem, assets: *const Assets, stream: Io.net.Stream) !void {
    const log = std.log.scoped(.session);
    defer stream.close(io);

    log.debug("new connection from {f}", .{stream.socket.address});
    defer log.debug("connection from {f} disconnected", .{stream.socket.address});

    var xorpad = try fs.readFile(gpa, "xorpad/bytes") orelse return error.MissingXorpadFile;
    defer gpa.free(xorpad);

    if (xorpad.len != xorpad_len) return error.InvalidXorpadFile;

    const connection = try gpa.create(Connection);
    defer gpa.destroy(connection);

    connection.init(io, stream, xorpad, assets);
    defer connection.deinit(gpa);

    while (!io.cancelRequested() and !connection.logout_requested) {
        if (connection.player == null) {
            if (connection.reader.interface.fillMore()) {
                try onReceive(gpa, io, fs, connection);
            } else |err| switch (err) {
                error.EndOfStream => return,
                else => return connection.reader.err.?,
            }
        } else {
            var recv_future = try io.concurrent(Io.Reader.fillMore, .{&connection.reader.interface});
            defer recv_future.cancel(io) catch {};

            var watch_future = try io.concurrent(FileSystem.waitForChanges, .{ fs, connection.player_data_path.? });
            defer if (watch_future.cancel(io)) |changes| changes.deinit() else |_| {};

            switch (try io.select(.{
                .recv = &recv_future,
                .watch = &watch_future,
            })) {
                .recv => |fallible| if (fallible) {
                    try onReceive(gpa, io, fs, connection);
                } else |err| switch (err) {
                    error.EndOfStream => return,
                    else => return connection.reader.err.?,
                },
                .watch => |maybe_changes| {
                    var changes = maybe_changes catch |err| {
                        log.err("watch failed: {t}", .{err});
                        continue;
                    };

                    for (changes.files) |file| {
                        connection.player.?.reloadFile(
                            gpa,
                            changes.arena.allocator(),
                            fs,
                            file,
                            connection.player_data_path.?,
                        ) catch |err| {
                            log.err("failed to reload {s}: {t}", .{ file.path, err });
                        };
                    }

                    try sync.send(connection, changes.arena.allocator(), io);
                    try connection.writer.interface.flush();
                },
            }
        }
    }
}

fn onReceive(gpa: Allocator, io: Io, fs: *FileSystem, connection: *Connection) !void {
    const log = std.log.scoped(.network);

    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var fixed_reader = Io.Reader.fixed(connection.reader.interface.buffered());

    while (try Packet.read(&fixed_reader)) |packet| {
        connection.reader.interface.discardAll(packet.encodingLength()) catch unreachable;
        xor(packet.body, connection.xorpad);

        var head_reader = Io.Reader.fixed(packet.head);
        const packet_head = try proto.decodeMessage(&head_reader, arena, proto.pb.PacketHead, proto.pb.desc_common);

        log.debug("received packet with cmd_id: {}, packet_id: {}", .{ packet.cmd_id, packet_head.packet_id });

        var context: Context = .{
            .gpa = gpa,
            .arena = arena,
            .connection = connection,
            .fs = fs,
            .io = io,
            .packet_head = packet_head,
        };

        handlers.dispatchPacket(&context, &packet) catch |err| switch (err) {
            error.HandlerNotFound => {
                log.warn("no handler for cmd_id {}", .{packet.cmd_id});
                try connection.writeDummy(packet_head.packet_id);
            },
        };

        if (connection.player) |*player| {
            player.save(context.arena, fs) catch |err| {
                log.err(
                    "failed to save player data (uid: {}): {t}",
                    .{ player.player_uid, err },
                );
            };

            player.sync.reset();
        }
    }

    try connection.writer.interface.flush();
}

pub const Connection = struct {
    stream: Io.net.Stream,
    reader: Io.net.Stream.Reader,
    writer: XoringWriter,
    xorpad: []u8,
    recv_buffer: [32678]u8 = undefined, // TODO: make it resizable
    send_buffer: [8192]u8 = undefined,
    player_data_path_buf: [128]u8 = undefined,
    outgoing_packet_id_counter: u32 = 0,
    player_uid: ?u32 = null,
    player_data_path: ?[]const u8 = null,
    player: ?Player = null,
    logout_requested: bool = false,
    assets: *const Assets,

    pub fn init(
        connection: *Connection,
        io: Io,
        stream: Io.net.Stream,
        xorpad: []u8,
        assets: *const Assets,
    ) void {
        connection.* = .{
            .assets = assets,
            .xorpad = xorpad,
            .stream = stream,
            .reader = stream.reader(io, connection.recv_buffer[0..]),
            .writer = XoringWriter.init(connection.send_buffer[0..], xorpad, stream.writer(io, "")),
        };
    }

    pub fn deinit(connection: *Connection, gpa: Allocator) void {
        if (connection.player) |*player| player.deinit(gpa);
    }

    pub fn flushSync(connection: *Connection, arena: Allocator, io: Io) !void {
        try sync.send(connection, arena, io);
    }

    pub fn setPlayerUID(connection: *Connection, uid: u32) !void {
        if (connection.player_uid != null) return error.RepeatedLogin;

        connection.player_uid = uid;
        connection.player_data_path = std.fmt.bufPrint(
            &connection.player_data_path_buf,
            "player/{}/",
            .{connection.player_uid.?},
        ) catch unreachable;
    }

    pub fn getPlayer(connection: *Connection) !*Player {
        return &(connection.player orelse return error.NotLoggedIn);
    }

    pub fn write(connection: *Connection, message: anytype, ack_packet_id: u32) !void {
        return connection.writeMessage(message, proto.pb_desc, ack_packet_id);
    }

    pub fn writeDummy(connection: *Connection, ack_packet_id: u32) !void {
        return connection.writeMessage(proto.pb.DummyMessage{}, proto.pb.desc_common, ack_packet_id);
    }

    fn writeMessage(connection: *Connection, message: anytype, desc_set: type, ack_packet_id: u32) !void {
        const Message = @TypeOf(message);
        const message_name = @typeName(Message)[3..];
        if (!@hasDecl(desc_set, message_name)) {
            std.log.debug("trying to send a message which is not defined in descriptor set: {s}, falling back to dummy", .{message_name});
            return connection.writeDummy(ack_packet_id);
        }

        const message_desc = @field(desc_set, message_name);
        const packet_head: proto.pb.PacketHead = .{
            .packet_id = connection.outgoing_packet_id_counter,
            .ack_packet_id = ack_packet_id,
        };

        connection.outgoing_packet_id_counter += 1;
        const w = &connection.writer.interface;
        try w.writeInt(u32, Packet.head_magic, .big);
        try w.writeInt(u16, message_desc.cmd_id, .big);
        try w.writeInt(u16, @intCast(proto.encodingLength(packet_head, proto.pb.desc_common)), .big);
        try w.writeInt(u32, @intCast(proto.encodingLength(message, desc_set)), .big);
        try proto.encodeMessage(w, packet_head, proto.pb.desc_common);
        connection.writer.pushXorStartIndex();
        try proto.encodeMessage(w, message, desc_set);
        connection.writer.popXorStartIndex();
        try w.writeInt(u32, Packet.tail_magic, .big);
    }
};

pub const Context = struct {
    gpa: Allocator,
    arena: Allocator,
    connection: *Connection,
    fs: *FileSystem,
    io: Io,
    packet_head: proto.pb.PacketHead,

    pub fn respond(context: *Context, message: anytype) !void {
        try context.connection.write(message, context.packet_head.packet_id);
    }

    pub fn notify(context: *Context, message: anytype) !void {
        try context.connection.write(message, 0);
    }
};

fn xor(buffer: []u8, xorpad: []const u8) void {
    for (0..buffer.len) |i| buffer[i] ^= xorpad[i % xorpad_len];
}

pub const Packet = struct {
    pub const head_magic: u32 = 0x01234567;
    pub const tail_magic: u32 = 0x89ABCDEF;

    cmd_id: u16,
    head: []const u8,
    body: []u8,

    pub fn read(reader: *Io.Reader) !?Packet {
        const metadata = reader.peekArray(12) catch return null;
        if (std.mem.readInt(u32, metadata[0..4], .big) != head_magic) return error.MagicMismatch;
        const head_len = std.mem.readInt(u16, metadata[6..8], .big);
        const body_len = std.mem.readInt(u32, metadata[8..12], .big);
        const buffer = reader.take(16 + head_len + body_len) catch return null;

        const tail = buffer[12 + head_len + body_len ..];
        if (std.mem.readInt(u32, tail[0..4], .big) != tail_magic) return error.MagicMismatch;

        return .{
            .cmd_id = std.mem.readInt(u16, buffer[4..6], .big),
            .head = buffer[12 .. head_len + 12],
            .body = buffer[12 + head_len .. 12 + head_len + body_len],
        };
    }

    pub fn encodingLength(packet: Packet) usize {
        return 16 + packet.head.len + packet.body.len;
    }
};

const XoringWriter = struct {
    xor_start_index: ?usize = null,
    xorpad_index: ?usize = null,
    interface: Io.Writer,
    underlying_stream: Io.net.Stream.Writer,
    xorpad: []const u8,

    pub fn init(buffer: []u8, xorpad: []const u8, underlying_stream: Io.net.Stream.Writer) @This() {
        return .{
            .underlying_stream = underlying_stream,
            .xorpad = xorpad,
            .interface = .{ .buffer = buffer, .vtable = &.{ .drain = @This().drain } },
        };
    }

    pub fn pushXorStartIndex(self: *@This()) void {
        if (self.xor_start_index == null) self.xor_start_index = self.interface.end;
    }

    pub fn popXorStartIndex(self: *@This()) void {
        if (self.xor_start_index) |index| {
            const buf = self.interface.buffered()[index..];
            const xorpad_index = self.xorpad_index orelse 0;

            for (0..buf.len) |i| {
                buf[i] ^= self.xorpad[(xorpad_index + i) % 4096];
            }

            self.xor_start_index = null;
            self.xorpad_index = null;
        }
    }

    fn drain(w: *Io.Writer, data: []const []const u8, _: usize) Io.Writer.Error!usize {
        const this: *@This() = @alignCast(@fieldParentPtr("interface", w));
        const buf = w.buffered();
        w.end = 0;

        if (this.xor_start_index) |index| {
            var xorpad_index = this.xorpad_index orelse 0;

            const slice = buf[index..];
            for (0..slice.len) |i| {
                slice[i] ^= this.xorpad[xorpad_index % 4096];
                xorpad_index += 1;
            }

            this.xor_start_index = 0;
            this.xorpad_index = xorpad_index;
        }

        try this.underlying_stream.interface.writeAll(buf);

        @memcpy(w.buffer[0..data[0].len], data[0]);
        w.end = data[0].len;

        return buf.len;
    }
};
