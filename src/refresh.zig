const std = @import("std");
const u = @import("util.zig");
const os = @import("darwin.zig");
const git = @import("git.zig");
const cache = @import("cache.zig");
pub fn timeoutFromEnv(environ: std.process.Environ) u32 {
    const value = os.env(environ, "NBSP_GIT_TIMEOUT_MS") orelse return 1500;
    // CLI/environment integers retain strtol's whitespace and optional '+' behavior.
    const parsed = u.signedDecimal(value) catch return 1500;
    return if (parsed >= 50 and parsed <= 60000) @intCast(parsed) else 1500;
}
fn fresh(a: u.Allocator, environ: std.process.Environ, repo: []const u8) u.Error!bool {
    const value = cache.load(a, environ, repo) catch |err| {
        if (err == error.OutOfMemory) return err;
        return false;
    };
    defer value.deinit(a);
    const now = os.millis(false);
    return now >= value.status.updated_ms and now - value.status.updated_ms < 250;
}
pub fn run(a: u.Allocator, environ: std.process.Environ, cwd: [:0]const u8, force: bool) u.Error!void {
    const repo = git.discover(a, cwd) catch |err| {
        if (err == error.OutOfMemory) return err;
        return;
    };
    defer repo.deinit(a);
    if (!force and try fresh(a, environ, repo.root)) return;
    const fd = cache.lock(a, environ, repo.root) catch |err| {
        if (err == error.Busy) return;
        return err;
    };
    defer cache.unlock(fd);
    if (!force and try fresh(a, environ, repo.root)) return;
    const collected = try git.collect(a, environ, repo, timeoutFromEnv(environ));
    defer collected.deinit(a);
    const branch = try git.readBranch(a, repo);
    defer a.free(branch);
    if (!u.eq(branch, collected.status.branch)) return error.Invalid;
    try cache.store(a, environ, repo.root, collected.status);
}
