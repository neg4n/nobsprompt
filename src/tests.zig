const std = @import("std");
const t = std.testing;
const a = t.allocator;
const u = @import("util.zig");
const os = @import("darwin.zig");
const git = @import("git.zig");
const cache = @import("cache.zig");
const dirs = @import("dirs.zig");
const snapshot = @import("snapshot.zig");
const header = "# branch.oid 1234567890abcdef1234567890abcdef12345678\n# branch.head main\n";
const fixture = "version=2\nrepo=/tmp/repo%20with%20spaces\nupdated_ms=123456\nbranch=main\nstaged=1\nmodified=2\nuntracked=3\nconflicted=4\nahead=5\nbehind=6\nstashes=7\n";

test "byte paths retain abbreviation rules and malformed UTF-8" {
    const paths = [_][]const u8{ "/Users/igorklepacki/programming/test", "/one/.config/three/four", "/", "relative/tree/end", "/αβ/γδ/end", "/\xffbad/final", "" };
    const expected = [_][]const u8{ "/U/i/p/test", "/o/.c/t/four", "/", "r/t/end", "/α/γ/end", "/\xff/final", "?" };
    for (paths, expected) |path, gold| {
        const result = try u.abbreviate(a, path);
        defer a.free(result);
        try t.expectEqualStrings(gold, result);
    }
}
test "NVM label extraction is borrowed and bounded" {
    for ([_][]const u8{ "/x/v22.1.0/bin", "/x/v22.1.0/bin///", "v22.1.0", "/x/alias-name/bin", "bin", "/bin", "/a//bin", "/x/evil$(command)/bin", "/", "" }, [_][]const u8{ "22.1.0", "22.1.0", "22.1.0", "alias-name", "bin", "", "", "", "", "" }) |value, gold| try t.expectEqualStrings(gold, u.nvmVersion(value));
    var long: [256]u8 = @splat('a');
    try t.expectEqual(@as(usize, 0), u.nvmVersion(&long).len);
    try t.expectEqual(@as(usize, 255), u.nvmVersion(long[0..255]).len);
}
test "strict unsigned parsing rejects signs, whitespace, and overflow" {
    try t.expectEqual(std.math.maxInt(u64), try u.unsigned(u64, "18446744073709551615"));
    try t.expectEqual(std.math.maxInt(u32), try u.unsigned(u32, "4294967295"));
    for ([_][]const u8{ "", "-1", "+1", " 1", "1 ", "1x", "18446744073709551616" }) |bad| try t.expectError(error.Invalid, u.unsigned(u64, bad));
    try t.expectError(error.Invalid, u.unsigned(u32, "4294967296"));
    try t.expectEqual(@as(u64, 0xcbf29ce484222325), u.hashPath(""));
    try t.expectEqual(@as(u64, 0xaf63dc4c8601ec8c), u.hashPath("a"));
}
test "percent codec is lossless for every non-NUL byte" {
    var bytes: [255]u8 = undefined;
    for (&bytes, 1..) |*byte, value| byte.* = @intCast(value);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try u.encode(&out.writer, &bytes);
    const decoded = try u.decode(a, out.written(), 256);
    defer a.free(decoded);
    try t.expectEqualSlices(u8, &bytes, decoded);
    try t.expect(u.encodedEquals(out.written(), &bytes));
    try u.validate(out.written());
    for ([_][]const u8{ "%", "%a", "%GG", "%00", "space here", "a=b", "\x00", "#" }) |bad| try t.expectError(error.Invalid, u.validate(bad));
    try t.expectError(error.Limit, u.decode(a, "abcd", 4));
}
test "porcelain records and coherent headers" {
    const sample = header ++ "# branch.upstream origin/main\n# branch.ab +2 -3\n# stash 4\n" ++
        "1 M. N... 100644 100644 100644 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa staged\n" ++
        "1 .M N... 100644 100644 100644 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa modified\n" ++
        "1 MM N... 100644 100644 100644 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa both\n" ++
        "u UU N... 100644 100644 100644 100644 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa conflict\n? dir/\n! ignored\n";
    const result = try git.parse(sample, 42);
    try t.expectEqualStrings("main", result.branch);
    try t.expectEqual(@as(u32, 2), result.staged);
    try t.expectEqual(@as(u32, 2), result.modified);
    try t.expectEqual(@as(u32, 1), result.untracked);
    try t.expectEqual(@as(u32, 1), result.conflicted);
    try t.expectEqual(@as(u32, 2), result.ahead);
    try t.expectEqual(@as(u32, 3), result.behind);
    try t.expectEqual(@as(u32, 4), result.stashes);
    const detached = try git.parse("# branch.oid abcdef0123456789abcdef0123456789abcdef01\n# branch.head (detached)\n", 42);
    try t.expectEqualStrings("abcdef01", detached.branch);
    const rename = try git.parse(header ++ "2 R. N... 100644 100644 100644 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa R100 new\told\n", 42);
    try t.expectEqual(@as(u32, 1), rename.staged);
}
test "malformed porcelain never returns a partial status" {
    const bad = [_][]const u8{ "", "# branch.head main\n", header ++ "# branch.head other\n", header ++ "#unknown value\n", header ++ "# branch.ab +1 -0\n", header ++ "# stash -1\n", header ++ "# stash 0\n", header ++ "1 M. N... 100644\n", "# branch.oid (initial)\n# branch.head (detached)\n", header ++ "\n? untracked\n", header[0 .. header.len - 1], header ++ "? path\n# stash 1\n", header ++ "? p\r\n", header ++ "? a\x00b\n", header ++ "# branch.upstream origin/main\n# branch.ab +4294967296 -0\n" };
    for (bad) |input| try t.expectError(error.Invalid, git.parse(input, 42));
    var long: [256]u8 = @splat('a');
    const input = try std.mem.concat(a, u8, &.{ "# branch.oid (initial)\n# branch.head ", &long, "\n" });
    defer a.free(input);
    try t.expectError(error.Invalid, git.parse(input, 42));
}
test "cache version, fields, branch encoding and unknown keys" {
    const loaded = try cache.parse(a, fixture, "/tmp/repo with spaces");
    defer loaded.deinit(a);
    try t.expectEqual(@as(u32, 7), loaded.status.stashes);
    try t.expectEqualStrings("main", loaded.status.branch);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try cache.serialize(&out.writer, "/tmp/repo with spaces", loaded.status);
    try t.expectEqualStrings(fixture, out.written());
    const additive = try cache.parse(a, fixture ++ "future_key=%21\n", "/tmp/repo with spaces");
    defer additive.deinit(a);
    try t.expectError(error.Invalid, cache.parse(a, fixture, "/different"));
    for ([_][]const u8{ fixture ++ "branch=other\n", fixture ++ "future=x=y\n", fixture ++ "bad-key=x\n", fixture ++ "future=%00\n", fixture ++ "\n", fixture ++ "future=\x00\n", "version=2\nrepo=/tmp/repo%20with%20spaces\n" }) |input| try t.expectError(error.Invalid, cache.parse(a, input, "/tmp/repo with spaces"));
    const crlf = try std.mem.replaceOwned(u8, a, fixture, "\n", "\r\n");
    defer a.free(crlf);
    const compatible = try cache.parse(a, crlf, "/tmp/repo with spaces");
    defer compatible.deinit(a);
}
fn allocatingHelpers(allocator: u.Allocator) !void {
    const path = try u.abbreviate(allocator, "/one/.config/three/four");
    defer allocator.free(path);
    const decoded = try u.decode(allocator, "a%20b%FF", 256);
    defer allocator.free(decoded);
    const parsed = try cache.parse(allocator, fixture, "/tmp/repo with spaces");
    defer parsed.deinit(allocator);
    const normalized = try cache.normalize(allocator, "/tmp///cache/", "/nbsp");
    defer allocator.free(normalized);
}
test "all helper allocation failures unwind without leaks" {
    try t.checkAllAllocationFailures(a, allocatingHelpers, .{});
}
test "cache normalization and artifact names" {
    const path = try cache.normalize(a, "/tmp///cache/", "/nbsp");
    defer a.free(path);
    try t.expectEqualStrings("/tmp/cache/nbsp", path);
    for ([_][]const u8{ "", "relative", "/", "/tmp/./cache", "/tmp/../cache" }) |bad| try t.expectError(error.Invalid, cache.normalize(a, bad, ""));
    try t.expect(cache.artifact("0123456789abcdef.cache"));
    try t.expect(cache.artifact("0123456789abcdef.cache.tmp.1"));
    try t.expect(!cache.artifact("0123456789abcdef.lock"));
    try t.expect(!cache.artifact("0123456789abcdef.cache.tmp."));
    try t.expect(!cache.artifact("0123456789abcdeg.cache"));
}
const Environment = struct {
    entry: [:0]u8,
    block: [1:null]?[*:0]const u8,
    fn init(key: []const u8, value: []const u8) !Environment {
        const entry = try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ key, value }, 0);
        return .{ .entry = entry, .block = .{entry.ptr} };
    }
    fn get(self: *const Environment) std.process.Environ {
        return .{ .block = .{ .slice = &self.block } };
    }
    fn deinit(self: Environment) void {
        a.free(self.entry);
    }
};
fn tempPath(tmp: t.TmpDir) ![:0]u8 {
    const relative = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    defer a.free(relative);
    return os.realpath(a, relative);
}
fn writeFile(dir: os.c.fd_t, name: [:0]const u8, text: []const u8) !void {
    const fd = os.c.openat(dir, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(os.c.mode_t, 0o600));
    if (fd < 0) return error.Io;
    defer _ = os.c.close(fd);
    try os.writeAll(fd, text);
}
test "discovery handles normal repos, gitfiles, HEAD symlinks and detached SHA256" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempPath(tmp);
    defer a.free(root);
    const fd = tmp.dir.handle;
    try t.expectEqual(@as(c_int, 0), os.c.mkdirat(fd, ".git", 0o700));
    const gd = os.c.openat(fd, ".git", .{ .ACCMODE = .RDONLY, .DIRECTORY = true });
    try t.expect(gd >= 0);
    defer _ = os.c.close(gd);
    try writeFile(gd, "HEAD", "ref: refs/heads/main\n");
    const repo = try git.discover(a, root);
    defer repo.deinit(a);
    const main = try git.readBranch(a, repo);
    defer a.free(main);
    try t.expectEqualStrings("main", main);
    try writeFile(gd, "HEAD", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n");
    const detached = try git.readBranch(a, repo);
    defer a.free(detached);
    try t.expectEqualStrings("aaaaaaaa", detached);
    try t.expectEqual(@as(c_int, 0), os.c.unlinkat(gd, "HEAD", 0));
    try t.expectEqual(@as(c_int, 0), os.c.symlinkat("refs/heads/legacy", gd, "HEAD"));
    const legacy = try git.readBranch(a, repo);
    defer a.free(legacy);
    try t.expectEqualStrings("legacy", legacy);
    try t.checkAllAllocationFailures(a, discoverFailure, .{root});
    try t.expectEqual(@as(c_int, 0), os.c.mkdirat(fd, "worktree", 0o700));
    const work = os.c.openat(fd, "worktree", .{ .ACCMODE = .RDONLY, .DIRECTORY = true });
    defer _ = os.c.close(work);
    try writeFile(work, ".git", "gitdir: ../.git\n");
    const work_path = try std.fmt.allocPrintSentinel(a, "{s}/worktree", .{root}, 0);
    defer a.free(work_path);
    const linked = try git.discover(a, work_path);
    defer linked.deinit(a);
    try t.expectEqualStrings(repo.git_dir, linked.git_dir);
    try t.checkAllAllocationFailures(a, discoverFailure, .{work_path});
}
fn storeFailure(allocator: u.Allocator, environ: std.process.Environ) !void {
    try cache.store(allocator, environ, "/repo", .{ .branch = "main", .updated_ms = 42 });
}
fn loadFailure(allocator: u.Allocator, environ: std.process.Environ) !void {
    const loaded = try cache.load(allocator, environ, "/repo");
    defer loaded.deinit(allocator);
}
fn clearFailure(allocator: u.Allocator, environ: std.process.Environ) !void {
    try cache.store(allocator, environ, "/repo", .{ .branch = "main", .updated_ms = 42 });
    try cache.clear(allocator, environ);
}
test "cache filesystem publication, clear and insecure artifacts" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(tmp);
    defer a.free(path);
    try t.expectEqual(@as(c_int, 0), os.c.fchmod(tmp.dir.handle, 0o700));
    var environment = try Environment.init("NBSP_CACHE_DIR", path);
    defer environment.deinit();
    const environ = environment.get();
    try t.checkAllAllocationFailures(a, storeFailure, .{environ});
    try storeFailure(a, environ);
    try t.checkAllAllocationFailures(a, loadFailure, .{environ});
    const fd = try cache.openGitDir(a, environ, false);
    defer _ = os.c.close(fd);
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrintSentinel(&name_buf, "{x:0>16}.cache", .{u.hashPath("/repo")}, 0);
    const file = os.c.openat(fd, name, .{ .ACCMODE = .RDONLY });
    try t.expect(file >= 0);
    defer _ = os.c.close(file);
    try t.expectEqual(@as(c_int, 0), os.c.fchmod(file, 0o644));
    try t.expectError(error.Invalid, cache.load(a, environ, "/repo"));
    try t.expectError(error.Invalid, cache.store(a, environ, "/repo", .{ .branch = "main", .updated_ms = 42 }));
    try t.expectEqual(@as(c_int, 0), os.c.fchmod(file, 0o600));
    try t.expectEqual(@as(c_int, 0), os.c.linkat(fd, name, fd, "hardlink", 0));
    try t.expectError(error.Invalid, cache.load(a, environ, "/repo"));
    try t.expectEqual(@as(c_int, 0), os.c.unlinkat(fd, "hardlink", 0));
    const lock_fd = try cache.lock(a, environ, "/repo");
    cache.unlock(lock_fd);
    try t.checkAllAllocationFailures(a, clearFailure, .{environ});
    try cache.clear(a, environ);
    try t.expectError(error.Io, cache.load(a, environ, "/repo"));
    var lock_buf: [64]u8 = undefined;
    const lock_name = try std.fmt.bufPrintSentinel(&lock_buf, "{x:0>16}.lock", .{u.hashPath("/repo")}, 0);
    var info: os.c.Stat = undefined;
    try t.expectEqual(@as(c_int, 0), os.c.fstatat(fd, lock_name, &info, 0));
    try t.expectEqual(@as(c_int, 0), os.c.symlinkat("missing", fd, name));
    try t.expectError(error.Io, cache.load(a, environ, "/repo"));
    try t.expectError(error.Invalid, cache.store(a, environ, "/repo", .{ .branch = "main", .updated_ms = 42 }));
    try t.expectError(error.Io, cache.clear(a, environ));
}
fn dirsFailure(allocator: u.Allocator, cwd: [:0]const u8) !void {
    var names = try dirs.collect(allocator, cwd);
    defer dirs.deinit(allocator, &names);
}
test "directory snapshot includes symlinks, sorts bytes and rejects excess entries" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(tmp);
    defer a.free(path);
    const fd = tmp.dir.handle;
    for ([_][:0]const u8{ "zeta", "alpha", ".hidden", "omega" }) |name| try t.expectEqual(@as(c_int, 0), os.c.mkdirat(fd, name, 0o700));
    try t.expectEqual(@as(c_int, 0), os.c.symlinkat("alpha", fd, "link"));
    try t.expectEqual(@as(c_int, 0), os.c.symlinkat("missing", fd, "broken"));
    try writeFile(fd, "file", "");
    try t.checkAllAllocationFailures(a, dirsFailure, .{path});
    var names = try dirs.collect(a, path);
    defer dirs.deinit(a, &names);
    try t.expectEqual(@as(usize, 5), names.items.len);
    try t.expectEqualStrings(".hidden", names.items[0]);
    try t.expectEqualStrings("zeta", names.items[4]);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try dirs.write(&out.writer, names.items);
    try t.expect(std.mem.endsWith(u8, out.written(), "complete\x001\x00"));
    var buf: [32]u8 = undefined;
    for (0..1020) |i| {
        const name = try std.fmt.bufPrintSentinel(&buf, "entry-{d}", .{i}, 0);
        try t.expectEqual(@as(c_int, 0), os.c.mkdirat(fd, name, 0o700));
    }
    try t.expectError(error.Limit, dirs.collect(a, path));
    try t.expectEqual(@as(c_int, 0), os.c.mkdirat(fd, "wide", 0o700));
    const wide_fd = os.c.openat(fd, "wide", .{ .ACCMODE = .RDONLY, .DIRECTORY = true });
    defer _ = os.c.close(wide_fd);
    var long_name: [251]u8 = @splat('a');
    long_name[250] = 0;
    for (0..300) |i| {
        var prefix: [5]u8 = undefined;
        const number = try std.fmt.bufPrint(&prefix, "{d:0>4}", .{i});
        @memcpy(long_name[0..4], number);
        try t.expectEqual(@as(c_int, 0), os.c.mkdirat(wide_fd, long_name[0..250 :0], 0o700));
    }
    const wide_path = try std.fmt.allocPrintSentinel(a, "{s}/wide", .{path}, 0);
    defer a.free(wide_path);
    // Fewer than 1024 entries: this must exercise the independent byte cap.
    try t.expectError(error.Limit, dirs.collect(a, wide_path));
}
test "data frame has exactly the documented keys in both formats" {
    const cwd = try a.dupeZ(u8, "/tmp/a b");
    const path = try a.dupe(u8, "/t/a b");
    const data: snapshot.Snapshot = .{ .cwd = cwd, .path = path, .status = 17, .duration_ms = 2345, .jobs = 2 };
    defer data.deinit(a);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try snapshot.write(&out.writer, data, false);
    try t.expect(std.mem.startsWith(u8, out.written(), "schema_version=2\ncwd=/tmp/a%20b\n"));
    try t.expectEqual(@as(usize, 18), std.mem.count(u8, out.written(), "\n"));
    out.clearRetainingCapacity();
    try snapshot.write(&out.writer, data, true);
    try t.expectEqual(@as(usize, 36), std.mem.count(u8, out.written(), "\x00"));
}

