//! The script domain: where a JavaScript program runs. Spawned by a host
//! with a single capability — a badged calling end of the host's
//! channel — it asks the host for its data buffer, finds the source
//! there, runs it with the engine in `lib/js` over a static heap, sends
//! each `print` line back through the same buffer and finally reports
//! the completion value or the uncaught exception. It holds no
//! filesystem, no network and no clock of its own: what the host
//! offers arrives as modules — `moss:fs` is the one view the host may
//! lend, reached by calls back through the channel, and a relative
//! import is a file of that view — so a program gets exactly what its
//! domain holds. When its heap runs out it says so and dies, and the
//! host sees a dead client.
const std = @import("std");
const shared = @import("shared");
const mosslib = @import("mosslib");
const usys = @import("usys.zig");
const js = mosslib.js;
const wire = shared.js;
const Vm = js.vm.Vm;
const Value = js.value.Value;
const Error = js.vm.Error;

comptime {
    asm (usys.imageHeaderStack("jsrun", 128));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    var line: [240]u8 = undefined;
    _ = usys.log(glog, std.fmt.bufPrint(&line, "jsrun: panic: {s} (at 0x{x})", .{ msg, ret_addr orelse 0 }) catch "jsrun: panic");
    var fp: usize = @frameAddress();
    var depth: usize = 0;
    while (fp != 0 and depth < 12) : (depth += 1) {
        const frame: *const [2]usize = @ptrFromInt(fp);
        _ = usys.log(glog, std.fmt.bufPrint(&line, "  frame {d}: 0x{x}", .{ depth, frame[1] }) catch "?");
        if (frame[0] <= fp) break;
        fp = frame[0];
    }
    usys.exit(255);
}

var glog: u64 = 0;
var host: u64 = 0;
var data: [*]u8 = undefined;
var data_len: usize = 0;
var flags: u64 = 0;

/// The engine's heap: every JavaScript value lives here.
var region: [8 << 20]u8 align(16) = undefined;
/// The engine's bookkeeping (shapes, atoms, the register stack, the
/// compiler's scratch): a bump heap for now, which frees only its last
/// block — enough for a script's run, and the residual the design
/// notes name.
var meta_buf: [12 << 20]u8 align(16) = undefined;
var meta_fba: std.heap.FixedBufferAllocator = undefined;
var vm: Vm = undefined;

fn call(req: wire.RunReq) wire.HostResp {
    return switch (usys.callTyped(wire.RunReq, wire.HostResp, host, req, 0)) {
        .ok => |rep| rep,
        .err => usys.exit(0), // the host is gone: so are we
    };
}

fn attach() []const u8 {
    const d = switch (usys.callTypedCap(wire.RunReq, wire.HostResp, host, .attach_data, 0)) {
        .ok => |ok| ok,
        .err => usys.exit(0),
    };
    if (d.rep != .data_buf or d.cap == 0) {
        _ = usys.log(glog, "jsrun: no data buffer from the host");
        usys.exit(3);
    }
    const dm = usys.shmMap(d.cap);
    _ = usys.capDrop(d.cap);
    if (dm.err != .ok) usys.exit(3);
    data = @ptrFromInt(dm.data[0]);
    data_len = dm.data[1] * 4096;
    flags = d.rep.data_buf.flags;
    return data[0..@min(d.rep.data_buf.len, data_len)];
}

/// Text to the host through the data buffer, cut to what fits.
fn sendText(comptime req: enum { output, done }, ok: bool, text: []const u8) void {
    const n = @min(text.len, data_len);
    @memcpy(data[0..n], text[0..n]);
    _ = switch (req) {
        .output => call(.{ .output = .{ .len = n } }),
        .done => call(.{ .done = .{ .ok = if (ok) 1 else 0, .len = n } }),
    };
}

// ------------------------------------------------------------ console

/// The arguments' strings joined by spaces, as one output line with an
/// optional tag in front.
fn emitLine(v: *Vm, tag: []const u8, args: []const Value) Error!void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(v.meta);
    try line.appendSlice(v.meta, tag);
    for (args, 0..) |a, i| {
        if (i > 0) try line.append(v.meta, ' ');
        const s = try v.toString(a);
        const u = try v.utf8(s, v.meta);
        defer v.meta.free(u);
        try line.appendSlice(v.meta, u);
    }
    sendText(.output, true, line.items);
}

