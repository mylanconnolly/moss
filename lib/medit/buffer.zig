//! Adapted from medit; see README.md for provenance and Moss changes.
const std = @import("std");
const uwidth = @import("uwidth.zig");

pub const Pos = struct {
    line: usize,
    /// Byte offset within the line.
    col: usize,

    pub fn eql(a: Pos, b: Pos) bool {
        return a.line == b.line and a.col == b.col;
    }

    pub fn lessThan(a: Pos, b: Pos) bool {
        if (a.line != b.line) return a.line < b.line;
        return a.col < b.col;
    }
};

pub const Range = struct {
    start: Pos,
    end: Pos,

    pub fn normalized(r: Range) Range {
        if (r.end.lessThan(r.start)) return .{ .start = r.end, .end = r.start };
        return r;
    }

    pub fn isEmpty(r: Range) bool {
        return r.start.eql(r.end);
    }
};

const Line = std.ArrayList(u8);

pub const Buffer = struct {
    gpa: std.mem.Allocator,
    lines: std.ArrayList(Line),
    pub fn init(gpa: std.mem.Allocator) !Buffer {
        var lines: std.ArrayList(Line) = .empty;
        try lines.append(gpa, .empty);
        return .{ .gpa = gpa, .lines = lines };
    }

    pub fn deinit(self: *Buffer) void {
        for (self.lines.items) |*l| l.deinit(self.gpa);
        self.lines.deinit(self.gpa);
    }

    /// Copies bytes without newline normalization. Empty final lines are real.
    /// Allocation failure leaves the original buffer intact.
    pub fn loadBytes(self: *Buffer, bytes: []const u8) !void {
        var fresh: Buffer = .{ .gpa = self.gpa, .lines = .empty };
        errdefer fresh.deinit();
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |seg| {
            var line: Line = .empty;
            errdefer line.deinit(self.gpa);
            try line.appendSlice(self.gpa, seg);
            try fresh.lines.append(self.gpa, line);
        }
        self.deinit();
        self.* = fresh;
    }

    /// Full buffer content joined with '\n'. Caller owns the result.
    pub fn contentAlloc(self: *const Buffer, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (self.lines.items, 0..) |l, i| {
            if (i != 0) try out.append(gpa, '\n');
            try out.appendSlice(gpa, l.items);
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn lineCount(self: *const Buffer) usize {
        return self.lines.items.len;
    }

    pub fn lineSlice(self: *const Buffer, i: usize) []const u8 {
        return self.lines.items[i].items;
    }

    /// Logical line end excludes CR only when it belongs to a CRLF pair.
    pub fn lineEnd(self: *const Buffer, line: usize) usize {
        const bytes = self.lineSlice(line);
        return bytes.len - @as(usize, @intFromBool(line + 1 < self.lineCount() and bytes.len > 0 and bytes[bytes.len - 1] == '\r'));
    }

    pub fn endPos(self: *const Buffer) Pos {
        const last = self.lines.items.len - 1;
        return .{ .line = last, .col = self.lines.items[last].items.len };
    }

    pub fn clampPos(self: *const Buffer, p: Pos) Pos {
        var out = p;
        if (out.line >= self.lines.items.len) return self.endPos();
        const len = self.lineEnd(out.line);
        if (out.col > len) out.col = len;
        // Snap into a codepoint boundary.
        const l = self.lines.items[out.line].items;
        while (out.col > 0 and out.col < l.len and (l[out.col] & 0xC0) == 0x80) out.col -= 1;
        return out;
    }

    /// Position after inserting `text` at `at`.
    pub fn advance(at: Pos, text: []const u8) Pos {
        var line = at.line;
        var col = at.col;
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, i, '\n')) |nl| {
            line += 1;
            col = 0;
            i = nl + 1;
        }
        col += text.len - i;
        if (line != at.line) col = text.len - i;
        return .{ .line = line, .col = col };
    }

    /// Text of a range without modifying the buffer. Caller owns.
    pub fn rangeTextAlloc(self: *const Buffer, gpa: std.mem.Allocator, range: Range) ![]u8 {
        const r = range.normalized();
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        if (r.start.line == r.end.line) {
            try out.appendSlice(gpa, self.lineSlice(r.start.line)[r.start.col..r.end.col]);
        } else {
            try out.appendSlice(gpa, self.lineSlice(r.start.line)[r.start.col..]);
            try out.append(gpa, '\n');
            var i = r.start.line + 1;
            while (i < r.end.line) : (i += 1) {
                try out.appendSlice(gpa, self.lineSlice(i));
                try out.append(gpa, '\n');
            }
            try out.appendSlice(gpa, self.lineSlice(r.end.line)[0..r.end.col]);
        }
        return out.toOwnedSlice(gpa);
    }

    // --- codepoint / word navigation ---

    /// Codepoint starting at byte `col` of `l` (replacement char on error).
    fn cpAt(l: []const u8, col: usize) u21 {
        const len = std.unicode.utf8ByteSequenceLength(l[col]) catch return 0xFFFD;
        const end = @min(col + len, l.len);
        return std.unicode.utf8Decode(l[col..end]) catch 0xFFFD;
    }

    pub fn prevPos(self: *const Buffer, p: Pos) Pos {
        if (p.col == 0) {
            if (p.line == 0) return p;
            return .{ .line = p.line - 1, .col = self.lineEnd(p.line - 1) };
        }
        const l = self.lineSlice(p.line);
        var col = p.col - 1;
        while (col > 0 and (l[col] & 0xC0) == 0x80) col -= 1;
        // Keep stepping over zero-width marks so the cursor moves by
        // grapheme-ish clusters (base char + combining marks / VS / ZWJ).
        while (col > 0 and uwidth.isZeroWidth(cpAt(l, col))) {
            col -= 1;
            while (col > 0 and (l[col] & 0xC0) == 0x80) col -= 1;
        }
        return .{ .line = p.line, .col = col };
    }

    pub fn nextPos(self: *const Buffer, p: Pos) Pos {
        const l = self.lineSlice(p.line);
        if (p.col >= self.lineEnd(p.line)) {
            if (p.line + 1 >= self.lineCount()) return p;
            return .{ .line = p.line + 1, .col = 0 };
        }
        var col = p.col;
        const len = std.unicode.utf8ByteSequenceLength(l[col]) catch 1;
        col = @min(col + len, l.len);
        // Absorb trailing zero-width marks into this step.
        while (col < l.len and uwidth.isZeroWidth(cpAt(l, col))) {
            const n = std.unicode.utf8ByteSequenceLength(l[col]) catch 1;
            col = @min(col + n, l.len);
        }
        return .{ .line = p.line, .col = col };
    }

    const CharClass = enum { space, word, symbol };

    fn classOf(b: u8) CharClass {
        if (b == ' ' or b == '\t') return .space;
        if (b == '_' or std.ascii.isAlphanumeric(b) or b >= 0x80) return .word;
        return .symbol;
    }

    pub fn wordLeft(self: *const Buffer, p: Pos) Pos {
        var cur = self.prevPos(p);
        if (cur.eql(p)) return p;
        // Classify the character under the cursor after stepping left, not
        // the preceding byte (which incorrectly skipped the current word).
        while (cur.col < self.lineSlice(cur.line).len and classOf(self.lineSlice(cur.line)[cur.col]) == .space) {
            const prev = self.prevPos(cur);
            if (prev.eql(cur)) return cur;
            cur = prev;
        }
        const l = self.lineSlice(cur.line);
        if (cur.col >= l.len) return cur;
        const cls = classOf(l[cur.col]);
        while (cur.col > 0) {
            const prev = self.prevPos(cur);
            if (classOf(l[prev.col]) != cls) break;
            cur = prev;
        }
        return cur;
    }

    pub fn wordRight(self: *const Buffer, p: Pos) Pos {
        var cur = p;
        const l = self.lineSlice(p.line)[0..self.lineEnd(p.line)];
        if (cur.col >= l.len) return self.nextPos(cur);
        const cls = classOf(l[cur.col]);
        while (cur.col < l.len and classOf(l[cur.col]) == cls) cur = self.nextPos(cur);
        while (cur.col < l.len and classOf(l[cur.col]) == .space) cur = self.nextPos(cur);
        return cur;
    }

    // --- LSP position encoding helpers ---

    pub fn byteColToUtf16(self: *const Buffer, line: usize, byte_col: usize) usize {
        const l = self.lineSlice(line);
        var i: usize = 0;
        var units: usize = 0;
        while (i < l.len and i < byte_col) {
            const len = std.unicode.utf8ByteSequenceLength(l[i]) catch 1;
            const cp = std.unicode.utf8Decode(l[i..][0..@min(len, l.len - i)]) catch 0xFFFD;
            units += if (cp >= 0x10000) 2 else 1;
            i += len;
        }
        return units;
    }

    pub fn utf16ColToByte(self: *const Buffer, line: usize, utf16_col: usize) usize {
        const l = self.lineSlice(line);
        var i: usize = 0;
        var units: usize = 0;
        while (i < l.len and units < utf16_col) {
            const len = std.unicode.utf8ByteSequenceLength(l[i]) catch 1;
            const cp = std.unicode.utf8Decode(l[i..][0..@min(len, l.len - i)]) catch 0xFFFD;
            units += if (cp >= 0x10000) 2 else 1;
            i += len;
        }
        return i;
    }
};
