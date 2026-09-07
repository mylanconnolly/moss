//! HTTP for mshl hosts, on top of the network commands' sockets:
//! `http-read $sock` parses a request into a record, `http-write $sock
//! $resp` answers it, `http-serve $listener $handler [n]` loops accept /
//! read / handle / write with handlers as ordinary functions of the
//! request record (one connection at a time; for concurrency across
//! connections, the worker-pool `serve` hands each socket to a worker
//! whose handler may itself call http-read/http-write), and `fetch URL
//! [opts]` is the client. What a
//! handler returns decides the response: a record { status, headers,
//! body } is explicit; a string is 200 text/plain; a list, record or
//! table is 200 application/json. Every outcome the network or the
//! peer decides is a result. Parsing and formatting live in lib/http.zig
//! (host-tested); this file only moves bytes.
//!
//! Connections are kept alive as HTTP/1.1 does: `serve` answers every
//! request a connection carries (bytes read past one request wait in
//! a per-socket leftover for the next, so pipelined requests are fine)
//! until the peer says close, the count is reached, or the connection
//! sits idle for `idle_ms`; `http-write` says keep-alive unless the
//! record says `close: true`; `fetch` keeps up to `pool_size` idle
//! connections by address and port and retries once on a fresh one
//! when a kept connection turns out dead (the peer closed it while it
//! sat), so a script talking to one server pays the handshake once.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const netcmds = @import("netcmds.zig");
const tlscmds = @import("tlscmds.zig");
const mosslib = @import("mosslib");
const mshl = mosslib.mshl;
const http = mosslib.http;
const json = mosslib.json;
const Value = mshl.Value;
const Net = netcmds.Net;

fn errResult(it: *mshl.Interp, msg: []const u8) mshl.Error!Value {
    const r = try it.arena.create(mshl.Result);
    r.* = .{ .ok = false, .val = .{ .str = msg } };
    return .{ .result = r };
}

fn okResult(it: *mshl.Interp, v: Value) mshl.Error!Value {
    const r = try it.arena.create(mshl.Result);
    r.* = .{ .ok = true, .val = v };
    return .{ .result = r };
}

fn record(it: *mshl.Interp, keys: []const []const u8, vals: []const Value) mshl.Error!Value {
    return .{ .record = .{ .keys = try it.arena.dupe([]const u8, keys), .vals = try it.arena.dupe(Value, vals) } };
}

// ------------------------------------------------------ connection state
//
// Bytes received past the end of one request belong to the next one on
// the same socket; they live here between calls (the interpreter's
// arena is a line's).

const max_leftover = shared.net_max_recv;
const Leftover = struct { key: u64 = 0, has: bool = false, len: usize = 0, buf: [max_leftover]u8 = undefined };
const max_conns = 8;
var leftovers: [max_conns]Leftover = @splat(.{});

fn leftoverOf(key: u64) ?*Leftover {
    for (&leftovers) |*l| if (l.has and l.key == key and l.len > 0) return l;
    return null;
}

fn keepLeftover(key: u64, bytes: []const u8) void {
    for (&leftovers) |*l| if (l.has and l.key == key) {
        l.has = false;
        l.len = 0;
    };
    if (bytes.len == 0 or bytes.len > max_leftover) return;
    for (&leftovers) |*l| if (!l.has) {
        l.has = true;
        l.key = key;
        l.len = bytes.len;
        @memcpy(l.buf[0..bytes.len], bytes);
        return;
    };
}

/// How long `serve` waits for the next request on a kept connection.
const idle_ms: u64 = 3000;
/// How long any read waits for the rest of a request once it began.
const stall_ms: u64 = 10_000;

