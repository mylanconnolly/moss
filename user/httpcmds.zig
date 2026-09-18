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
const web = mosslib.web;
const flate = std.compress.flate;
const fscmds = @import("fscmds.zig");
const fsc = @import("fsclient.zig");
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
    return sendReply(n, it, c, v, keep, false);
}

/// A handler's reply on the wire: a file body streamed from the view
/// (`body: { file: PATH, repeat: N }`), or the record rendered whole;
/// the head alone for a HEAD request, its Content-Length intact.
fn sendReply(n: *Net, it: *mshl.Interp, c: Conn, v: Value, keep: bool, head_only: bool) mshl.Error!?[]const u8 {
    if (fileBody(v)) |fb| return sendFile(n, it, c, v, fb, keep, head_only);
    var out: std.ArrayList(u8) = .empty;
    try responseBytes(it, v, &out, keep);
    if (head_only) {
        const he = (std.mem.indexOf(u8, out.items, "\r\n\r\n") orelse out.items.len - 4) + 4;
        return c.send(n, out.items[0..he]);
    }
    return c.send(n, out.items);
}

const FileBody = struct { path: []const u8, repeat: u64 };

fn fileBody(v: Value) ?FileBody {
    if (v != .record) return null;
    const b = v.record.get("body") orelse return null;
    if (b != .record) return null;
    const f = b.record.get("file") orelse return null;
    if (f != .str) return null;
    var repeat: u64 = 1;
    if (b.record.get("repeat")) |r| if (r == .int and r.int > 0) {
        repeat = @intCast(r.int);
    };
    return .{ .path = f.str, .repeat = repeat };
}

/// The response for a file body: the head with the file's length
/// (times `repeat`) and a Content-Type from its name unless the record
/// gives one, then the file read in `fs_max_io` pieces through the
/// view's buffer and sent as they come — never whole in memory. A
/// `repeat` past 1 sends the same bytes again: a fixture server's way
/// to a large body without a large file.
fn sendFile(n: *Net, it: *mshl.Interp, c: Conn, v: Value, fb: FileBody, keep: bool, head_only: bool) mshl.Error!?[]const u8 {
    const f = fs orelse return it.fail("http: a file body needs a filesystem view", .{});
    const t = try f.resolve(it, fb.path);
    const st = switch (fsc.fsStatR(t.chan, t.buf, t.path)) {
        .ok => |x| x,
        .err => |e| {
            // A file the handler named but the view has not: the client
            // gets a 404 and the server stays up — one bad route must not
            // end every page it serves.
            var line: [160]u8 = undefined;
            _ = usys.log(log_h, std.fmt.bufPrint(&line, "http: cannot serve {s}: {t}", .{ fb.path, e }) catch "http: cannot serve a file");
            const missing = try record(it, &.{ "status", "body" }, &.{ .{ .int = 404 }, .{ .str = "no such file" } });
            return sendReply(n, it, c, missing, keep, head_only);
        },
    };
    var status: u16 = 200;
    var headers: std.ArrayList(http.Header) = .empty;
    var typed = false;
    if (v.record.get("status")) |x| if (x == .int and x.int >= 100 and x.int <= 599) {
        status = @intCast(x.int);
    };
    if (v.record.get("headers")) |h| {
        if (h != .record) return it.fail("http: headers must be a record", .{});
        for (h.record.keys, h.record.vals) |k, hv| {
            if (hv != .str) return it.fail("http: header {s} must be a string", .{k});
            if (std.ascii.eqlIgnoreCase(k, "content-type")) typed = true;
            try headers.append(it.arena, .{ .name = k, .value = hv.str });
        }
    }
    if (!typed) try headers.append(it.arena, .{ .name = "Content-Type", .value = http.contentTypeFor(fb.path) });
    var date_buf: [32]u8 = undefined;
    const date: ?[]const u8 = if (usys.wallMs()) |ms| shared.civil.imfText(&date_buf, @intCast(ms / 1000)) else null;
    var out: std.ArrayList(u8) = .empty;
    const total: u64 = st.size * fb.repeat;
    try http.formatHead(it.arena, &out, status, headers.items, @intCast(total), keep, date);
    if (c.send(n, out.items)) |m| return m;
    if (head_only) return null;
    const fd = switch (fsc.fsOpen(t.chan, t.buf, t.path, 0)) {
        .fd => |x| x,
        .err => |e| return it.fail("http: cannot open {s}: {t}", .{ fb.path, e }),
    };
    defer fsc.fsClose(t.chan, fd);
    var round: u64 = 0;
    while (round < fb.repeat) : (round += 1) {
        var off: u64 = 0;
        while (off < st.size) {
            const want = @min(shared.fs_max_io, st.size - off);
            const got = fsc.fsReadAt(t.chan, fd, off, want) orelse return "reading the file failed";
            if (got == 0) return "the file shrank while it was being sent";
            if (c.send(n, t.buf[0..got])) |m| return m;
            off += got;
        }
    }
    return null;
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
                if (try sendReply(n, it, c, reply, keep, is(u8, req.method, "HEAD"))) |_| break;
                if (!keep) break;
            }
            keepLeftover(c.leftoverKey(), ""); // the number may be reused
        }
        return try okResult(it, .{ .int = served });
    }
    if (is(u8, name, "fetch")) return try fetch(n, it, args);
    return null;
}

