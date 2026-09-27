const std = @import("std");
pub const Allocator = std.mem.Allocator;
pub const Error = error{ Invalid, Limit, Io, Timeout, Busy, Missing } || Allocator.Error;
pub const path_cap = 4096;

pub fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn starts(a: []const u8, b: []const u8) bool {
    return std.mem.startsWith(u8, a, b);
}
pub fn unsigned(comptime T: type, value: []const u8) Error!T {
    if (value.len == 0) return error.Invalid;
    var n: T = 0;
    for (value) |ch| {
        if (ch < '0' or ch > '9') return error.Invalid;
        const digit: T = ch - '0';
        if (n > (std.math.maxInt(T) - digit) / 10) return error.Invalid;
        n = n * 10 + digit;
    }
    return n;
}
/// Decimal strtol domain: leading ASCII space, optional sign, no trailing bytes.
pub fn signedDecimal(value: []const u8) Error!i64 {
    var text = std.mem.trimStart(u8, value, " \t\r\n\x0b\x0c");
    const negative = text.len != 0 and text[0] == '-';
    if (text.len != 0 and (text[0] == '+' or text[0] == '-')) text = text[1..];
    const magnitude = try unsigned(u64, text);
    const limit: u64 = @as(u64, std.math.maxInt(i64)) + @intFromBool(negative);
    if (magnitude > limit) return error.Invalid;
    if (negative and magnitude == limit) return std.math.minInt(i64);
    const number: i64 = @intCast(magnitude);
    return if (negative) -number else number;
}
pub fn unreserved(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '/';
}
pub fn encode(out: *std.Io.Writer, text: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (text) |ch| {
        if (unreserved(ch)) try out.writeByte(ch) else try out.writeAll(&.{ '%', hex[ch >> 4], hex[ch & 15] });
    }
}
fn next(encoded: []const u8, at: *usize) Error!u8 {
    const ch = encoded[at.*];
    at.* += 1;
    if (ch != '%') {
        if (!unreserved(ch)) return error.Invalid;
        return ch;
    }
    if (encoded.len - at.* < 2) return error.Invalid;
    const hi = std.fmt.charToDigit(encoded[at.*], 16) catch return error.Invalid;
    const lo = std.fmt.charToDigit(encoded[at.* + 1], 16) catch return error.Invalid;
    at.* += 2;
    const result = hi * 16 + lo;
    if (result == 0) return error.Invalid;
    return result;
}
pub fn validate(encoded: []const u8) Error!void {
    var at: usize = 0;
    while (at < encoded.len) _ = try next(encoded, &at);
}
pub fn encodedEquals(encoded: []const u8, plain: []const u8) bool {
    var at: usize = 0;
    var p: usize = 0;
    while (at < encoded.len) {
        const ch = next(encoded, &at) catch return false;
        if (p >= plain.len or plain[p] != ch) return false;
        p += 1;
    }
    return p == plain.len;
}
pub fn decode(a: Allocator, encoded: []const u8, limit: usize) Error![]u8 {
    var at: usize = 0;
    var size: usize = 0;
    while (at < encoded.len) {
        _ = try next(encoded, &at);
        size += 1;
        if (size >= limit) return error.Limit;
    }
    const result = try a.alloc(u8, size);
    errdefer a.free(result);
    at = 0;
    var i: usize = 0;
    while (at < encoded.len) : (i += 1) result[i] = try next(encoded, &at);
    return result;
}
pub fn hashPath(path: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (path) |ch| {
        hash ^= ch;
        hash *%= 1099511628211;
    }
    return hash;
}
pub fn nvmVersion(value: []const u8) []const u8 {
    if (value.len == 0) return "";
    var end = value.len;
    while (end > 1 and value[end - 1] == '/') end -= 1;
    var begin = std.mem.lastIndexOfScalar(u8, value[0..end], '/') orelse 0;
    if (value[begin] == '/') begin += 1;
    if (eq(value[begin..end], "bin") and begin > 0) {
        end = begin - 1;
        begin = if (std.mem.lastIndexOfScalar(u8, value[0..end], '/')) |p| p + 1 else 0;
    }
    if (end - begin > 1 and value[begin] == 'v' and std.ascii.isDigit(value[begin + 1])) begin += 1;
    const label = value[begin..end];
    if (label.len == 0 or label.len > 255) return "";
    for (label) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '-' and ch != '_') return "";
    return label;
}
pub fn abbreviate(a: Allocator, cwd: []const u8) Error![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    if (cwd.len == 0) return a.dupe(u8, "?");
    if (cwd[0] == '/') try result.append(a, '/');
    var parts = std.mem.tokenizeScalar(u8, cwd, '/');
    var first = true;
    while (parts.next()) |part| {
        if (!first) try result.append(a, '/');
        if (parts.peek() == null) try result.appendSlice(a, part) else {
            var offset: usize = 0;
            if (part.len > 1 and part[0] == '.') {
                try result.append(a, '.');
                offset = 1;
            }
            const ch = part[offset];
            var length: usize = if (ch & 0xe0 == 0xc0) 2 else if (ch & 0xf0 == 0xe0) 3 else if (ch & 0xf8 == 0xf0) 4 else 1;
            if (length > part.len - offset) length = 1 else for (part[offset + 1 .. offset + length]) |tail| {
                if (tail & 0xc0 != 0x80) {
                    length = 1;
                    break;
                }
            }
            try result.appendSlice(a, part[offset..][0..length]);
        }
        first = false;
    }
    if (result.items.len >= path_cap) return error.Limit;
    return result.toOwnedSlice(a);
}
pub fn branchValid(branch: []const u8) bool {
    if (branch.len == 0 or branch.len > 255) return false;
    for (branch) |ch| if (ch < 32 or ch == 127) return false;
    return true;
}
