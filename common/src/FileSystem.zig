const FileSystem = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

io: Io,
gpa: Allocator,
root_dir: Io.Dir,
map_lock: Io.Mutex = .init,
map: std.StringArrayHashMapUnmanaged(FileEntry) = .empty,
watchers_lock: Io.Mutex = .init,
watchers: std.ArrayList(*WatchSubscriber) = .empty,

const FileEntry = struct {
    file_lock: Io.Mutex = .init,
    content: ?[]const u8,
    mtime: i64,
};

const WatchSubscriber = struct {
    basepath: []const u8,
    awaiter: *Io.Queue(Changes),
    dead: bool = false,
};

pub const ReadDir = struct {
    pub const Entry = struct {
        path: []const u8,
        kind: std.fs.Dir.Entry.Kind, // TODO: exposes old std.fs api

        pub fn basename(entry: Entry) []const u8 {
            return if (std.mem.findScalarLast(u8, entry.path, '/')) |last_segment_begin|
                entry.path[last_segment_begin + 1 ..]
            else
                entry.path;
        }
    };

    entries: []const Entry,
    arena: ArenaAllocator,

    pub fn deinit(readdir: ReadDir) void {
        readdir.arena.deinit();
    }
};

pub fn init(gpa: Allocator, io: Io, root_path: []const u8) !FileSystem {
    const root_dir = try Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    return .{ .root_dir = root_dir, .gpa = gpa, .io = io };
}

pub fn deinit(fs: *FileSystem) void {
    var iterator = fs.map.iterator();
    while (iterator.next()) |entry| {
        fs.gpa.free(entry.key_ptr.*);

        if (entry.value_ptr.content) |content|
            fs.gpa.free(content);
    }

    for (fs.watchers.items) |watcher| {
        fs.gpa.free(watcher.basepath);
        fs.gpa.destroy(watcher);
    }

    fs.map.deinit(fs.gpa);
    fs.root_dir.close(fs.io);
}

pub fn readFile(fs: *FileSystem, caller_gpa: Allocator, path: []const u8) !?[:0]u8 {
    try fs.map_lock.lock(fs.io);
    defer fs.map_lock.unlock(fs.io);

    if (fs.map.getPtr(path)) |cached| {
        try cached.file_lock.lock(fs.io);
        defer cached.file_lock.unlock(fs.io);

        if (fs.root_dir.statPath(fs.io, path, .{})) |stat| {
            if (stat.mtime.toSeconds() > cached.mtime) {
                const cached_content = (try readEntireFileAlloc(fs.io, fs.root_dir, path, fs.gpa)) orelse return null;
                errdefer fs.gpa.free(cached_content);
                const content = try fs.gpa.dupeZ(u8, cached_content);

                if (cached.content) |old_content|
                    fs.gpa.free(old_content);

                cached.mtime = stat.mtime.toSeconds();
                cached.content = cached_content;
                return content;
            } else return if (cached.content) |content| try caller_gpa.dupeZ(u8, content) else null;
        } else |_| {
            if (cached.content) |content| {
                fs.gpa.free(content);
                cached.content = null;
            }

            return null;
        }
    } else {
        const stat = fs.root_dir.statPath(fs.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };

        const cached_content = (try readEntireFileAlloc(fs.io, fs.root_dir, path, fs.gpa)) orelse return null;
        errdefer fs.gpa.free(cached_content);

        try fs.map.put(fs.gpa, try fs.gpa.dupe(u8, path), .{
            .content = cached_content,
            .mtime = stat.mtime.toSeconds(),
        });

        return try fs.gpa.dupeZ(u8, cached_content);
    }
}

pub fn readDir(fs: *FileSystem, path: []const u8) !?ReadDir {
    var dir = fs.root_dir.openDir(fs.io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    defer dir.close(fs.io);

    var arena = ArenaAllocator.init(fs.gpa);
    errdefer arena.deinit();

    var entries: std.ArrayList(ReadDir.Entry) = .empty;

    const deprecated_dir = std.fs.Dir.adaptFromNewApi(dir);
    var walker = try deprecated_dir.walk(fs.gpa);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        try entries.append(arena.allocator(), .{
            .path = try std.fmt.allocPrint(arena.allocator(), "{s}/{s}", .{ path, entry.path }),
            .kind = entry.kind,
        });
    }

    return .{
        .entries = entries.items,
        .arena = arena,
    };
}

