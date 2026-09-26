//! Strings as the specification has them: sequences of UTF-16 code
//! units. Most text is Latin-1, so a string whose units all fit a byte
//! is stored one byte each and widened on the way out; concatenation
//! makes a rope (two children, no copy) flattened the first time its
//! units are read; property keys are atoms — interned by content, so
//! two keys are the same key when they are the same pointer. A string's
//! hash is computed once and kept.
const std = @import("std");
const heap = @import("heap.zig");
const Cell = heap.Cell;
const Heap = heap.Heap;

pub const Error = error{OutOfMemory};

pub const String = extern struct {
    header: Cell,
    /// Code units.
    len: u32,
    hash_: u32 = 0,
    form: Form,
    /// An atom (interned): identity is content.
    atom: bool = false,
    _pad: [6]u8 = @splat(0),
    /// `.latin1`/`.utf16`: a pointer to the units, which follow the
    /// struct in the same cell; `.rope`: the two halves.
    data: extern union {
        flat: [*]u8,
        rope: extern struct { left: *String, right: *String },
    },

    pub const Form = enum(u8) { latin1, utf16, rope };

    pub fn cell(s: *String) *Cell {
        return &s.header;
    }

    /// The units, flattening a rope in place (the rope cell is rewritten
    /// as a flat string when it fits its class, else a fresh cell is
    /// linked from it).
    pub fn latin1(s: *String) ?[]const u8 {
        if (s.form != .latin1) return null;
        return s.data.flat[0..s.len];
    }

    pub fn utf16(s: *String) ?[]const u16 {
        if (s.form != .utf16) return null;
        const p: [*]const u16 = @ptrCast(@alignCast(s.data.flat));
        return p[0..s.len];
    }

    pub fn isFlat(s: *const String) bool {
        return s.form != .rope;
    }

    /// The code unit at `i` of a flat string.
    pub fn unitAt(s: *String, i: usize) u16 {
        return switch (s.form) {
            .latin1 => s.data.flat[i],
            .utf16 => @as([*]const u16, @ptrCast(@alignCast(s.data.flat)))[i],
            .rope => unreachable,
        };
    }

    pub fn hash(s: *String) u32 {
        if (s.hash_ != 0) return s.hash_;
        var h: u32 = 2166136261;
        for (0..s.len) |i| {
            const u = s.unitAt(i);
            h = (h ^ (u & 0xff)) *% 16777619;
            h = (h ^ (u >> 8)) *% 16777619;
        }
        if (h == 0) h = 1;
        s.hash_ = h;
        return h;
    }

    /// Same code units.
    pub fn eql(a: *String, b: *String) bool {
        if (a == b) return true;
        if (a.len != b.len) return false;
        if (a.atom and b.atom) return false; // atoms with the same content are one cell
        if (a.form == .latin1 and b.form == .latin1) return std.mem.eql(u8, a.latin1().?, b.latin1().?);
        for (0..a.len) |i| if (a.unitAt(i) != b.unitAt(i)) return false;
        return true;
    }

    pub fn eqlLatin1(a: *String, text: []const u8) bool {
        if (a.len != text.len) return false;
        for (text, 0..) |c, i| if (a.unitAt(i) != c) return false;
        return true;
    }

    /// Whether every unit fits Latin-1.
    fn narrow(units: []const u16) bool {
        for (units) |u| if (u > 0xff) return false;
        return true;
    }
};