/// A client connection: a socket, or a tls session over one.
const Conn = union(enum) {
    plain: u64,
    tls: tlscmds.Conn,

    fn send(c: Conn, n: *Net, data: []const u8) ?[]const u8 {
        return switch (c) {
            .plain => |s| n.sendAll(s, data),
            .tls => |t| tlscmds.sendAll(t, data),
        };
    }

    fn recvFor(c: Conn, n: *Net, ms: u64) Net.RecvFor {
        return switch (c) {
            .plain => |s| n.recvSomeFor(s, ms),
            .tls => |t| tlscmds.recvSomeFor(t, ms),
        };
    }

    fn close(c: Conn, n: *Net) void {
        switch (c) {
            .plain => |s| n.closeRaw(s),
            .tls => |t| tlscmds.close(t),
        }
    }

    /// A key for the per-connection leftover buffer, distinct across the
    /// plain and TLS namespaces (a socket number and a tls connection
    /// number can collide otherwise).
    fn leftoverKey(c: Conn) u64 {
        return switch (c) {
            .plain => |s| s,
            .tls => |t| (1 << 40) | t,
        };
    }
};

/// `fetch`'s kept connections: one per host (as written in the URL:
/// an address or a name), port and scheme, idle.
const pool_size = 4;
const max_host = 128;
const Pooled = struct { used: bool = false, host: [max_host]u8 = undefined, host_len: usize = 0, port: u64 = 0, tls: bool = false, conn: Conn = .{ .plain = 0 } };
var pool: [pool_size]Pooled = @splat(.{});

fn pooled(host: []const u8, port: u64, tls: bool) ?*Pooled {
    for (&pool) |*p| if (p.used and p.port == port and p.tls == tls and std.mem.eql(u8, p.host[0..p.host_len], host)) return p;
    return null;
}

fn poolPut(n: *Net, host: []const u8, port: u64, tls: bool, conn: Conn) void {
    if (host.len > max_host) return conn.close(n);
    for (&pool) |*p| if (!p.used) {
        p.* = .{ .used = true, .host_len = host.len, .port = port, .tls = tls, .conn = conn };
        @memcpy(p.host[0..host.len], host);
        return;
    };
    conn.close(n); // no room: not kept
}

/// A fresh connection for a URL: TCP to the host, and for https the
/// handshake as `name` (the certificate's name: the host unless the
/// options say otherwise).
const ConnOut = union(enum) { conn: Conn, failed: []const u8 };

fn connectUrl(n: *Net, url: http.Url, name: []const u8) ConnOut {
    if (url.tls) return switch (tlscmds.open(n, url.host, url.port, name)) {
        .conn => |t| .{ .conn = .{ .tls = t } },
        .failed => |m| .{ .failed = m },
    };
    return switch (n.connectHost(url.host, url.port)) {
        .sock => |x| .{ .conn = .{ .plain = x } },
        .failed => |m| .{ .failed = m },
    };
}

/// Text if it is UTF-8, bytes otherwise.
fn bodyValue(b: []const u8) Value {
    return if (std.unicode.utf8ValidateSlice(b)) .{ .str = b } else .{ .bytes = b };
}

/// Read one request from a socket into the arena, starting with what
/// the last read left over; what this one leaves is kept for the next.
/// `idle`: how long to wait for the first byte (null: as long as it
/// takes); a request that began is waited for `stall_ms`.
const ReadOut = union(enum) { request: http.Request, failed: []const u8, idle };

fn readRequest(n: *Net, it: *mshl.Interp, c: Conn, idle: ?u64) mshl.Error!ReadOut {
    const key = c.leftoverKey();
    var buf: std.ArrayList(u8) = .empty;
    if (leftoverOf(key)) |l| {
        try buf.appendSlice(it.arena, l.buf[0..l.len]);
        l.has = false;
        l.len = 0;
    }
    while (true) {
        switch (http.parseRequest(it.arena, buf.items) catch |e| return .{ .failed = switch (e) {
            error.OutOfMemory => return mshl.Error.OutOfMemory,
            error.Bad => "bad request",
            error.TooLarge => "request too large",
        } }) {
            .done => |r| {
                keepLeftover(key, buf.items[r.len..]);
                return .{ .request = r };
            },
            .incomplete => {},
        }
        // The first byte waits `idle` (or, for http-read, a long time);
        // once a request has begun, `stall_ms` for the rest.
        const ms: u64 = if (buf.items.len == 0) (idle orelse forever_ms) else stall_ms;
        switch (c.recvFor(n, ms)) {
            .data => |d| try buf.appendSlice(it.arena, d),
            .closed => return .{ .failed = if (buf.items.len == 0) "closed" else "closed mid-request" },
            .failed => |m| return .{ .failed = m },
            .timeout => return if (buf.items.len == 0 and idle != null) .idle else .{ .failed = "timed out mid-request" },
        }
    }
}