// ------------------------------------------------------------------ fetch

/// What `fetch URL { … }` accepts: `method`, `headers`, `body`, `keep`,
/// `host` (the certificate's name), `follow` (redirects: a count, or
/// false), `decode` (gzip/deflate bodies decoded, the default), `to`
/// (stream the body into a file at this path — no size cap unless
/// `max` says; identity encoding is asked for), `max` (the body cap in
/// bytes; 256 KB in memory by default) and `timeout` (ms to wait on the
/// peer, 10 s by default).
const FetchOpts = struct {
    method: []const u8 = "GET",
    headers: std.ArrayList(http.Header) = .empty,
    body: []const u8 = "",
    keep: bool = true,
    cert_name: ?[]const u8 = null,
    follow: u32 = 10,
    decode: bool = true,
    to: ?[]const u8 = null,
    max: usize = http.max_body,
    timeout_ms: u64 = stall_ms,
};

fn fetchOpts(it: *mshl.Interp, args: []const Value) mshl.Error!FetchOpts {
    var o: FetchOpts = .{};
    if (args.len < 2) return o;
    const r = args[1].record;
    if (r.get("keep")) |k| o.keep = k.asBool();
    if (r.get("decode")) |k| o.decode = k.asBool();
    if (r.get("host")) |h| {
        if (h != .str) return it.fail("fetch: host must be a string", .{});
        o.cert_name = h.str;
    }
    if (r.get("method")) |m| {
        if (m != .str) return it.fail("fetch: method must be a string", .{});
        o.method = m.str;
    }
    if (r.get("to")) |t| {
        if (t != .str) return it.fail("fetch: `to` must be a path", .{});
        o.to = t.str;
        o.max = std.math.maxInt(usize);
    }
    if (r.get("max")) |m| {
        if (m != .int or m.int < 0) return it.fail("fetch: max must be a byte count", .{});
        o.max = @intCast(m.int);
    }
    if (r.get("timeout")) |m| {
        if (m != .int or m.int <= 0) return it.fail("fetch: timeout must be milliseconds", .{});
        o.timeout_ms = @intCast(m.int);
    }
    if (r.get("follow")) |f| switch (f) {
        .bool => |b| o.follow = if (b) 10 else 0,
        .int => |i| o.follow = if (i < 0) 0 else @intCast(@min(i, 50)),
        else => return it.fail("fetch: follow must be a count or a bool", .{}),
    };
    if (r.get("headers")) |h| {
        if (h != .record) return it.fail("fetch: headers must be a record", .{});
        for (h.record.keys, h.record.vals) |k, hv| {
            if (hv != .str) return it.fail("fetch: header {s} must be a string", .{k});
            try o.headers.append(it.arena, .{ .name = k, .value = hv.str });
        }
    }
    if (r.get("body")) |b| switch (b) {
        .str => |t| o.body = t,
        .bytes => |t| o.body = t,
        .nothing => {},
        else => {
            if (!b.isData()) return it.fail("fetch: the body must be text, bytes or data", .{});
            var jb: std.ArrayList(u8) = .empty;
            try json.encode(b, it.arena, &jb);
            o.body = jb.items;
            try o.headers.append(it.arena, .{ .name = "Content-Type", .value = "application/json" });
        },
    };
    return o;
}

