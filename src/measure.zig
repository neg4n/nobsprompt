const std = @import("std");
const u = @import("util.zig");
const os = @import("darwin.zig");
const snapshot = @import("snapshot.zig");
const dirs = @import("dirs.zig");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
/// Counts explicit backend allocations, excluding libc's internal allocations.
const Counter = struct {
    backing: Allocator = std.heap.c_allocator,
    allocations: usize = 0,
    resizes: usize = 0,
    bytes: usize = 0,
    live: usize = 0,
    peak: usize = 0,
    fn allocator(self: *Counter) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn changed(self: *Counter, old: usize, new: usize) void {
        self.live = self.live - old + new;
        self.peak = @max(self.peak, self.live);
        if (new > old) self.bytes += new - old;
    }
    fn alloc(context: *anyopaque, len: usize, alignment: Alignment, ret: usize) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(context));
        const result = self.backing.rawAlloc(len, alignment, ret) orelse return null;
        self.allocations += 1;
        self.changed(0, len);
        return result;
    }
    fn resize(context: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ret: usize) bool {
        const self: *Counter = @ptrCast(@alignCast(context));
        if (!self.backing.rawResize(memory, alignment, len, ret)) return false;
        self.resizes += 1;
        self.changed(memory.len, len);
        return true;
    }
    fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ret: usize) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(context));
        const result = self.backing.rawRemap(memory, alignment, len, ret) orelse return null;
        self.resizes += 1;
        self.changed(memory.len, len);
        return result;
    }
    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, ret: usize) void {
        const self: *Counter = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, ret);
        self.live -= memory.len;
    }
};
pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.next();
    const command = args.next() orelse "data";
    if (args.next() != null) return error.Invalid;
    var counter: Counter = .{};
    const a = counter.allocator();
    if (u.eq(command, "data")) {
        const data = try snapshot.collect(a, init.environ, 17, 2345, 2);
        data.deinit(a);
    } else if (u.eq(command, "dirs")) {
        const cwd = try os.cwd(a);
        defer a.free(cwd);
        var names = try dirs.collect(a, cwd);
        dirs.deinit(a, &names);
    } else return error.Invalid;
    if (counter.live != 0) return error.Leak;
    var buffer: [512]u8 = undefined;
    var output = os.Writer.init(1, &buffer);
    try output.interface.print("allocations={d}\nsuccessful_resizes={d}\nrequested_bytes={d}\npeak_live_requested_bytes={d}\n", .{ counter.allocations, counter.resizes, counter.bytes, counter.peak });
    try output.interface.flush();
}
