//! ucdgen: distill the Unicode Character Database (tools/testdata/ucd,
//! fetched by tools/fetch-ucd.sh) into lib/js/unicode.bin — the code
//! point tables the JavaScript engine reads: general categories,
//! scripts and script extensions, the binary properties ECMA-262
//! §22.2.2.9.7 names, ID_Start/ID_Continue, simple and full case
//! mappings and simple case folding. Every table is a sorted, merged
//! list of ranges; names include every alias PropertyValueAliases.txt
//! and PropertyAliases.txt give. `lib/js/unicode.zig` reads the blob.
//!
//! Blob layout (little endian): "UCD1", a u32 entry count, then the
//! directory of entries sorted by name — 32 bytes of name (NUL padded),
//! u32 offset from the blob's start, u32 count — then the tables: a
//! range table is count × (u32 lo, u32 hi); a pair table ("fold",
//! "upper", "lower") is count × (u32 from, u32 to); a full-mapping
//! table ("upper_full", "lower_full") is count × (u32 from, u32 n,
//! 3 × u32 to); a string table ("<property>/s": the sequences of a
//! property of strings, beside "<property>/r" for its single code
//! points) is count u32 words of (u32 n, n × u32 code point) records.
const std = @import("std");

var io: std.Io = undefined;

const Range = struct { lo: u32, hi: u32 };

const Table = struct {
    name: []const u8,
    kind: enum { ranges, pairs, full, strings },
    ranges: std.ArrayList(Range) = .empty,
    full: std.ArrayList([5]u32) = .empty,
    strings: std.ArrayList([]const u32) = .empty,
};

const Gen = struct {
    gpa: std.mem.Allocator,
    dir: []const u8,
    tables: std.StringArrayHashMapUnmanaged(*Table) = .empty,

    fn table(g: *Gen, name: []const u8, kind: @TypeOf(@as(Table, undefined).kind)) !*Table {
        if (g.tables.get(name)) |t| return t;
        const t = try g.gpa.create(Table);
        t.* = .{ .name = try g.gpa.dupe(u8, name), .kind = kind };
        try g.tables.put(g.gpa, t.name, t);
        return t;
    }

    fn add(g: *Gen, name: []const u8, lo: u32, hi: u32) !void {
        const t = try g.table(name, .ranges);
        try t.ranges.append(g.gpa, .{ .lo = lo, .hi = hi });
    }

    fn read(g: *Gen, sub: []const u8) ![]u8 {
        const path = try std.fmt.allocPrint(g.gpa, "{s}/{s}", .{ g.dir, sub });
        return std.Io.Dir.cwd().readFileAlloc(io, path, g.gpa, .limited(64 << 20));
    }

    /// The `XXXX` or `XXXX..YYYY` at the start of a field.
    fn parseRange(field: []const u8) ?Range {
        const f = std.mem.trim(u8, field, " \t");
        if (std.mem.indexOf(u8, f, "..")) |i| {
            const lo = std.fmt.parseInt(u32, f[0..i], 16) catch return null;
            const hi = std.fmt.parseInt(u32, f[i + 2 ..], 16) catch return null;
            return .{ .lo = lo, .hi = hi };
        }
        const v = std.fmt.parseInt(u32, f, 16) catch return null;
        return .{ .lo = v, .hi = v };
    }

    /// An emoji sequence file ("code points ; property ; ..."): a single
    /// code point or range joins the property's "/r" table, a sequence
    /// its "/s" table; RGI_Emoji unites them all (UTS #51).
    fn eachSequence(g: *Gen, sub: []const u8) !void {
        const text = try g.read(sub);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw;
            var it = std.mem.splitScalar(u8, line, ';');
            const cps_field = std.mem.trim(u8, it.next() orelse continue, " \t\r");
            const prop = std.mem.trim(u8, it.next() orelse continue, " \t\r");
            if (cps_field.len == 0 or prop.len == 0) continue;
            const targets = [_][]const u8{ prop, "RGI_Emoji" };
            if (parseRange(cps_field)) |r| {
                for (targets) |t| try g.add(try std.fmt.allocPrint(g.gpa, "{s}/r", .{t}), r.lo, r.hi);
                continue;
            }
            var cps: std.ArrayList(u32) = .empty;
            var words = std.mem.tokenizeAny(u8, cps_field, " \t");
            while (words.next()) |w| try cps.append(g.gpa, try std.fmt.parseInt(u32, w, 16));
            for (targets) |t| {
                const tab = try g.table(try std.fmt.allocPrint(g.gpa, "{s}/s", .{t}), .strings);
                try tab.strings.append(g.gpa, cps.items);
            }
        }
    }

    /// Lines of "range ; value [; ...] # comment" → callback(range, fields).
    fn eachLine(g: *Gen, sub: []const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), Range, []const []const u8) anyerror!void) !void {
        const text = try g.read(sub);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw;
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
            var fields: [8][]const u8 = undefined;
            var n: usize = 0;
            var it = std.mem.splitScalar(u8, line, ';');
            while (it.next()) |fld| : (n += 1) {
                if (n == fields.len) break;
                fields[n] = std.mem.trim(u8, fld, " \t\r");
            }
            if (n < 2) continue;
            const r = parseRange(fields[0]) orelse continue;
            try f(ctx, r, fields[1..n]);
        }
    }
};