test "CLI decimals match strtol without accepting Zig separators" {
    try t.expectEqual(@as(i64, 42), try u.signedDecimal(" \t+42"));
    try t.expectEqual(@as(i64, 0), try u.signedDecimal("-0"));
    try t.expectEqual(std.math.minInt(i64), try u.signedDecimal("-9223372036854775808"));
    for ([_][]const u8{ "1_0", "1 ", "+", "--1", "0x10", "9223372036854775808", "-9223372036854775809" }) |bad| try t.expectError(error.Invalid, u.signedDecimal(bad));
}

extern "c" fn fork() os.c.pid_t;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
test "fcntl locks exclude another process and survive concurrent clear" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(tmp);
    defer a.free(path);
    try t.expectEqual(@as(c_int, 0), os.c.fchmod(tmp.dir.handle, 0o700));
    var environment = try Environment.init("NBSP_CACHE_DIR", path);
    defer environment.deinit();
    const environ = environment.get();
    const fd = try cache.lock(a, environ, "/repo");
    defer cache.unlock(fd);
    try cache.store(a, environ, "/repo", .{ .branch = "main", .updated_ms = 42 });
    try cache.clear(a, environ);
    const child = fork();
    try t.expect(child >= 0);
    if (child == 0) {
        const lock_fd = cache.lock(std.heap.c_allocator, environ, "/repo") catch |err| os.c._exit(if (err == error.Busy) 0 else 1);
        cache.unlock(lock_fd);
        os.c._exit(1);
    }
    var status: c_int = 0;
    try t.expectEqual(child, os.c.waitpid(child, &status, 0));
    try t.expect(os.c.W.IFEXITED(@bitCast(status)) and os.c.W.EXITSTATUS(@bitCast(status)) == 0);
}
fn discoverFailure(allocator: u.Allocator, path: [:0]const u8) !void {
    const repo = try git.discover(allocator, path);
    defer repo.deinit(allocator);
    const branch = try git.readBranch(allocator, repo);
    defer allocator.free(branch);
}
test "repository and HEAD allocation failures unwind" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(tmp);
    defer a.free(path);
    try t.expectEqual(@as(c_int, 0), os.c.mkdirat(tmp.dir.handle, ".git", 0o700));
    const fd = os.c.openat(tmp.dir.handle, ".git", .{ .ACCMODE = .RDONLY, .DIRECTORY = true });
    defer _ = os.c.close(fd);
    try writeFile(fd, "HEAD", "ref: refs/heads/main\n");
    try t.checkAllAllocationFailures(a, discoverFailure, .{path});
}
test "buffered output reports final flush failures" {
    var buffer: [8]u8 = undefined;
    var output = os.Writer.init(-1, &buffer);
    try output.interface.writeAll("small");
    try t.expectError(error.WriteFailed, output.interface.flush());
}

