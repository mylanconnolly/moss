//! Native controls shared by document windows and dialogs: the user-side
//! binding of the UI toolkit (lib/ui). The toolkit owns the models and the
//! arithmetic; this file owns what only a program can — the frame's pixels
//! and glyph metrics, the clipboard, and the wire's key bytes, which it
//! maps to the toolkit's semantic text commands.
const wf = @import("windowframe.zig");
const shared = @import("shared");
const ui = @import("mosslib").ui;
const clip = @import("clipboard.zig");
pub const Rect = ui.Rect;
pub const contains = ui.contains;
pub fn height() usize {
    return @max(wf.lineOf(wf.R_UI), wf.iconSize()) + 16;
}
pub const Button = struct {
    pub fn draw(r: Rect, label: []const u8, icon: []const u8, focused: bool, primary: bool, disabled: bool) void {
        const p = wf.pal;
        const bg = if (primary and !disabled) p.primary else p.surface_hi;
        const ink = if (disabled) p.text_muted else if (primary) p.primary_ink else p.text;
        wf.panel(r.x, r.y, r.w, r.h, ui.control.radius, bg, if (focused) p.focus else p.border, if (focused) p.focus_w else p.border_w);
        const size = wf.iconSize();
        const has_icon = ui.icons.parse(icon) != null and r.w >= size + 16 + (if (label.len > 0) wf.strW(wf.R_UI, label) + @as(usize, 8) else 0);
        const inset: usize = if (has_icon) size + 8 else 0;
        if (has_icon) wf.drawIcon(r.x + 8, r.y + (r.h -| size) / 2, size, icon, ink);
        const width = @min(wf.strW(wf.R_UI, label), r.w -| (inset + 16));
        const x = if (has_icon) r.x + 8 + inset else r.x + (r.w -| width) / 2;
        wf.drawStrTrunc(x, r.y + (r.h -| wf.lineOf(wf.R_UI)) / 2, wf.R_UI, label, r.w -| (inset + 16), ink, bg);
    }
};
pub fn input(r: Rect, ed: *ui.text.Editor, focused: bool) void {
    const p = wf.pal;
    wf.panel(r.x, r.y, r.w, r.h, ui.control.radius, p.field_bg, if (focused) p.focus else p.border, if (focused) p.focus_w else p.border_w);
    const room = r.w -| 20;
    const shown = ed.buf[0..ed.len];
    ed.first = @min(ed.first, ed.cursor);
    while (ed.first < ed.cursor and wf.strW(wf.R_UI, shown[ed.first..ed.cursor]) > room) ed.first = ed.next(ed.first);
    var last = ed.first;
    while (last < ed.len) {
        const next = ed.next(last);
        if (wf.strW(wf.R_UI, shown[ed.first..next]) > room) break;
        last = next;
    }
    const x = r.x + 8;
    const y = r.y + (r.h -| wf.lineOf(wf.R_UI)) / 2;
    const lo = @max(ed.first, ed.low());
    const hi = @min(last, ed.high());
    if (focused and hi > lo) {
        const sx = x + wf.strW(wf.R_UI, shown[ed.first..lo]);
        const sw = wf.strW(wf.R_UI, shown[lo..hi]);
        wf.fillRect(sx, y, sw, wf.lineOf(wf.R_UI), p.primary);
        wf.drawStr(x, y, wf.R_UI, shown[ed.first..lo], p.text, p.field_bg);
        wf.drawStr(sx, y, wf.R_UI, shown[lo..hi], p.primary_ink, p.primary);
        wf.drawStr(sx + sw, y, wf.R_UI, shown[hi..last], p.text, p.field_bg);
    } else wf.drawStr(x, y, wf.R_UI, shown[ed.first..last], p.text, p.field_bg);
    if (focused) wf.fillRect(x + wf.strW(wf.R_UI, shown[ed.first..ed.cursor]), y, 2, wf.lineOf(wf.R_UI), p.focus);
}

/// The wire's key byte as a text command: the private seat keys
/// (shared/keyboard.zig), the Emacs control codes, printable ASCII.
/// Null for a byte a text field does not act on.
pub fn textCommand(ch: u8) ?ui.text.Command {
    const k = shared.keyboard;
    return switch (ch) {
        1, k.home => .home,
        5, k.end => .end,
        2, k.left => .left,
        6, k.right => .right,
        k.word_left => .word_left,
        k.word_right => .word_right,
        k.select_left => .select_left,
        k.select_right => .select_right,
        k.select_home => .select_home,
        k.select_end => .select_end,
        k.select_word_left => .select_word_left,
        k.select_word_right => .select_word_right,
        k.select_all => .select_all,
        8, 127 => .backspace,
        4, k.delete => .delete,
        11 => .kill_to_end,
        21 => .kill_to_start,
        23, k.delete_word => .kill_word,
        25 => .yank,
        26, k.undo => .undo,
        k.redo => .redo,
        else => if (ch >= 32 and ch < 127) .{ .insert = ch } else null,
    };
}

/// A key byte for a focused field: clipboard shortcuts here (they need the
/// session clipboard), everything else through `textCommand`. True when
/// the field consumed the key.
pub fn fieldKey(ed: *ui.text.Editor, ch: u8) bool {
    return fieldKeyOpts(ed, ch, .{});
}
pub const FieldOptions = struct {
    /// A password field: paste yes, copy and cut never.
    secret: bool = false,
};
pub fn fieldKeyOpts(ed: *ui.text.Editor, ch: u8, opts: FieldOptions) bool {
    const k = shared.keyboard;
    if (ch == k.copy or ch == k.cut or ch == k.paste or ch == 3 or ch == 24 or ch == 22) {
        ed.typing = false;
        if (ch == k.paste or ch == 22) {
            if (clip.get()) |text| ed.paste(text);
        } else if (!opts.secret and ed.low() != ed.high()) {
            if (clip.set(ed.buf[ed.low()..ed.high()]) and (ch == k.cut or ch == 24)) ed.apply(.backspace);
        }
        return true;
    }
    const cmd = textCommand(ch) orelse return false;
    ed.apply(cmd);
    return true;
}
