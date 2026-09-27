const std = @import("std");
const u = @import("util.zig");
const os = @import("darwin.zig");
const c = os.c;

pub const Repo = struct {
    root: [:0]u8,
    git_dir: [:0]u8,
    pub fn deinit(self: Repo, a: u.Allocator) void {
        a.free(self.root);
        a.free(self.git_dir);
    }
};
pub const Status = struct {
    branch: []const u8 = "",
    updated_ms: u64 = 0,
    staged: u32 = 0,
    modified: u32 = 0,
    untracked: u32 = 0,
    conflicted: u32 = 0,
    ahead: u32 = 0,
    behind: u32 = 0,
    stashes: u32 = 0,
};
pub fn discover(a: u.Allocator, cwd: [:0]const u8) u.Error!Repo {
    const physical = try os.realpath(a, cwd);
    defer a.free(physical);
    var info: c.Stat = undefined;
    if (os.stat(physical, &info) != 0 or !c.S.ISDIR(info.mode)) return error.Invalid;
    const device = info.dev;
    var current: []const u8 = physical;
    while (true) {
        const path = try a.dupeZ(u8, current);
        defer a.free(path);
        if (os.stat(path, &info) != 0 or info.dev != device) return error.Invalid;
        const git_path = try std.fmt.allocPrintSentinel(a, "{s}{s}.git", .{ current, if (u.eq(current, "/")) "" else "/" }, 0);
        defer a.free(git_path);
        if (git_path.len >= u.path_cap) return error.Limit;
        if (os.lstat(git_path, &info) == 0) {
            if (os.stat(git_path, &info) != 0) return error.Io;
            const git_dir = if (c.S.ISDIR(info.mode)) try os.realpath(a, git_path) else if (c.S.ISREG(info.mode)) blk: {
                const line = try os.readLine(a, git_path, u.path_cap);
                defer a.free(line);
                if (!u.starts(line, "gitdir: ") or line.len == 8) return error.Invalid;
                const value = line[8..];
                const candidate = if (value[0] == '/') try a.dupeZ(u8, value) else try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ current, value }, 0);
                defer a.free(candidate);
                if (candidate.len >= u.path_cap) return error.Limit;
                break :blk try os.realpath(a, candidate);
            } else return error.Invalid;
            errdefer a.free(git_dir);
            if (os.stat(git_dir, &info) != 0 or !c.S.ISDIR(info.mode)) return error.Invalid;
            return .{ .root = try a.dupeZ(u8, current), .git_dir = git_dir };
        }
        if (os.errno() != .NOENT and os.errno() != .NOTDIR) return error.Io;
        if (u.eq(current, "/")) return error.Missing;
        const slash = std.mem.lastIndexOfScalar(u8, current, '/') orelse return error.Invalid;
        current = current[0..if (slash == 0) 1 else slash];
    }
}
fn noSpace(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| if (ch <= 32 or ch == 127) return false;
    return true;
}
fn oidValid(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}
fn symbolic(a: u.Allocator, reference: []const u8) u.Error![]u8 {
    if (!u.starts(reference, "refs/")) return error.Invalid;
    const label = if (u.starts(reference, "refs/heads/")) reference[11..] else reference;
    if (!noSpace(label) or label.len > 255) return error.Invalid;
    return a.dupe(u8, label);
}
pub fn readBranch(a: u.Allocator, repo: Repo) u.Error![]u8 {
    const path = try std.fmt.allocPrintSentinel(a, "{s}/HEAD", .{repo.git_dir}, 0);
    defer a.free(path);
    if (path.len >= u.path_cap) return error.Limit;
    var info: c.Stat = undefined;
    if (os.lstat(path, &info) != 0) return error.Io;
    if (c.S.ISLNK(info.mode)) {
        const buf = try a.alloc(u8, 1023);
        defer a.free(buf);
        const len = c.readlink(path, buf.ptr, buf.len);
        if (len <= 0) return error.Invalid;
        return symbolic(a, buf[0..@intCast(len)]);
    }
    if (!c.S.ISREG(info.mode)) return error.Invalid;
    const line = try os.readLine(a, path, 1024);
    defer a.free(line);
    if (u.starts(line, "ref: ")) return symbolic(a, line[5..]);
    if (!oidValid(line)) return error.Invalid;
    return a.dupe(u8, line[0..8]);
}
fn modeValid(field: []const u8) bool {
    for ([_][]const u8{ "000000", "100644", "100755", "120000", "160000" }) |mode| if (u.eq(field, mode)) return true;
    return false;
}
fn submoduleValid(field: []const u8) bool {
    if (u.eq(field, "N...")) return true;
    return field.len == 4 and field[0] == 'S' and (field[1] == '.' or field[1] == 'C') and (field[2] == '.' or field[2] == 'M') and (field[3] == '.' or field[3] == 'U');
}
fn takeField(cursor: *[]const u8) u.Error![]const u8 {
    const space = std.mem.indexOfScalar(u8, cursor.*, ' ') orelse return error.Invalid;
    if (space == 0 or space + 1 >= cursor.len or cursor.*[space + 1] == ' ' or std.mem.indexOfScalar(u8, cursor.*[0..space], '\t') != null) return error.Invalid;
    const field = cursor.*[0..space];
    cursor.* = cursor.*[space + 1 ..];
    return field;
}
fn increment(count: *u32) u.Error!void {
    if (count.* == std.math.maxInt(u32)) return error.Invalid;
    count.* += 1;
}
fn tracked(line: []const u8, status: *Status) u.Error!void {
    var cursor = line[2..];
    var fields: [8][]const u8 = undefined;
    const renamed = line[0] == '2';
    const count: usize = if (renamed) 8 else 7;
    for (fields[0..count]) |*field| field.* = try takeField(&cursor);
    if (fields[0].len != 2) return error.Invalid;
    for (fields[0]) |ch| if (std.mem.indexOfScalar(u8, ".MTADRCU", ch) == null) return error.Invalid;
    if (!submoduleValid(fields[1])) return error.Invalid;
    for (fields[2..5]) |field| if (!modeValid(field)) return error.Invalid;
    for (fields[5..7]) |field| if (!oidValid(field)) return error.Invalid;
    if (cursor.len == 0) return error.Invalid;
    if (renamed) {
        const score = fields[7];
        if (score.len < 2 or (score[0] != 'R' and score[0] != 'C') or try u.unsigned(u32, score[1..]) > 100) return error.Invalid;
        const tab = std.mem.indexOfScalar(u8, cursor, '\t') orelse return error.Invalid;
        if (tab == 0 or tab + 1 == cursor.len) return error.Invalid;
    }
    if (fields[0][0] != '.') try increment(&status.staged);
    if (fields[0][1] != '.') try increment(&status.modified);
}
fn unmerged(line: []const u8, status: *Status) u.Error!void {
    var cursor = line[2..];
    var fields: [9][]const u8 = undefined;
    for (&fields) |*field| field.* = try takeField(&cursor);
    var valid = false;
    for ([_][]const u8{ "DD", "AU", "UD", "UA", "DU", "AA", "UU" }) |xy| {
        if (u.eq(fields[0], xy)) valid = true;
    }
    if (!valid or !submoduleValid(fields[1])) return error.Invalid;
    for (fields[2..6]) |field| if (!modeValid(field)) return error.Invalid;
    for (fields[6..9]) |field| if (!oidValid(field)) return error.Invalid;
    if (cursor.len == 0) return error.Invalid;
    try increment(&status.conflicted);
}
/// Returned branch borrows the input. Callers retain input until publication ends.
pub fn parse(output: []const u8, timestamp: u64) u.Error!Status {
    if (output.len == 0 or output[output.len - 1] != '\n' or std.mem.indexOfScalar(u8, output, 0) != null) return error.Invalid;
    var result: Status = .{ .updated_ms = timestamp };
    var seen: u5 = 0;
    var detached_oid: []const u8 = "";
    var initial = false;
    var detached = false;
    var saw_record = false;
    var lines = std.mem.splitScalar(u8, output[0 .. output.len - 1], '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or std.mem.indexOfScalar(u8, line, '\r') != null) return error.Invalid;
        if (line[0] == '#') {
            if (saw_record) return error.Invalid;
            var bit: u5 = 0;
            if (u.starts(line, "# branch.oid ")) {
                bit = 1;
                const oid = line[13..];
                initial = u.eq(oid, "(initial)");
                if (!initial) {
                    if (!oidValid(oid)) return error.Invalid;
                    detached_oid = oid[0..8];
                }
            } else if (u.starts(line, "# branch.head ")) {
                bit = 2;
                const branch = line[14..];
                if (!noSpace(branch)) return error.Invalid;
                detached = u.eq(branch, "(detached)");
                if (!detached) {
                    if (branch.len > 255) return error.Invalid;
                    result.branch = branch;
                }
            } else if (u.starts(line, "# branch.upstream ")) {
                bit = 4;
                if (!noSpace(line[18..])) return error.Invalid;
            } else if (u.starts(line, "# branch.ab ")) {
                bit = 8;
                const value = line[12..];
                if (!u.starts(value, "+")) return error.Invalid;
                const space = std.mem.indexOfScalar(u8, value, ' ') orelse return error.Invalid;
                if (space + 1 >= value.len or value[space + 1] != '-') return error.Invalid;
                result.ahead = try u.unsigned(u32, value[1..space]);
                result.behind = try u.unsigned(u32, value[space + 2 ..]);
            } else if (u.starts(line, "# stash ")) {
                bit = 16;
                result.stashes = try u.unsigned(u32, line[8..]);
                if (result.stashes == 0) return error.Invalid;
            } else {
                if (!u.starts(line, "# ") or line.len == 2) return error.Invalid;
                for (line[2..]) |ch| if (ch < 32 or ch == 127) return error.Invalid;
            }
            if (seen & bit != 0) return error.Invalid;
            seen |= bit;
        } else {
            saw_record = true;
            if (u.starts(line, "1 ") or u.starts(line, "2 ")) try tracked(line, &result) else if (u.starts(line, "u ")) try unmerged(line, &result) else if (line.len > 2 and u.starts(line, "? ")) try increment(&result.untracked) else if (!(line.len > 2 and u.starts(line, "! "))) return error.Invalid;
        }
    }
    if (seen & 3 != 3 or (seen & 8 != 0 and seen & 4 == 0) or (detached and (initial or detached_oid.len == 0))) return error.Invalid;
    if (detached) result.branch = detached_oid;
    return result;
}

