//! HTTP/1.1, the small part a script needs: parse a request or a
//! response out of bytes (incrementally: `incomplete` until the head
//! and the body it announces are all there), format one, and take a
//! URL apart. Pure and host-tested; the hosts wire it to sockets.
//! Headers come back as a record with lowercased names; bodies are
//! bounded by Content-Length (chunked transfer is refused — the peer
//! is asked for Connection: close instead, and a response with no
//! length runs to the close).

const std = @import("std");
const mshl = @import("mshl.zig");
const Value = mshl.Value;

pub const max_head = 16 << 10;
pub const max_body = 256 << 10;

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    version: []const u8,
    headers: []const Header,
    body: []const u8,
    /// Bytes consumed (the head and the body).
    len: usize,
};

pub const Response = struct {
    status: u16,
    reason: []const u8,
    headers: []const Header,
    body: []const u8,
    len: usize,
    /// No Content-Length: the body is everything until the close.
    to_close: bool,
};

pub const ParseError = error{ OutOfMemory, Bad, TooLarge, Chunked };

pub fn Parsed(comptime T: type) type {
    return union(enum) { done: T, incomplete };
}

/// The head ends at the first blank line.
fn headEnd(bytes: []const u8) ?usize {
    return if (std.mem.indexOf(u8, bytes, "\r\n\r\n")) |i| i + 4 else null;
}

fn headerValue(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

/// Header lines after the first line; names lowercased, values trimmed.
fn parseHeaders(a: std.mem.Allocator, head: []const u8) ParseError![]const Header {
    var list: std.ArrayList(Header) = .empty;
    var it = std.mem.splitSequence(u8, head, "\r\n");
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.Bad;
        const name = try std.ascii.allocLowerString(a, std.mem.trim(u8, line[0..colon], " \t"));
        if (name.len == 0) return error.Bad;
        try list.append(a, .{ .name = name, .value = std.mem.trim(u8, line[colon + 1 ..], " \t") });
    }
    return list.items;
}

fn bodyLength(headers: []const Header) ParseError!?usize {
    if (headerValue(headers, "transfer-encoding")) |te| {
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, te, " "), "identity")) return error.Chunked;
    }
    const cl = headerValue(headers, "content-length") orelse return null;
    const n = std.fmt.parseInt(usize, cl, 10) catch return error.Bad;
    if (n > max_body) return error.TooLarge;
    return n;
}

pub fn parseRequest(a: std.mem.Allocator, bytes: []const u8) ParseError!Parsed(Request) {
    const he = headEnd(bytes) orelse {
        if (bytes.len > max_head) return error.TooLarge;
        return .incomplete;
    };
    if (he > max_head) return error.TooLarge;
    const head = bytes[0 .. he - 4];
    const first_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    var words = std.mem.splitScalar(u8, head[0..first_end], ' ');
    const method = words.next() orelse return error.Bad;
    const target = words.next() orelse return error.Bad;
    const version = words.next() orelse return error.Bad;
    if (words.next() != null or method.len == 0 or target.len == 0 or !std.mem.startsWith(u8, version, "HTTP/1.")) return error.Bad;
    const headers = try parseHeaders(a, head[@min(first_end + 2, head.len)..]);
    const want = (try bodyLength(headers)) orelse 0;
    if (bytes.len < he + want) return .incomplete;
    const q = std.mem.indexOfScalar(u8, target, '?');
    return .{ .done = .{
        .method = method,
        .path = if (q) |i| target[0..i] else target,
        .query = if (q) |i| target[i + 1 ..] else "",
        .version = version,
        .headers = headers,
        .body = bytes[he .. he + want],
        .len = he + want,
    } };
}

