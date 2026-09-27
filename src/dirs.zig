const std = @import("std");
const u = @import("util.zig");
const os = @import("darwin.zig");
const c = os.c;
const snapshot = @import("snapshot.zig");
pub const armTimer = os.armDirectoryTimer;
pub const disarmTimer = os.disarmDirectoryTimer;
fn less(_: void, left: [:0]u8, right: [:0]u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}
pub fn collect(a: u.Allocator, cwd: [:0]const u8) u.Error!std.ArrayList([:0]u8) {
    const dir = c.opendir(cwd) orelse return error.Io;
    var dir_open = true;
    defer if (dir_open) {
        _ = c.closedir(dir);
    };
    var names: std.ArrayList([:0]u8) = .empty;
    errdefer deinit(a, &names);
    var bytes: usize = "schema_version".len + 1 + 2 + "complete".len + 1 + 2;
    while (true) {
        c._errno().* = 0;
        const entry = c.readdir(dir) orelse {
            if (os.errno() != .SUCCESS) return error.Io;
            break;
        };
        const name = entry.name[0..entry.namlen];
        if (u.eq(name, ".") or u.eq(name, "..")) continue;
        if (entry.type != c.DT.DIR) {
            if (entry.type != c.DT.UNKNOWN and entry.type != c.DT.LNK) continue;
            var info: c.Stat = undefined;
            if (c.fstatat(os.dirfd(dir), @ptrCast(&entry.name), &info, 0) != 0 or !c.S.ISDIR(info.mode)) continue;
        }
        const size = "dir".len + 1 + name.len + 1;
        if (names.items.len >= 1024 or size > 65536 - bytes) return error.Limit;
        bytes += size;
        const copy = try a.dupeZ(u8, name);
        errdefer a.free(copy);
        try names.append(a, copy);
    }
    dir_open = false;
    if (c.closedir(dir) != 0) return error.Io;
    std.mem.sortUnstable([:0]u8, names.items, {}, less);
    return names;
}
pub fn deinit(a: u.Allocator, names: *std.ArrayList([:0]u8)) void {
    for (names.items) |name| a.free(name);
    names.deinit(a);
}
pub fn write(out: *std.Io.Writer, names: []const [:0]u8) !void {
    try snapshot.record(out, "schema_version", "1", true);
    for (names) |name| try snapshot.record(out, "dir", name, true);
    try snapshot.record(out, "complete", "1", true);
}
