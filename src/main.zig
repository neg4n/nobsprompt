const std = @import("std");
const u = @import("util.zig");
const os = @import("darwin.zig");
const snapshot = @import("snapshot.zig");
const refresh = @import("refresh.zig");
const cache = @import("cache.zig");
const dirs = @import("dirs.zig");
pub const std_options: std.Options = .{ .enable_segfault_handler = @import("builtin").mode == .Debug, .signal_stack_size = if (@import("builtin").mode == .Debug) (1 << 18) else null };
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = if (@import("builtin").mode == .Debug) std.Io.Threaded.global_single_threaded else null;
pub const panic = if (@import("builtin").mode == .Debug) std.debug.FullPanic(std.debug.defaultPanic) else std.debug.FullPanic(fatal);
fn fatal(message: []const u8, _: ?usize) noreturn {
    os.writeAll(2, "nbsp: runtime safety failure: ") catch {};
    os.writeAll(2, message) catch {};
    os.writeAll(2, "\n") catch {};
    os.c.abort();
}
const usage = "Usage:\n  nbsp init zsh [--detached] [--autosuggest]\n  nbsp data [--status N] [--duration-ms N] [--jobs N] [--format lines|nul]\n  nbsp refresh [--cwd PATH] [--notify] [--force]\n  nbsp dirs [--cwd PATH] [--format nul]\n  nbsp cache clear\n  nbsp --help\n  nbsp --version\n";
fn signed(value: []const u8, max: i64) u.Error!u64 {
    const number = try u.signedDecimal(value);
    if (number < 0 or number > max) return error.Invalid;
    return @intCast(number);
}
fn selfPath(a: u.Allocator) u.Error![:0]u8 {
    var size: u32 = u.path_cap;
    const raw = try a.allocSentinel(u8, u.path_cap - 1, 0);
    defer a.free(raw);
    if (os.c._NSGetExecutablePath(raw.ptr, &size) != 0) return error.Limit;
    const path = std.mem.sliceTo(raw, 0);
    return os.realpath(a, path) catch |err| {
        if (err == error.OutOfMemory) return err;
        return a.dupeZ(u8, path);
    };
}
fn init(out: *std.Io.Writer, a: u.Allocator, detached: bool, autosuggest: bool) !void {
    try out.print("typeset -g _NBSP_INIT_MODE={s}\ntypeset -g _NBSP_BIN=", .{if (detached) "detached" else "prompt"});
    if (selfPath(a)) |path| {
        defer a.free(path);
        try out.writeByte('\'');
        for (path) |ch| {
            if (ch == '\'') try out.writeAll("'\\''") else try out.writeByte(ch);
        }
        try out.writeByte('\'');
    } else |err| {
        if (err == error.OutOfMemory) return err;
        try out.writeAll("nbsp");
    }
    try out.writeByte('\n');
    try out.writeAll(@embedFile("nbsp_zsh.zsh"));
    if (!detached) try out.writeAll(@embedFile("nbsp_opinionated.zsh"));
    if (autosuggest) try out.writeAll(@embedFile("nbsp_autosuggest.zsh"));
}
pub fn dispatch(a: u.Allocator, environ: std.process.Environ, args: []const [:0]const u8, out: *std.Io.Writer) !u8 {
    if (args.len < 2) {
        os.writeAll(2, usage) catch {};
        return 2;
    }
    const command = args[1];
    if (u.eq(command, "--version") or u.eq(command, "-V")) {
        try out.writeAll("nbsp 0.2.0\n");
        return 0;
    }
    if (u.eq(command, "--help") or u.eq(command, "-h")) {
        try out.writeAll(usage);
        try out.writeAll("\nnbsp is a small, asynchronous prompt for macOS and Zsh.\nRun 'eval \"$(nbsp init zsh)\"' from .zshrc for the opinionated prompt.\nUse 'nbsp init zsh --detached' to own PROMPT from NBSP_DATA.\nThe data path never starts Git; refresh is the background worker.\n");
        return 0;
    }
    if (u.eq(command, "init")) {
        if (args.len < 3 or !u.eq(args[2], "zsh")) return error.Invalid;
        var detached = false;
        var autosuggest = false;
        for (args[3..]) |arg| {
            if (u.eq(arg, "--detached") and !detached) detached = true else if (u.eq(arg, "--autosuggest") and !autosuggest) autosuggest = true else return error.Invalid;
        }
        try init(out, a, detached, autosuggest);
        return 0;
    }
    if (u.eq(command, "cache")) {
        if (args.len != 3 or !u.eq(args[2], "clear")) return error.Invalid;
        cache.clear(a, environ) catch {
            try os.writeAll(2, "nbsp: failed to clear cache\n");
            return 1;
        };
        return 0;
    }
    const is_data = u.eq(command, "data");
    const is_refresh = u.eq(command, "refresh");
    const is_dirs = u.eq(command, "dirs");
    if (!is_data and !is_refresh and !is_dirs) return error.Invalid;
    var status: u8 = 0;
    var duration: u64 = 0;
    var jobs: u32 = 0;
    var nul = false;
    var cwd_arg: ?[:0]const u8 = null;
    var notify = false;
    var force = false;
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (is_refresh and u.eq(arg, "--notify")) {
            notify = true;
            continue;
        }
        if (is_refresh and u.eq(arg, "--force")) {
            force = true;
            continue;
        }
        if (u.eq(arg, "--") and index + 1 == args.len) break;
        const equals = std.mem.indexOfScalar(u8, arg, '=');
        const key = if (equals) |pos| arg[0..pos] else arg;
        const value: [:0]const u8 = if (equals) |pos| arg[pos + 1 ..] else blk: {
            index += 1;
            if (index >= args.len) return error.Invalid;
            break :blk args[index];
        };
        if (is_data and u.eq(key, "--status")) status = @intCast(try signed(value, 255)) else if (is_data and u.eq(key, "--duration-ms")) duration = try signed(value, std.math.maxInt(i64)) else if (is_data and u.eq(key, "--jobs")) jobs = @intCast(try signed(value, std.math.maxInt(i32))) else if ((is_data or is_dirs) and u.eq(key, "--format")) {
            if (u.eq(value, "nul")) nul = true else if (is_data and u.eq(value, "lines")) nul = false else return error.Invalid;
        } else if ((is_refresh or is_dirs) and u.eq(key, "--cwd")) cwd_arg = value else return error.Invalid;
    }
    if (is_data) {
        const data = try snapshot.collect(a, environ, status, duration, jobs);
        defer data.deinit(a);
        try snapshot.write(out, data, nul);
        return 0;
    }
    const owned_cwd: ?[:0]u8 = if (cwd_arg == null) os.cwd(a) catch {
        if (notify) {
            try out.writeByte('\n');
            try out.flush();
        }
        return 1;
    } else null;
    defer if (owned_cwd) |cwd| a.free(cwd);
    const cwd = cwd_arg orelse owned_cwd.?;
    if (is_refresh) {
        const result: u8 = if (refresh.run(a, environ, cwd, force)) 0 else |err| if (err == error.Timeout) 124 else 1;
        if (notify) {
            try out.writeByte('\n');
            try out.flush();
        }
        return result;
    }
    try dirs.armTimer();
    defer dirs.disarmTimer();
    var names = try dirs.collect(a, cwd);
    defer dirs.deinit(a, &names);
    try dirs.write(out, names.items);
    try out.flush();
    return 0;
}
pub fn main(process: std.process.Init.Minimal) u8 {
    const a = std.heap.c_allocator;
    var buffer: [4096]u8 = undefined;
    var stdout = os.Writer.init(1, &buffer);
    var args = process.args.iterate();
    var argv: std.ArrayList([:0]const u8) = .empty;
    defer argv.deinit(a);
    while (args.next()) |arg| argv.append(a, arg) catch return 1;
    const result = dispatch(a, process.environ, argv.items, &stdout.interface) catch |err| {
        if (err == error.Invalid) {
            os.writeAll(2, usage) catch {};
            return 2;
        }
        return 1;
    };
    stdout.interface.flush() catch return 1;
    return result;
}