const selector_names = [_][]const u8{
    "GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_IMPLICIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_NAMESPACE", "GIT_SHALLOW_FILE", "GIT_GRAFT_FILE", "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE", "GIT_REFERENCE_BACKEND", "GIT_QUARANTINE_PATH", "GIT_PREFIX", "GIT_SUPER_PREFIX", "GIT_INTERNAL_SUPER_PREFIX",
};
fn selector(entry: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, entry, '=') orelse return false;
    for (selector_names) |name| if (u.eq(entry[0..end], name)) return true;
    return false;
}
fn killGroup(child: c.pid_t) void {
    _ = c.kill(-child, .KILL);
    _ = c.kill(child, .KILL);
}
fn reap(child: c.pid_t) void {
    var status: c_int = 0;
    while (c.waitpid(child, &status, 0) < 0 and os.errno() == .INTR) {}
}
fn preparePipe(fd: *c.fd_t, nonblocking: bool) u.Error!void {
    if (fd.* <= 2) {
        const replacement = c.fcntl(fd.*, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
        if (replacement < 0) return error.Io;
        const old = fd.*;
        fd.* = replacement;
        try os.close(old);
    }
    const flags = c.fcntl(fd.*, c.F.GETFD);
    if (flags < 0 or c.fcntl(fd.*, c.F.SETFD, flags | @as(c_int, c.FD_CLOEXEC)) != 0) return error.Io;
    if (nonblocking) {
        const file_flags = c.fcntl(fd.*, c.F.GETFL);
        const nonblock: c_int = @intCast(@as(u32, @bitCast(c.O{ .NONBLOCK = true })));
        if (file_flags < 0 or c.fcntl(fd.*, c.F.SETFL, file_flags | nonblock) != 0) return error.Io;
    }
}
pub const Collected = struct {
    output: []u8,
    status: Status,
    pub fn deinit(self: Collected, a: u.Allocator) void {
        a.free(self.output);
    }
};
pub fn collect(a: u.Allocator, environ: std.process.Environ, repo: Repo, timeout: u32) u.Error!Collected {
    const started = try os.clockMillis(true);
    var pipe: [2]c.fd_t = undefined;
    if (c.pipe(&pipe) != 0) return error.Io;
    var read_open = true;
    var write_open = true;
    defer if (read_open) {
        _ = c.close(pipe[0]);
    };
    defer if (write_open) {
        _ = c.close(pipe[1]);
    };
    try preparePipe(&pipe[0], true);
    try preparePipe(&pipe[1], false);
    var actions: c.posix_spawn_file_actions_t = undefined;
    if (c.posix_spawn_file_actions_init(&actions) != 0) return error.Io;
    var actions_open = true;
    defer if (actions_open) {
        _ = c.posix_spawn_file_actions_destroy(&actions);
    };
    if (c.posix_spawn_file_actions_adddup2(&actions, pipe[1], 1) != 0 or c.posix_spawn_file_actions_addclose(&actions, pipe[0]) != 0 or c.posix_spawn_file_actions_addclose(&actions, pipe[1]) != 0 or c.posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", 0, 0) != 0 or c.posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", 1, 0) != 0) return error.Io;
    var attr: c.posix_spawnattr_t = undefined;
    if (c.posix_spawnattr_init(&attr) != 0) return error.Io;
    var attr_open = true;
    defer if (attr_open) {
        _ = c.posix_spawnattr_destroy(&attr);
    };
    if (os.posix_spawnattr_setpgroup(&attr, 0) != 0 or c.posix_spawnattr_setflags(&attr, .{ .SETPGROUP = true }) != 0) return error.Io;
    const block = environ.block.slice;
    const clean = try a.allocSentinel(?[*:0]const u8, block.len, null);
    defer a.free(clean);
    var count: usize = 0;
    for (block) |entry| {
        if (!selector(std.mem.span(entry.?))) {
            clean[count] = entry;
            count += 1;
        }
    }
    clean[count] = null;
    const git_arg = try std.fmt.allocPrintSentinel(a, "--git-dir={s}", .{repo.git_dir}, 0);
    defer a.free(git_arg);
    const work_arg = try std.fmt.allocPrintSentinel(a, "--work-tree={s}", .{repo.root}, 0);
    defer a.free(work_arg);
    const argv = [_:null]?[*:0]const u8{ "git", "--no-optional-locks", "-C", repo.root, git_arg, work_arg, "status", "--porcelain=v2", "--branch", "--show-stash", "--untracked-files=normal", "--ignore-submodules=dirty", "--no-renames" };
    var child: c.pid_t = 0;
    if (c.posix_spawnp(&child, "git", &actions, &attr, &argv, clean.ptr) != 0) return error.Io;
    var reaped = false;
    defer if (!reaped) {
        killGroup(child);
        reap(child);
    };
    attr_open = false;
    const attr_result = c.posix_spawnattr_destroy(&attr);
    actions_open = false;
    const actions_result = c.posix_spawn_file_actions_destroy(&actions);
    write_open = false;
    try os.close(pipe[1]);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(a);
    var eof = false;
    var child_status: c_int = 0;
    var chunk: [8192]u8 = undefined;
    while (true) {
        if (eof) {
            const waited = c.waitpid(child, &child_status, c.W.NOHANG);
            if (waited == child) {
                reaped = true;
                if (!c.W.IFEXITED(@bitCast(child_status)) or c.W.EXITSTATUS(@bitCast(child_status)) != 0) return error.Io;
                break;
            }
            if (waited < 0 and os.errno() == .CHILD) {
                reaped = true;
                return error.Io;
            }
            if (waited < 0 and os.errno() != .INTR) return error.Io;
        }
        var now = try os.clockMillis(true);
        if (now < started or now - started >= timeout) return error.Timeout;
        const remaining = timeout - (now - started);
        var pfd: c.pollfd = .{ .fd = pipe[0], .events = c.POLL.IN | c.POLL.HUP, .revents = 0 };
        const ready = c.poll(@ptrCast(&pfd), if (eof) 0 else 1, @intCast(@min(remaining, 25)));
        if (ready < 0) {
            if (os.errno() == .INTR) continue;
            return error.Io;
        }
        if (ready == 0 or eof) continue;
        if (pfd.revents & c.POLL.NVAL != 0) return error.Io;
        if (pfd.revents & (c.POLL.IN | c.POLL.HUP | c.POLL.ERR) == 0) continue;
        while (true) {
            now = try os.clockMillis(true);
            if (now < started or now - started >= timeout) return error.Timeout;
            const n = c.read(pipe[0], &chunk, chunk.len);
            if (n > 0) {
                const size: usize = @intCast(n);
                if (size > 8 * 1024 * 1024 - output.items.len) return error.Limit;
                try output.appendSlice(a, chunk[0..size]);
            } else if (n == 0) {
                eof = true;
                break;
            } else if (os.errno() == .AGAIN) break else if (os.errno() != .INTR) return error.Io;
        }
    }
    read_open = false;
    try os.close(pipe[0]);
    if (attr_result != 0 or actions_result != 0) return error.Io;
    const bytes = try output.toOwnedSlice(a);
    errdefer a.free(bytes);
    return .{ .output = bytes, .status = try parse(bytes, try os.clockMillis(false)) };
}
