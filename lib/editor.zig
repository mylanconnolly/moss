//! Native-UI-independent single-document editor, using medit's UTF-8 buffer core.
const std = @import("std");
pub const Buffer = @import("medit/buffer.zig").Buffer;
pub const Pos = @import("medit/buffer.zig").Pos;
pub const Range = @import("medit/buffer.zig").Range;
pub const uwidth = @import("medit/uwidth.zig");
pub const max_bytes = 256 * 1024;
pub const max_lines = 8192;
const max_history = 64;
pub const history_bytes = 2 * 1024 * 1024;
pub const Movement = enum { left, right, up, down, word_left, word_right, line_start, line_end, document_start, document_end };
const Snapshot = struct { text: []u8, cursor: Pos, anchor: ?Pos, seq: u64 = 0 };

/// A history budget several editors share. An editor on its own bounds
/// its histories at `history_bytes`; editors attached to one Budget are
/// bounded together, and when the sum exceeds the limit the oldest
/// snapshot in the whole set goes, whichever editor holds it — a tab
/// left open long ago gives way to the one being edited now, and a
/// dozen tabs cannot hold a dozen budgets against one heap.
pub const Budget = struct {
    limit: usize = history_bytes,
    bytes: usize = 0,
    seq: u64 = 0,
    editors: ?*Editor = null,

    /// Drop the oldest snapshot of any attached editor. False when there
    /// is nothing left to drop, or the oldest is the one just recorded.
    fn evictOldest(self: *Budget, keep: u64) bool {
        var oldest: ?*History = null;
        var oldest_ed: *Editor = undefined;
        var e = self.editors;
        while (e) |ed| : (e = ed.budget_next) {
            for ([_]*History{ &ed.undo_history, &ed.redo_history }) |h| {
                if (h.len == 0) continue;
                if (oldest == null or h.items[0].seq < oldest.?.items[0].seq) {
                    oldest = h;
                    oldest_ed = ed;
                }
            }
        }
        const h = oldest orelse return false;
        if (h.items[0].seq == keep) return false;
        h.evictFront(oldest_ed);
        return true;
    }
};