/// `closed` says the peer has closed: a body with no length is then
/// complete.
pub fn parseResponse(a: std.mem.Allocator, bytes: []const u8, closed: bool) ParseError!Parsed(Response) {
    const he = headEnd(bytes) orelse {
        if (bytes.len > max_head) return error.TooLarge;
        return .incomplete;
    };
    if (he > max_head) return error.TooLarge;
    const head = bytes[0 .. he - 4];
    const first_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    const line = head[0..first_end];
    if (!std.mem.startsWith(u8, line, "HTTP/1.") or line.len < 12 or line[8] != ' ') return error.Bad;
    const status = std.fmt.parseInt(u16, line[9..12], 10) catch return error.Bad;
    const reason = if (line.len > 13) line[13..] else "";
    const headers = try parseHeaders(a, head[@min(first_end + 2, head.len)..]);
    if (try bodyLength(headers)) |want| {
        if (bytes.len < he + want) return .incomplete;
        return .{ .done = .{ .status = status, .reason = reason, .headers = headers, .body = bytes[he .. he + want], .len = he + want, .to_close = false } };
    }
    if (!closed) {
        if (bytes.len - he > max_body) return error.TooLarge;
        return .incomplete;
    }
    return .{ .done = .{ .status = status, .reason = reason, .headers = headers, .body = bytes[he..], .len = bytes.len, .to_close = true } };
}

pub fn reasonFor(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        else => "Status",
    };
}

