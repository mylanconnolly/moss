//! Bounded single-line editor. Positions stay on UTF-8 code-point boundaries.
const std = @import("std");
const k = @import("keyboard.zig");
pub const Editor = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
    anchor: usize = 0,
    first: usize = 0,
    kill: [64]u8 = undefined,
    kill_len: usize = 0,

    undo_items: [32]Snapshot = undefined,
    redo_items: [32]Snapshot = undefined,
    undo_len: usize = 0,
    redo_len: usize = 0,
    typing: bool = false,

    const Snapshot = struct { buf: [64]u8, len: usize, cursor: usize, anchor: usize };

    fn snapshot(self: *const Editor) Snapshot {
        return .{ .buf = self.buf, .len = self.len, .cursor = self.cursor, .anchor = self.anchor };
    }
    fn push(items: *[32]Snapshot, len: *usize, value: Snapshot) void {
        if (len.* == items.len) {
            std.mem.copyForwards(Snapshot, items[0 .. items.len - 1], items[1..]);
            len.* -= 1;
        }
        items[len.*] = value;
        len.* += 1;
    }
    fn restore(self: *Editor, value: Snapshot) void {
        self.buf = value.buf;
        self.len = value.len;
        self.cursor = value.cursor;
        self.anchor = value.anchor;
        self.first = 0;
        self.typing = false;
    }
    pub fn undo(self: *Editor, redo: bool) void {
        self.typing = false;
        const src = if (redo) &self.redo_items else &self.undo_items;
        const n = if (redo) &self.redo_len else &self.undo_len;
        if (n.* == 0) return;
        push(if (redo) &self.undo_items else &self.redo_items, if (redo) &self.undo_len else &self.redo_len, self.snapshot());
        n.* -= 1;
        self.restore(src[n.*]);
    }
    fn changed(self: *Editor, before: Snapshot, group: bool, was_typing: bool) void {
        if (std.mem.eql(u8, before.buf[0..before.len], self.buf[0..self.len])) return;
        if (!group or !was_typing) push(&self.undo_items, &self.undo_len, before);
        self.redo_len = 0;
        self.typing = group;
    }
    /// Paste is one undo transaction. Reject invalid UTF-8; flatten line breaks
    /// and tabs for a single-line field, and truncate only at code-point edges.
    pub fn paste(self: *Editor, text: []const u8) void {
        if (!std.unicode.utf8ValidateSlice(text)) return;
        const before = self.snapshot();
        var clean: [64]u8 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        const room = self.buf.len - (self.len - (self.high() - self.low()));
        while (i < text.len) {
            const size = std.unicode.utf8ByteSequenceLength(text[i]) catch return;
            if (text[i] < 32 or text[i] == 127) {
                if (text[i] == '\r' or text[i] == '\n' or text[i] == '\t') {
                    if (n == room) break;
                    clean[n] = ' ';
                    n += 1;
                    if (text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n') i += 1;
                }
            } else {
                if (n + size > room) break;
                @memcpy(clean[n..][0..size], text[i..][0..size]);
                n += size;
            }
            i += size;
        }
        if (n == 0) return;
        self.insert(clean[0..n]);
        self.changed(before, false, false);
        self.typing = false;
    }
    pub fn seed(self: *Editor, text: []const u8) void {
        self.undo_len = 0;
        self.redo_len = 0;
        var n = @min(text.len, self.buf.len);
        while (n < text.len and n > 0 and continuation(text[n])) n -= 1;
        @memcpy(self.buf[0..n], text[0..n]);
        self.len = n;
        self.move(n, false);
    }
    pub fn low(self: *const Editor) usize {
        return @min(self.cursor, self.anchor);
    }
    pub fn high(self: *const Editor) usize {
        return @max(self.cursor, self.anchor);
    }
    pub fn prev(self: *const Editor, pos: usize) usize {
        var p = pos -| 1;
        while (p > 0 and continuation(self.buf[p])) p -= 1;
        return p;
    }
    pub fn next(self: *const Editor, pos: usize) usize {
        var p = @min(pos + 1, self.len);
        while (p < self.len and continuation(self.buf[p])) p += 1;
        return p;
    }
    pub fn move(self: *Editor, pos: usize, select: bool) void {
        self.typing = false;
        self.cursor = @min(pos, self.len);
        if (!select) self.anchor = self.cursor;
    }
    fn word(self: *const Editor, left: bool) usize {
        var p = self.cursor;
        if (left) {
            while (p > 0 and self.buf[self.prev(p)] == ' ') p = self.prev(p);
            while (p > 0 and self.buf[self.prev(p)] != ' ') p = self.prev(p);
        } else {
            while (p < self.len and self.buf[p] != ' ') p = self.next(p);
            while (p < self.len and self.buf[p] == ' ') p = self.next(p);
        }
        return p;
    }
    fn erase(self: *Editor, lo: usize, hi: usize, save: bool) void {
        if (save and hi > lo) {
            self.kill_len = hi - lo;
            @memcpy(self.kill[0..self.kill_len], self.buf[lo..hi]);
        }
        std.mem.copyForwards(u8, self.buf[lo..], self.buf[hi..self.len]);
        self.len -= hi - lo;
        self.move(lo, false);
        self.first = @min(self.first, self.cursor);
    }
    fn insert(self: *Editor, bytes: []const u8) void {
        if (self.len - (self.high() - self.low()) + bytes.len > self.buf.len) return;
        self.erase(self.low(), self.high(), false);
        std.mem.copyBackwards(u8, self.buf[self.cursor + bytes.len .. self.len + bytes.len], self.buf[self.cursor..self.len]);
        @memcpy(self.buf[self.cursor..][0..bytes.len], bytes);
        self.len += bytes.len;
        self.move(self.cursor + bytes.len, false);
    }
    pub fn key(self: *Editor, ch: u8) bool {
        if (ch == k.undo or ch == k.redo) {
            self.undo(ch == k.redo);
            return true;
        }
        const before = self.snapshot();
        const was_typing = self.typing;
        const group = ch >= 32 and ch < 127 and self.low() == self.high();
        self.typing = false;
        defer self.changed(before, group, was_typing);
        const selected = self.low() != self.high();
        switch (ch) {
            1, k.home => self.move(0, false),
            5, k.end => self.move(self.len, false),
            2, k.left => self.move(if (selected) self.low() else self.prev(self.cursor), false),
            6, k.right => self.move(if (selected) self.high() else self.next(self.cursor), false),
            k.word_left => self.move(self.word(true), false),
            k.word_right => self.move(self.word(false), false),
            k.select_left => self.move(self.prev(self.cursor), true),
            k.select_right => self.move(self.next(self.cursor), true),
            k.select_home => self.move(0, true),
            k.select_end => self.move(self.len, true),
            k.select_word_left => self.move(self.word(true), true),
            k.select_word_right => self.move(self.word(false), true),
            k.select_all => {
                self.anchor = 0;
                self.cursor = self.len;
            },
            8, 127 => self.erase(if (selected) self.low() else self.prev(self.cursor), self.high(), false),
            4, k.delete => self.erase(self.low(), if (selected) self.high() else self.next(self.cursor), false),
            11 => self.erase(if (selected) self.low() else self.cursor, if (selected) self.high() else self.len, true),
            21 => self.erase(if (selected) self.low() else 0, self.high(), true),
            23, k.delete_word => self.erase(if (selected) self.low() else self.word(true), self.high(), true),
            25 => self.insert(self.kill[0..self.kill_len]),
            else => if (ch >= 32 and ch < 127) self.insert(&.{ch}) else return false,
        }
        return true;
    }
};
fn continuation(ch: u8) bool {
    return ch & 0xc0 == 0x80;
}

