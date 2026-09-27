const std = @import("std");
const u = @import("util.zig");
const git = @import("git.zig");
const cache = @import("cache.zig");
const seeds = [_][]const u8{
    "# branch.oid (initial)\n# branch.head main\n? file\n",
    "# branch.oid abcdef0123456789abcdef0123456789abcdef01\n# branch.head (detached)\n",
    "version=2\nrepo=/tmp/repo\nupdated_ms=1\nbranch=main\nstaged=1\nmodified=0\nuntracked=0\nconflicted=0\nahead=0\nbehind=0\nstashes=0\n",
    "/Users/test/.config/αβ/final",
    "/nvm/v22.1.0/bin",
    "1234567890",
    "%20%FF%21",
};
fn exercise(a: u.Allocator, input: []const u8) !void {
    _ = git.parse(input, 42) catch null;
    if (cache.parse(a, input, "/tmp/repo")) |parsed| parsed.deinit(a) else |err| if (err == error.OutOfMemory) return err;
    _ = u.unsigned(u64, input) catch null;
    _ = u.signedDecimal(input) catch null;
    _ = u.unsigned(u32, input) catch null;
    _ = u.nvmVersion(input);
    if (u.abbreviate(a, input)) |path| a.free(path) else |err| if (err == error.OutOfMemory) return err;
    if (u.decode(a, input, 4096)) |decoded| a.free(decoded) else |err| if (err == error.OutOfMemory) return err;
    var encoded: std.Io.Writer.Allocating = .init(a);
    defer encoded.deinit();
    u.encode(&encoded.writer, input) catch return error.OutOfMemory;
    if (std.mem.indexOfScalar(u8, input, 0) == null) {
        const decoded = try u.decode(a, encoded.written(), 16385);
        defer a.free(decoded);
        if (!u.eq(decoded, input) or !u.encodedEquals(encoded.written(), input)) return error.RoundTrip;
    }
}
pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.next();
    const iterations = if (args.next()) |arg| try u.unsigned(u32, arg) else 250000;
    if (iterations == 0 or iterations > 10000000 or args.next() != null) return error.Invalid;
    var debug: std.heap.DebugAllocator(.{ .stack_trace_frames = 8 }) = .init;
    defer if (debug.deinit() == .leak) @panic("mutation harness leaked");
    const a = debug.allocator();
    var prng = std.Random.DefaultPrng.init(0x4e425350_00000002);
    const random = prng.random();
    var buffer: [16384]u8 = undefined;
    for (seeds) |seed| try exercise(a, seed);
    for (0..iterations) |i| {
        const seed = seeds[i % seeds.len];
        const size = if (i % 8 == 0) random.uintLessThan(usize, buffer.len + 1) else seed.len;
        random.bytes(buffer[0..size]);
        if (i % 8 != 0) {
            @memcpy(buffer[0..size], seed);
            const edits = 1 + random.uintLessThan(usize, 8);
            for (0..edits) |_| buffer[random.uintLessThan(usize, size)] = random.int(u8);
        }
        try exercise(a, buffer[0..size]);
    }
}