/// The string table: allocation, ropes and atoms over a heap.
pub const Strings = struct {
    heap: *Heap,
    atoms: std.HashMapUnmanaged(*String, void, AtomContext, 80) = .empty,
    meta: std.mem.Allocator,
    /// The empty string, made once and kept alive by `markRoots`.
    empty_atom: ?*String = null,

    pub const AtomContext = struct {
        pub fn hash(_: AtomContext, s: *String) u64 {
            return s.hash();
        }
        pub fn eql(_: AtomContext, a: *String, b: *String) bool {
            if (a.len != b.len) return false;
            for (0..a.len) |i| if (a.unitAt(i) != b.unitAt(i)) return false;
            return true;
        }
    };

    pub fn init(h: *Heap, meta: std.mem.Allocator) Strings {
        return .{ .heap = h, .meta = meta };
    }

    pub fn deinit(t: *Strings) void {
        t.atoms.deinit(t.meta);
    }

    /// What the table itself keeps alive (the realm's root calls it).
    pub fn markRoots(t: *Strings, m: *heap.Marker) void {
        if (t.empty_atom) |e| m.markCell(e.cell());
    }

    /// Atoms are weak: the sweep drops the ones nobody marked. Called
    /// from the heap's finalizer for string cells.
    pub fn forget(t: *Strings, s: *String) void {
        if (s.atom) _ = t.atoms.remove(s);
    }

    fn allocFlat(t: *Strings, len: usize, wide: bool) Error!*String {
        const bytes = if (wide) len * 2 else len;
        // The units follow the header, 16-byte aligned for the wide case.
        const c = try t.heap.alloc(.string, @sizeOf(String) + bytes + 8);
        const s = c.as(String);
        s.len = @intCast(len);
        s.form = if (wide) .utf16 else .latin1;
        const base: [*]u8 = @ptrCast(s);
        const off = (@sizeOf(String) + 7) & ~@as(usize, 7);
        s.data.flat = base + off;
        return s;
    }

    /// A string from UTF-8 (WTF-8 for lone surrogates), the narrow form
    /// when it fits.
    pub fn fromUtf8(t: *Strings, text: []const u8) Error!*String {
        // Count units and whether any exceeds Latin-1.
        var units: usize = 0;
        var wide = false;
        var i: usize = 0;
        while (i < text.len) {
            const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            const cp: u21 = if (i + n <= text.len) (std.unicode.wtf8Decode(text[i .. i + n]) catch 0xfffd) else 0xfffd;
            i += n;
            if (cp > 0xff) wide = true;
            units += if (cp > 0xffff) 2 else 1;
        }
        const s = try t.allocFlat(units, wide);
        var k: usize = 0;
        i = 0;
        while (i < text.len) {
            const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            const cp: u21 = if (i + n <= text.len) (std.unicode.wtf8Decode(text[i .. i + n]) catch 0xfffd) else 0xfffd;
            i += n;
            if (wide) {
                const out: [*]u16 = @ptrCast(@alignCast(s.data.flat));
                if (cp > 0xffff) {
                    const v = cp - 0x10000;
                    out[k] = @intCast(0xd800 + (v >> 10));
                    out[k + 1] = @intCast(0xdc00 + (v & 0x3ff));
                    k += 2;
                } else {
                    out[k] = @intCast(cp);
                    k += 1;
                }
            } else {
                s.data.flat[k] = @intCast(cp);
                k += 1;
            }
        }
        return s;
    }

    /// A narrow string from Latin-1 bytes.
    pub fn fromLatin1(t: *Strings, bytes: []const u8) Error!*String {
        const s = try t.allocFlat(bytes.len, false);
        @memcpy(s.data.flat[0..bytes.len], bytes);
        return s;
    }

    pub fn fromUnits(t: *Strings, units: []const u16) Error!*String {
        const wide = !String.narrow(units);
        const s = try t.allocFlat(units.len, wide);
        if (wide) {
            const out: [*]u16 = @ptrCast(@alignCast(s.data.flat));
            @memcpy(out[0..units.len], units);
        } else for (units, 0..) |u, i| s.data.flat[i] = @intCast(u);
        return s;
    }

    /// The interned string for `text`: the same cell every time.
    pub fn atom(t: *Strings, text: []const u8) Error!*String {
        // A probe string on the stack would need the hash context to see
        // it as a String; build the real one and intern it (a hit frees
        // the fresh cell at the next sweep).
        const s = try t.fromUtf8(text);
        return t.intern(s);
    }

    pub fn intern(t: *Strings, s: *String) Error!*String {
        if (s.atom) return s;
        const mark = t.heap.tempMark();
        defer t.heap.tempRelease(mark);
        t.heap.tempPush(s.cell());
        const flat = try t.flatten(s);
        const g = try t.atoms.getOrPut(t.meta, flat);
        if (g.found_existing) return g.key_ptr.*;
        flat.atom = true;
        return flat;
    }

    /// `a + b`: a rope, unless the result is short enough that copying
    /// is cheaper than a node.
    pub fn concat(t: *Strings, a: *String, b: *String) Error!*String {
        if (a.len == 0) return b;
        if (b.len == 0) return a;
        const total = @as(usize, a.len) + b.len;
        if (total <= 32) {
            const mark = t.heap.tempMark();
            defer t.heap.tempRelease(mark);
            const fa = try t.flatten(a);
            t.heap.tempPush(fa.cell());
            const fb = try t.flatten(b);
            t.heap.tempPush(fb.cell());
            const wide = fa.form == .utf16 or fb.form == .utf16;
            const s = try t.allocFlat(total, wide);
            for (0..fa.len) |i| t.put(s, i, fa.unitAt(i));
            for (0..fb.len) |i| t.put(s, fa.len + i, fb.unitAt(i));
            return s;
        }
        const c = try t.heap.alloc(.string, @sizeOf(String));
        const s = c.as(String);
        s.len = @intCast(total);
        s.form = .rope;
        s.data.rope = .{ .left = a, .right = b };
        return s;
    }

    fn put(_: *Strings, s: *String, i: usize, u: u16) void {
        switch (s.form) {
            .latin1 => s.data.flat[i] = @intCast(u),
            .utf16 => @as([*]u16, @ptrCast(@alignCast(s.data.flat)))[i] = u,
            .rope => unreachable,
        }
    }

    /// A flat string with the rope's units; the rope itself is left
    /// pointing at it (as its left child, length-preserving) so a
    /// second flatten is a lookup.
    pub fn flatten(t: *Strings, s: *String) Error!*String {
        if (s.form != .rope) return s;
        if (s.data.rope.right.len == 0) return t.flatten(s.data.rope.left);
        // Walk the rope iteratively: leaves left to right.
        var wide = false;
        var stack: std.ArrayList(*String) = .empty;
        defer stack.deinit(t.meta);
        try stack.append(t.meta, s);
        while (stack.pop()) |n| {
            if (n.form == .rope) {
                try stack.append(t.meta, n.data.rope.right);
                try stack.append(t.meta, n.data.rope.left);
            } else if (n.form == .utf16) wide = true;
        }
        const flat = try t.allocFlat(s.len, wide);
        var k: usize = 0;
        try stack.append(t.meta, s);
        while (stack.pop()) |n| {
            if (n.form == .rope) {
                try stack.append(t.meta, n.data.rope.right);
                try stack.append(t.meta, n.data.rope.left);
            } else {
                for (0..n.len) |i| t.put(flat, k + i, n.unitAt(i));
                k += n.len;
            }
        }
        // Memoize: the rope becomes (flat, "") — flat reachable from the
        // rope before anything else can allocate.
        s.data.rope = .{ .left = flat, .right = flat };
        s.data.rope.right = try t.empty();
        return flat;
    }

    pub fn empty(t: *Strings) Error!*String {
        if (t.empty_atom) |e| return e;
        const e = try t.atom("");
        t.empty_atom = e;
        return e;
    }

    /// UTF-8 of a string (lone surrogates as WTF-8), into `a`.
    pub fn toUtf8(t: *Strings, a: std.mem.Allocator, s_in: *String) Error![]u8 {
        const s = try t.flatten(s_in);
        // Sized first, filled second: one allocation of the exact length,
        // so a caller's fixed buffer holds what fits in it (a growing list
        // asked for twice the text and fell back to the heap, and leaked).
        var total: usize = 0;
        var pass: u8 = 0;
        var out: []u8 = &.{};
        while (pass < 2) : (pass += 1) {
            if (pass == 1) out = try a.alloc(u8, total);
            var at: usize = 0;
            var i: usize = 0;
            while (i < s.len) : (i += 1) {
                var cp: u21 = s.unitAt(i);
                if (cp >= 0xd800 and cp <= 0xdbff and i + 1 < s.len) {
                    const lo = s.unitAt(i + 1);
                    if (lo >= 0xdc00 and lo <= 0xdfff) {
                        cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                        i += 1;
                    }
                }
                var buf: [4]u8 = undefined;
                const n = std.unicode.wtf8Encode(cp, &buf) catch continue;
                if (pass == 1) @memcpy(out[at .. at + n], buf[0..n]);
                at += n;
            }
            total = at;
        }
        return out;
    }

    /// Trace a string's references (a rope's children).
    pub fn trace(s: *String, m: *heap.Marker) void {
        if (s.form == .rope) {
            m.markCell(s.data.rope.left.cell());
            m.markCell(s.data.rope.right.cell());
        }
    }
};

