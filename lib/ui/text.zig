//! Bounded single-line editor. Positions stay on UTF-8 code-point boundaries.
//!
//! Input is semantic: a `Command`, never a key byte. The binding that owns
//! the keyboard (user/widgets.zig) maps the wire's bytes — including the
//! Emacs control codes — to these; the editor and its tests know only what
//! the user meant.
const std = @import("std");

pub const Command = union(enum) {
    /// One printable ASCII character.
    insert: u8,
    home,
    end,
    left,
    right,
    word_left,
    word_right,
    select_left,
    select_right,
    select_home,
    select_end,
    select_word_left,
    select_word_right,
    select_all,
    /// Backspace: the selection, else the code point before the caret.
    backspace,
    /// Forward delete: the selection, else the code point after the caret.
    delete,
    /// Emacs C-k: to the end of the line, into the kill buffer.
    kill_to_end,
    /// Emacs C-u: to the start of the line, into the kill buffer.
    kill_to_start,
    /// Emacs C-w: the word before the caret, into the kill buffer.
    kill_word,
    /// Emacs C-y: insert the kill buffer.
    yank,
    undo,
    redo,
};

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
    /// Apply one command. Consecutive inserts without a selection group
    /// into one undo step; anything else ends the group.
    pub fn apply(self: *Editor, cmd: Command) void {
        switch (cmd) {
            .undo => return self.undo(false),
            .redo => return self.undo(true),
            else => {},
        }
        const before = self.snapshot();
        const was_typing = self.typing;
        const group = cmd == .insert and self.low() == self.high();
        self.typing = false;
        defer self.changed(before, group, was_typing);
        const selected = self.low() != self.high();
        switch (cmd) {
            .insert => |ch| if (ch >= 32 and ch < 127) self.insert(&.{ch}),
            .home => self.move(0, false),
            .end => self.move(self.len, false),
            .left => self.move(if (selected) self.low() else self.prev(self.cursor), false),
            .right => self.move(if (selected) self.high() else self.next(self.cursor), false),
            .word_left => self.move(self.word(true), false),
            .word_right => self.move(self.word(false), false),
            .select_left => self.move(self.prev(self.cursor), true),
            .select_right => self.move(self.next(self.cursor), true),
            .select_home => self.move(0, true),
            .select_end => self.move(self.len, true),
            .select_word_left => self.move(self.word(true), true),
            .select_word_right => self.move(self.word(false), true),
            .select_all => {
                self.anchor = 0;
                self.cursor = self.len;
            },
            .backspace => self.erase(if (selected) self.low() else self.prev(self.cursor), self.high(), false),
            .delete => self.erase(self.low(), if (selected) self.high() else self.next(self.cursor), false),
            .kill_to_end => self.erase(if (selected) self.low() else self.cursor, if (selected) self.high() else self.len, true),
            .kill_to_start => self.erase(if (selected) self.low() else 0, self.high(), true),
            .kill_word => self.erase(if (selected) self.low() else self.word(true), self.high(), true),
            .yank => self.insert(self.kill[0..self.kill_len]),
            .undo, .redo => unreachable,
        }
    }
};
fn continuation(ch: u8) bool {
    return ch & 0xc0 == 0x80;
}

test "selection replacement, collapse, UTF-8 deletion and kill/yank" {
    var e: Editor = .{};
    e.seed("héllo world");
    e.apply(.home);
    e.apply(.right);
    e.apply(.select_right);
    e.apply(.{ .insert = 'a' });
    try std.testing.expectEqualStrings("hallo world", e.buf[0..e.len]);
    e.apply(.select_end);
    e.apply(.left);
    try std.testing.expectEqual(@as(usize, 2), e.cursor);
    e.apply(.kill_to_end);
    e.apply(.yank);
    try std.testing.expectEqualStrings("hallo world", e.buf[0..e.len]);
    e.apply(.select_all);
    e.apply(.backspace);
    try std.testing.expectEqual(@as(usize, 0), e.len);
    e.seed("é");
    e.apply(.backspace);
    try std.testing.expectEqual(@as(usize, 0), e.len);
}
test "full buffer replacement and word selection" {
    var e: Editor = .{};
    e.seed(&(@as([64]u8, @splat('x'))));
    e.apply(.{ .insert = 'y' });
    try std.testing.expectEqual(@as(usize, 64), e.len);
    e.apply(.select_all);
    e.apply(.{ .insert = 'z' });
    try std.testing.expectEqualStrings("z", e.buf[0..e.len]);
    e.seed("one two");
    e.apply(.select_word_left);
    e.apply(.delete);
    try std.testing.expectEqualStrings("one ", e.buf[0..e.len]);
}

test "undo groups typing, restores selection, branches redo, and bounds history" {
    var e: Editor = .{};
    e.seed("old");
    e.apply(.select_all);
    e.paste("new\r\nvalue\t世界");
    try std.testing.expectEqualStrings("new value 世界", e.buf[0..e.len]);
    e.undo(false);
    try std.testing.expectEqualStrings("old", e.buf[0..e.len]);
    try std.testing.expectEqual(@as(usize, 0), e.low());
    try std.testing.expectEqual(@as(usize, 3), e.high());
    e.undo(true);
    e.apply(.end);
    e.apply(.{ .insert = 'a' });
    e.apply(.{ .insert = 'b' });
    e.apply(.{ .insert = 'c' });
    e.undo(false);
    try std.testing.expectEqualStrings("new value 世界", e.buf[0..e.len]);
    e.apply(.{ .insert = '!' });
    e.undo(true);
    try std.testing.expectEqualStrings("new value 世界!", e.buf[0..e.len]);
    for (0..80) |_| {
        e.apply(.backspace);
        e.apply(.{ .insert = 'x' });
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
    e.apply(.select_all);
    e.paste("é世界");
    e.undo(false);
    try std.testing.expectEqual(@as(usize, 63), e.len);
}