const History = struct {
    items: [max_history]Snapshot = undefined,
    len: usize = 0,
    bytes: usize = 0,
    fn clear(self: *History, ed: *Editor) void {
        for (self.items[0..self.len]) |s| ed.gpa.free(s.text);
        if (ed.budget) |b| b.bytes -= self.bytes;
        self.len = 0;
        self.bytes = 0;
    }
    fn evictFront(self: *History, ed: *Editor) void {
        self.bytes -= self.items[0].text.len;
        if (ed.budget) |b| b.bytes -= self.items[0].text.len;
        ed.gpa.free(self.items[0].text);
        std.mem.copyForwards(Snapshot, self.items[0 .. self.len - 1], self.items[1..self.len]);
        self.len -= 1;
    }
    fn push(self: *History, ed: *Editor, snap: Snapshot) void {
        var s = snap;
        while (self.len == max_history) self.evictFront(ed);
        if (ed.budget) |b| {
            s.seq = b.seq;
            b.seq += 1;
            self.items[self.len] = s;
            self.len += 1;
            self.bytes += s.text.len;
            b.bytes += s.text.len;
            while (b.bytes > b.limit and b.evictOldest(s.seq)) {}
        } else {
            while (self.len > 0 and self.bytes + s.text.len > history_bytes) self.evictFront(ed);
            s.seq = ed.seq;
            ed.seq += 1;
            self.items[self.len] = s;
            self.len += 1;
            self.bytes += s.text.len;
        }
    }
    fn pop(self: *History, ed: *Editor) Snapshot {
        self.len -= 1;
        const s = self.items[self.len];
        self.bytes -= s.text.len;
        if (ed.budget) |b| b.bytes -= s.text.len;
        return s;
    }
};
pub const Editor = struct {
    gpa: std.mem.Allocator,
    buffer: Buffer,
    cursor: Pos = .{ .line = 0, .col = 0 },
    anchor: ?Pos = null,
    saved: []u8,
    undo_history: History = .{},
    redo_history: History = .{},
    typing: bool = false,
    preferred_col: ?usize = null,
    /// Snapshot ordering when the editor bounds its own histories.
    seq: u64 = 0,
    budget: ?*Budget = null,
    budget_next: ?*Editor = null,

    pub fn init(gpa: std.mem.Allocator) !Editor {
        var b = try Buffer.init(gpa);
        errdefer b.deinit();
        return .{ .gpa = gpa, .buffer = b, .saved = try gpa.dupe(u8, "") };
    }
    /// Share a history budget. Call once the editor has its final address
    /// (the budget keeps a pointer) and before its first edit; `deinit`
    /// detaches. The editor's existing snapshots are charged as they are.
    pub fn attach(self: *Editor, budget: *Budget) void {
        std.debug.assert(self.budget == null);
        self.budget = budget;
        self.budget_next = budget.editors;
        budget.editors = self;
        budget.bytes += self.undo_history.bytes + self.redo_history.bytes;
    }
    fn detach(self: *Editor) void {
        const b = self.budget orelse return;
        b.bytes -= self.undo_history.bytes + self.redo_history.bytes;
        var link = &b.editors;
        while (link.*) |ed| : (link = &ed.budget_next) {
            if (ed == self) {
                link.* = self.budget_next;
                break;
            }
        }
        self.budget = null;
        self.budget_next = null;
    }
    pub fn deinit(self: *Editor) void {
        self.detach();
        self.buffer.deinit();
        self.gpa.free(self.saved);
        self.undo_history.clear(self);
        self.redo_history.clear(self);
    }
    fn validate(text: []const u8) !void {
        if (text.len > max_bytes) return error.FileTooLarge;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, text, 0) != null) return error.BinaryFile;
        if (std.mem.count(u8, text, "\n") >= max_lines) return error.TooManyLines;
    }
    pub fn load(self: *Editor, text: []const u8) !void {
        try validate(text);
        const saved = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(saved);
        try self.buffer.loadBytes(text);
        self.gpa.free(self.saved);
        self.saved = saved;
        self.undo_history.clear(self);
        self.redo_history.clear(self);
        self.cursor = .{ .line = 0, .col = 0 };
        self.anchor = null;
        self.breakGroup();
    }
    pub fn contentAlloc(self: *const Editor, gpa: std.mem.Allocator) ![]u8 {
        return self.buffer.contentAlloc(gpa);
    }
    pub fn markSaved(self: *Editor) !void {
        const saved = try self.contentAlloc(self.gpa);
        self.markSavedOwned(saved);
    }
    /// Takes a snapshot allocated by this editor's allocator. The caller must
    /// pass the current serialized document, after its synchronous save succeeds.
    /// No allocation can fail after the external write has committed.
    pub fn markSavedOwned(self: *Editor, saved: []u8) void {
        self.gpa.free(self.saved);
        self.saved = saved;
        self.breakGroup();
    }
    pub fn dirty(self: *const Editor) bool {
        var off: usize = 0;
        for (0..self.buffer.lineCount()) |i| {
            if (i != 0) {
                if (off >= self.saved.len or self.saved[off] != '\n') return true;
                off += 1;
            }
            const line = self.buffer.lineSlice(i);
            if (line.len > self.saved.len - off or !std.mem.eql(u8, line, self.saved[off..][0..line.len])) return true;
            off += line.len;
        }
        return off != self.saved.len;
    }
    pub fn selection(self: *const Editor) ?Range {
        const a = self.anchor orelse return null;
        const r = Range{ .start = a, .end = self.cursor };
        return if (r.isEmpty()) null else r.normalized();
    }
    pub fn selectionAlloc(self: *const Editor, gpa: std.mem.Allocator) ![]u8 {
        return if (self.selection()) |r| self.buffer.rangeTextAlloc(gpa, r) else gpa.dupe(u8, "");
    }
    pub fn breakGroup(self: *Editor) void {
        self.typing = false;
        self.preferred_col = null;
    }
    pub fn setCursor(self: *Editor, p: Pos, extend: bool) void {
        self.breakGroup();
        if (extend) {
            if (self.anchor == null) self.anchor = self.cursor;
        } else self.anchor = null;
        self.cursor = self.buffer.clampPos(p);
    }
    pub fn selectAll(self: *Editor) void {
        self.setCursor(.{ .line = 0, .col = 0 }, false);
        self.setCursor(self.buffer.endPos(), true);
    }
    /// One code point's step across a monospace line: the byte after it
    /// and the display column after it. Tabs use four-cell stops, CR is
    /// invisible, wide and combining characters take their cell width.
    /// The one place that arithmetic lives; the renderer walks cells with
    /// it too.
    pub fn cellStep(line: []const u8, i: usize, col: usize) struct { next: usize, col: usize } {
        const n = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        const next = @min(line.len, i + n);
        const cp = std.unicode.utf8Decode(line[i..next]) catch 0xfffd;
        return .{ .next = next, .col = if (cp == '\t') col + 4 - col % 4 else if (cp == '\r') col else col + uwidth.cellWidth(cp) };
    }
    /// Monospace display column of byte offset `end`.
    pub fn visualCol(line: []const u8, end: usize) usize {
        var col: usize = 0;
        var i: usize = 0;
        while (i < @min(end, line.len)) {
            const step = cellStep(line, i, col);
            col = step.col;
            i = step.next;
        }
        return col;
    }
    /// Byte boundary at or before a display column, absorbing zero-width marks.
    pub fn byteCol(line: []const u8, target: usize) usize {
        var col: usize = 0;
        var i: usize = 0;
        while (i < line.len) {
            const step = cellStep(line, i, col);
            if (step.col > target) break;
            col = step.col;
            i = step.next;
        }
        return i;
    }
    fn wordClass(b: u8) enum { space, word, symbol } {
        return if (b == ' ' or b == '\t' or b == '\r') .space else if (b >= 128 or b == '_' or std.ascii.isAlphanumeric(b)) .word else .symbol;
    }
    /// Select the run under a double click, including its first character.
    pub fn selectWordAt(self: *Editor, at: Pos) void {
        const p = self.buffer.clampPos(at);
        const line = self.buffer.lineSlice(p.line)[0..self.buffer.lineEnd(p.line)];
        if (line.len == 0) {
            self.setCursor(p, false);
            return;
        }
        var start = if (p.col == line.len) self.buffer.prevPos(p) else p;
        var end = self.buffer.nextPos(start);
        const class = wordClass(line[start.col]);
        while (start.col > 0) {
            const prev = self.buffer.prevPos(start);
            if (wordClass(line[prev.col]) != class) break;
            start = prev;
        }
        while (end.col < line.len and wordClass(line[end.col]) == class) end = self.buffer.nextPos(end);
        self.setCursor(start, false);
        self.setCursor(end, true);
    }
    pub fn move(self: *Editor, direction: Movement, extend: bool) void {
        if (!extend and (direction == .left or direction == .right)) {
            if (self.selection()) |r| {
                self.setCursor(if (direction == .left) r.start else r.end, false);
                return;
            }
        }
        const p = self.cursor;
        const preferred = self.preferred_col orelse visualCol(self.buffer.lineSlice(p.line), p.col);
        const next = switch (direction) {
            .left => self.buffer.prevPos(p),
            .right => self.buffer.nextPos(p),
            .word_left => self.buffer.wordLeft(p),
            .word_right => self.buffer.wordRight(p),
            .up => Pos{ .line = p.line -| 1, .col = byteCol(self.buffer.lineSlice(p.line -| 1), preferred) },
            .down => Pos{ .line = @min(p.line + 1, self.buffer.lineCount() - 1), .col = byteCol(self.buffer.lineSlice(@min(p.line + 1, self.buffer.lineCount() - 1)), preferred) },
            .line_start => Pos{ .line = p.line, .col = 0 },
            .line_end => Pos{ .line = p.line, .col = self.buffer.lineEnd(p.line) },
            .document_start => Pos{ .line = 0, .col = 0 },
            .document_end => self.buffer.endPos(),
        };
        self.setCursor(next, extend);
        if (direction == .up or direction == .down) self.preferred_col = preferred;
    }
    fn offset(self: *const Editor, p: Pos) usize {
        var n = p.col;
        for (0..p.line) |i| n += self.buffer.lineSlice(i).len + 1;
        return n;
    }
    fn snapshot(self: *const Editor) !Snapshot {
        return .{ .text = try self.contentAlloc(self.gpa), .cursor = self.cursor, .anchor = self.anchor };
    }
    /// Construct and validate the replacement before publishing any document/history change.
    fn replace(self: *Editor, r: Range, text: []const u8, coalesce: bool) !void {
        if (r.isEmpty() and text.len == 0) return;
        const before = try self.snapshot();
        errdefer self.gpa.free(before.text);
        const start = self.offset(r.start);
        const end = self.offset(r.end);
        if (text.len > max_bytes or before.text.len - (end - start) > max_bytes - text.len) return error.FileTooLarge;
        const after = try std.mem.concat(self.gpa, u8, &.{ before.text[0..start], text, before.text[end..] });
        defer self.gpa.free(after);
        try validate(after);
        try self.buffer.loadBytes(after);
        if (coalesce and self.typing and self.undo_history.len > 0) {
            self.gpa.free(before.text);
        } else self.undo_history.push(self, before);
        self.redo_history.clear(self);
        self.cursor = Buffer.advance(r.start, text);
        self.anchor = null;
        self.preferred_col = null;
        self.typing = coalesce;
    }
    pub fn insert(self: *Editor, text: []const u8) !void {
        const r = self.selection() orelse Range{ .start = self.cursor, .end = self.cursor };
        const coalesce = r.isEmpty() and text.len <= 4 and std.mem.indexOfScalar(u8, text, '\n') == null and !std.mem.eql(u8, text, "\t");
        try self.replace(r, text, coalesce);
    }
    /// Continue the local newline style and copy indentation up to the caret.
    /// A final line without its own terminator inherits the first line's style.
    pub fn newline(self: *Editor) !void {
        const at = if (self.selection()) |r| r.start else self.cursor;
        const line = self.buffer.lineSlice(at.line);
        const style_line = if (at.line + 1 < self.buffer.lineCount()) at.line else 0;
        const crlf = self.buffer.lineEnd(style_line) < self.buffer.lineSlice(style_line).len;
        var indent: usize = 0;
        while (indent < @min(at.col, line.len) and (line[indent] == ' ' or line[indent] == '\t')) indent += 1;
        const text = try std.mem.concat(self.gpa, u8, &.{ if (crlf) "\r\n" else "\n", line[0..indent] });
        defer self.gpa.free(text);
        try self.insert(text);
    }
    pub fn backspace(self: *Editor) !void {
        try self.replace(self.selection() orelse .{ .start = self.buffer.prevPos(self.cursor), .end = self.cursor }, "", false);
    }
    pub fn deleteForward(self: *Editor) !void {
        try self.replace(self.selection() orelse .{ .start = self.cursor, .end = self.buffer.nextPos(self.cursor) }, "", false);
    }
    fn restore(self: *Editor, from: *History, to: *History) !bool {
        if (from.len == 0) return false;
        const current = try self.snapshot();
        errdefer self.gpa.free(current.text);
        const target = from.items[from.len - 1];
        try self.buffer.loadBytes(target.text);
        _ = from.pop(self);
        to.push(self, current);
        self.cursor = target.cursor;
        self.anchor = target.anchor;
        self.gpa.free(target.text);
        self.breakGroup();
        return true;
    }
    pub fn undo(self: *Editor) !bool {
        return self.restore(&self.undo_history, &self.redo_history);
    }
    pub fn redo(self: *Editor) !bool {
        return self.restore(&self.redo_history, &self.undo_history);
    }
    /// Find from the current selection's edge, wrapping once. Exact UTF-8 search.
    pub fn find(self: *Editor, query: []const u8, backwards: bool) !bool {
        if (query.len == 0) return false;
        try validate(query);
        const text = try self.contentAlloc(self.gpa);
        defer self.gpa.free(text);
        const r = self.selection();
        const start = self.offset(if (r) |s| (if (backwards) s.start else s.end) else self.cursor);
        // Wrap searches the whole text, not just the part before the
        // caret: a match that straddles the caret starts before it and
        // ends after it, so neither half alone contains it.
        const at = if (backwards)
            std.mem.lastIndexOf(u8, text[0..start], query) orelse std.mem.lastIndexOf(u8, text, query)
        else
            std.mem.indexOfPos(u8, text, start, query) orelse std.mem.indexOf(u8, text, query);
        const found = at orelse return false;
        const p = Buffer.advance(.{ .line = 0, .col = 0 }, text[0..found]);
        self.setCursor(p, false);
        self.setCursor(Buffer.advance(p, query), true);
        return true;
    }
};

