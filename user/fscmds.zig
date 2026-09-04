//! The filesystem commands every mshl host shares — msh and mshrun —
//! over the view protocol: each turns a typed reply into a value (a
//! table, a record, a string, nothing) and never text parsed out of a
//! service. The host says where a path lives (`Fs.resolve`: one view,
//! or a view plus mounted shares), which channel `sync`/`df` talk to,
//! and which stores `use name` may read a module from.
//!
//! Every command has a SIGNATURE (`signature`): its arguments, its
//! input and its answer as shapes, the answer's derived from the
//! protocol types it is built from (`Stat`, `Df`, `shared.FsErr`) so the
//! declared shape and the value cannot drift. What the filesystem
//! decides — a path that is not there, a view that is read-only — is a
//! RESULT (`ok v` / `err not_found`), the error a word from the
//! protocol's own enumeration; misuse (a wrong argument) is a typed
//! error the interpreter raises from the signature before the call.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const fsc = @import("fsclient.zig");
const loader = @import("loader.zig");
const mshl = @import("mosslib").mshl;
const Value = mshl.Value;
const Shape = mshl.Shape;
const Param = mshl.Param;
const Signature = mshl.Signature;

/// Where a path lives: a view's channel and buffer, and the path in it.
pub const Target = struct { chan: u64, buf: [*]u8, path: []const u8 };

/// A program store: a view whose root is an `img/` directory.
pub const Store = struct { chan: u64, buf: [*]u8, name: []const u8 };

pub const Fs = struct {
    resolve: *const fn (it: *mshl.Interp, path: []const u8) mshl.Error!Target,
    /// The channel `sync` and `df` address (the host's main view).
    root: u64,
    /// The stores `use NAME` consults, in order (the user's own, then
    /// the system's); absent ones are null.
    stores: []const ?Store = &.{},
};

// ------------------------------------------------------------ the shapes
//
// What the commands answer, as Zig types: the value is built from the
// same definition (`toValue`) the shape is derived from (`shapeOf`).

/// One entry, as `stat` answers and `ls` lists.
pub const Stat = struct { name: []const u8, type: shared.FsType, size: i64, mtime: i64 };
/// `df`.
pub const Df = struct { free_kb: i64, total_kb: i64, encrypted: bool };

const fs_err = mshl.shapeOf(shared.FsErr);
const stat_result = mshl.resultShape(mshl.shapeOf(Stat), fs_err);
const ls_result = mshl.resultShape(mshl.shapeOf([]const Stat), fs_err);
const text_result = mshl.resultShape(.string, fs_err);
const done_result = mshl.resultShape(.nothing, fs_err);
const module_err = blk: {
    const alts = [_]Shape{ .{ .word = "not_found" }, .{ .word = "not_a_module" }, .{ .word = "bad_digest" }, fs_err };
    break :blk Shape{ .one_of = &alts };
};
const module_result = mshl.resultShape(.string, module_err);
const df_shape = mshl.shapeOf(Df);
const path_param = Param{ .name = "path", .shape = .string };

pub const command_names = [_][]const u8{ "ls", "tree", "cat", "open", "write", "save", "stat", "mkdir", "rm", "mv", "ln", "readlink", "sync", "df", "source", "module" };

