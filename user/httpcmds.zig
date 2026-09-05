//! HTTP for mshl hosts, on top of the network commands' sockets:
//! `http-read $sock` parses a request into a record, `http-write $sock
//! $resp` answers it, `serve $listener $handler [n]` loops accept /
//! read / handle / write with handlers as ordinary functions of the
//! request record, and `fetch URL [opts]` is the client. What a
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
//! sits idle for `idle_ticks`; `http-write` says keep-alive unless the
//! record says `close: true`; `fetch` keeps up to `pool_size` idle
//! connections by address and port and retries once on a fresh one
//! when a kept connection turns out dead (the peer closed it while it
//! sat), so a script talking to one server pays the handshake once.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const netcmds = @import("netcmds.zig");
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
const Leftover = struct { sock: u64 = 0, len: usize = 0, buf: [max_leftover]u8 = undefined };
const max_conns = 8;
var leftovers: [max_conns]Leftover = @splat(.{});

fn leftoverOf(sock: u64) ?*Leftover {
    for (&leftovers) |*l| if (l.sock == sock and l.len > 0) return l;
    return null;
}

fn keepLeftover(sock: u64, bytes: []const u8) void {
    for (&leftovers) |*l| if (l.sock == sock) {
        l.len = 0;
        l.sock = 0;
    };
    if (bytes.len == 0 or bytes.len > max_leftover) return;
    for (&leftovers) |*l| if (l.len == 0) {
        l.sock = sock;
        l.len = bytes.len;
        @memcpy(l.buf[0..bytes.len], bytes);
        return;
    };
}

/// How long `serve` waits for the next request on a kept connection.
const idle_ticks: u64 = 300; // 3 s
/// How long any read waits for the rest of a request once it began.
const stall_ticks: u64 = 1000; // 10 s

/// `fetch`'s kept connections: one per address and port, idle.
const pool_size = 4;
const Pooled = struct { used: bool = false, words: [2]u64 = .{ 0, 0 }, port: u64 = 0, sock: u64 = 0 };
var pool: [pool_size]Pooled = @splat(.{});

fn pooled(words: [2]u64, port: u64) ?*Pooled {
    for (&pool) |*p| if (p.used and p.words[0] == words[0] and p.words[1] == words[1] and p.port == port) return p;
    return null;
}

fn poolPut(n: *Net, words: [2]u64, port: u64, sock: u64) void {
    for (&pool) |*p| if (!p.used) {
        p.* = .{ .used = true, .words = words, .port = port, .sock = sock };
        return;
    };
    n.closeRaw(sock); // no room: not kept
}

/// Text if it is UTF-8, bytes otherwise.
fn bodyValue(b: []const u8) Value {
    return if (std.unicode.utf8ValidateSlice(b)) .{ .str = b } else .{ .bytes = b };
}

/// Read one request from a socket into the arena, starting with what
/// the last read left over; what this one leaves is kept for the next.
/// `idle`: how long to wait for the first byte (null: as long as it
/// takes); a request that began is waited for `stall_ticks`.
const ReadOut = union(enum) { request: http.Request, failed: []const u8, idle };

fn readRequest(n: *Net, it: *mshl.Interp, s: u64, idle: ?u64) mshl.Error!ReadOut {
    var buf: std.ArrayList(u8) = .empty;
    if (leftoverOf(s)) |l| {
        try buf.appendSlice(it.arena, l.buf[0..l.len]);
        l.len = 0;
        l.sock = 0;
    }
    while (true) {
        switch (http.parseRequest(it.arena, buf.items) catch |e| return .{ .failed = switch (e) {
            error.OutOfMemory => return mshl.Error.OutOfMemory,
            error.Bad => "bad request",
            error.TooLarge => "request too large",
        } }) {
            .done => |r| {
                keepLeftover(s, buf.items[r.len..]);
                return .{ .request = r };
            },
            .incomplete => {},
        }
        const wait: ?u64 = if (buf.items.len == 0) idle else stall_ticks;
        if (wait) |ticks| {
            switch (n.recvSomeFor(s, ticks)) {
                .data => |d| try buf.appendSlice(it.arena, d),
                .closed => return .{ .failed = if (buf.items.len == 0) "closed" else "closed mid-request" },
                .failed => |m| return .{ .failed = m },
                .timeout => return if (buf.items.len == 0) .idle else .{ .failed = "timed out mid-request" },
            }
        } else switch (n.recvSome(s)) {
            .data => |d| try buf.appendSlice(it.arena, d),
            .closed => return .{ .failed = if (buf.items.len == 0) "closed" else "closed mid-request" },
            .failed => |m| return .{ .failed = m },
        }
    }
}

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
    try http.formatResponse(it.arena, out, status, headers.items, body, keep and !wantsClose(v));
}

fn writeResponse(n: *Net, it: *mshl.Interp, s: u64, v: Value, keep: bool) mshl.Error!?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try responseBytes(it, v, &out, keep);
    return n.sendAll(s, out.items);
}