fn addProp(g: *Gen, r: Range, fields: []const []const u8) !void {
    // Only the plain "range ; Property" lines; valued ones (InCB=...) are skipped.
    if (fields.len != 1) return;
    try g.add(fields[0], r.lo, r.hi);
}

fn addGc(g: *Gen, r: Range, fields: []const []const u8) !void {
    const name = try std.fmt.allocPrint(g.gpa, "gc={s}", .{fields[0]});
    try g.add(name, r.lo, r.hi);
}

fn addScript(g: *Gen, r: Range, fields: []const []const u8) !void {
    const name = try std.fmt.allocPrint(g.gpa, "sc={s}", .{fields[0]});
    try g.add(name, r.lo, r.hi);
}

const Scx = struct { g: *Gen, explicit: std.ArrayList(Range) = .empty };

fn addScx(s: *Scx, r: Range, fields: []const []const u8) !void {
    var it = std.mem.splitScalar(u8, fields[0], ' ');
    while (it.next()) |short| {
        if (short.len == 0) continue;
        const name = try std.fmt.allocPrint(s.g.gpa, "scx={s}", .{short});
        try s.g.add(name, r.lo, r.hi);
    }
    try s.explicit.append(s.g.gpa, r);
}

fn lessRange(_: void, a: Range, b: Range) bool {
    return a.lo < b.lo;
}

fn mergeInto(gpa: std.mem.Allocator, list: *std.ArrayList(Range)) !void {
    std.mem.sort(Range, list.items, {}, lessRange);
    var w: usize = 0;
    for (list.items) |r| {
        if (w > 0 and r.lo <= list.items[w - 1].hi + 1) {
            if (r.hi > list.items[w - 1].hi) list.items[w - 1].hi = r.hi;
        } else {
            list.items[w] = r;
            w += 1;
        }
    }
    list.shrinkRetainingCapacity(w);
    _ = gpa;
}

/// The properties of strings (§22.2.2.9.7, table 68): the emoji
/// sequence sets of UTS #51, and their union.
const string_props = [_][]const u8{ "Basic_Emoji", "Emoji_Keycap_Sequence", "RGI_Emoji_Modifier_Sequence", "RGI_Emoji_Flag_Sequence", "RGI_Emoji_Tag_Sequence", "RGI_Emoji_ZWJ_Sequence", "RGI_Emoji" };