/// The signature of a file command; null when the name is not one.
pub fn signature(name: []const u8) ?Signature {
    if (is(name, "ls")) return .{ .params = &.{.{ .name = "path", .shape = .string, .optional = true }}, .ret = ls_result };
    if (is(name, "tree")) return .{ .params = &.{.{ .name = "path", .shape = .string, .optional = true }}, .rest = .any, .ret = .string };
    if (is(name, "cat") or is(name, "open")) return .{ .params = &.{path_param}, .ret = text_result };
    if (is(name, "write")) return .{ .params = &.{ path_param, .{ .name = "text" } }, .ret = done_result };
    if (is(name, "save")) return .{ .params = &.{ path_param, .{ .name = "text", .optional = true } }, .input = .{ .optional = .any }, .ret = done_result };
    if (is(name, "stat")) return .{ .params = &.{path_param}, .ret = stat_result };
    if (is(name, "mkdir") or is(name, "rm")) return .{ .params = &.{path_param}, .ret = done_result };
    if (is(name, "mv")) return .{ .params = &.{ .{ .name = "from", .shape = .string }, .{ .name = "to", .shape = .string } }, .ret = done_result };
    if (is(name, "ln")) return .{ .params = &.{ path_param, .{ .name = "target", .shape = .string } }, .ret = done_result };
    if (is(name, "readlink")) return .{ .params = &.{path_param}, .ret = text_result };
    if (is(name, "sync")) return .{ .ret = done_result };
    if (is(name, "df")) return .{ .ret = df_shape };
    if (is(name, "source")) return .{ .params = &.{path_param}, .ret = done_result };
    if (is(name, "module")) return .{ .params = &.{.{ .name = "name", .shape = .string }}, .ret = module_result };
    return null;
}

fn errWord(it: *mshl.Interp, e: shared.FsErr) mshl.Error!Value {
    return it.mkResult(false, .{ .str = @tagName(e) });
}

fn errName(it: *mshl.Interp, word: []const u8) mshl.Error!Value {
    return it.mkResult(false, .{ .str = word });
}

fn okv(it: *mshl.Interp, v: Value) mshl.Error!Value {
    return it.mkResult(true, v);
}

/// The shared commands: ls, tree, cat/open, write, save, stat, mkdir,
/// rm, mv, ln, readlink, sync, df, source, module. null = not one of
/// these. Arguments arrive checked against `signature`.
pub fn call(fs: *const Fs, it: *mshl.Interp, name: []const u8, args: []const Value, input: ?Value) mshl.Error!?Value {
    const a = it.arena;
    if (is(name, "ls")) return try lsTable(fs, it, if (args.len > 0) args[0].str else "");
    if (is(name, "tree")) {
        var path: []const u8 = "";
        var depth: usize = 8;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const s = try pathArg(it, args[i]);
            if (is(s, "--depth") and i + 1 < args.len) {
                depth = @intCast(try intOf(it, args[i + 1]));
                i += 1;
            } else path = s;
        }
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(a, if (path.len == 0) "." else path);
        try text.append(a, '\n');
        try treeInto(fs, it, &text, path, "", depth);
        return .{ .str = text.items };
    }
    if (is(name, "cat") or is(name, "open")) {
        return switch (try readFileR(fs, it, args[0].str)) {
            .text => |t| try okv(it, .{ .str = t }),
            .err => |e| try errWord(it, e),
        };
    }
    if (is(name, "write")) {
        var text: std.ArrayList(u8) = .empty;
        try mshl.renderInline(args[1], a, &text);
        return try doneResult(it, try writeFileR(fs, it, args[0].str, text.items));
    }
    if (is(name, "save")) {
        // `x | save path`, or the redirect form (path, rendered text).
        var text: std.ArrayList(u8) = .empty;
        if (args.len >= 2) {
            try mshl.renderInline(args[1], a, &text);
        } else if (input) |v| {
            try mshl.render(v, a, &text);
        } else return it.fail("save: nothing to save", .{});
        return try doneResult(it, try writeFileR(fs, it, args[0].str, text.items));
    }
    if (is(name, "stat")) {
        const path = args[0].str;
        const t = try fs.resolve(it, path);
        return switch (fsc.fsStatR(t.chan, t.buf, t.path)) {
            .ok => |st| try okv(it, try statRecord(it, baseName(path), st)),
            .err => |e| try errWord(it, e),
        };
    }
    if (is(name, "mkdir")) {
        const t = try fs.resolve(it, args[0].str);
        return try doneResult(it, fsc.fsMkdirR(t.chan, t.buf, t.path));
    }
    if (is(name, "rm")) {
        const t = try fs.resolve(it, args[0].str);
        return switch (fsc.fsDelete(t.chan, t.buf, t.path)) {
            .ok => try okv(it, .nothing),
            .err => |e| try errWord(it, e),
        };
    }
    if (is(name, "mv")) {
        const from = try fs.resolve(it, args[0].str);
        const to = try fs.resolve(it, args[1].str);
        if (from.chan != to.chan) return it.fail("mv: both paths must be in the same filesystem", .{});
        return try doneResult(it, fsc.fsRenameR(from.chan, from.buf, from.path, to.path));
    }
    if (is(name, "ln")) {
        const t = try fs.resolve(it, args[0].str);
        return try doneResult(it, fsc.fsSymlinkR(t.chan, t.buf, t.path, args[1].str));
    }
    if (is(name, "readlink")) {
        const t = try fs.resolve(it, args[0].str);
        return switch (fsc.fsReadlinkR(t.chan, t.buf, t.path)) {
            .ok => |n| try okv(it, .{ .str = try a.dupe(u8, t.buf[0..@min(n, 256)]) }),
            .err => |e| try errWord(it, e),
        };
    }
    if (is(name, "sync")) return try doneResult(it, fsc.fsSyncR(fs.root));
    if (is(name, "df")) {
        const st = fsc.fsStatfs(fs.root) orelse return it.fail("df: the filesystem did not answer", .{});
        return try mshl.toValue(a, Df{ .free_kb = @intCast(st.free_blocks * 4), .total_kb = @intCast(st.total_blocks * 4), .encrypted = st.encrypted });
    }
    if (is(name, "source")) {
        const text = switch (try readFileR(fs, it, args[0].str)) {
            .text => |t| t,
            .err => |e| return try errWord(it, e),
        };
        _ = try it.evalScript(text, &it.out); // its output joins this line's
        return try okv(it, .nothing);
    }
    if (is(name, "module")) return try moduleText(fs, it, args[0].str);
    return null;
}