fn isHttpUrl(u: *const web.url.Url) bool {
    return std.mem.eql(u8, u.scheme, "http") or std.mem.eql(u8, u.scheme, "https");
}

fn isRedirect(status: u16) bool {
    return status == 301 or status == 302 or status == 303 or status == 307 or status == 308;
}

/// The network's view of a URL: the host as an address or a name
/// (an IPv6 literal without its brackets), the port, the path with its
/// query, and whether to speak TLS.
fn httpTarget(it: *mshl.Interp, u: *const web.url.Url) mshl.Error!http.Url {
    const h = u.host orelse return it.fail("fetch: the URL has no host", .{});
    const host: []const u8 = switch (h) {
        .ipv6 => |pieces| blk: {
            var out: std.ArrayList(u8) = .empty;
            const bracketed = try h.serialize(it.arena);
            try out.appendSlice(it.arena, bracketed[1 .. bracketed.len - 1]);
            _ = pieces;
            break :blk out.items;
        },
        else => try h.serialize(it.arena),
    };
    const path = try u.pathname(it.arena);
    const query = try u.search(it.arena);
    const full = try std.mem.concat(it.arena, u8, &.{ path, query });
    const tls = std.mem.eql(u8, u.scheme, "https");
    return .{ .host = host, .port = u.port orelse (if (tls) 443 else 80), .path = full, .tls = tls };
}

fn dropHeader(headers: *std.ArrayList(http.Header), header_name: []const u8) void {
    var i: usize = 0;
    while (i < headers.items.len) {
        if (std.ascii.eqlIgnoreCase(headers.items[i].name, header_name)) {
            _ = headers.orderedRemove(i);
        } else i += 1;
    }
}

fn hasHeader(headers: []const http.Header, header_name: []const u8) bool {
    return http.headerValue(headers, header_name) != null;
}

