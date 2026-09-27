const std = @import("std");
const u = @import("util.zig");
const os = @import("darwin.zig");
const git = @import("git.zig");
const cache = @import("cache.zig");
pub const Snapshot = struct {
    cwd: [:0]u8,
    path: []u8,
    branch: []const u8 = "",
    node_version: []const u8 = "",
    git_present: bool = false,
    git_valid: bool = false,
    git_status: git.Status = .{},
    status: u8,
    duration_ms: u64,
    jobs: u32,
    pub fn deinit(self: Snapshot, a: u.Allocator) void {
        a.free(self.cwd);
        a.free(self.path);
        if (self.branch.len != 0) a.free(self.branch);
    }
};
pub fn collect(a: u.Allocator, environ: std.process.Environ, status: u8, duration: u64, jobs: u32) u.Error!Snapshot {
    const cwd = try os.cwd(a);
    errdefer a.free(cwd);
    const path = try u.abbreviate(a, cwd);
    errdefer a.free(path);
    var result: Snapshot = .{ .cwd = cwd, .path = path, .status = status, .duration_ms = duration, .jobs = jobs, .node_version = u.nvmVersion(os.env(environ, "NVM_BIN") orelse "") };
    const repo = git.discover(a, cwd) catch |err| {
        if (err == error.OutOfMemory) return err;
        return result;
    };
    defer repo.deinit(a);
    result.git_present = true;
    const cached: ?cache.Loaded = cache.load(a, environ, repo.root) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        break :blk null;
    };
    defer if (cached) |value| value.deinit(a);
    const current = git.readBranch(a, repo) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        break :blk null;
    };
    if (current) |branch| {
        result.branch = branch;
        if (cached) |value| if (u.eq(value.status.branch, branch)) {
            result.git_valid = true;
            result.git_status = value.status;
        };
    } else if (cached) |value| {
        result.branch = try a.dupe(u8, value.status.branch);
    }
    result.git_status.branch = result.branch;
    return result;
}
pub fn write(out: *std.Io.Writer, data: Snapshot, nul: bool) !void {
    try record(out, "schema_version", "2", nul);
    try record(out, "cwd", data.cwd, nul);
    try record(out, "path", data.path, nul);
    try number(out, "status", data.status, nul);
    try number(out, "duration_ms", data.duration_ms, nul);
    try number(out, "jobs", data.jobs, nul);
    try record(out, "node_version", data.node_version, nul);
    try number(out, "git_present", @intFromBool(data.git_present), nul);
    try number(out, "git_valid", @intFromBool(data.git_valid), nul);
    try record(out, "git_branch", data.branch, nul);
    try number(out, "git_updated_ms", data.git_status.updated_ms, nul);
    inline for (.{ "staged", "modified", "untracked", "conflicted", "ahead", "behind", "stashes" }) |key| try number(out, "git_" ++ key, @field(data.git_status, key), nul);
}
pub fn record(out: *std.Io.Writer, key: []const u8, value: []const u8, nul: bool) !void {
    try out.writeAll(key);
    try out.writeByte(if (nul) 0 else '=');
    if (nul) try out.writeAll(value) else try u.encode(out, value);
    try out.writeByte(if (nul) 0 else '\n');
}
fn number(out: *std.Io.Writer, key: []const u8, value: u64, nul: bool) !void {
    var buf: [32]u8 = undefined;
    try record(out, key, try std.fmt.bufPrint(&buf, "{d}", .{value}), nul);
}
