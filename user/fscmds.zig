//! The filesystem commands every mshl host shares — msh and mshrun —
//! over the view protocol: each turns a typed reply into a value (a
//! table, a record, a string, nothing) and never text parsed out of a
//! service. The host says where a path lives (`Fs.resolve`: one view,
//! or a view plus mounted shares) and which channel `sync`/`df` talk to.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const fsc = @import("fsclient.zig");
const mshl = @import("mosslib").mshl;
const Value = mshl.Value;

/// Where a path lives: a view's channel and buffer, and the path in it.
pub const Target = struct { chan: u64, buf: [*]u8, path: []const u8 };

pub const Fs = struct {
    resolve: *const fn (it: *mshl.Interp, path: []const u8) mshl.Error!Target,
    /// The channel `sync` and `df` address (the host's main view).
    root: u64,
};

/// The shared commands: ls, tree, cat/open, write, save, stat, mkdir,
/// rm, mv, ln, readlink, sync, df, source. null = not one of these.
pub fn call(fs: *const Fs, it: *mshl.Interp, name: []const u8, args: []const Value, input: ?Value) mshl.Error!?Value {
    const a = it.arena;
    if (is(name, "ls")) return try lsTable(fs, it, if (args.len > 0) try pathArg(it, args[0]) else "");
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
        if (args.len < 1) return it.fail("{s}: path expected", .{name});
        return .{ .str = try readFile(fs, it, try pathArg(it, args[0])) };
    }
    if (is(name, "write")) {
        if (args.len < 2) return it.fail("write: path and text expected", .{});
        var text: std.ArrayList(u8) = .empty;
        try mshl.renderInline(args[1], a, &text);
        try writeFile(fs, it, try pathArg(it, args[0]), text.items);
        return .nothing;
    }
    if (is(name, "save")) {
        // `x | save path`, or the redirect form (path, rendered text).
        if (args.len < 1) return it.fail("save: path expected", .{});
        var text: std.ArrayList(u8) = .empty;
        if (args.len >= 2) {
            try mshl.renderInline(args[1], a, &text);
        } else if (input) |v| {
            try mshl.render(v, a, &text);
        } else return it.fail("save: nothing to save", .{});
        try writeFile(fs, it, try pathArg(it, args[0]), text.items);
        return .nothing;
    }
    if (is(name, "stat")) {
        if (args.len < 1) return it.fail("stat: path expected", .{});
        const path = try pathArg(it, args[0]);
        const t = try fs.resolve(it, path);
        const st = fsc.fsStat(t.chan, t.buf, t.path) orelse return it.fail("stat: {s}: not found", .{path});
        return try statRecord(it, baseName(path), st);
    }
    if (is(name, "mkdir")) {
        if (args.len < 1) return it.fail("mkdir: path expected", .{});
        const path = try pathArg(it, args[0]);
        const t = try fs.resolve(it, path);
        if (!fsc.fsMkdir(t.chan, t.buf, t.path)) return it.fail("mkdir: {s}: failed", .{path});
        return .nothing;
    }
    if (is(name, "rm")) {
        if (args.len < 1) return it.fail("rm: path expected", .{});
        const path = try pathArg(it, args[0]);
        const t = try fs.resolve(it, path);
        return switch (fsc.fsDelete(t.chan, t.buf, t.path)) {
            .ok => .nothing,
            .err => |e| it.fail("rm: {s}: {t}", .{ path, e }),
        };
    }
    if (is(name, "mv")) {
        if (args.len < 2) return it.fail("mv: from and to expected", .{});
        const from = try fs.resolve(it, try pathArg(it, args[0]));
        const to = try fs.resolve(it, try pathArg(it, args[1]));
        if (from.chan != to.chan) return it.fail("mv: both paths must be in the same filesystem", .{});
        if (!fsc.fsRename(from.chan, from.buf, from.path, to.path)) return it.fail("mv: failed", .{});
        return .nothing;
    }
    if (is(name, "ln")) {
        if (args.len < 2) return it.fail("ln: path and target expected", .{});
        const t = try fs.resolve(it, try pathArg(it, args[0]));
        if (!fsc.fsSymlink(t.chan, t.buf, t.path, try pathArg(it, args[1]))) return it.fail("ln: failed", .{});
        return .nothing;
    }
    if (is(name, "readlink")) {
        if (args.len < 1) return it.fail("readlink: path expected", .{});
        const t = try fs.resolve(it, try pathArg(it, args[0]));
        const n = fsc.fsReadlink(t.chan, t.buf, t.path) orelse return it.fail("readlink: failed", .{});
        return .{ .str = try a.dupe(u8, t.buf[0..@min(n, 256)]) };
    }
    if (is(name, "sync")) {
        if (!fsc.fsSync(fs.root)) return it.fail("sync: failed", .{});
        return .nothing;
    }
    if (is(name, "df")) {
        const st = fsc.fsStatfs(fs.root) orelse return it.fail("df: failed", .{});
        return try record(it, &.{ "free_kb", "total_kb", "encrypted" }, &.{
            .{ .int = @intCast(st.free_blocks * 4) }, .{ .int = @intCast(st.total_blocks * 4) }, .{ .bool = st.encrypted },
        });
    }
    if (is(name, "source")) {
        if (args.len < 1) return it.fail("source: path expected", .{});
        const text = try readFile(fs, it, try pathArg(it, args[0]));
        _ = try it.evalScript(text, &it.out); // its output joins this line's
        return .nothing;
    }
    return null;
}