test "selection replacement, collapse, UTF-8 deletion and kill/yank" {
    var e: Editor = .{};
    e.seed("héllo world");
    _ = e.key(1);
    _ = e.key(6);
    _ = e.key(k.select_right);
    _ = e.key('a');
    try std.testing.expectEqualStrings("hallo world", e.buf[0..e.len]);
    _ = e.key(k.select_end);
    _ = e.key(k.left);
    try std.testing.expectEqual(@as(usize, 2), e.cursor);
    _ = e.key(11);
    _ = e.key(25);
    try std.testing.expectEqualStrings("hallo world", e.buf[0..e.len]);
    _ = e.key(k.select_all);
    _ = e.key(8);
    try std.testing.expectEqual(@as(usize, 0), e.len);
    e.seed("é");
    _ = e.key(8);
    try std.testing.expectEqual(@as(usize, 0), e.len);
}
test "full buffer replacement and word selection" {
    var e: Editor = .{};
    e.seed(&(@as([64]u8, @splat('x'))));
    _ = e.key('y');
    try std.testing.expectEqual(@as(usize, 64), e.len);
    _ = e.key(k.select_all);
    _ = e.key('z');
    try std.testing.expectEqualStrings("z", e.buf[0..e.len]);
    e.seed("one two");
    _ = e.key(k.select_word_left);
    _ = e.key(4);
    try std.testing.expectEqualStrings("one ", e.buf[0..e.len]);
}

test "undo groups typing, restores selection, branches redo, and bounds history" {
    var e: Editor = .{};
    e.seed("old");
    _ = e.key(k.select_all);
    e.paste("new\r\nvalue\t世界");
    try std.testing.expectEqualStrings("new value 世界", e.buf[0..e.len]);
    e.undo(false);
    try std.testing.expectEqualStrings("old", e.buf[0..e.len]);
    try std.testing.expectEqual(@as(usize, 0), e.low());
    try std.testing.expectEqual(@as(usize, 3), e.high());
    e.undo(true);
    _ = e.key(k.end);
    _ = e.key('a');
    _ = e.key('b');
    _ = e.key('c');
    e.undo(false);
    try std.testing.expectEqualStrings("new value 世界", e.buf[0..e.len]);
    _ = e.key('!');
    e.undo(true);
    try std.testing.expectEqualStrings("new value 世界!", e.buf[0..e.len]);
    for (0..80) |_| {
        _ = e.key(8);
        _ = e.key('x');
    }
    try std.testing.expect(e.undo_len <= 32);
}
test "paste refuses malformed data and truncates on UTF-8 boundaries" {
    var e: Editor = .{};
    e.seed("seed");
    e.paste(&.{0xff});
    try std.testing.expectEqualStrings("seed", e.buf[0..e.len]);
    e.seed(&(@as([63]u8, @splat('x'))));
    e.paste("é");
    try std.testing.expectEqual(@as(usize, 63), e.len);
    try std.testing.expectEqual(@as(usize, 0), e.undo_len);
    _ = e.key(k.select_all);
    e.paste("é世界");
    e.undo(false);
    try std.testing.expectEqual(@as(usize, 63), e.len);
}