fn print(v: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    try emitLine(v, "", args);
    return Value.undefined_;
}

fn consoleWarn(v: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    try emitLine(v, "[warn] ", args);
    return Value.undefined_;
}

fn consoleError(v: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    try emitLine(v, "[error] ", args);
    return Value.undefined_;
}

// ------------------------------------------------------------ moss:fs

/// A path argument into the data buffer, for a request that names one.
fn pathArg(v: *Vm, args: []const Value, at: usize) Error![]const u8 {
    if (at >= args.len or !args[at].isString()) return v.throwTypeError("a path string is needed");
    const s = try v.utf8(Vm.asString(args[at]), v.meta);
    defer v.meta.free(s);
    if (s.len == 0 or s.len > 1024) return v.throwRangeError("the path is empty or too long");
    // A leading slash means the view's root, the same place as no slash.
    const p = if (s[0] == '/') s[1..] else s;
    @memcpy(data[0..p.len], p);
    return data[0..p.len];
}

fn refusedError(v: *Vm, what: []const u8, path: []const u8, code: u64) Error {
    const why = if (code == 0) "the domain holds no filesystem view" else if (std.enums.fromInt(shared.FsErr, code)) |e| @tagName(e) else "refused";
    var msg: [1200]u8 = undefined;
    const m = std.fmt.bufPrint(&msg, "{s} {s}: {s}", .{ what, path, why }) catch "filesystem call refused";
    return v.throwError(.Error, m);
}

fn fsRead(v: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const path = try pathArg(v, args, 0);
    var pcopy: [1024]u8 = undefined;
    @memcpy(pcopy[0..path.len], path);
    switch (call(.{ .fs_read = .{ .len = path.len } })) {
        .text => |t| {
            const n = @min(t.len, data_len);
            return Vm.strValue(try v.strings.fromUtf8(data[0..n]));
        },
        .refused => |r| return refusedError(v, "read", pcopy[0..path.len], r.code),
        else => return v.throwError(.Error, "read: the host answered with nonsense"),
    }
}

fn fsWrite(v: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    if (args.len < 2) return v.throwTypeError("write(path, text) needs both");
    const text = try v.utf8(try v.toString(args[1]), v.meta);
    defer v.meta.free(text);
    const path = try pathArg(v, args, 0);
    var pcopy: [1024]u8 = undefined;
    @memcpy(pcopy[0..path.len], path);
    if (path.len + text.len > data_len) return v.throwRangeError("write: the text does not fit the data buffer");
    @memcpy(data[path.len .. path.len + text.len], text);
    switch (call(.{ .fs_write = .{ .path_len = path.len, .data_len = text.len } })) {
        .ok => return Value.undefined_,
        .refused => |r| return refusedError(v, "write", pcopy[0..path.len], r.code),
        else => return v.throwError(.Error, "write: the host answered with nonsense"),
    }
}

fn kindValue(v: *Vm, kind: u64) Error!Value {
    const name: []const u8 = if (std.enums.fromInt(shared.FsType, kind)) |k| @tagName(k) else "unknown";
    return v.str(name);
}

fn fsList(v: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const path = if (args.len == 0 or args[0].isUndefined()) blk: {
        data[0] = '.';
        break :blk data[0..1];
    } else try pathArg(v, args, 0);
    var pcopy: [1024]u8 = undefined;
    @memcpy(pcopy[0..path.len], path);
    switch (call(.{ .fs_list = .{ .len = path.len } })) {
        .text => |t| {
            const n = @min(t.len, data_len);
            const out = try v.newArray(0);
            var lines = std.mem.splitScalar(u8, data[0..n], '\n');
            while (lines.next()) |line| {
                if (line.len < 4) continue;
                // "<kind> <size> <name>"
                var parts = std.mem.splitScalar(u8, line, ' ');
                const kind_s = parts.next() orelse continue;
                const size_s = parts.next() orelse continue;
                const name = parts.rest();
                const entry = try v.newObject();
                try v.defineValue(entry, "name", Vm.strValue(try v.strings.fromUtf8(name)), .default);
                try v.defineValue(entry, "kind", try v.str(if (std.mem.eql(u8, kind_s, "d")) "dir" else if (std.mem.eql(u8, kind_s, "l")) "link" else "file"), .default);
                try v.defineValue(entry, "size", Value.fromF64(@floatFromInt(std.fmt.parseInt(u64, size_s, 10) catch 0)), .default);
                try v.arrayPush(out, entry.asValue());
            }
            return out.asValue();
        },
        .refused => |r| return refusedError(v, "list", pcopy[0..path.len], r.code),
        else => return v.throwError(.Error, "list: the host answered with nonsense"),
    }
}