// ------------------------------------------------------------- tests

fn traceTest(_: *Heap, c: *Cell, m: *heap.Marker) void {
    if (c.kind == .string) Strings.trace(c.as(String), m);
}

test "string: narrow and wide forms, ropes, atoms and hashing" {
    const region = try std.testing.allocator.alloc(u8, 256 << 10);
    defer std.testing.allocator.free(region);
    var h = Heap.init(region, std.testing.allocator, traceTest);
    defer h.deinit();
    var t = Strings.init(&h, std.testing.allocator);
    defer t.deinit();
    const a = try t.fromUtf8("hello");
    try std.testing.expectEqual(String.Form.latin1, a.form);
    try std.testing.expectEqualStrings("hello", a.latin1().?);
    const w = try t.fromUtf8("héllo — 😀");
    try std.testing.expectEqual(String.Form.utf16, w.form);
    try std.testing.expectEqual(@as(u32, 10), w.len); // the emoji is a pair
    try std.testing.expectEqual(@as(u16, 0xd83d), w.unitAt(8));
    const back = try t.toUtf8(std.testing.allocator, w);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings("héllo — 😀", back);
    // Ropes: long enough to stay a rope, flattened on read.
    const long = try t.fromUtf8("0123456789012345678901234567890123456789");
    const r = try t.concat(long, w);
    try std.testing.expectEqual(String.Form.rope, r.form);
    try std.testing.expectEqual(@as(u32, 50), r.len);
    const f = try t.flatten(r);
    try std.testing.expectEqual(@as(u16, 'é'), f.unitAt(41));
    try std.testing.expect(f.eql(try t.flatten(r)));
    // Atoms: one cell per content.
    const k1 = try t.atom("key");
    const k2 = try t.atom("key");
    try std.testing.expectEqual(k1, k2);
    const k3 = try t.intern(try t.concat(try t.fromUtf8("ke"), try t.fromUtf8("y")));
    try std.testing.expectEqual(k1, k3);
    try std.testing.expect(k1.hash() == (try t.fromUtf8("key")).hash());
    try std.testing.expect(a.eqlLatin1("hello") and !a.eqlLatin1("hell"));
}
