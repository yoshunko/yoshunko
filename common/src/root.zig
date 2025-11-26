const std = @import("std");

pub const ayo = @import("ayo.zig");
pub const args = @import("args.zig");
pub const var_set = @import("var_set.zig");
pub const FileSystem = @import("FileSystem.zig");
pub const rsa = @import("rsa.zig");
pub const random = @import("random.zig");

pub const Gateway = struct {
    title: []const u8,
    dispatch_url: []const u8,
    versions: []const []const u8,
    ip: []const u8,
    port: u16,
};

pub const Version = struct {
    data_base_url: []const u8,
    data_revision: []const u8,
    data_md5_files: []const u8,
    res_base_url: []const u8,
    branch: []const u8,
    audio_revision: []const u8,
    res_revision: []const u8,
    res_md5_files: []const u8,
    silence_base_url: []const u8,
    silence_revision: []const u8,
    silence_md5_files: []const u8,
    cdn_check_url: []const u8,
};

pub fn printSplash() void {
    var stderr = std.fs.File.stderr().writer("");
    stderr.interface.writeAll(
        \\ __  ______  ______ ____  ___  ____ ______ 
        \\ \ \/ / __ \/ __/ // / / / / |/ / //_/ __ \
        \\  \  / /_/ /\ \/ _  / /_/ /    / ,< / /_/ /
        \\  /_/\____/___/_//_/\____/_/|_/_/|_|\____/ 
        \\
    ) catch {};
}