fn fsStat(v: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const path = try pathArg(v, args, 0);
    var pcopy: [1024]u8 = undefined;
    @memcpy(pcopy[0..path.len], path);
    switch (call(.{ .fs_stat = .{ .len = path.len } })) {
        .stat => |st| {
            const entry = try v.newObject();
            try v.defineValue(entry, "kind", try kindValue(v, st.kind), .default);
            try v.defineValue(entry, "size", Value.fromF64(@floatFromInt(st.size)), .default);
            return entry.asValue();
        },
        .refused => |r| return refusedError(v, "stat", pcopy[0..path.len], r.code),
        else => return v.throwError(.Error, "stat: the host answered with nonsense"),
    }
}

fn fsExists(v: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const path = try pathArg(v, args, 0);
    return switch (call(.{ .fs_stat = .{ .len = path.len } })) {
        .stat => Value.true_,
        else => Value.false_,
    };
}

// ----------------------------------------------------------- moss:net

fn refuseText(code: u64) []const u8 {
    if (code == 0) return "the domain holds no network view";
    return if (std.enums.fromInt(shared.web.RefuseCode, code)) |c| @tagName(c) else "refused";
}

/// `fetch(url, { method, body })`: the whole resource through the
/// host's broker, chunk by chunk through the data buffer, as a promise
/// of `{ ok, status, url, type, text }`.
fn netFetch(v: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    if (args.len < 1 or !args[0].isString()) return v.throwTypeError("fetch(url) needs a URL string");
    const url = try v.utf8(Vm.asString(args[0]), v.meta);
    defer v.meta.free(url);
    var post = false;
    var body: []const u8 = "";
    var body_owned: ?[]u8 = null;
    defer if (body_owned) |b| v.meta.free(b);
    if (args.len > 1 and args[1].isObject()) {
        const o = Vm.asObject(args[1]);
        const m = try v.get(o, .{ .atom = try v.atom("method") }, args[1]);
        if (m.isString()) {
            const mt = try v.utf8(Vm.asString(m), v.meta);
            defer v.meta.free(mt);
            post = std.ascii.eqlIgnoreCase(mt, "POST");
        }
        const b = try v.get(o, .{ .atom = try v.atom("body") }, args[1]);
        if (!b.isUndefined()) {
            body_owned = try v.utf8(try v.toString(b), v.meta);
            body = body_owned.?;
        }
    }
    if (url.len + body.len > data_len or url.len > 2048) return v.throwRangeError("fetch: the URL and body do not fit the data buffer");
    @memcpy(data[0..url.len], url);
    @memcpy(data[url.len .. url.len + body.len], body);
    const open_flags: u64 = (if (post) @as(u64, 1) else 0) | (@as(u64, body.len) << 8);
    var status: u64 = 0;
    var final_url: []u8 = undefined;
    var ctype: []u8 = undefined;
    switch (call(.{ .net_open = .{ .off = 0, .len = url.len, .flags = open_flags } })) {
        .opened => |op| {
            status = op.status;
            const ul = @min(op.url_len, data_len);
            final_url = try v.meta.dupe(u8, data[0..ul]);
            const cl = @min(op.type_len, data_len - ul);
            ctype = try v.meta.dupe(u8, data[ul .. ul + cl]);
        },
        .refused => |r| {
            var msg: [2200]u8 = undefined;
            return v.throwError(.Error, std.fmt.bufPrint(&msg, "fetch {s}: {s}", .{ url, refuseText(r.code) }) catch "fetch refused");
        },
        else => return v.throwError(.Error, "fetch: the host answered with nonsense"),
    }
    defer v.meta.free(final_url);
    defer v.meta.free(ctype);
    // The body, a chunk at a time.
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(v.meta);
    while (true) {
        switch (call(.{ .net_read = .{ .max = data_len } })) {
            .chunk => |c| {
                const n = @min(c.len, data_len);
                try bytes.appendSlice(v.meta, data[0..n]);
                const end = std.enums.fromInt(shared.web.ChunkEnd, c.done) orelse .failed;
                if (end == .failed) return v.throwError(.Error, "fetch: the body was cut short");
                if (end == .done) break;
            },
            else => return v.throwError(.Error, "fetch: the host answered with nonsense"),
        }
    }
    const result = try v.newObject();
    try v.defineValue(result, "ok", Value.fromBool(status >= 200 and status < 300), .default);
    try v.defineValue(result, "status", Value.fromF64(@floatFromInt(status)), .default);
    try v.defineValue(result, "url", Vm.strValue(try v.strings.fromUtf8(final_url)), .default);
    try v.defineValue(result, "type", Vm.strValue(try v.strings.fromUtf8(ctype)), .default);
    try v.defineValue(result, "text", Vm.strValue(try v.strings.fromUtf8(bytes.items)), .default);
    return js.realm.promiseResolve(v, result.asValue());
}