fn lockFailure(allocator: u.Allocator, environ: std.process.Environ) !void {
    const fd = try cache.lock(allocator, environ, "/repo");
    defer cache.unlock(fd);
}
test "cache root precedence, permissions and intermediate symlinks fail closed" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(tmp);
    defer a.free(path);
    const fd = tmp.dir.handle;
    try t.expectEqual(@as(c_int, 0), os.c.fchmod(fd, 0o700));
    var environment = try Environment.init("NBSP_CACHE_DIR", path);
    defer environment.deinit();
    try t.checkAllAllocationFailures(a, lockFailure, .{environment.get()});
    try t.expectEqual(@as(c_int, 0), os.c.fchmod(fd, 0o755));
    try t.expectError(error.Invalid, cache.openGitDir(a, environment.get(), true));
    try t.expectEqual(@as(c_int, 0), os.c.fchmod(fd, 0o700));
    try t.expectEqual(@as(c_int, 0), os.c.mkdirat(fd, "real", 0o700));
    try t.expectEqual(@as(c_int, 0), os.c.symlinkat("real", fd, "link"));
    const linked = try std.fmt.allocPrint(a, "{s}/link/cache", .{path});
    defer a.free(linked);
    var symlink_env = try Environment.init("NBSP_CACHE_DIR", linked);
    defer symlink_env.deinit();
    try t.expectError(error.Io, cache.openGitDir(a, symlink_env.get(), true));
    var invalid = try Environment.init("NBSP_CACHE_DIR", "relative");
    defer invalid.deinit();
    try t.expectError(error.Invalid, cache.openGitDir(a, invalid.get(), true));
    const empty: std.process.Environ = .{ .block = .{ .slice = &.{} } };
    try t.expectError(error.Missing, cache.openGitDir(a, empty, true));
    var xdg = try Environment.init("XDG_CACHE_HOME", path);
    defer xdg.deinit();
    const xdg_fd = try cache.openGitDir(a, xdg.get(), true);
    defer _ = os.c.close(xdg_fd);
    try t.expectEqual(@as(c_int, 0), os.c.faccessat(fd, "nbsp/git", os.c.F_OK, 0));
    var home = try Environment.init("HOME", path);
    defer home.deinit();
    const relative_xdg: [:0]const u8 = "XDG_CACHE_HOME=relative";
    var block = [_:null]?[*:0]const u8{ relative_xdg.ptr, home.entry.ptr };
    const fallback: std.process.Environ = .{ .block = .{ .slice = &block } };
    const home_fd = try cache.openGitDir(a, fallback, true);
    defer _ = os.c.close(home_fd);
    try t.expectEqual(@as(c_int, 0), os.c.faccessat(fd, "Library/Caches/nbsp/git", os.c.F_OK, 0));
}