fn fetch(n: *Net, it: *mshl.Interp, args: []const Value) mshl.Error!Value {
    var opts = try fetchOpts(it, args);
    var current = web.url.parse(it.arena, args[0].str, null) catch return it.fail("fetch: not a URL: {s}", .{args[0].str});
    if (!isHttpUrl(&current)) return it.fail("fetch: not an http or https URL: {s}", .{args[0].str});
    var redirects: u32 = 0;
    while (true) {
        const target = try httpTarget(it, &current);
        const head_only = std.mem.eql(u8, opts.method, "HEAD");
        var headers: std.ArrayList(http.Header) = .empty;
        try headers.appendSlice(it.arena, opts.headers.items);
        // Compressed bodies are asked for when they will be decoded in
        // memory; a streamed download takes the bytes as they are.
        if (opts.decode and opts.to == null and !hasHeader(headers.items, "accept-encoding")) try headers.append(it.arena, .{ .name = "Accept-Encoding", .value = "gzip, deflate" });
        var host_hdr: [64]u8 = undefined;
        const host = std.fmt.bufPrint(&host_hdr, "{s}:{d}", .{ target.host, target.port }) catch target.host;
        var req: std.ArrayList(u8) = .empty;
        try http.formatRequest(it.arena, &req, opts.method, target.path, host, headers.items, opts.body, opts.keep);
        const out = try fetchOnce(n, it, target, opts.cert_name orelse target.host, req.items, &opts, head_only);
        if (out.failed) |m| return try errResult(it, m);
        // A redirect, followed: the next URL from Location against this
        // one; a 303 and a redirected POST become a GET with no body; a
        // change of origin drops the credentials.
        if (opts.follow > 0 and isRedirect(out.status)) if (http.headerValue(out.headers, "location")) |loc| {
            redirects += 1;
            if (redirects > opts.follow) return try errResult(it, "too many redirects");
            const next = web.url.resolve(it.arena, loc, &current) catch return try errResult(it, "a redirect to a bad location");
            if (!isHttpUrl(&next)) return try errResult(it, "a redirect to a non-http URL");
            const get_now = out.status == 303 or ((out.status == 301 or out.status == 302) and !std.mem.eql(u8, opts.method, "GET") and !head_only);
            if (get_now) {
                opts.method = "GET";
                opts.body = "";
                dropHeader(&opts.headers, "content-type");
            }
            const same_origin = std.mem.eql(u8, try current.origin(it.arena), try next.origin(it.arena));
            if (!same_origin) {
                dropHeader(&opts.headers, "authorization");
                dropHeader(&opts.headers, "cookie");
            }
            current = next;
            continue;
        };
        const final = try current.href(it.arena);
        if (opts.to != null) {
            return try okResult(it, try record(it, &.{ "status", "headers", "body", "url", "redirects", "bytes" }, &.{
                .{ .int = out.status },
                try http.headersRecord(it.arena, out.headers),
                .nothing,
                .{ .str = final },
                .{ .int = redirects },
                .{ .int = @intCast(out.bytes) },
            }));
        }
        const decoded = try decodeBody(it, out.headers, out.body, opts.max, opts.decode);
        const hdrs = if (decoded.decoded) try withoutEncoding(it, out.headers) else out.headers;
        return try okResult(it, try record(it, &.{ "status", "headers", "body", "url", "redirects" }, &.{
            .{ .int = out.status },
            try http.headersRecord(it.arena, hdrs),
            bodyValue(decoded.data),
            .{ .str = final },
            .{ .int = redirects },
        }));
    }
}

const FetchOut = struct {
    status: u16 = 0,
    headers: []const http.Header = &.{},
    body: []const u8 = "",
    bytes: u64 = 0,
    failed: ?[]const u8 = null,
};

/// One request to one target, on a kept connection first and once more
/// on a fresh one if the kept one turns out dead before a byte came
/// back; the body in memory, or streamed to `opts.to`.
fn fetchOnce(n: *Net, it: *mshl.Interp, target: http.Url, cert_name: []const u8, req: []const u8, opts: *const FetchOpts, head_only: bool) mshl.Error!FetchOut {
    var reused = false;
    var c: Conn = undefined;
    if (pooled(target.host, target.port, target.tls)) |p| {
        c = p.conn;
        p.used = false;
        reused = true;
    } else c = switch (connectUrl(n, target, cert_name)) {
        .conn => |x| x,
        .failed => |m| return .{ .failed = m },
    };
    while (true) {
        const out = if (opts.to) |path|
            try streamExchange(n, it, c, req, opts, path, head_only)
        else
            try exchange(n, it, c, req, opts, head_only);
        if (out.failed == null) {
            if (out.kept) poolPut(n, target.host, target.port, target.tls, c) else c.close(n);
            return .{ .status = out.status, .headers = out.headers, .body = out.body, .bytes = out.bytes };
        }
        c.close(n);
        if (reused and out.early) {
            reused = false;
            c = switch (connectUrl(n, target, cert_name)) {
                .conn => |x| x,
                .failed => |m2| return .{ .failed = m2 },
            };
            continue;
        }
        return .{ .failed = out.failed };
    }
}

const ExchangeOut = struct {
    status: u16 = 0,
    headers: []const http.Header = &.{},
    body: []const u8 = "",
    bytes: u64 = 0,
    kept: bool = false,
    failed: ?[]const u8 = null,
    /// Nothing had come back when it failed: on a kept connection, the
    /// peer had closed it while it sat — worth one retry.
    early: bool = false,
};

