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
    return ui.paint.controlHeight(wf.brush());
}
pub const Button = struct {
    pub fn draw(r: Rect, label: []const u8, icon: []const u8, focused: bool, primary: bool, disabled: bool) void {
        ui.paint.button(wf.brush(), r, label, ui.icons.parse(icon), .{ .focused = focused, .primary = primary, .disabled = disabled });
    }
};
pub fn input(r: Rect, ed: *ui.text.Editor, focused: bool) void {
    ui.paint.field(wf.brush(), r, ed, focused);
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