const net_module_source =
    \\const net = globalThis.__moss_net;
    \\export const fetch = net.fetch;
    \\export default net;
;

/// The `moss:fs` module's text: its exports are the natives on the
/// hidden `__moss_fs` object, the domain's one view.
const fs_module_source =
    \\const fs = globalThis.__moss_fs;
    \\export const read = fs.read;
    \\export const write = fs.write;
    \\export const list = fs.list;
    \\export const stat = fs.stat;
    \\export const exists = fs.exists;
    \\export default fs;
;

/// The module loader: `moss:fs` is synthesized; anything else is a
/// file of the view, resolved relative to the importing module.
fn hostLoad(v: *Vm, referrer: ?[]const u8, specifier: []const u8) Error!?js.module.Loaded {
    const a = v.meta;
    if (std.mem.eql(u8, specifier, "moss:fs")) {
        if (flags & wire.flag_fs == 0) return null;
        return .{ .name = try a.dupe(u8, "moss:fs"), .source = try a.dupe(u8, fs_module_source) };
    }
    if (std.mem.eql(u8, specifier, "moss:net")) {
        if (flags & wire.flag_net == 0) return null;
        return .{ .name = try a.dupe(u8, "moss:net"), .source = try a.dupe(u8, net_module_source) };
    }
    if (flags & wire.flag_fs == 0) return null;
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(a);
    const relative = std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../");
    if (relative) if (referrer) |ref| {
        if (!std.mem.startsWith(u8, ref, "moss:")) if (std.mem.lastIndexOfScalar(u8, ref, '/')) |i| try path.appendSlice(a, ref[0..i]);
    };
    var it = std.mem.splitScalar(u8, specifier, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (std.mem.lastIndexOfScalar(u8, path.items, '/')) |i| path.shrinkRetainingCapacity(i) else path.clearRetainingCapacity();
            continue;
        }
        if (path.items.len > 0) try path.append(a, '/');
        try path.appendSlice(a, seg);
    }
    if (path.items.len == 0 or path.items.len > 1024) return null;
    @memcpy(data[0..path.items.len], path.items);
    switch (call(.{ .fs_read = .{ .len = path.items.len } })) {
        .text => |t| {
            const n = @min(t.len, data_len);
            return .{ .name = try a.dupe(u8, path.items), .source = try a.dupe(u8, data[0..n]) };
        },
        else => return null,
    }
}