fn doneResult(it: *mshl.Interp, out: fsc.Outcome(void)) mshl.Error!Value {
    return switch (out) {
        .ok => try okv(it, .nothing),
        .err => |e| try errWord(it, e),
    };
}

/// `use NAME`: a path (a `/` in it, or `.msh` at its end) is a file in
/// the view; a bare name is a module in a store — `NAME.msh` there is
/// a manifest `{ source: "<digest>" }` and the text is the blob of that
/// name, verified against the digest (the name IS the content, as for
/// programs). The user's own store is consulted before the system's.
pub fn moduleText(fs: *const Fs, it: *mshl.Interp, name: []const u8) mshl.Error!Value {
    if (std.mem.indexOfScalar(u8, name, '/') != null or std.mem.endsWith(u8, name, ".msh")) {
        return switch (try readFileR(fs, it, name)) {
            .text => |t| try okv(it, .{ .str = t }),
            .err => |e| try errWord(it, e),
        };
    }
    for (fs.stores) |maybe| {
        const st = maybe orelse continue;
        var mpath: [64]u8 = undefined;
        if (name.len + shared.img_manifest_ext.len > mpath.len) return it.fail("use: name too long", .{});
        @memcpy(mpath[0..name.len], name);
        @memcpy(mpath[name.len .. name.len + shared.img_manifest_ext.len], shared.img_manifest_ext);
        const mp = mpath[0 .. name.len + shared.img_manifest_ext.len];
        const manifest = switch (try readFileViaR(it, st.chan, st.buf, mp)) {
            .text => |t| t,
            .err => continue,
        };
        const v = try it.parseData(manifest);
        if (v != .record) return try errName(it, "not_a_module");
        const src = v.record.get("source") orelse return try errName(it, "not_a_module");
        if (src != .str or src.str.len != shared.img_digest_hex_len) return try errName(it, "not_a_module");
        const text = switch (try readFileViaR(it, st.chan, st.buf, src.str)) {
            .text => |t| t,
            .err => |e| return try errWord(it, e),
        };
        const have = loader.digestHex(text);
        if (!std.mem.eql(u8, &have, src.str)) return try errName(it, "bad_digest");
        return try okv(it, .{ .str = text });
    }
    return try errName(it, "not_found");
}