/// One request and its whole response on a socket, the body in the
/// arena under `opts.max`.
fn exchange(n: *Net, it: *mshl.Interp, c: Conn, req: []const u8, opts: *const FetchOpts, head_only: bool) mshl.Error!ExchangeOut {
    if (c.send(n, req)) |m| return .{ .failed = m, .early = true };
    var buf: std.ArrayList(u8) = .empty;
    var closed = false;
    while (true) {
        switch (http.parseResponseLimit(it.arena, buf.items, closed, opts.max, head_only) catch |e| return .{ .failed = switch (e) {
            error.OutOfMemory => return mshl.Error.OutOfMemory,
            error.Bad => "bad response",
            error.TooLarge => "response too large (fetch { to: PATH } streams it, max: raises the cap)",
        }, .early = false }) {
            .done => |r| return .{ .status = r.status, .headers = r.headers, .body = r.body, .bytes = r.body.len, .kept = opts.keep and r.keep and !r.to_close and !closed },
            .incomplete => {},
        }
        if (closed) return .{ .failed = "closed before the response was complete", .early = buf.items.len == 0 };
        // A kept connection the peer closed answers nothing at all.
        switch (c.recvFor(n, opts.timeout_ms)) {
            .data => |d| try buf.appendSlice(it.arena, d),
            .closed => closed = true,
            .failed => |m| return .{ .failed = m, .early = buf.items.len == 0 },
            .timeout => return .{ .failed = "timed out waiting for the response", .early = false },
        }
    }
}

// ------------------------------------------------------------- streaming

/// The host's filesystem: what `fetch { to }` writes through and what
/// an `http-serve` file body reads through. The host (mshrun, msh) sets
/// it once it holds a view; null refuses those forms.
pub var fs: ?*const fscmds.Fs = null;
/// The host's log, for what a server must say without ending (a file it
/// cannot serve).
pub var log_h: u64 = 0;

/// A file being written in order, `fs_max_io` bytes per exchange
/// through the view's buffer; truncated to what was written on close.
const FileSink = struct {
    chan: u64,
    buf: [*]u8,
    fd: u64,
    off: u64 = 0,

    fn open(it: *mshl.Interp, path: []const u8) mshl.Error!union(enum) { sink: FileSink, failed: []const u8 } {
        const f = fs orelse return .{ .failed = "fetch: no filesystem to write into" };
        const t = try f.resolve(it, path);
        return switch (fsc.fsOpen(t.chan, t.buf, t.path, 1)) {
            .fd => |fd| .{ .sink = .{ .chan = t.chan, .buf = t.buf, .fd = fd } },
            .err => |e| .{ .failed = try std.fmt.allocPrint(it.arena, "fetch: cannot open {s}: {t}", .{ path, e }) },
        };
    }

    fn write(s: *FileSink, data: []const u8) bool {
        var done: usize = 0;
        while (done < data.len) {
            const len = @min(shared.fs_max_io, data.len - done);
            if (!fsc.fsWriteAt(s.chan, s.buf, s.fd, s.off, data[done .. done + len])) return false;
            s.off += len;
            done += len;
        }
        return true;
    }

    fn close(s: *FileSink) void {
        _ = fsc.fsTruncate(s.chan, s.fd, s.off);
        fsc.fsClose(s.chan, s.fd);
    }
};