test "exact newlines, selection replacement, history and save point" {
    const a = std.testing.allocator;
    var e = try Editor.init(a);
    defer e.deinit();
    for ([_][]const u8{ "", "a", "a\n", "a\n\n", "a\r\nb" }) |text| {
        try e.load(text);
        const actual = try e.contentAlloc(a);
        defer a.free(actual);
        try std.testing.expectEqualStrings(text, actual);
        try std.testing.expect(!e.dirty());
    }
    try e.load("abc\ndef\n");
    e.setCursor(.{ .line = 0, .col = 1 }, false);
    e.setCursor(.{ .line = 1, .col = 2 }, true);
    try e.insert("X");
    try std.testing.expectEqualStrings("aXf", e.buffer.lineSlice(0));
    try std.testing.expect(e.dirty());
    try std.testing.expect(try e.undo());
    try std.testing.expect(!e.dirty());
    try std.testing.expect(try e.redo());
    try e.markSaved();
    try std.testing.expect(!e.dirty());
    try std.testing.expect(try e.undo());
    try std.testing.expect(e.dirty());
    try std.testing.expect(try e.redo());
    try std.testing.expect(!e.dirty());
}
test "unicode movement, typing group and wrapped search" {
    var e = try Editor.init(std.testing.allocator);
    defer e.deinit();
    try e.insert("é");
    try e.insert("x");
    try std.testing.expect(try e.undo());
    try std.testing.expectEqualStrings("", e.buffer.lineSlice(0));
    try std.testing.expect(try e.redo());
    e.move(.left, false);
    try std.testing.expectEqual(@as(usize, 2), e.cursor.col);
    e.move(.left, false);
    try std.testing.expectEqual(@as(usize, 0), e.cursor.col);
    try e.load("aé a\naé");
    try std.testing.expect(try e.find("aé", false));
    try std.testing.expectEqual(@as(usize, 0), e.cursor.line);
    try std.testing.expect(try e.find("aé", false));
    try std.testing.expectEqual(@as(usize, 1), e.cursor.line);
    try std.testing.expect(try e.find("aé", false));
    try std.testing.expectEqual(@as(usize, 0), e.cursor.line);
    try std.testing.expectError(error.InvalidUtf8, e.insert("\xff"));
    try std.testing.expectEqualStrings("aé a", e.buffer.lineSlice(0));
    // A match straddling the caret is found in both directions when the
    // search wraps: the only "aa" starts before column 2 and ends after it.
    try e.load("xaay");
    e.setCursor(.{ .line = 0, .col = 2 }, false);
    try std.testing.expect(try e.find("aa", false));
    try std.testing.expectEqual(@as(usize, 1), e.selection().?.start.col);
    e.setCursor(.{ .line = 0, .col = 2 }, false);
    try std.testing.expect(try e.find("aa", true));
    try std.testing.expectEqual(@as(usize, 1), e.selection().?.start.col);
}
fn allocationSequence(gpa: std.mem.Allocator) !void {
    var e = try Editor.init(gpa);
    defer e.deinit();
    try e.load("one\ntwo\n");
    e.selectAll();
    e.insert("new\ntext") catch |err| {
        try std.testing.expectEqualStrings("one", e.buffer.lineSlice(0));
        try std.testing.expect(!e.dirty());
        return err;
    };
    _ = try e.undo();
    _ = try e.redo();
    try e.newline();
    try e.markSaved();
}
test "every allocation failure leaves storage owned and edits atomic" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationSequence, .{});
}

