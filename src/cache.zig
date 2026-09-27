const std = @import("std");
const u = @import("util.zig");
const os = @import("darwin.zig");
const c = os.c;
const git = @import("git.zig");
const directory_flags: c.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true };

pub fn normalize(a: u.Allocator, base: []const u8, suffix: []const u8) u.Error![:0]u8 {
    if (base.len == 0 or base[0] != '/' or base.len + suffix.len >= u.path_cap) return error.Invalid;
    const combined = try std.mem.concat(a, u8, &.{ base, suffix });
    defer a.free(combined);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var parts = std.mem.tokenizeScalar(u8, combined, '/');
    while (parts.next()) |part| {
        if (u.eq(part, ".") or u.eq(part, "..")) return error.Invalid;
        try out.append(a, '/');
        try out.appendSlice(a, part);
    }
    if (out.items.len < 2) return error.Invalid;
    return a.dupeZ(u8, out.items);
}
fn root(a: u.Allocator, environ: std.process.Environ) u.Error![:0]u8 {
    const chosen = if (os.env(environ, "NBSP_CACHE_DIR")) |override| try normalize(a, override, "") else if (os.env(environ, "XDG_CACHE_HOME")) |xdg| blk: {
        if (u.starts(xdg, "/")) break :blk try normalize(a, xdg, "/nbsp");
        break :blk try normalize(a, os.env(environ, "HOME") orelse return error.Missing, "/Library/Caches/nbsp");
    } else try normalize(a, os.env(environ, "HOME") orelse return error.Missing, "/Library/Caches/nbsp");
    errdefer a.free(chosen);
    const slash = std.mem.indexOfScalarPos(u8, chosen, 1, '/') orelse chosen.len;
    const first = try a.dupeZ(u8, chosen[0..slash]);
    defer a.free(first);
    var info: c.Stat = undefined;
    if (os.lstat(first, &info) != 0) {
        if (os.errno() == .NOENT) return chosen;
        return error.Io;
    }
    if (!c.S.ISLNK(info.mode)) return chosen;
    const target: []const u8 = if (u.eq(first, "/tmp")) "private/tmp" else if (u.eq(first, "/var")) "private/var" else return error.Invalid;
    if (info.uid != 0) return error.Invalid;
    var link: [32]u8 = undefined;
    const len = c.readlink(first, &link, link.len);
    if (len < 0 or !u.eq(link[0..@intCast(len)], target)) return error.Invalid;
    const replacement = try std.fmt.allocPrintSentinel(a, "/{s}{s}", .{ target, chosen[slash..] }, 0);
    a.free(chosen);
    return replacement;
}
pub fn secureDirectory(info: c.Stat) bool {
    return c.S.ISDIR(info.mode) and info.uid == c.getuid() and info.mode & 0o7777 == 0o700;
}
pub fn secureFile(info: c.Stat) bool {
    return c.S.ISREG(info.mode) and info.uid == c.getuid() and info.mode & 0o7777 == 0o600 and info.nlink == 1;
}
pub fn openGitDir(a: u.Allocator, environ: std.process.Environ, create: bool) u.Error!c.fd_t {
    const path = try root(a, environ);
    defer a.free(path);
    if (path.len + 4 >= u.path_cap) return error.Limit;
    var current = c.open("/", directory_flags);
    if (current < 0) return error.Io;
    errdefer _ = c.close(current);
    // The normalized path is owned and will not be reused. Terminate each
    // borrowed component in place for openat; no component allocation is needed.
    var start: usize = 1;
    while (start < path.len) {
        const end = std.mem.indexOfScalarPos(u8, path, start, '/') orelse path.len;
        path[end] = 0;
        const name: [:0]const u8 = path[start..end :0];
        start = end + 1;
        var next = c.openat(current, name, directory_flags);
        if (next < 0 and os.errno() == .NOENT and create) {
            if (c.mkdirat(current, name, 0o700) != 0 and os.errno() != .EXIST) return error.Io;
            next = c.openat(current, name, directory_flags);
        }
        if (next < 0) {
            if (!create and os.errno() == .NOENT) return error.Missing;
            return error.Io;
        }
        const old = current;
        current = next;
        try os.close(old);
    }
    var info: c.Stat = undefined;
    if (c.fstat(current, &info) != 0 or !secureDirectory(info)) return error.Invalid;
    if (create and c.mkdirat(current, "git", 0o700) != 0 and os.errno() != .EXIST) return error.Io;
    const fd = c.openat(current, "git", directory_flags);
    if (fd < 0) {
        if (!create and os.errno() == .NOENT) return error.Missing;
        return error.Io;
    }
    errdefer _ = c.close(fd);
    if (c.fstat(fd, &info) != 0 or !secureDirectory(info)) return error.Invalid;
    const old = current;
    current = -1;
    try os.close(old);
    return fd;
}
fn filename(buffer: []u8, repo: []const u8, suffix: []const u8) u.Error![:0]u8 {
    return std.fmt.bufPrintSentinel(buffer, "{x:0>16}{s}", .{ u.hashPath(repo), suffix }, 0) catch return error.Limit;
}
pub const Loaded = struct {
    status: git.Status,
    pub fn deinit(self: Loaded, a: u.Allocator) void {
        a.free(self.status.branch);
    }
};
pub fn parse(a: u.Allocator, content: []const u8, repo: []const u8) u.Error!Loaded {
    if (content.len == 0 or content.len >= 16384 or std.mem.indexOfScalar(u8, content, 0) != null) return error.Invalid;
    var status: git.Status = .{};
    var seen: u11 = 0;
    errdefer if (seen & 8 != 0) a.free(status.branch);
    const bytes = if (content[content.len - 1] == '\n') content[0 .. content.len - 1] else content;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.Invalid;
        const key = line[0..equals];
        const value = line[equals + 1 ..];
        if (key.len == 0 or std.mem.indexOfScalar(u8, value, '=') != null) return error.Invalid;
        for (key) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '_') return error.Invalid;
        const keys = [_][]const u8{ "version", "repo", "updated_ms", "branch", "staged", "modified", "untracked", "conflicted", "ahead", "behind", "stashes" };
        var known: ?usize = null;
        for (keys, 0..) |name, i| if (u.eq(key, name)) {
            known = i;
            break;
        };
        if (known) |index| {
            const bit = @as(u11, 1) << @as(u4, @intCast(index));
            if (seen & bit != 0) return error.Invalid;
            switch (index) {
                0 => if (!u.eq(value, "2")) return error.Invalid,
                1 => if (!u.encodedEquals(value, repo)) return error.Invalid,
                2 => {
                    status.updated_ms = try u.unsigned(u64, value);
                    if (status.updated_ms == 0) return error.Invalid;
                },
                3 => {
                    const branch = try u.decode(a, value, 256);
                    if (!u.branchValid(branch)) {
                        a.free(branch);
                        return error.Invalid;
                    }
                    status.branch = branch;
                },
                4 => status.staged = try u.unsigned(u32, value),
                5 => status.modified = try u.unsigned(u32, value),
                6 => status.untracked = try u.unsigned(u32, value),
                7 => status.conflicted = try u.unsigned(u32, value),
                8 => status.ahead = try u.unsigned(u32, value),
                9 => status.behind = try u.unsigned(u32, value),
                10 => status.stashes = try u.unsigned(u32, value),
                else => unreachable,
            }
            seen |= bit;
        } else try u.validate(value);
    }
    if (seen != std.math.maxInt(u11)) return error.Invalid;
    return .{ .status = status };
}
pub fn load(a: u.Allocator, environ: std.process.Environ, repo: []const u8) u.Error!Loaded {
    const dir = try openGitDir(a, environ, false);
    var dir_open = true;
    defer if (dir_open) {
        _ = c.close(dir);
    };
    var name_buf: [64]u8 = undefined;
    const name = try filename(&name_buf, repo, ".cache");
    const fd = c.openat(dir, name, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true });
    if (fd < 0) return error.Io;
    var fd_open = true;
    defer if (fd_open) {
        _ = c.close(fd);
    };
    var info: c.Stat = undefined;
    if (c.fstat(fd, &info) != 0 or !secureFile(info) or info.size <= 0 or info.size >= 16384) return error.Invalid;
    const buf = try a.alloc(u8, @intCast(info.size));
    defer a.free(buf);
    var at: usize = 0;
    while (at < buf.len) {
        const n = try os.read(fd, buf[at..]);
        if (n == 0) return error.Invalid;
        at += n;
    }
    var extra: [1]u8 = undefined;
    if (try os.read(fd, &extra) != 0) return error.Invalid;
    fd_open = false;
    try os.close(fd);
    dir_open = false;
    try os.close(dir);
    return parse(a, buf, repo);
}
pub fn serialize(writer: *std.Io.Writer, repo: []const u8, status: git.Status) !void {
    try writer.writeAll("version=2\nrepo=");
    try u.encode(writer, repo);
    try writer.print("\nupdated_ms={d}\nbranch=", .{status.updated_ms});
    try u.encode(writer, status.branch);
    inline for (.{ "staged", "modified", "untracked", "conflicted", "ahead", "behind", "stashes" }) |field| try writer.print("\n{s}={d}", .{ field, @field(status, field) });
    try writer.writeByte('\n');
}
pub fn store(a: u.Allocator, environ: std.process.Environ, repo: []const u8, status: git.Status) u.Error!void {
    if (status.updated_ms == 0 or !u.branchValid(status.branch)) return error.Invalid;
    const dir = try openGitDir(a, environ, true);
    var dir_open = true;
    defer if (dir_open) {
        _ = c.close(dir);
    };
    var name_buf: [64]u8 = undefined;
    const name = try filename(&name_buf, repo, ".cache");
    var info: c.Stat = undefined;
    if (c.fstatat(dir, name, &info, c.AT.SYMLINK_NOFOLLOW) == 0) {
        if (!secureFile(info)) return error.Invalid;
    } else if (os.errno() != .NOENT) return error.Io;
    var temp_buf: [128]u8 = undefined;
    var temp: [:0]u8 = undefined;
    var fd: c.fd_t = -1;
    const nonce = os.millis(true);
    for (0..128) |attempt| {
        temp = std.fmt.bufPrintSentinel(&temp_buf, "{x:0>16}.cache.tmp.{d}.{d}.{d}", .{ u.hashPath(repo), c.getpid(), nonce, attempt }, 0) catch return error.Limit;
        fd = c.openat(dir, temp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
        if (fd >= 0) break;
        if (os.errno() != .EXIST) return error.Io;
    }
    if (fd < 0) return error.Io;
    defer _ = c.unlinkat(dir, temp, 0);
    var fd_open = true;
    defer if (fd_open) {
        _ = c.close(fd);
    };
    if (c.fchmod(fd, 0o600) != 0 or c.fstat(fd, &info) != 0 or !secureFile(info)) return error.Invalid;
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    serialize(&output.writer, repo, status) catch return error.OutOfMemory;
    try os.writeAll(fd, output.written());
    if (c.fsync(fd) != 0) return error.Io;
    fd_open = false;
    try os.close(fd);
    if (c.renameat(dir, temp, dir, name) != 0) return error.Io;
    dir_open = false;
    try os.close(dir);
}
pub fn lock(a: u.Allocator, environ: std.process.Environ, repo: []const u8) u.Error!c.fd_t {
    const dir = try openGitDir(a, environ, true);
    var dir_open = true;
    defer if (dir_open) {
        _ = c.close(dir);
    };
    var name_buf: [64]u8 = undefined;
    const name = try filename(&name_buf, repo, ".lock");
    var created = true;
    var fd = c.openat(dir, name, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0 and os.errno() == .EXIST) {
        created = false;
        fd = c.openat(dir, name, .{ .ACCMODE = .RDWR, .NOFOLLOW = true, .CLOEXEC = true });
    }
    if (fd < 0) return error.Io;
    errdefer _ = c.close(fd);
    if (created and c.fchmod(fd, 0o600) != 0) {
        _ = c.unlinkat(dir, name, 0);
        return error.Io;
    }
    var info: c.Stat = undefined;
    if (c.fstat(fd, &info) != 0 or !secureFile(info)) {
        if (created) _ = c.unlinkat(dir, name, 0);
        return error.Invalid;
    }
    var record: c.Flock = .{ .type = c.F.WRLCK, .whence = c.SEEK.SET, .start = 0, .len = 0, .pid = 0 };
    if (c.fcntl(fd, c.F.SETLK, &record) != 0) {
        if (os.errno() == .ACCES or os.errno() == .AGAIN) return error.Busy;
        return error.Io;
    }
    dir_open = false;
    try os.close(dir);
    return fd;
}
pub fn unlock(fd: c.fd_t) void {
    var record: c.Flock = .{ .type = c.F.UNLCK, .whence = c.SEEK.SET, .start = 0, .len = 0, .pid = 0 };
    _ = c.fcntl(fd, c.F.SETLK, &record);
    _ = c.close(fd);
}
pub fn artifact(name: []const u8) bool {
    if (name.len < 22) return false;
    for (name[0..16]) |ch| if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return false;
    return u.eq(name[16..], ".cache") or (name.len > 27 and u.starts(name[16..], ".cache.tmp."));
}
pub fn clear(a: u.Allocator, environ: std.process.Environ) u.Error!void {
    const dir = openGitDir(a, environ, false) catch |err| {
        if (err == error.Missing) return;
        return err;
    };
    const unlink_fd = c.fcntl(dir, c.F.DUPFD_CLOEXEC, @as(c_int, 0));
    if (unlink_fd < 0) {
        _ = c.close(dir);
        return error.Io;
    }
    var unlink_open = true;
    defer if (unlink_open) {
        _ = c.close(unlink_fd);
    };
    const handle = c.fdopendir(dir) orelse {
        _ = c.close(dir);
        return error.Io;
    };
    var handle_open = true;
    defer if (handle_open) {
        _ = c.closedir(handle);
    };
    var names: std.ArrayList([:0]u8) = .empty;
    defer {
        for (names.items) |name| a.free(name);
        names.deinit(a);
    }
    while (true) {
        c._errno().* = 0;
        const entry = c.readdir(handle) orelse {
            if (os.errno() != .SUCCESS) return error.Io;
            break;
        };
        const name = entry.name[0..entry.namlen];
        if (!artifact(name)) continue;
        const copy = try a.dupeZ(u8, name);
        errdefer a.free(copy);
        try names.append(a, copy);
    }
    handle_open = false;
    if (c.closedir(handle) != 0) return error.Io;
    var failed = false;
    for (names.items) |name| {
        var info: c.Stat = undefined;
        if (c.fstatat(unlink_fd, name, &info, c.AT.SYMLINK_NOFOLLOW) != 0) {
            if (os.errno() != .NOENT) failed = true;
        } else if (!secureFile(info)) failed = true else if (c.unlinkat(unlink_fd, name, 0) != 0 and os.errno() != .NOENT) failed = true;
    }
    unlink_open = false;
    try os.close(unlink_fd);
    if (failed) return error.Io;
}