fn collectFailure(allocator: u.Allocator, environ: std.process.Environ, repo: git.Repo) !void {
    const result = try git.collect(allocator, environ, repo, 1500);
    defer result.deinit(allocator);
}
fn interrupted(_: os.c.SIG) callconv(.c) void {}
test "interrupted supervision and allocation failures clean up the child" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(tmp);
    defer a.free(path);
    var old_action: os.c.Sigaction = undefined;
    var action: os.c.Sigaction = .{ .handler = .{ .handler = interrupted }, .mask = 0, .flags = 0 };
    try t.expectEqual(@as(c_int, 0), os.c.sigaction(.USR1, &action, &old_action));
    defer _ = os.c.sigaction(.USR1, &old_action, null);
    try writeFile(tmp.dir.handle, "git", "#!/bin/sh\n/bin/sleep .01\n/bin/kill -USR1 \"$PPID\"\nprintf '# branch.oid (initial)\\n# branch.head main\\n'\n");
    try t.expectEqual(@as(c_int, 0), os.c.fchmodat(tmp.dir.handle, "git", 0o700, 0));
    var environment = try Environment.init("PATH", path);
    defer environment.deinit();
    // posix_spawnp resolves the executable with the parent's PATH on Darwin.
    const old_path = try a.dupeZ(u8, std.mem.span(os.c.getenv("PATH") orelse return error.Missing));
    defer a.free(old_path);
    try t.expectEqual(@as(c_int, 0), setenv("PATH", path, 1));
    defer _ = setenv("PATH", old_path, 1);
    const repo: git.Repo = .{ .root = path, .git_dir = path };
    try t.checkAllAllocationFailures(a, collectFailure, .{ environment.get(), repo });
}
test "failed cache write leaves the published snapshot intact" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(tmp);
    defer a.free(path);
    try t.expectEqual(@as(c_int, 0), os.c.fchmod(tmp.dir.handle, 0o700));
    var environment = try Environment.init("NBSP_CACHE_DIR", path);
    defer environment.deinit();
    const environ = environment.get();
    try cache.store(a, environ, "/repo", .{ .branch = "main", .updated_ms = 42 });
    const child = fork();
    try t.expect(child >= 0);
    if (child == 0) {
        const limit: os.c.rlimit = .{ .cur = 1, .max = 1 };
        var action: os.c.Sigaction = .{ .handler = .{ .handler = os.c.SIG.IGN }, .mask = 0, .flags = 0 };
        if (os.c.sigaction(.XFSZ, &action, null) != 0 or os.c.setrlimit(.FSIZE, &limit) != 0) os.c._exit(2);
        cache.store(std.heap.c_allocator, environ, "/repo", .{ .branch = "changed", .updated_ms = 43 }) catch |err| os.c._exit(if (err == error.Io) 0 else 1);
        os.c._exit(1);
    }
    var status: c_int = 0;
    try t.expectEqual(child, os.c.waitpid(child, &status, 0));
    try t.expect(os.c.W.IFEXITED(@bitCast(status)) and os.c.W.EXITSTATUS(@bitCast(status)) == 0);
    const stored = try cache.load(a, environ, "/repo");
    defer stored.deinit(a);
    try t.expectEqualStrings("main", stored.status.branch);
    try t.expectEqual(@as(u64, 42), stored.status.updated_ms);
}