test "word movement stays in the current word and vertical movement remembers column" {
    var e = try Editor.init(std.testing.allocator);
    defer e.deinit();
    try e.load("first word\nx\nlonger line");
    e.setCursor(.{ .line = 0, .col = 7 }, false);
    e.move(.word_left, false);
    try std.testing.expectEqual(@as(usize, 6), e.cursor.col);
    e.move(.word_left, false);
    try std.testing.expectEqual(@as(usize, 0), e.cursor.col);
    e.setCursor(.{ .line = 0, .col = 8 }, false);
    e.move(.down, false);
    try std.testing.expectEqual(@as(usize, 1), e.cursor.col);
    e.move(.down, false);
    try std.testing.expectEqual(@as(usize, 8), e.cursor.col);
}

test "sustained edits reclaim pool allocations and bound history" {
    const P = @import("pool.zig").Pool(64, 131072);
    const p = try std.testing.allocator.create(P);
    defer std.testing.allocator.destroy(p);
    p.* = .{};
    {
        var e = try Editor.init(p.allocator());
        defer e.deinit();
        for (0..512) |_| {
            e.breakGroup();
            try e.insert("line\n");
        }
        try std.testing.expectEqual(@as(usize, 64), e.undo_history.len);
        for (0..64) |_| try std.testing.expect(try e.undo());
        try std.testing.expect(!try e.undo());
        for (0..64) |_| try std.testing.expect(try e.redo());
        try std.testing.expectEqual(@as(usize, 513), e.buffer.lineCount());
        try e.markSaved();
        try std.testing.expect(!e.dirty());
        try std.testing.expect(try e.undo());
        try std.testing.expect(e.dirty());
        try std.testing.expect(try e.redo());
        try std.testing.expect(!e.dirty());
        for (0..32) |_| {
            try e.load("loaded\r\n\ttext\n");
            e.move(.document_end, false);
            try e.insert("more");
            try e.markSaved();
            try std.testing.expect(try e.undo());
            try std.testing.expect(e.dirty());
            try std.testing.expect(try e.redo());
            try std.testing.expect(!e.dirty());
        }
    }
    for (p.used) |used| try std.testing.expect(!used);
}