fn readEntireFileAlloc(io: Io, dir: Io.Dir, sub_path: []const u8, a: Allocator) !?[]u8 {
    var file = dir.openFile(io, sub_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    defer file.close(io);

    var reader = file.reader(io, "");
    return try reader.interface.allocRemaining(a, .unlimited);
}

pub fn writeFile(fs: *FileSystem, path: []const u8, content: []const u8) !void {
    try fs.map_lock.lock(fs.io);
    defer fs.map_lock.unlock(fs.io);

    if (fs.map.getPtr(path)) |cached| {
        try cached.file_lock.lock(fs.io);
        defer cached.file_lock.unlock(fs.io);

        if (cached.content) |old_content| fs.gpa.free(old_content);
        cached.content = try fs.gpa.dupe(u8, content);
    } else {
        const realtime_clock: Io.Clock = .real;
        try fs.map.put(fs.gpa, try fs.gpa.dupe(u8, path), .{
            .content = try fs.gpa.dupe(u8, content),
            .mtime = @intCast((try realtime_clock.now(fs.io)).toSeconds()),
        });
    }

    try makeDirAndWriteFile(fs.io, fs.root_dir, path, content);
}

pub const Changes = struct {
    files: []const File,
    arena: ArenaAllocator,

    pub const File = struct {
        path: []const u8,

        pub fn basename(file: File) []const u8 {
            return if (std.mem.findScalarLast(u8, file.path, '/')) |last_segment_begin|
                file.path[last_segment_begin + 1 ..]
            else
                file.path;
        }
    };

    pub fn deinit(changes: Changes) void {
        changes.arena.deinit();
    }
};

pub fn waitForChanges(fs: *FileSystem, base_path: []const u8) !Changes {
    // wait through a oneshot queue, similar to a channel

    var queue_buffer: [1]Changes = undefined;
    var awaiter = Io.Queue(Changes).init(queue_buffer[0..]);

    const watcher_ptr = blk: {
        try fs.watchers_lock.lock(fs.io);
        defer fs.watchers_lock.unlock(fs.io);

        const watcher = try fs.gpa.create(WatchSubscriber);
        errdefer fs.gpa.destroy(watcher);
        watcher.* = .{
            .basepath = try fs.gpa.dupe(u8, base_path),
            .awaiter = &awaiter,
        };
        errdefer fs.gpa.free(watcher.basepath);
        try fs.watchers.append(fs.gpa, watcher);
        break :blk watcher;
    };

    return awaiter.getOne(fs.io) catch |err| {
        @atomicStore(bool, &watcher_ptr.dead, true, .seq_cst);
        return err;
    };
}

// Sets up the filesystem watcher. Meant to be ran concurrently.
pub fn watch(fs: *FileSystem) !void {
    const io = fs.io;
    const realtime_clock: Io.Clock = .real;
    const loop_interval = Io.Duration.fromMilliseconds(1000);
    const deprecated_dir = std.fs.Dir.adaptFromNewApi(fs.root_dir);

    while (!io.cancelRequested()) {
        try io.sleep(loop_interval, realtime_clock);

        try fs.watchers_lock.lock(fs.io);
        defer fs.watchers_lock.unlock(fs.io);

        for (fs.watchers.items) |watcher| {
            if (watcher.dead) continue;

            var arena = ArenaAllocator.init(fs.gpa);
            errdefer arena.deinit();

            var changes: std.ArrayList(Changes.File) = .empty;

            var walker = try deprecated_dir.walk(fs.gpa);
            defer walker.deinit();

            while (try walker.next()) |entry| {
                if (entry.kind != .file) continue;
                if (std.mem.startsWith(u8, entry.path, watcher.basepath)) {
                    const file_stat = fs.root_dir.statPath(fs.io, entry.path, .{}) catch continue;
                    if (!(try fs.isChangeAcknowledged(entry.path, file_stat.mtime.toSeconds()))) {
                        try changes.append(arena.allocator(), .{
                            .path = try arena.allocator().dupe(u8, entry.path),
                        });
                    }
                }
            }

            if (changes.items.len > 0) {
                watcher.dead = true;
                try watcher.awaiter.putOne(fs.io, .{
                    .files = changes.items,
                    .arena = arena,
                });
            }
        }

        var i: usize = 0;
        while (i < fs.watchers.items.len) {
            if (fs.watchers.items[i].dead) {
                fs.gpa.free(fs.watchers.items[i].basepath);
                fs.gpa.destroy(fs.watchers.items[i]);
                _ = fs.watchers.swapRemove(i);
            } else i += 1;
        }
    }
}

fn isChangeAcknowledged(fs: *FileSystem, path: []const u8, mtime: i64) !bool {
    try fs.map_lock.lock(fs.io);
    defer fs.map_lock.unlock(fs.io);

    const entry = fs.map.getPtr(path) orelse return false;
    return entry.mtime >= mtime;
}

fn makeDirAndWriteFile(io: Io, dir: Io.Dir, sub_path: []const u8, content: []const u8) !void {
    if (std.mem.findScalarLast(u8, sub_path, '/')) |last_segment_begin| {
        const dir_path = sub_path[0..last_segment_begin];
        try dir.makePath(io, dir_path);
    }

    const file = try dir.createFile(io, sub_path, .{});
    defer file.close(io);

    // TODO: Io.File w/ Io.Threaded doesn't have writing implemented atm
    const deprecated_file = std.fs.File.adaptFromNewApi(file);
    var writer = deprecated_file.writer("");
    try writer.interface.writeAll(content);
}

pub const FileLock = struct {
    fs: *FileSystem,
    path: []const u8,
    content: []const u8,
    mutex: *Io.Mutex,

    pub fn unlock(lock: *FileLock, replace_with: ?[]const u8) !void {
        lock.mutex.unlock(lock.fs.io);

        if (replace_with) |new_content| {
            try lock.fs.writeFile(lock.path, new_content);
        }
    }
};

pub fn lockFile(fs: *FileSystem, path: []const u8) !?FileLock {
    try fs.map_lock.lock(fs.io);
    defer fs.map_lock.unlock(fs.io);

    if (fs.map.getPtr(path)) |cached| {
        try cached.file_lock.lock(fs.io);

        if (fs.root_dir.statPath(fs.io, path, .{})) |stat| {
            if (stat.mtime.toSeconds() > cached.mtime) {
                const content = (try readEntireFileAlloc(fs.io, fs.root_dir, path, fs.gpa)) orelse return null;
                errdefer fs.gpa.free(content);

                if (cached.content) |old_content|
                    fs.gpa.free(old_content);

                cached.mtime = stat.mtime.toSeconds();
                cached.content = content;
                return .{
                    .fs = fs,
                    .path = path,
                    .content = cached.content.?,
                    .mutex = &cached.file_lock,
                };
            } else return if (cached.content) |content| {
                return .{
                    .fs = fs,
                    .path = path,
                    .content = content,
                    .mutex = &cached.file_lock,
                };
            } else {
                cached.file_lock.unlock(fs.io);
                return null;
            };
        } else |_| {
            if (cached.content) |content| {
                fs.gpa.free(content);
                cached.file_lock.unlock(fs.io);
                cached.content = null;
            }

            return null;
        }
    } else {
        const stat = fs.root_dir.statPath(fs.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };

        const content = (try readEntireFileAlloc(fs.io, fs.root_dir, path, fs.gpa)) orelse return null;
        errdefer fs.gpa.free(content);

        try fs.map.put(fs.gpa, try fs.gpa.dupe(u8, path), .{
            .content = content,
            .mtime = stat.mtime.toSeconds(),
        });

        const cached = fs.map.getPtr(path).?;
        try cached.file_lock.lock(fs.io);

        return .{
            .fs = fs,
            .path = path,
            .content = cached.content.?,
            .mutex = &cached.file_lock,
        };
    }
}