/// Chunked transfer decoded as the bytes arrive: sizes, data, the CRLF
/// after each chunk, the trailers after the last.
const Dechunker = struct {
    state: enum { size, data, crlf, trailer } = .size,
    remaining: usize = 0,
    line: [96]u8 = undefined,
    line_len: usize = 0,
    done: bool = false,

    const Feed = struct { consumed: usize, failed: bool };

    /// Feed bytes; chunk data goes to `sink` (or is dropped when null).
    /// Returns how many bytes were taken (all of them, unless the message
    /// ended inside `bytes`) and whether the framing was bad.
    fn feed(d: *Dechunker, bytes: []const u8, sink: ?*FileSink) Feed {
        var i: usize = 0;
        while (i < bytes.len and !d.done) {
            switch (d.state) {
                .size => {
                    const ch = bytes[i];
                    i += 1;
                    if (ch != '\n') {
                        if (d.line_len == d.line.len) return .{ .consumed = i, .failed = true };
                        d.line[d.line_len] = ch;
                        d.line_len += 1;
                        continue;
                    }
                    var l: []const u8 = d.line[0..d.line_len];
                    d.line_len = 0;
                    if (l.len > 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];
                    if (std.mem.indexOfScalar(u8, l, ';')) |semi| l = l[0..semi];
                    const size = std.fmt.parseInt(usize, std.mem.trim(u8, l, " \t"), 16) catch return .{ .consumed = i, .failed = true };
                    if (size == 0) {
                        d.state = .trailer;
                    } else {
                        d.remaining = size;
                        d.state = .data;
                    }
                },
                .data => {
                    const len = @min(d.remaining, bytes.len - i);
                    if (sink) |s| if (!s.write(bytes[i .. i + len])) return .{ .consumed = i, .failed = true };
                    i += len;
                    d.remaining -= len;
                    if (d.remaining == 0) d.state = .crlf;
                },
                .crlf => {
                    const ch = bytes[i];
                    i += 1;
                    if (ch == '\n') d.state = .size else if (ch != '\r') return .{ .consumed = i, .failed = true };
                },
                .trailer => {
                    const ch = bytes[i];
                    i += 1;
                    if (ch != '\n') {
                        if (d.line_len < d.line.len) {
                            d.line[d.line_len] = ch;
                            d.line_len += 1;
                        }
                        continue;
                    }
                    const empty = d.line_len == 0 or (d.line_len == 1 and d.line[0] == '\r');
                    d.line_len = 0;
                    if (empty) d.done = true;
                },
            }
        }
        return .{ .consumed = i, .failed = false };
    }
};

/// One request and its response with the body streamed into the file
/// at `path` as it arrives — the arena holds the head and nothing more,
/// so a download is bounded by the disk, not the budget. A redirect's
/// body is drained and dropped, so no file is made for it.
fn streamExchange(n: *Net, it: *mshl.Interp, c: Conn, req: []const u8, opts: *const FetchOpts, path: []const u8, head_only: bool) mshl.Error!ExchangeOut {
    if (c.send(n, req)) |m| return .{ .failed = m, .early = true };
    var buf: std.ArrayList(u8) = .empty;
    var closed = false;
    var head: http.Head = undefined;
    while (true) {
        if (http.parseHead(it.arena, buf.items) catch |e| return .{ .failed = switch (e) {
            error.OutOfMemory => return mshl.Error.OutOfMemory,
            error.Bad => "bad response",
            error.TooLarge => "response head too large",
        }, .early = false }) |h| {
            head = h;
            break;
        }
        if (closed) return .{ .failed = "closed before the response was complete", .early = buf.items.len == 0 };
        switch (c.recvFor(n, opts.timeout_ms)) {
            .data => |d| try buf.appendSlice(it.arena, d),
            .closed => closed = true,
            .failed => |m| return .{ .failed = m, .early = buf.items.len == 0 },
            .timeout => return .{ .failed = "timed out waiting for the response", .early = false },
        }
    }
    const redirect = opts.follow > 0 and isRedirect(head.status) and http.headerValue(head.headers, "location") != null;
    const bodiless = head_only or head.bodiless;
    var sink: ?FileSink = null;
    if (!redirect and !bodiless) sink = switch (try FileSink.open(it, path)) {
        .sink => |s| s,
        .failed => |m| return .{ .failed = m },
    };
    defer if (sink) |*s| s.close();
    const sink_ptr: ?*FileSink = if (sink) |*s| s else null;
    var dech: Dechunker = .{};
    var got: u64 = 0;
    var pending: []const u8 = buf.items[head.len..];
    var done = bodiless;
    var clean = true; // the message ended where the framing said
    while (!done) {
        switch (head.framing) {
            .none => {
                if (sink_ptr) |s| if (!s.write(pending)) return .{ .failed = "fetch: writing the file failed" };
                got += pending.len;
                if (closed) done = true;
            },
            .length => |want| {
                const take: usize = @intCast(@min(pending.len, want - got));
                if (sink_ptr) |s| if (!s.write(pending[0..take])) return .{ .failed = "fetch: writing the file failed" };
                got += take;
                if (got == want) done = true;
            },
            .chunked => {
                const fed = dech.feed(pending, sink_ptr);
                if (fed.failed) return .{ .failed = "bad chunked body" };
                if (sink_ptr) |s| got = s.off;
                if (dech.done) done = true;
            },
        }
        if (opts.max != std.math.maxInt(usize) and got > opts.max) return .{ .failed = "response too large" };
        if (done) break;
        if (closed) {
            clean = false;
            return .{ .failed = "closed mid-body" };
        }
        switch (c.recvFor(n, opts.timeout_ms)) {
            .data => |d| pending = d,
            .closed => {
                closed = true;
                pending = "";
            },
            .failed => |m| return .{ .failed = m },
            .timeout => return .{ .failed = "timed out mid-body" },
        }
    }
    return .{ .status = head.status, .headers = head.headers, .bytes = got, .kept = opts.keep and head.keep and head.framing != .none and !closed and clean };
}