pub fn lsTable(fs: *const Fs, it: *mshl.Interp, path_arg: []const u8) mshl.Error!Value {
    const a = it.arena;
    const t = try fs.resolve(it, path_arg);
    const path = t.path;
    const count = switch (fsc.fsListR(t.chan, t.buf, path)) {
        .ok => |n| n,
        .err => |e| return try errWord(it, e),
    };
    const names = try a.dupe(u8, t.buf[0..count]);
    var rows: std.ArrayList(Stat) = .empty;
    var split = std.mem.splitScalar(u8, names, '\n');
    while (split.next()) |name| {
        if (name.len == 0) continue;
        var full: [256]u8 = undefined;
        const fl = joinPath(&full, path, name);
        const st = fsc.fsStat(t.chan, t.buf, full[0..fl]) orelse continue;
        try rows.append(a, try statOf(it, name, st));
    }
    // An empty listing is still a table with the columns.
    if (rows.items.len == 0) return try okv(it, .{ .table = .{ .cols = &.{ "name", "type", "size", "mtime" }, .rows = &.{} } });
    return try okv(it, try mshl.toValue(a, @as([]const Stat, rows.items)));
}

pub fn treeInto(fs: *const Fs, it: *mshl.Interp, text: *std.ArrayList(u8), path_arg: []const u8, indent: []const u8, depth: usize) mshl.Error!void {
    const a = it.arena;
    if (depth == 0) return;
    const t = try fs.resolve(it, path_arg);
    const path = t.path;
    const count = fsc.fsList(t.chan, t.buf, path) orelse return;
    const names = try a.dupe(u8, t.buf[0..count]);
    var total: usize = 0;
    var split = std.mem.splitScalar(u8, names, '\n');
    while (split.next()) |n| {
        if (n.len > 0) total += 1;
    }
    var i: usize = 0;
    split = std.mem.splitScalar(u8, names, '\n');
    while (split.next()) |name| {
        if (name.len == 0) continue;
        i += 1;
        const last = i == total;
        var full: [256]u8 = undefined;
        const fl = joinPath(&full, path, name);
        const st = fsc.fsStat(t.chan, t.buf, full[0..fl]);
        try text.appendSlice(a, indent);
        try text.appendSlice(a, if (last) "└── " else "├── ");
        try text.appendSlice(a, name);
        if (st) |s| {
            if (s.typ == @intFromEnum(shared.FsType.dir)) {
                try text.appendSlice(a, "/\n");
                const sub = try std.mem.concat(a, u8, &.{ indent, if (last) "    " else "│   " });
                try treeInto(fs, it, text, full[0..fl], sub, depth - 1);
                continue;
            }
            if (s.typ == @intFromEnum(shared.FsType.symlink)) try text.appendSlice(a, " -> ?");
        }
        try text.append(a, '\n');
    }
}

pub const ReadOut = union(enum) { text: []const u8, err: shared.FsErr };

/// A file's text, or the filesystem's reason.
pub fn readFileR(fs: *const Fs, it: *mshl.Interp, path: []const u8) mshl.Error!ReadOut {
    const t = try fs.resolve(it, path);
    return readFileViaR(it, t.chan, t.buf, t.path);
}

pub fn readFileViaR(it: *mshl.Interp, chan: u64, buf: [*]u8, path: []const u8) mshl.Error!ReadOut {
    const fd = switch (fsc.fsOpen(chan, buf, path, 0)) {
        .fd => |f| f,
        .err => |e| return .{ .err = e },
    };
    defer fsc.fsClose(chan, fd);
    var out: std.ArrayList(u8) = .empty;
    var off: u64 = 0;
    while (true) {
        const n = fsc.fsReadAt(chan, fd, off, shared.fs_max_io) orelse return .{ .err = .io };
        if (n == 0) break;
        try out.appendSlice(it.arena, buf[0..n]);
        off += n;
    }
    return .{ .text = out.items };
}