test "vertical cursor keeps display column across tabs wide characters and combining marks" {
    var e = try Editor.init(std.testing.allocator);
    defer e.deinit();
    try e.load("12345x\n\téx\n你你 x\na\né2345x");
    e.setCursor(.{ .line = 0, .col = 5 }, false);
    e.move(.down, false);
    try std.testing.expectEqual(@as(usize, 3), e.cursor.col);
    e.move(.down, true);
    try std.testing.expectEqual(@as(usize, 7), e.cursor.col);
    e.move(.down, true);
    try std.testing.expectEqual(@as(usize, 1), e.cursor.col);
    e.move(.down, true);
    try std.testing.expectEqual(@as(usize, 7), e.cursor.col);
    try std.testing.expectEqual(@as(usize, 5), Editor.visualCol(e.buffer.lineSlice(4), e.cursor.col));
    try std.testing.expectEqual(@as(usize, 0), Editor.byteCol("\tx", 2));
    try std.testing.expectEqual(@as(usize, 3), Editor.byteCol("éx", 1));
}
test "double click selects current word including its leading boundary" {
    var e = try Editor.init(std.testing.allocator);
    defer e.deinit();
    try e.load("first word!");
    for ([_]usize{ 6, 7, 9 }) |col| {
        e.selectWordAt(.{ .line = 0, .col = col });
        const text = try e.selectionAlloc(std.testing.allocator);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings("word", text);
    }
    e.selectWordAt(.{ .line = 0, .col = 10 });
    try std.testing.expectEqual(@as(usize, 10), e.selection().?.start.col);
    try std.testing.expectEqual(@as(usize, 11), e.selection().?.end.col);
}