/// A stand-in for "as long as it takes" on a single http-read.
const forever_ms: u64 = 3600_000;

fn requestRecord(it: *mshl.Interp, r: http.Request) mshl.Error!Value {
    return record(it, &.{ "method", "path", "query", "headers", "body" }, &.{
        .{ .str = r.method },
        .{ .str = r.path },
        if (r.query.len > 0) .{ .str = r.query } else .nothing,
        try http.headersRecord(it.arena, r.headers),
        bodyValue(r.body),
    });
}

/// A response record may say `close: true` to end the connection.
fn wantsClose(v: Value) bool {
    if (v != .record) return false;
    const c = v.record.get("close") orelse return false;
    return c.asBool();
}

/// What a handler (or the caller of http-write) gave, as wire bytes.
fn responseBytes(it: *mshl.Interp, v: Value, out: *std.ArrayList(u8), keep: bool) mshl.Error!void {
    var status: u16 = 200;
    var headers: std.ArrayList(http.Header) = .empty;
    var body: []const u8 = "";
    var content_type: ?[]const u8 = null;
    var body_val: Value = v;
    if (v == .record and (v.record.get("status") != null or v.record.get("body") != null or v.record.get("headers") != null or v.record.get("close") != null)) {
        if (v.record.get("status")) |st| {
            if (st != .int or st.int < 100 or st.int > 599) return it.fail("http: status must be an int from 100 to 599", .{});
            status = @intCast(st.int);
        }
        if (v.record.get("headers")) |h| {
            if (h != .record) return it.fail("http: headers must be a record", .{});
            for (h.record.keys, h.record.vals) |k, hv| {
                if (hv != .str) return it.fail("http: header {s} must be a string", .{k});
                if (std.ascii.eqlIgnoreCase(k, "content-type")) content_type = hv.str;
                try headers.append(it.arena, .{ .name = k, .value = hv.str });
            }
        }
        body_val = v.record.get("body") orelse .nothing;
    }
    switch (body_val) {
        .nothing => {},
        .str => |t| {
            body = t;
            if (content_type == null) try headers.append(it.arena, .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" });
        },
        .bytes => |b| {
            body = b;
            if (content_type == null) try headers.append(it.arena, .{ .name = "Content-Type", .value = "application/octet-stream" });
        },
        .list, .record, .table, .bool, .int => {
            if (!body_val.isData()) return it.fail("http: the body holds something that is not data", .{});
            var jb: std.ArrayList(u8) = .empty;
            try json.encode(body_val, it.arena, &jb);
            body = jb.items;
            if (content_type == null) try headers.append(it.arena, .{ .name = "Content-Type", .value = "application/json" });
        },
        else => return it.fail("http: cannot send a {s} as a body", .{body_val.typeName()}),
    }
    var date_buf: [32]u8 = undefined;
    const date: ?[]const u8 = if (usys.wallMs()) |ms| shared.civil.imfText(&date_buf, @intCast(ms / 1000)) else null;
    try http.formatResponse(it.arena, out, status, headers.items, body, keep and !wantsClose(v), date);
}

fn writeResponse(n: *Net, it: *mshl.Interp, c: Conn, v: Value, keep: bool) mshl.Error!?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try responseBytes(it, v, &out, keep);
    return c.send(n, out.items);
}