// -------------------------------------------------------------- decoding

// The inflater's window, static: a host command's frame must stay small
// (HACKING), and one body is decoded at a time.
var flate_window: [flate.max_window_len]u8 = undefined;

const Decoded = struct { data: []const u8, decoded: bool };

/// The body as the caller wants it: gzip and deflate undone (under
/// `max`), identity as given; an unknown coding is left alone and its
/// header kept, so the caller can see what it got.
fn decodeBody(it: *mshl.Interp, headers: []const http.Header, body: []const u8, max: usize, decode: bool) mshl.Error!Decoded {
    if (!decode or body.len == 0) return .{ .data = body, .decoded = false };
    const ce = std.mem.trim(u8, http.headerValue(headers, "content-encoding") orelse return .{ .data = body, .decoded = false }, " \t");
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(ce, "identity") or ce.len == 0) return .{ .data = body, .decoded = false };
    if (eq(ce, "gzip") or eq(ce, "x-gzip")) return .{ .data = try inflate(it, body, .gzip, max), .decoded = true };
    if (eq(ce, "deflate")) {
        // Servers send zlib for "deflate"; a few send the raw stream.
        const zlib = inflate(it, body, .zlib, max) catch |e| switch (e) {
            mshl.Error.Runtime => try inflate(it, body, .raw, max),
            else => return e,
        };
        return .{ .data = zlib, .decoded = true };
    }
    return .{ .data = body, .decoded = false };
}

fn inflate(it: *mshl.Interp, body: []const u8, container: flate.Container, max: usize) mshl.Error![]const u8 {
    var in = std.Io.Reader.fixed(body);
    var dc = flate.Decompress.init(&in, container, &flate_window);
    const out = dc.reader.allocRemaining(it.arena, .limited(max + 1)) catch |e| switch (e) {
        error.OutOfMemory => return mshl.Error.OutOfMemory,
        error.StreamTooLong => return it.fail("fetch: the decoded body is larger than {d} bytes (max: raises the cap)", .{max}),
        else => return it.fail("fetch: the compressed body is corrupt", .{}),
    };
    if (out.len > max) return it.fail("fetch: the decoded body is larger than {d} bytes (max: raises the cap)", .{max});
    return out;
}

fn withoutEncoding(it: *mshl.Interp, headers: []const http.Header) mshl.Error![]const http.Header {
    var out: std.ArrayList(http.Header) = .empty;
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-encoding") or std.ascii.eqlIgnoreCase(h.name, "content-length")) continue;
        try out.append(it.arena, h);
    }
    return out.items;
}

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
const body_or_nothing = blk: {
    const alts = [_]Shape{ .string, .bytes, .nothing };
    break :blk Shape{ .one_of = &alts };
};
/// What `fetch` answers: the body is nothing when it went to a file
/// (`bytes` says how many), `url` is where the redirects ended.
const response_shape = blk: {
    const fields = [_]Shape.Field{ .{ .key = "status", .shape = .int }, .{ .key = "headers", .shape = .record }, .{ .key = "body", .shape = body_or_nothing }, .{ .key = "url", .shape = .string }, .{ .key = "redirects", .shape = .int } };
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