test "CRLF editing keeps line endings atomic and autoindent preserves bytes" {
    const a = std.testing.allocator;
    var e = try Editor.init(a);
    defer e.deinit();
    try e.load("  one\r\n  two\r\n");
    e.move(.line_end, false);
    try std.testing.expectEqual(@as(usize, 5), e.cursor.col);
    try e.insert("!");
    try e.newline();
    try std.testing.expectEqual(@as(usize, 1), e.cursor.line);
    try std.testing.expectEqual(@as(usize, 2), e.cursor.col);
    try std.testing.expectEqualStrings("  one!\r", e.buffer.lineSlice(0));
    e.move(.line_start, false);
    try e.backspace();
    const joined = try e.contentAlloc(a);
    defer a.free(joined);
    try std.testing.expectEqualStrings("  one!  \r\n  two\r\n", joined);
    try e.markSaved();
    try std.testing.expect(!e.dirty());
    e.move(.line_end, false);
    e.move(.right, false);
    try std.testing.expectEqual(@as(usize, 1), e.cursor.line);
    try std.testing.expectEqual(@as(usize, 0), e.cursor.col);
    e.move(.left, false);
    try std.testing.expectEqual(@as(usize, 0), e.cursor.line);
    try std.testing.expectEqual(@as(usize, 8), e.cursor.col);
    try e.deleteForward();
    try std.testing.expectEqualStrings("  one!    two\r", e.buffer.lineSlice(0));
    try std.testing.expect(try e.undo());
    try std.testing.expect(!e.dirty());
    e.move(.document_end, false);
    try e.newline();
    const final = try e.contentAlloc(a);
    defer a.free(final);
    try std.testing.expectEqualStrings("  one!  \r\n  two\r\n\r\n", final);
    try e.load("literal\r");
    e.move(.line_end, false);
    try std.testing.expectEqual(@as(usize, 8), e.cursor.col);
    try e.backspace();
    try std.testing.expectEqualStrings("literal", e.buffer.lineSlice(0));
}