/// A connection from a handle: a plain socket, or a tls connection.
fn connOfHandle(it: *mshl.Interp, v: Value, cmd: []const u8) mshl.Error!Conn {
    if (v == .handle and std.mem.eql(u8, v.handle.kind, "tls")) {
        if (v.handle.closed) return it.fail("{s}: the tls connection is closed", .{cmd});
        return .{ .tls = v.handle.id };
    }
    return .{ .plain = try netcmds.sockArg(it, v, cmd, "socket") };
}

/// null = not an HTTP command.
pub fn call(n: *Net, it: *mshl.Interp, name: []const u8, args: []const Value, input: ?Value) mshl.Error!?Value {
    const is = std.mem.eql;
    if (is(u8, name, "http-read")) {
        const sv = input orelse (if (args.len > 0) args[0] else return it.fail("http-read: a socket expected", .{}));
        const c = try connOfHandle(it, sv, "http-read");
        return switch (try readRequest(n, it, c, null)) {
            .request => |r| try okResult(it, try requestRecord(it, r)),
            .failed => |m| try errResult(it, m),
            .idle => unreachable, // no idle limit was given
        };
    }
    if (is(u8, name, "http-write")) {
        const c = try connOfHandle(it, args[0], "http-write");
        if (try writeResponse(n, it, c, args[1], true)) |m| return try errResult(it, m);
        return try okResult(it, .nothing);
    }
    if (is(u8, name, "http-serve")) {
        const tls_listener = args[0] == .handle and is(u8, args[0].handle.kind, "tls-listener");
        const l = try netcmds.sockArg(it, args[0], "http-serve", if (tls_listener) "tls-listener" else "listener");
        var left: ?i64 = null;
        if (args.len > 2) {
            if (args[2].int < 1) return it.fail("http-serve: the count must be a positive int", .{});
            left = args[2].int;
        }
        var served: i64 = 0;
        while (left == null or left.? > 0) {
            const c: Conn = if (tls_listener) switch (tlscmds.accept(n, l)) {
                .conn => |t| .{ .tls = t },
                // A handshake that fails is one client's problem, not the
                // server's: wait for the next.
                .failed => continue,
            } else switch (n.acceptRaw(l)) {
                .sock => |x| .{ .plain = x },
                .failed => |m| return try errResult(it, m),
            };
            defer c.close(n);
            // Every request the connection carries, until the peer says
            // close, the count runs out, or it sits idle.
            while (left == null or left.? > 0) {
                const req = switch (try readRequest(n, it, c, idle_ms)) {
                    .request => |r| r,
                    .idle => break,
                    .failed => |m| {
                        if (!is(u8, m, "closed")) _ = try writeResponse(n, it, c, .{ .record = .{ .keys = &.{ "status", "body" }, .vals = &.{ .{ .int = 400 }, .{ .str = m } } } }, false);
                        break;
                    },
                };
                // The handler runs in its own line-sized world; a failure is
                // a 500 with the message, never the end of the server.
                const reply: Value = blk: {
                    const out = it.callValue(args[1], &.{try requestRecord(it, req)}, null, &.{"req"}) catch |e| switch (e) {
                        mshl.Error.Runtime => break :blk .{ .record = .{ .keys = &.{ "status", "body" }, .vals = &.{ .{ .int = 500 }, .{ .str = it.err_msg } } } },
                        else => return e,
                    };
                    if (out == .result) {
                        if (!out.result.ok) {
                            var msg: std.ArrayList(u8) = .empty;
                            try mshl.renderInline(out.result.val, it.arena, &msg);
                            break :blk .{ .record = .{ .keys = &.{ "status", "body" }, .vals = &.{ .{ .int = 500 }, .{ .str = msg.items } } } };
                        }
                        break :blk out.result.val;
                    }
                    break :blk out;
                };
                served += 1;
                if (left) |*k| k.* -= 1;
                const keep = req.keep and !wantsClose(reply) and (left == null or left.? > 0);
                if (try writeResponse(n, it, c, reply, keep)) |_| break;
                if (!keep) break;
            }
            keepLeftover(c.leftoverKey(), ""); // the number may be reused
        }
        return try okResult(it, .{ .int = served });
    }
    if (is(u8, name, "fetch")) {
        const url = http.parseUrl(args[0].str) orelse return it.fail("fetch: not an http or https URL: {s}", .{args[0].str});
        var method: []const u8 = "GET";
        var headers: std.ArrayList(http.Header) = .empty;
        var body: []const u8 = "";
        var keep = true;
        var cert_name = url.host;
        if (args.len > 1) {
            const o = args[1].record;
            if (o.get("keep")) |k| keep = k.asBool();
            if (o.get("host")) |h| {
                if (h != .str) return it.fail("fetch: host must be a string", .{});
                cert_name = h.str;
            }
            if (o.get("method")) |m| {
                if (m != .str) return it.fail("fetch: method must be a string", .{});
                method = m.str;
            }
            if (o.get("headers")) |h| {
                if (h != .record) return it.fail("fetch: headers must be a record", .{});
                for (h.record.keys, h.record.vals) |k, hv| {
                    if (hv != .str) return it.fail("fetch: header {s} must be a string", .{k});
                    try headers.append(it.arena, .{ .name = k, .value = hv.str });
                }
            }
            if (o.get("body")) |b| switch (b) {
                .str => |t| body = t,
                .bytes => |t| body = t,
                .nothing => {},
                else => {
                    if (!b.isData()) return it.fail("fetch: the body must be text, bytes or data", .{});
                    var jb: std.ArrayList(u8) = .empty;
                    try json.encode(b, it.arena, &jb);
                    body = jb.items;
                    try headers.append(it.arena, .{ .name = "Content-Type", .value = "application/json" });
                },
            };
        }
        var host_hdr: [64]u8 = undefined;
        const host = std.fmt.bufPrint(&host_hdr, "{s}:{d}", .{ url.host, url.port }) catch url.host;
        var req: std.ArrayList(u8) = .empty;
        try http.formatRequest(it.arena, &req, method, url.path, host, headers.items, body, keep);
        // A kept connection first; if it turns out dead before a byte
        // came back, once more on a fresh one.
        // The host is an address or a name; every address it has is
        // tried in turn.
        var reused = false;
        var c: Conn = undefined;
        if (pooled(url.host, url.port, url.tls)) |p| {
            c = p.conn;
            p.used = false;
            reused = true;
        } else c = switch (connectUrl(n, url, cert_name)) {
            .conn => |x| x,
            .failed => |m| return try errResult(it, m),
        };
        while (true) {
            const out = try exchange(n, it, c, req.items, keep);
            if (out.response) |v| {
                if (out.kept) poolPut(n, url.host, url.port, url.tls, c) else c.close(n);
                return try okResult(it, v);
            }
            c.close(n);
            if (reused and out.early) {
                reused = false;
                c = switch (connectUrl(n, url, cert_name)) {
                    .conn => |x| x,
                    .failed => |m2| return try errResult(it, m2),
                };
                continue;
            }
            return try errResult(it, out.failed orelse "failed");
        }
    }
    return null;
}

