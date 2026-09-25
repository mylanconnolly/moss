//! The test262 runner (`zig build test262 -- [test/language/...]`): every
//! `.js` under the given directories of tools/testdata/test262 (fetched
//! at its pinned commit by tools/fetch-test262.sh), judged by its front
//! matter. Today the engine parses: a file counts as passed when it
//! parses (as a script, and as a module when flagged) — or, for a
//! `negative: phase: parse` file, when it is refused. Counts print per
//! top-level directory under `test/`, the numbers DESIGN.md records.
//! Files needing features the front matter lists as beyond the stage
//! are counted, not hidden: the number is the number.
const std = @import("std");
const mosslib = @import("mosslib");
const js = mosslib.js;

var io: std.Io = undefined;

const Meta = struct {
    negative_parse: bool = false,
    negative_any: bool = false,
    module: bool = false,
    raw: bool = false,
    only_strict: bool = false,
    no_strict: bool = false,
};

/// The YAML front matter between `/*---` and `---*/`, read for the few
/// keys the runner needs.
fn readMeta(src: []const u8) Meta {
    var m: Meta = .{};
    const start = std.mem.indexOf(u8, src, "/*---") orelse return m;
    const end = std.mem.indexOfPos(u8, src, start, "---*/") orelse return m;
    const fm = src[start..end];
    if (std.mem.indexOf(u8, fm, "negative:")) |neg| {
        m.negative_any = true;
        const rest = fm[neg..];
        if (std.mem.indexOf(u8, rest, "phase: parse") != null) m.negative_parse = true;
    }
    if (std.mem.indexOf(u8, fm, "flags:")) |fl| {
        const line_end = std.mem.indexOfScalarPos(u8, fm, fl, '\n') orelse fm.len;
        const line = fm[fl..line_end];
        if (std.mem.indexOf(u8, line, "module") != null) m.module = true;
        if (std.mem.indexOf(u8, line, "raw") != null) m.raw = true;
        if (std.mem.indexOf(u8, line, "onlyStrict") != null) m.only_strict = true;
        if (std.mem.indexOf(u8, line, "noStrict") != null) m.no_strict = true;
    }
    return m;
}

const Tally = struct { pass: usize = 0, fail: usize = 0 };

pub fn main(init: std.process.Init) !u8 {
    io = init.io;
    const gpa = init.gpa;
    const cwd = std.Io.Dir.cwd();
    var args: std.ArrayList([]const u8) = .empty;
    var ait = std.process.Args.Iterator.init(init.minimal.args);
    while (ait.next()) |a| try args.append(gpa, try gpa.dupe(u8, a));
    const root = "tools/testdata/test262";
    var dirs: std.ArrayList([]const u8) = .empty;
    if (args.items.len > 1) {
        for (args.items[1..]) |a| try dirs.append(gpa, a);
    } else {
        try dirs.append(gpa, "test/language");
    }
    const verbose = std.c.getenv("TEST262_VERBOSE") != null;
    var by_dir: std.StringArrayHashMapUnmanaged(Tally) = .empty;
    var total: Tally = .{};
    for (dirs.items) |sub| {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, sub });
        var dir = cwd.openDir(io, path, .{ .iterate = true }) catch {
            std.debug.print("test262: cannot open {s} — run tools/fetch-test262.sh\n", .{path});
            return 1;
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".js")) continue;
            if (std.mem.endsWith(u8, entry.path, "_FIXTURE.js")) continue;
            const src = dir.readFileAlloc(io, entry.path, gpa, .limited(8 << 20)) catch continue;
            const meta = readMeta(src);
            // The tally's key: the first path component under the given
            // directory (`expressions`, `statements`, ...).
            const slash = std.mem.indexOfScalar(u8, entry.path, '/') orelse entry.path.len;
            const key = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ sub, entry.path[0..slash] });
            const g = try by_dir.getOrPut(gpa, key);
            if (!g.found_existing) g.value_ptr.* = .{};
            const ok = judge(gpa, src, meta);
            if (ok) {
                g.value_ptr.pass += 1;
                total.pass += 1;
            } else {
                g.value_ptr.fail += 1;
                total.fail += 1;
                if (verbose) {
                    var arena = std.heap.ArenaAllocator.init(gpa);
                    defer arena.deinit();
                    var p = js.parser.Parser.init(arena.allocator(), src, .{ .module = meta.module, .strict = meta.only_strict });
                    const why: []const u8 = if (p.parseProgram()) |_| "parsed" else |_| p.err;
                    std.debug.print("  FAIL {s}/{s}: {s}\n", .{ sub, entry.path, why });
                }
            }
            gpa.free(src);
        }
    }
    var it = by_dir.iterator();
    while (it.next()) |e| std.debug.print("test262: {s}: {d}/{d}\n", .{ e.key_ptr.*, e.value_ptr.pass, e.value_ptr.pass + e.value_ptr.fail });
    std.debug.print("test262: total {d}/{d} parse as their front matter says\n", .{ total.pass, total.pass + total.fail });
    return 0;
}

/// One file against the parser: a negative-parse test passes when the
/// parser refuses it; any other passes when the parser accepts it.
/// `onlyStrict` files are parsed as strict code; a file with neither
/// flag parses both ways (sloppy and strict), as the harness runs it.
fn judge(gpa: std.mem.Allocator, src: []const u8, meta: Meta) bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (meta.module) {
        const ok = if (js.parser.parse(a, src, .{ .module = true })) |_| true else |_| false;
        return if (meta.negative_parse) !ok else ok;
    }
    if (meta.negative_parse) {
        // Refused in every mode it would run in.
        if (!meta.only_strict) if (js.parser.parse(a, src, .{})) |_| return false else |_| {};
        if (!meta.no_strict and !meta.raw) if (js.parser.parse(a, src, .{ .strict = true })) |_| return false else |_| {};
        return true;
    }
    if (!meta.only_strict) if (js.parser.parse(a, src, .{})) |_| {} else |_| return false;
    if (!meta.no_strict and !meta.raw) if (js.parser.parse(a, src, .{ .strict = true })) |_| {} else |_| return false;
    return true;
}