test "a shared budget evicts the oldest snapshot across editors" {
    const a = std.testing.allocator;
    var budget: Budget = .{ .limit = 400 };
    var first = try Editor.init(a);
    defer first.deinit();
    first.attach(&budget);
    var second = try Editor.init(a);
    defer second.deinit();
    second.attach(&budget);
    // Ten 20-byte lines: each edit snapshots the text before it, so the
    // last two snapshots (180 + 160 bytes) are all the budget holds.
    for (0..10) |_| {
        first.breakGroup();
        try first.insert("0123456789abcdefghi\n");
    }
    try std.testing.expectEqual(@as(usize, 2), first.undo_history.len);
    try std.testing.expectEqual(@as(usize, 340), budget.bytes);
    // The second editor's edits (0 + 20 + 40 + 60 bytes) push the first's
    // oldest snapshot out; the first still undoes the one it has left.
    for (0..4) |_| {
        second.breakGroup();
        try second.insert("0123456789abcdefghi\n");
    }
    try std.testing.expectEqual(@as(usize, 1), first.undo_history.len);
    try std.testing.expectEqual(@as(usize, 4), second.undo_history.len);
    try std.testing.expectEqual(first.undo_history.bytes + second.undo_history.bytes, budget.bytes);
    try std.testing.expect(try first.undo());
    try std.testing.expectEqual(@as(usize, 10), first.buffer.lineCount());
    try std.testing.expect(!try first.undo());
    // Undoing moved the 200-byte current text to redo, within the budget.
    try std.testing.expectEqual(@as(usize, 320), budget.bytes);
    // A closed editor hands its share back and leaves the list.
    second.deinit();
    second = try Editor.init(a);
    try std.testing.expectEqual(@as(usize, 200), budget.bytes);
    try std.testing.expect(budget.editors == &first);
    try std.testing.expect(first.budget_next == null);
    // A snapshot larger than the whole budget still lands: the newest is
    // never the one evicted; everything older goes to make room.
    var big = try Editor.init(a);
    defer big.deinit();
    big.attach(&budget);
    try big.insert("x" ** 450);
    big.breakGroup();
    try big.insert("y");
    try std.testing.expectEqual(@as(usize, 1), big.undo_history.len);
    try std.testing.expectEqual(@as(usize, 0), first.redo_history.len);
    try std.testing.expectEqual(@as(usize, 450), budget.bytes);
}