pub fn lsTable(fs: *const Fs, it: *mshl.Interp, path_arg: []const u8) mshl.Error!Value {
    const a = it.arena;
    const t = try fs.resolve(it, path_arg);
    const path = t.path;
    const count = fsc.fsList(t.chan, t.buf, path) orelse return it.fail("ls: {s}: cannot list", .{path_arg});
    const names = try a.dupe(u8, t.buf[0..count]);
    var rows: std.ArrayList([]const Value) = .empty;
    var split = std.mem.splitScalar(u8, names, '\n');
    while (split.next()) |name| {
        if (name.len == 0) continue;
        var full: [256]u8 = undefined;
        const fl = joinPath(&full, path, name);
        const st = fsc.fsStat(t.chan, t.buf, full[0..fl]) orelse continue;
        const row = try a.alloc(Value, 4);
        row[0] = .{ .str = name };
        row[1] = .{ .str = typeName(st.typ) };
        row[2] = .{ .int = @intCast(st.size) };
        row[3] = .{ .int = @intCast(st.mtime) };
        try rows.append(a, row);
    }
    return .{ .table = .{ .cols = &.{ "name", "type", "size", "mtime" }, .rows = rows.items } };
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

pub fn readFile(fs: *const Fs, it: *mshl.Interp, path: []const u8) mshl.Error![]const u8 {
    const t = try fs.resolve(it, path);
    return readFileVia(it, t.chan, t.buf, t.path);
}

pub fn readFileVia(it: *mshl.Interp, chan: u64, buf: [*]u8, path: []const u8) mshl.Error![]const u8 {
    const fd = switch (fsc.fsOpen(chan, buf, path, 0)) {
        .fd => |f| f,
        .err => |e| return it.fail("cannot open {s}: {t}", .{ path, e }),
    };
    defer fsc.fsClose(chan, fd);
    var out: std.ArrayList(u8) = .empty;
    var off: u64 = 0;
    while (true) {
        const n = fsc.fsReadAt(chan, fd, off, shared.fs_max_io) orelse return it.fail("read error on {s}", .{path});
        if (n == 0) break;
        try out.appendSlice(it.arena, buf[0..n]);
        off += n;
    }
    return out.items;
}

pub fn writeFile(fs: *const Fs, it: *mshl.Interp, path: []const u8, text: []const u8) mshl.Error!void {
    const t = try fs.resolve(it, path);
    return writeFileVia(it, t.chan, t.buf, t.path, text);
}

pub fn writeFileVia(it: *mshl.Interp, chan: u64, buf: [*]u8, path: []const u8, text: []const u8) mshl.Error!void {
    const fd = switch (fsc.fsOpen(chan, buf, path, 1)) {
        .fd => |f| f,
        .err => |e| return it.fail("cannot open {s}: {t}", .{ path, e }),
    };
    defer fsc.fsClose(chan, fd);
    var off: usize = 0;
    while (off < text.len) {
        const n = @min(shared.fs_max_io, text.len - off);
        if (!fsc.fsWriteAt(chan, buf, fd, off, text[off .. off + n])) return it.fail("write failed on {s}", .{path});
        off += n;
    }
    if (!fsc.fsTruncate(chan, fd, text.len)) return it.fail("truncate failed on {s}", .{path});
}

pub fn statRecord(it: *mshl.Interp, name: []const u8, st: fsc.StatOut) mshl.Error!Value {
    return record(it, &.{ "name", "type", "size", "mtime" }, &.{
        .{ .str = name }, .{ .str = typeName(st.typ) }, .{ .int = @intCast(st.size) }, .{ .int = @intCast(st.mtime) },
    });
}

pub fn typeName(typ: u64) []const u8 {
    return switch (typ) {
        @intFromEnum(shared.FsType.file) => "file",
        @intFromEnum(shared.FsType.dir) => "dir",
        @intFromEnum(shared.FsType.symlink) => "symlink",
        else => "?",
    };
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
