const std = @import("std");
const u = @import("util.zig");
pub const c = std.c;
pub fn errno() c.E {
    return @enumFromInt(c._errno().*);
}
pub fn close(fd: c.fd_t) u.Error!void {
    if (c.close(fd) != 0) return error.Io;
}
pub fn writeAll(fd: c.fd_t, bytes: []const u8) u.Error!void {
    var at: usize = 0;
    while (at < bytes.len) {
        const n = c.write(fd, bytes.ptr + at, bytes.len - at);
        if (n > 0) at += @intCast(n) else if (n == 0 or errno() != .INTR) return error.Io;
    }
}
pub fn read(fd: c.fd_t, bytes: []u8) u.Error!usize {
    while (true) {
        const n = c.read(fd, bytes.ptr, bytes.len);
        if (n >= 0) return @intCast(n);
        if (errno() != .INTR) return error.Io;
    }
}
pub fn cwd(a: u.Allocator) u.Error![:0]u8 {
    const buf = try a.allocSentinel(u8, u.path_cap - 1, 0);
    defer a.free(buf);
    if (c.getcwd(buf.ptr, buf.len + 1) == null) return error.Io;
    return a.dupeZ(u8, std.mem.sliceTo(buf, 0));
}
pub fn realpath(a: u.Allocator, path: [:0]const u8) u.Error![:0]u8 {
    const buf = try a.allocSentinel(u8, u.path_cap - 1, 0);
    defer a.free(buf);
    if (c.realpath(path, buf.ptr) == null) return error.Io;
    return a.dupeZ(u8, std.mem.sliceTo(buf, 0));
}
pub fn clockMillis(monotonic: bool) u.Error!u64 {
    var t: c.timespec = undefined;
    if (c.clock_gettime(if (monotonic) c.CLOCK.MONOTONIC else c.CLOCK.REALTIME, &t) != 0 or t.sec < 0 or t.nsec < 0 or t.nsec >= 1000000000) return error.Io;
    const seconds: u64 = @intCast(t.sec);
    if (seconds > (std.math.maxInt(u64) - 999) / 1000) return error.Limit;
    return seconds * 1000 + @as(u64, @intCast(t.nsec)) / 1000000;
}
pub fn millis(monotonic: bool) u64 {
    return clockMillis(monotonic) catch 0;
}
pub fn env(environ: std.process.Environ, key: []const u8) ?[]const u8 {
    return environ.getPosix(key);
}
pub fn readLine(a: u.Allocator, path: [:0]const u8, cap: usize) u.Error![]u8 {
    const fd = c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return error.Io;
    var open = true;
    defer if (open) {
        _ = c.close(fd);
    };
    const buf = try a.alloc(u8, cap - 1);
    defer a.free(buf);
    var at: usize = 0;
    while (at < buf.len) {
        const count = try read(fd, buf[at..]);
        if (count == 0) {
            if (at == 0) return error.Invalid;
            break;
        }
        const chunk = buf[at..][0..count];
        if (std.mem.indexOfScalar(u8, chunk, 0) != null) return error.Invalid;
        if (std.mem.indexOfScalar(u8, chunk, '\n')) |p| {
            at += p;
            break;
        }
        at += count;
        if (at == buf.len) return error.Limit;
    }
    open = false;
    try close(fd);
    if (at > 0 and buf[at - 1] == '\r') at -= 1;
    return a.dupe(u8, buf[0..at]);
}
pub extern "c" fn dirfd(dir: *c.DIR) c_int;
pub fn stat(path: [*:0]const u8, info: *c.Stat) c_int {
    return c.fstatat(c.AT.FDCWD, path, info, 0);
}
pub fn lstat(path: [*:0]const u8, info: *c.Stat) c_int {
    return c.fstatat(c.AT.FDCWD, path, info, c.AT.SYMLINK_NOFOLLOW);
}
pub extern "c" fn posix_spawnattr_setpgroup(attr: *c.posix_spawnattr_t, pgroup: c.pid_t) c_int;
/// Buffered synchronous descriptor writer. No scheduler or filesystem machinery
/// is needed to write a completed protocol frame to stdout.
pub const Writer = struct {
    fd: c.fd_t,
    interface: std.Io.Writer,
    pub fn init(fd: c.fd_t, buffer: []u8) Writer {
        return .{ .fd = fd, .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Writer = @fieldParentPtr("interface", w);
        writeAll(self.fd, w.buffer[0..w.end]) catch return error.WriteFailed;
        w.end = 0;
        var size: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            writeAll(self.fd, bytes) catch return error.WriteFailed;
            size += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            writeAll(self.fd, last) catch return error.WriteFailed;
            size += last.len;
        }
        return size;
    }
};

// Darwin's interval timer is absent from std.c in Zig 0.16. Use the system ABI.
const Interval = extern struct { interval: c.timeval, value: c.timeval };
extern "c" fn setitimer(which: c_int, noalias value: *const Interval, noalias old: ?*Interval) c_int;
pub fn armDirectoryTimer() u.Error!void {
    var action: c.Sigaction = .{ .handler = .{ .handler = c.SIG.DFL }, .mask = 0, .flags = 0 };
    if (c.sigaction(.ALRM, &action, null) != 0) return error.Io;
    const mask: c.sigset_t = @as(c.sigset_t, 1) << (@intFromEnum(c.SIG.ALRM) - 1);
    if (c.sigprocmask(c.SIG.UNBLOCK, &mask, null) != 0) return error.Io;
    const timer: Interval = .{ .interval = .{ .sec = 0, .usec = 0 }, .value = .{ .sec = 0, .usec = 50000 } };
    if (setitimer(0, &timer, null) != 0) return error.Io;
}
pub fn disarmDirectoryTimer() void {
    const timer: Interval = std.mem.zeroes(Interval);
    _ = setitimer(0, &timer, null);
}