fn snapshotFailure(allocator: u.Allocator, environ: std.process.Environ) !void {
    const data = try snapshot.collect(allocator, environ, 17, 2345, 2);
    defer data.deinit(allocator);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    snapshot.write(&out.writer, data, false) catch return error.OutOfMemory;
    out.clearRetainingCapacity();
    snapshot.write(&out.writer, data, true) catch return error.OutOfMemory;
}
test "foreground collection and serialization propagate allocation failure" {
    const empty: std.process.Environ = .{ .block = .{ .slice = &.{} } };
    try t.checkAllAllocationFailures(a, snapshotFailure, .{empty});
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempPath(tmp);
    defer a.free(root);
    const original = os.c.open(".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    try t.expect(original >= 0);
    defer _ = os.c.close(original);
    defer _ = os.c.fchdir(original);
    try t.expectEqual(@as(c_int, 0), os.c.fchmod(tmp.dir.handle, 0o700));
    try t.expectEqual(@as(c_int, 0), os.c.mkdirat(tmp.dir.handle, ".git", 0o700));
    const gd = os.c.openat(tmp.dir.handle, ".git", .{ .ACCMODE = .RDONLY, .DIRECTORY = true });
    defer _ = os.c.close(gd);
    try writeFile(gd, "HEAD", "ref: refs/heads/main\n");
    var environment = try Environment.init("NBSP_CACHE_DIR", root);
    defer environment.deinit();
    try cache.store(a, environment.get(), root, .{ .branch = "main", .updated_ms = 42, .staged = 3 });
    try t.expectEqual(@as(c_int, 0), os.c.fchdir(tmp.dir.handle));
    try t.checkAllAllocationFailures(a, snapshotFailure, .{environment.get()});
    try t.expectEqual(@as(c_int, 0), os.c.unlinkat(gd, "HEAD", 0));
    try t.checkAllAllocationFailures(a, snapshotFailure, .{environment.get()});
    const fallback = try snapshot.collect(a, environment.get(), 0, 0, 0);
    defer fallback.deinit(a);
    try t.expectEqualStrings("main", fallback.branch);
    try t.expect(!fallback.git_valid and fallback.git_status.staged == 0);
}

fn initFailure(allocator: u.Allocator) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    _ = @import("main.zig").dispatch(allocator, .{ .block = .{ .slice = &.{} } }, &.{ "nbsp", "init", "zsh", "--autosuggest" }, &out.writer) catch return error.OutOfMemory;
}
test "embedded shell and executable-path allocation failures unwind" {
    try t.checkAllAllocationFailures(a, initFailure, .{});
}