/// The binary properties ECMA-262 lets `\p{}` name (table 67), by their
/// canonical names as the UCD files spell them.
const binary_props = [_][]const u8{
    "ASCII_Hex_Digit",         "Alphabetic",                   "Bidi_Control",            "Bidi_Mirrored",                "Case_Ignorable",          "Cased",
    "Changes_When_Casefolded", "Changes_When_Casemapped",      "Changes_When_Lowercased", "Changes_When_NFKC_Casefolded", "Changes_When_Titlecased", "Changes_When_Uppercased",
    "Dash",                    "Default_Ignorable_Code_Point", "Deprecated",              "Diacritic",                    "Emoji",                   "Emoji_Component",
    "Emoji_Modifier",          "Emoji_Modifier_Base",          "Emoji_Presentation",      "Extended_Pictographic",        "Extender",                "Grapheme_Base",
    "Grapheme_Extend",         "Hex_Digit",                    "IDS_Binary_Operator",     "IDS_Trinary_Operator",         "IDS_Unary_Operator",      "ID_Continue",
    "ID_Start",                "Ideographic",                  "Join_Control",            "Logical_Order_Exception",      "Lowercase",               "Math",
    "Noncharacter_Code_Point", "Pattern_Syntax",               "Pattern_White_Space",     "Quotation_Mark",               "Radical",                 "Regional_Indicator",
    "Sentence_Terminal",       "Soft_Dotted",                  "Terminal_Punctuation",    "Unified_Ideograph",            "Uppercase",               "Variation_Selector",
    "White_Space",             "XID_Continue",                 "XID_Start",
};