fn installHostObjects() Error!void {
    _ = try vm.defineNative(vm.global, "print", 1, print);
    const console = try vm.newObject();
    _ = try vm.defineNative(console, "log", 1, print);
    _ = try vm.defineNative(console, "info", 1, print);
    _ = try vm.defineNative(console, "debug", 1, print);
    _ = try vm.defineNative(console, "warn", 1, consoleWarn);
    _ = try vm.defineNative(console, "error", 1, consoleError);
    try vm.defineValue(vm.global, "console", console.asValue(), .hidden);
    if (flags & wire.flag_fs != 0) {
        const fs = try vm.newObject();
        _ = try vm.defineNative(fs, "read", 1, fsRead);
        _ = try vm.defineNative(fs, "write", 2, fsWrite);
        _ = try vm.defineNative(fs, "list", 1, fsList);
        _ = try vm.defineNative(fs, "stat", 1, fsStat);
        _ = try vm.defineNative(fs, "exists", 1, fsExists);
        try vm.defineValue(vm.global, "__moss_fs", fs.asValue(), .frozen);
    }
    if (flags & wire.flag_net != 0) {
        const net = try vm.newObject();
        _ = try vm.defineNative(net, "fetch", 1, netFetch);
        try vm.defineValue(vm.global, "__moss_net", net.asValue(), .frozen);
    }
    vm.host_load = hostLoad;
}

fn exceptionText(a: std.mem.Allocator) []const u8 {
    const s = vm.toString(vm.exception) catch return "uncaught exception";
    return vm.utf8(s, a) catch "uncaught exception";
}

export fn umain(log_h: u64, chan_h: u64, arg: u64, _: u64, _: u64) callconv(.c) noreturn {
    glog = log_h;
    host = chan_h;
    if (arg != wire.run_arg) {
        _ = usys.log(glog, "jsrun: spawned without a host to serve");
        usys.exit(2);
    }
    meta_fba = std.heap.FixedBufferAllocator.init(&meta_buf);
    const meta = meta_fba.allocator();
    // The source is copied out of the shared buffer: the engine keeps
    // slices of it (a function's text) and the buffer is about to carry
    // the output.
    const in_buf = attach();
    const src = meta.dupe(u8, in_buf) catch usys.exit(5);
    vm.init(&region, meta) catch {
        _ = usys.log(glog, "jsrun: the engine did not fit its heap");
        usys.exit(5);
    };
    installHostObjects() catch usys.exit(5);
    _ = usys.log(glog, "jsrun: up");
    if (flags & wire.flag_module != 0) {
        // A module: its evaluation is a promise (top-level await); an
        // uncaught exception rejects it.
        const p = js.module.runEntry(&vm, "main", src) catch |e| switch (e) {
            error.OutOfMemory => {
                _ = usys.log(glog, "jsrun: out of memory running");
                usys.exit(5);
            },
            error.Exception => {
                sendText(.done, false, exceptionText(meta));
                usys.exit(0);
            },
        };
        vm.runJobs() catch {};
        const pd = Vm.asObject(p).internal(js.vm.PromiseData);
        if (pd.state == 2) {
            vm.exception = pd.result;
            sendText(.done, false, exceptionText(meta));
            usys.exit(0);
        }
        sendText(.done, true, "");
        usys.exit(0);
    }
    const code = js.compiler.compile(meta, &vm.heap, &vm.strings, src, .{ .name = "script" }) catch |e| switch (e) {
        error.OutOfMemory => {
            _ = usys.log(glog, "jsrun: out of memory compiling");
            usys.exit(5);
        },
        error.SyntaxError => {
            var line: [512]u8 = undefined;
            sendText(.done, false, std.fmt.bufPrint(&line, "SyntaxError: {s}", .{js.compiler.last_error}) catch "SyntaxError");
            usys.exit(0);
        },
    };
    const result = js.interp.runScript(&vm, code, vm.global.asValue(), null, null, Value.undefined_) catch |e| switch (e) {
        error.OutOfMemory => {
            _ = usys.log(glog, "jsrun: out of memory running");
            usys.exit(5);
        },
        error.Exception => {
            sendText(.done, false, exceptionText(meta));
            usys.exit(0);
        },
    };
    vm.runJobs() catch {};
    const text = blk: {
        const s = vm.toString(result) catch break :blk "";
        break :blk vm.utf8(s, meta) catch "";
    };
    sendText(.done, true, text);
    usys.exit(0);
}