/// A file's text, failing the line when it cannot be read (for a host's
/// own needs — a startup script, a manifest — not for a command).
pub fn readFile(fs: *const Fs, it: *mshl.Interp, path: []const u8) mshl.Error![]const u8 {
    const t = try fs.resolve(it, path);
    return readFileVia(it, t.chan, t.buf, t.path);
}

pub fn readFileVia(it: *mshl.Interp, chan: u64, buf: [*]u8, path: []const u8) mshl.Error![]const u8 {
    return switch (try readFileViaR(it, chan, buf, path)) {
        .text => |t| t,
        .err => |e| it.fail("cannot open {s}: {t}", .{ path, e }),
    };
}

pub fn writeFileR(fs: *const Fs, it: *mshl.Interp, path: []const u8, text: []const u8) mshl.Error!fsc.Outcome(void) {
    const t = try fs.resolve(it, path);
    return writeFileViaR(t.chan, t.buf, t.path, text);
}

pub fn writeFileViaR(chan: u64, buf: [*]u8, path: []const u8, text: []const u8) fsc.Outcome(void) {
    const fd = switch (fsc.fsOpen(chan, buf, path, 1)) {
        .fd => |f| f,
        .err => |e| return .{ .err = e },
    };
    defer fsc.fsClose(chan, fd);
    var off: usize = 0;
    while (off < text.len) {
        const n = @min(shared.fs_max_io, text.len - off);
        if (!fsc.fsWriteAt(chan, buf, fd, off, text[off .. off + n])) return .{ .err = .io };
        off += n;
    }
    if (!fsc.fsTruncate(chan, fd, text.len)) return .{ .err = .io };
    return .{ .ok = {} };
}

pub fn writeFileVia(it: *mshl.Interp, chan: u64, buf: [*]u8, path: []const u8, text: []const u8) mshl.Error!void {
    switch (writeFileViaR(chan, buf, path, text)) {
        .ok => {},
        .err => |e| return it.fail("cannot write {s}: {t}", .{ path, e }),
    }
}

fn statOf(it: *mshl.Interp, name: []const u8, st: fsc.StatOut) mshl.Error!Stat {
    return .{
        .name = try it.arena.dupe(u8, name),
        .type = std.enums.fromInt(shared.FsType, st.typ) orelse return it.fail("stat: {s}: an object of unknown type {d}", .{ name, st.typ }),
        .size = @intCast(st.size),
        .mtime = @intCast(st.mtime),
    };
}

pub fn statRecord(it: *mshl.Interp, name: []const u8, st: fsc.StatOut) mshl.Error!Value {
    return mshl.toValue(it.arena, try statOf(it, name, st));
}

pub fn record(it: *mshl.Interp, keys: []const []const u8, vals: []const Value) mshl.Error!Value {
    return .{ .record = .{ .keys = keys, .vals = try it.arena.dupe(Value, vals) } };
}

pub fn pathArg(it: *mshl.Interp, v: Value) mshl.Error![]const u8 {
    return switch (v) {
        .str => |s| s,
        .int => |i| std.fmt.allocPrint(it.arena, "{d}", .{i}) catch return error.OutOfMemory,
        else => it.fail("path expected, got a {s}", .{v.typeName()}),
    };
}

pub fn intOf(it: *mshl.Interp, v: Value) mshl.Error!i64 {
    return switch (v) {
        .int => |i| i,
        .str => |s| std.fmt.parseInt(i64, s, 10) catch it.fail("number expected, got '{s}'", .{s}),
        else => it.fail("number expected, got a {s}", .{v.typeName()}),
    };
}

pub fn joinPath(out: *[256]u8, dir: []const u8, name: []const u8) usize {
    var n: usize = 0;
    if (dir.len > 0) {
        const d = @min(dir.len, out.len - 1);
        @memcpy(out[0..d], dir[0..d]);
        n = d;
        out[n] = '/';
        n += 1;
    }
    const k = @min(name.len, out.len - n);
    @memcpy(out[n .. n + k], name[0..k]);
    return n + k;
}

pub fn baseName(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0 and path[i - 1] != '/') i -= 1;
    return path[i..];
}

pub fn is(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