pub fn main(init: std.process.Init) !u8 {
    io = init.io;
    const gpa = init.gpa;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const dir = args.next() orelse "tools/testdata/ucd";
    const out_path = args.next() orelse "lib/js/unicode.bin";
    var g = Gen{ .gpa = gpa, .dir = dir };

    // General categories, scripts, script extensions.
    try g.eachLine("extracted/DerivedGeneralCategory.txt", &g, addGc);
    try g.eachLine("Scripts.txt", &g, addScript);
    var scx = Scx{ .g = &g };
    try g.eachLine("ScriptExtensions.txt", &scx, addScx);
    // Script_Extensions defaults to Script where no explicit set exists.
    try mergeInto(gpa, &scx.explicit);
    // (A snapshot: adding scx tables while walking the map would move it.)
    var sc_tables: std.ArrayList(*Table) = .empty;
    for (g.tables.values()) |t| if (std.mem.startsWith(u8, t.name, "sc=")) try sc_tables.append(gpa, t);
    for (sc_tables.items) |t| {
        const scx_name = try std.fmt.allocPrint(gpa, "scx={s}", .{t.name[3..]});
        for (t.ranges.items) |r| {
            // Add the parts of r not covered by an explicit scx entry.
            var lo = r.lo;
            for (scx.explicit.items) |e| {
                if (e.hi < lo) continue;
                if (e.lo > r.hi) break;
                if (e.lo > lo) try g.add(scx_name, lo, e.lo - 1);
                lo = @max(lo, e.hi + 1);
                if (lo > r.hi) break;
            }
            if (lo <= r.hi) try g.add(scx_name, lo, r.hi);
        }
    }
    // Script=Unknown (Zzzz): every code point no script claims — the
    // complement of the scripts' union (Scripts.txt lists none of them);
    // Script_Extensions=Unknown is the same set.
    {
        var all: std.ArrayList(Range) = .empty;
        for (sc_tables.items) |t| try all.appendSlice(gpa, t.ranges.items);
        try mergeInto(gpa, &all);
        var lo: u32 = 0;
        for (all.items) |r| {
            if (r.lo > lo) {
                try g.add("sc=Unknown", lo, r.lo - 1);
                try g.add("scx=Unknown", lo, r.lo - 1);
            }
            lo = r.hi + 1;
        }
        if (lo <= 0x10FFFF) {
            try g.add("sc=Unknown", lo, 0x10FFFF);
            try g.add("scx=Unknown", lo, 0x10FFFF);
        }
    }
    // Binary properties.
    try g.eachLine("PropList.txt", &g, addProp);
    try g.eachLine("DerivedCoreProperties.txt", &g, addProp);
    try g.eachLine("emoji/emoji-data.txt", &g, addProp);
    try g.eachLine("extracted/DerivedBinaryProperties.txt", &g, addProp);
    try g.eachLine("DerivedNormalizationProps.txt", &g, addProp);
    // Properties of strings (`\p{RGI_Emoji}` and the six it unites, v
    // mode): both tables of each exist even when empty, so the engine
    // can tell a property of strings from an unknown name.
    for (string_props) |sp| {
        _ = try g.table(try std.fmt.allocPrint(gpa, "{s}/r", .{sp}), .ranges);
        _ = try g.table(try std.fmt.allocPrint(gpa, "{s}/s", .{sp}), .strings);
    }
    try g.eachSequence("emoji/emoji-sequences.txt");
    try g.eachSequence("emoji/emoji-zwj-sequences.txt");
    // Case mappings (UnicodeData fields 12/13), folding, full mappings.
    {
        const upper = try g.table("upper", .pairs);
        const lower = try g.table("lower", .pairs);
        const text = try g.read("UnicodeData.txt");
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var fields: [16][]const u8 = undefined;
            var n: usize = 0;
            var it = std.mem.splitScalar(u8, line, ';');
            while (it.next()) |f| : (n += 1) {
                if (n == fields.len) break;
                fields[n] = f;
            }
            if (n < 14) continue;
            const cp = std.fmt.parseInt(u32, fields[0], 16) catch continue;
            if (fields[12].len > 0) try upper.ranges.append(gpa, .{ .lo = cp, .hi = std.fmt.parseInt(u32, fields[12], 16) catch continue });
            if (fields[13].len > 0) try lower.ranges.append(gpa, .{ .lo = cp, .hi = std.fmt.parseInt(u32, fields[13], 16) catch continue });
        }
        const fold = try g.table("fold", .pairs);
        const ftext = try g.read("CaseFolding.txt");
        var flines = std.mem.splitScalar(u8, ftext, '\n');
        while (flines.next()) |raw| {
            const line = if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw;
            var fields: [4][]const u8 = undefined;
            var n: usize = 0;
            var it = std.mem.splitScalar(u8, line, ';');
            while (it.next()) |f| : (n += 1) {
                if (n == fields.len) break;
                fields[n] = std.mem.trim(u8, f, " \t\r");
            }
            if (n < 3) continue;
            if (!std.mem.eql(u8, fields[1], "C") and !std.mem.eql(u8, fields[1], "S")) continue;
            const cp = std.fmt.parseInt(u32, fields[0], 16) catch continue;
            const to = std.fmt.parseInt(u32, fields[2], 16) catch continue;
            try fold.ranges.append(gpa, .{ .lo = cp, .hi = to });
        }
        const upper_full = try g.table("upper_full", .full);
        const lower_full = try g.table("lower_full", .full);
        const stext = try g.read("SpecialCasing.txt");
        var slines = std.mem.splitScalar(u8, stext, '\n');
        while (slines.next()) |raw| {
            const line = if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw;
            var fields: [6][]const u8 = undefined;
            var n: usize = 0;
            var it = std.mem.splitScalar(u8, line, ';');
            while (it.next()) |f| : (n += 1) {
                if (n == fields.len) break;
                fields[n] = std.mem.trim(u8, f, " \t\r");
            }
            if (n < 4) continue;
            // A fifth non-empty field is a condition: language- or
            // context-sensitive, handled in code (final sigma) or skipped.
            if (n >= 5 and fields[4].len > 0) continue;
            const cp = std.fmt.parseInt(u32, fields[0], 16) catch continue;
            inline for (.{ .{ 1, lower_full }, .{ 3, upper_full } }) |e| {
                var entry: [5]u32 = .{ cp, 0, 0, 0, 0 };
                var parts = std.mem.splitScalar(u8, fields[e[0]], ' ');
                while (parts.next()) |ps| {
                    if (ps.len == 0) continue;
                    if (entry[1] >= 3) break;
                    entry[2 + entry[1]] = std.fmt.parseInt(u32, ps, 16) catch continue;
                    entry[1] += 1;
                }
                try e[1].full.append(gpa, entry);
            }
        }
    }
    // Aliases: gc and sc values (short and long), grouped categories, and
    // property aliases for the binary set.
    {
        const text = try g.read("PropertyValueAliases.txt");
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw;
            var fields: [8][]const u8 = undefined;
            var n: usize = 0;
            var it = std.mem.splitScalar(u8, line, ';');
            while (it.next()) |f| : (n += 1) {
                if (n == fields.len) break;
                fields[n] = std.mem.trim(u8, f, " \t\r");
            }
            if (n < 3) continue;
            const prop = fields[0];
            if (!std.mem.eql(u8, prop, "gc") and !std.mem.eql(u8, prop, "sc")) continue;
            const short = fields[1];
            // Grouped categories (L, LC, M, N, P, S, Z, C): unions.
            if (std.mem.eql(u8, prop, "gc")) {
                const key = try std.fmt.allocPrint(gpa, "gc={s}", .{short});
                if (g.tables.get(key) == null) {
                    var members: std.ArrayList(*Table) = .empty;
                    for (g.tables.values()) |other| if (std.mem.startsWith(u8, other.name, "gc=")) try members.append(gpa, other);
                    const nt = try g.table(key, .ranges);
                    for (members.items) |other| {
                        const v = other.name[3..];
                        const member = if (std.mem.eql(u8, short, "LC")) (std.mem.eql(u8, v, "Ll") or std.mem.eql(u8, v, "Lt") or std.mem.eql(u8, v, "Lu")) else (v.len == 2 and v[0] == short[0] and short.len == 1);
                        if (member) try nt.ranges.appendSlice(gpa, other.ranges.items);
                    }
                }
            }
            // Every alias names the same table; the UCD files spell a
            // script by its long name in Scripts.txt and its short name in
            // ScriptExtensions.txt, so tables found under any alias merge.
            const prefixes: []const []const u8 = if (std.mem.eql(u8, prop, "sc")) &.{ "sc=", "scx=" } else &.{"gc="};
            for (prefixes) |prefix| {
                var target: ?*Table = null;
                var i: usize = 1;
                while (i < n) : (i += 1) {
                    if (fields[i].len == 0) continue;
                    const key = try std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, fields[i] });
                    if (g.tables.get(key)) |t| {
                        if (target) |tg| {
                            if (t != tg) try tg.ranges.appendSlice(gpa, t.ranges.items);
                        } else target = t;
                    }
                }
                const tg = target orelse continue;
                i = 1;
                while (i < n) : (i += 1) {
                    if (fields[i].len == 0) continue;
                    const key = try std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, fields[i] });
                    try g.tables.put(gpa, key, tg);
                }
            }
        }
        const ptext = try g.read("PropertyAliases.txt");
        var plines = std.mem.splitScalar(u8, ptext, '\n');
        while (plines.next()) |raw| {
            const line = if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw;
            var fields: [8][]const u8 = undefined;
            var n: usize = 0;
            var it = std.mem.splitScalar(u8, line, ';');
            while (it.next()) |f| : (n += 1) {
                if (n == fields.len) break;
                fields[n] = std.mem.trim(u8, f, " \t\r");
            }
            if (n < 2) continue;
            const long = fields[1];
            var known = false;
            for (binary_props) |bp| if (std.mem.eql(u8, bp, long)) {
                known = true;
            };
            if (!known) continue;
            const t = g.tables.get(long) orelse continue;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (i == 1 or fields[i].len == 0) continue;
                if (g.tables.get(fields[i]) == null) try g.tables.put(gpa, try gpa.dupe(u8, fields[i]), t);
            }
        }
    }
    // Any, ASCII, Assigned.
    try g.add("Any", 0, 0x10FFFF);
    try g.add("ASCII", 0, 0x7F);
    {
        const cn = g.tables.get("gc=Cn").?;
        try mergeInto(gpa, &cn.ranges);
        var lo: u32 = 0;
        for (cn.ranges.items) |r| {
            if (r.lo > lo) try g.add("Assigned", lo, r.lo - 1);
            lo = r.hi + 1;
        }
        if (lo <= 0x10FFFF) try g.add("Assigned", lo, 0x10FFFF);
    }
    // Only the tables the engine may name go into the blob: gc, sc, scx,
    // the binary set, and the case tables.
    var names: std.ArrayList([]const u8) = .empty;
    var it = g.tables.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const t = e.value_ptr.*;
        var keep = std.mem.startsWith(u8, name, "gc=") or std.mem.startsWith(u8, name, "sc=") or std.mem.startsWith(u8, name, "scx=") or t.kind != .ranges or std.mem.eql(u8, name, "Any") or std.mem.eql(u8, name, "ASCII") or std.mem.eql(u8, name, "Assigned") or std.mem.endsWith(u8, name, "/r");
        if (!keep) {
            for (binary_props) |bp| if (std.mem.eql(u8, bp, t.name)) {
                keep = true;
            };
        }
        if (keep) try names.append(gpa, name);
    }
    for (g.tables.values()) |t| switch (t.kind) {
        .ranges => try mergeInto(gpa, &t.ranges),
        // Pair and full-mapping tables are binary-searched by their first
        // code point: sorted, SpecialCasing.txt being grouped by topic.
        .pairs => std.mem.sort(Range, t.ranges.items, {}, lessRange),
        .full => std.mem.sort([5]u32, t.full.items, {}, struct {
            fn less(_: void, a: [5]u32, b: [5]u32) bool {
                return a[0] < b[0];
            }
        }.less),
        .strings => {},
    };
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    // Assemble the blob: tables are emitted once, shared by aliases.
    var blob: std.ArrayList(u8) = .empty;
    try blob.appendSlice(gpa, "UCD1");
    try blob.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, @intCast(names.items.len))));
    const dir_start = blob.items.len;
    try blob.appendNTimes(gpa, 0, names.items.len * 40);
    var offsets: std.AutoHashMapUnmanaged(*Table, u32) = .empty;
    for (names.items, 0..) |name, i| {
        const t = g.tables.get(name).?;
        if (!offsets.contains(t)) {
            try offsets.put(gpa, t, @intCast(blob.items.len));
            switch (t.kind) {
                .ranges, .pairs => for (t.ranges.items) |r| {
                    try blob.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, r.lo)));
                    try blob.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, r.hi)));
                },
                .full => for (t.full.items) |e| for (e) |v| try blob.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, v))),
                .strings => for (t.strings.items) |s| {
                    try blob.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, @intCast(s.len))));
                    for (s) |cp| try blob.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, cp)));
                },
            }
        }
        const entry = blob.items[dir_start + i * 40 ..][0..40];
        @memset(entry, 0);
        if (name.len > 32) return error.NameTooLong;
        @memcpy(entry[0..name.len], name);
        const count: u32 = switch (t.kind) {
            .full => @intCast(t.full.items.len),
            .strings => blk: {
                var words: u32 = 0;
                for (t.strings.items) |s| words += 1 + @as(u32, @intCast(s.len));
                break :blk words;
            },
            else => @intCast(t.ranges.items.len),
        };
        std.mem.writeInt(u32, entry[32..36], offsets.get(t).?, .little);
        std.mem.writeInt(u32, entry[36..40], count, .little);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = blob.items });
    std.debug.print("ucdgen: {d} names, {d} bytes → {s}\n", .{ names.items.len, blob.items.len, out_path });
    return 0;
}