/// One request and its response on a socket.
fn exchange(n: *Net, it: *mshl.Interp, c: Conn, req: []const u8, keep: bool) mshl.Error!ExchangeOut {
    if (c.send(n, req)) |m| return .{ .failed = m, .early = true };
    var buf: std.ArrayList(u8) = .empty;
    var closed = false;
    while (true) {
        switch (http.parseResponse(it.arena, buf.items, closed) catch |e| return .{ .failed = switch (e) {
            error.OutOfMemory => return mshl.Error.OutOfMemory,
            error.Bad => "bad response",
            error.TooLarge => "response too large",
        }, .early = false }) {
            .done => |r| return .{ .response = try record(it, &.{ "status", "headers", "body" }, &.{
                .{ .int = r.status },
                try http.headersRecord(it.arena, r.headers),
                bodyValue(r.body),
            }), .kept = keep and r.keep and !r.to_close and !closed },
            .incomplete => {},
        }
        if (closed) return .{ .failed = "closed before the response was complete", .early = buf.items.len == 0 };
        // A kept connection the peer closed answers nothing at all.
        switch (c.recvFor(n, stall_ms)) {
            .data => |d| try buf.appendSlice(it.arena, d),
            .closed => closed = true,
            .failed => |m| return .{ .failed = m, .early = buf.items.len == 0 },
            .timeout => return .{ .failed = "timed out waiting for the response", .early = false },
        }
    }
}