/// null = not an HTTP command.
pub fn call(n: *Net, it: *mshl.Interp, name: []const u8, args: []const Value, input: ?Value) mshl.Error!?Value {
    const is = std.mem.eql;
    if (is(u8, name, "http-read")) {
        const sv = input orelse (if (args.len > 0) args[0] else return it.fail("http-read: a socket expected", .{}));
        const s = try netcmds.sockArg(it, sv, "http-read", "socket");
        return switch (try readRequest(n, it, s, null)) {
            .request => |r| try okResult(it, try requestRecord(it, r)),
            .failed => |m| try errResult(it, m),
            .idle => unreachable, // no idle limit was given
        };
    }
    if (is(u8, name, "http-write")) {
        const s = try netcmds.sockArg(it, args[0], "http-write", "socket");
        if (try writeResponse(n, it, s, args[1], true)) |m| return try errResult(it, m);
        return try okResult(it, .nothing);
    }
    if (is(u8, name, "serve")) {
        const l = try netcmds.sockArg(it, args[0], "serve", "listener");
        var left: ?i64 = null;
        if (args.len > 2) {
            if (args[2].int < 1) return it.fail("serve: the count must be a positive int", .{});
            left = args[2].int;
        }
        var served: i64 = 0;
        while (left == null or left.? > 0) {
            const s = switch (n.acceptRaw(l)) {
                .sock => |x| x,
                .failed => |m| return try errResult(it, m),
            };
            defer n.closeRaw(s);
            // Every request the connection carries, until the peer says
            // close, the count runs out, or it sits idle.
            while (left == null or left.? > 0) {
                const req = switch (try readRequest(n, it, s, idle_ticks)) {
                    .request => |r| r,
                    .idle => break,
                    .failed => |m| {
                        if (!is(u8, m, "closed")) _ = try writeResponse(n, it, s, .{ .record = .{ .keys = &.{ "status", "body" }, .vals = &.{ .{ .int = 400 }, .{ .str = m } } } }, false);
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
                if (try writeResponse(n, it, s, reply, keep)) |_| break;
                if (!keep) break;
            }
            keepLeftover(s, ""); // the socket number may be reused
        }
        return try okResult(it, .{ .int = served });
    }
    if (is(u8, name, "fetch")) {
        const url = http.parseUrl(args[0].str) orelse return it.fail("fetch: not an http URL: {s}", .{args[0].str});
        const words = shared.parseAddr(url.host) orelse return it.fail("fetch: the host must be an address (there is no name resolution): {s}", .{url.host});
        var method: []const u8 = "GET";
        var headers: std.ArrayList(http.Header) = .empty;
        var body: []const u8 = "";
        var keep = true;
        if (args.len > 1) {
            const o = args[1].record;
            if (o.get("keep")) |k| keep = k.asBool();
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
        var reused = false;
        var s: u64 = undefined;
        if (pooled(words, url.port)) |p| {
            s = p.sock;
            p.used = false;
            reused = true;
        } else s = switch (n.connectRaw(words, url.port)) {
            .sock => |x| x,
            .failed => |m| return try errResult(it, m),
        };
        while (true) {
            const out = try exchange(n, it, s, req.items, keep);
            if (out.response) |v| {
                if (out.kept) poolPut(n, words, url.port, s) else n.closeRaw(s);
                return try okResult(it, v);
            }
            n.closeRaw(s);
            if (reused and out.early) {
                reused = false;
                s = switch (n.connectRaw(words, url.port)) {
                    .sock => |x| x,
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
fn exchange(n: *Net, it: *mshl.Interp, s: u64, req: []const u8, keep: bool) mshl.Error!ExchangeOut {
    if (n.sendAll(s, req)) |m| return .{ .failed = m, .early = true };
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
        switch (n.recvSomeFor(s, stall_ticks)) {
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

pub const command_names = [_][]const u8{ "http-read", "http-write", "serve", "fetch" };

// ---------------------------------------------------------- signatures

const Shape = mshl.Shape;
const socket: Shape = .{ .kind = "socket" };
const listener: Shape = .{ .kind = "listener" };
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
    if (is(u8, name, "http-read")) return .{ .params = &.{.{ .name = "socket", .shape = socket, .optional = true }}, .input = .{ .optional = socket }, .ret = read_result };
    if (is(u8, name, "http-write")) return .{ .params = &.{ .{ .name = "socket", .shape = socket }, .{ .name = "response" } }, .ret = done_result };
    if (is(u8, name, "serve")) return .{ .params = &.{ .{ .name = "listener", .shape = listener }, .{ .name = "handler", .shape = .function }, .{ .name = "count", .shape = .int, .optional = true } }, .ret = count_result };
    if (is(u8, name, "fetch")) return .{ .params = &.{ .{ .name = "url", .shape = .string }, .{ .name = "options", .shape = .record, .optional = true } }, .ret = fetch_result };
    return null;
}