/// A response with Content-Length and Connection: close, plus the
/// caller's headers (a content-type, say).
pub fn formatResponse(a: std.mem.Allocator, out: *std.ArrayList(u8), status: u16, headers: []const Header, body: []const u8) error{OutOfMemory}!void {
    var buf: [64]u8 = undefined;
    try out.appendSlice(a, std.fmt.bufPrint(&buf, "HTTP/1.1 {d} ", .{status}) catch "");
    try out.appendSlice(a, reasonFor(status));
    try out.appendSlice(a, "\r\n");
    for (headers) |h| try writeHeader(a, out, h.name, h.value);
    try out.appendSlice(a, std.fmt.bufPrint(&buf, "Content-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch "");
    try out.appendSlice(a, body);
}

pub fn formatRequest(a: std.mem.Allocator, out: *std.ArrayList(u8), method: []const u8, path: []const u8, host: []const u8, headers: []const Header, body: []const u8) error{OutOfMemory}!void {
    var buf: [64]u8 = undefined;
    try out.appendSlice(a, method);
    try out.append(a, ' ');
    try out.appendSlice(a, if (path.len == 0) "/" else path);
    try out.appendSlice(a, " HTTP/1.1\r\n");
    if (headerValue(headers, "host") == null) try writeHeader(a, out, "Host", host);
    for (headers) |h| try writeHeader(a, out, h.name, h.value);
    if (body.len > 0 or std.mem.eql(u8, method, "POST") or std.mem.eql(u8, method, "PUT")) {
        try out.appendSlice(a, std.fmt.bufPrint(&buf, "Content-Length: {d}\r\n", .{body.len}) catch "");
    }
    try out.appendSlice(a, "Connection: close\r\n\r\n");
    try out.appendSlice(a, body);
}

fn writeHeader(a: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: []const u8) error{OutOfMemory}!void {
    try out.appendSlice(a, name);
    try out.appendSlice(a, ": ");
    try out.appendSlice(a, value);
    try out.appendSlice(a, "\r\n");
}

pub const Url = struct { host: []const u8, port: u16, path: []const u8 };

/// `http://host[:port]/path?query`; the host may be an IPv6 literal
/// in brackets. Only http.
pub fn parseUrl(url: []const u8) ?Url {
    const rest = if (std.mem.startsWith(u8, url, "http://")) url[7..] else return null;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    var authority = rest[0..slash];
    const path = if (slash < rest.len) rest[slash..] else "/";
    var host: []const u8 = undefined;
    var port: u16 = 80;
    if (authority.len > 0 and authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        host = authority[1..close];
        authority = authority[close + 1 ..];
        if (authority.len > 0) {
            if (authority[0] != ':') return null;
            port = std.fmt.parseInt(u16, authority[1..], 10) catch return null;
        }
    } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |c| {
        host = authority[0..c];
        port = std.fmt.parseInt(u16, authority[c + 1 ..], 10) catch return null;
    } else host = authority;
    if (host.len == 0) return null;
    return .{ .host = host, .port = port, .path = path };
}

/// Headers as a record for the language (names already lowercased).
pub fn headersRecord(a: std.mem.Allocator, headers: []const Header) error{OutOfMemory}!Value {
    const keys = try a.alloc([]const u8, headers.len);
    const vals = try a.alloc(Value, headers.len);
    for (headers, 0..) |h, i| {
        keys[i] = h.name;
        vals[i] = .{ .str = h.value };
    }
    return .{ .record = .{ .keys = keys, .vals = vals } };
}

test "http: a request parses whole, or says incomplete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "POST /api/items?x=1&y=2 HTTP/1.1\r\nHost: moss\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhelloEXTRA";
    try std.testing.expect((try parseRequest(a, text[0..20])) == .incomplete);
    try std.testing.expect((try parseRequest(a, text[0 .. text.len - 8])) == .incomplete); // head done, body short
    const r = (try parseRequest(a, text)).done;
    try std.testing.expectEqualStrings("POST", r.method);
    try std.testing.expectEqualStrings("/api/items", r.path);
    try std.testing.expectEqualStrings("x=1&y=2", r.query);
    try std.testing.expectEqualStrings("hello", r.body);
    try std.testing.expectEqualStrings("moss", headerValue(r.headers, "HOST").?);
    try std.testing.expectEqualStrings("text/plain", r.headers[1].value);
    try std.testing.expectEqualStrings("content-type", r.headers[1].name);
    try std.testing.expectEqual(text.len - 5, r.len);
    const g = (try parseRequest(a, "GET / HTTP/1.1\r\n\r\n")).done;
    try std.testing.expectEqualStrings("/", g.path);
    try std.testing.expectEqual(@as(usize, 0), g.body.len);
    try std.testing.expectError(error.Bad, parseRequest(a, "GET / \r\n\r\n"));
    try std.testing.expectError(error.Chunked, parseRequest(a, "GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"));
}

test "http: responses with a length, or to the close" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = (try parseResponse(a, "HTTP/1.1 404 Not Found\r\nContent-Length: 2\r\n\r\nno", false)).done;
    try std.testing.expectEqual(@as(u16, 404), r.status);
    try std.testing.expectEqualStrings("Not Found", r.reason);
    try std.testing.expectEqualStrings("no", r.body);
    try std.testing.expect((try parseResponse(a, "HTTP/1.1 200 OK\r\n\r\npartial", false)) == .incomplete);
    const c = (try parseResponse(a, "HTTP/1.1 200 OK\r\n\r\nall of it", true)).done;
    try std.testing.expectEqualStrings("all of it", c.body);
    try std.testing.expect(c.to_close);
    try std.testing.expectError(error.Bad, parseResponse(a, "HTTP/1.1 2OO OK\r\n\r\n", true));
}

test "http: formatting and urls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    try formatResponse(a, &out, 201, &.{.{ .name = "Content-Type", .value = "application/json" }}, "{}");
    try std.testing.expectEqualStrings("HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}", out.items);
    out.clearRetainingCapacity();
    try formatRequest(a, &out, "GET", "/x?y", "10.0.2.100:9001", &.{}, "");
    try std.testing.expectEqualStrings("GET /x?y HTTP/1.1\r\nHost: 10.0.2.100:9001\r\nConnection: close\r\n\r\n", out.items);
    const u = parseUrl("http://10.0.2.100:9001/hello?a=1").?;
    try std.testing.expectEqualStrings("10.0.2.100", u.host);
    try std.testing.expectEqual(@as(u16, 9001), u.port);
    try std.testing.expectEqualStrings("/hello?a=1", u.path);
    const v6 = parseUrl("http://[fdcc::2]/").?;
    try std.testing.expectEqualStrings("fdcc::2", v6.host);
    try std.testing.expectEqual(@as(u16, 80), v6.port);
    try std.testing.expectEqualStrings("/", parseUrl("http://1.2.3.4").?.path);
    try std.testing.expect(parseUrl("https://x/") == null);
    try std.testing.expect(parseUrl("http://[::1") == null);
}