const ExchangeOut = struct {
    response: ?Value = null,
    kept: bool = false,
    failed: ?[]const u8 = null,
    /// Nothing had come back when it failed: on a kept connection, the
    /// peer had closed it while it sat — worth one retry.
    early: bool = false,
};

pub const command_names = [_][]const u8{ "http-read", "http-write", "http-serve", "fetch" };

// ---------------------------------------------------------- signatures

const Shape = mshl.Shape;
const socket: Shape = .{ .kind = "socket" };
const listener: Shape = .{ .kind = "listener" };
/// http-read/http-write and serve take a plain socket/listener or a TLS
/// one; the runtime dispatch tells them apart by the handle's kind.
const stream = blk: {
    const alts = [_]Shape{ .{ .kind = "socket" }, .{ .kind = "tls" } };
    break :blk Shape{ .one_of = &alts };
};
const any_listener = blk: {
    const alts = [_]Shape{ .{ .kind = "listener" }, .{ .kind = "tls-listener" } };
    break :blk Shape{ .one_of = &alts };
};
const text_or_bytes = blk: {
    const alts = [_]Shape{ .string, .bytes };
    break :blk Shape{ .one_of = &alts };
};
const maybe_text = blk: {
    const alts = [_]Shape{ .string, .nothing };
    break :blk Shape{ .one_of = &alts };
};
/// What `http-read` answers: the request as a record.
const request_shape = blk: {
    const fields = [_]Shape.Field{
        .{ .key = "method", .shape = .string },  .{ .key = "path", .shape = .string },       .{ .key = "query", .shape = maybe_text },
        .{ .key = "headers", .shape = .record }, .{ .key = "body", .shape = text_or_bytes },
    };
    break :blk Shape{ .record_of = &fields };
};
/// What `fetch` answers.
const response_shape = blk: {
    const fields = [_]Shape.Field{ .{ .key = "status", .shape = .int }, .{ .key = "headers", .shape = .record }, .{ .key = "body", .shape = text_or_bytes } };
    break :blk Shape{ .record_of = &fields };
};
const read_result = mshl.resultShape(request_shape, .string);
const done_result = mshl.resultShape(.nothing, .string);
const count_result = mshl.resultShape(.int, .string);
const fetch_result = mshl.resultShape(response_shape, .string);

pub fn signature(name: []const u8) ?mshl.Signature {
    const is = std.mem.eql;
    if (is(u8, name, "http-read")) return .{ .params = &.{.{ .name = "socket", .shape = stream, .optional = true }}, .input = .{ .optional = stream }, .ret = read_result };
    if (is(u8, name, "http-write")) return .{ .params = &.{ .{ .name = "socket", .shape = stream }, .{ .name = "response" } }, .ret = done_result };
    if (is(u8, name, "http-serve")) return .{ .params = &.{ .{ .name = "listener", .shape = any_listener }, .{ .name = "handler", .shape = .function }, .{ .name = "count", .shape = .int, .optional = true } }, .ret = count_result };
    if (is(u8, name, "fetch")) return .{ .params = &.{ .{ .name = "url", .shape = .string }, .{ .name = "options", .shape = .record, .optional = true } }, .ret = fetch_result };
    return null;
}
