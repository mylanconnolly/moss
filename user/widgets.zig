//! Native controls shared by document windows and capability pickers.
//! Layout uses the same font snapshot and semantic palette as mshl widgets.
const wf = @import("windowframe.zig");
const shared = @import("shared");
const clip = @import("clipboard.zig");
pub const Rect = wf.Rect;
pub fn contains(r: Rect, x: usize, y: usize) bool {
    return x >= r.x and y >= r.y and x - r.x < r.w and y - r.y < r.h;
}
pub fn height() usize {
    return @max(wf.lineOf(wf.R_UI), wf.iconSize()) + 16;
}
pub const Button = struct {
    pub fn draw(r: Rect, label: []const u8, icon: []const u8, focused: bool, primary: bool, disabled: bool) void {
        const p = wf.pal;
        const bg = if (primary and !disabled) p.primary else p.surface_hi;
        const ink = if (disabled) p.text_muted else if (primary) p.primary_ink else p.text;
        wf.panel(r.x, r.y, r.w, r.h, 6, bg, if (focused) p.focus else p.border, if (focused) p.focus_w else p.border_w);
        const size = wf.iconSize();
        const has_icon = shared.gui.icons.parse(icon) != null and r.w >= size + 16 + (if (label.len > 0) wf.strW(wf.R_UI, label) + @as(usize, 8) else 0);
        const inset: usize = if (has_icon) size + 8 else 0;
        if (has_icon) wf.drawIcon(r.x + 8, r.y + (r.h -| size) / 2, size, icon, ink);
        const width = @min(wf.strW(wf.R_UI, label), r.w -| (inset + 16));
        const x = if (has_icon) r.x + 8 + inset else r.x + (r.w -| width) / 2;
        wf.drawStrTrunc(x, r.y + (r.h -| wf.lineOf(wf.R_UI)) / 2, wf.R_UI, label, r.w -| (inset + 16), ink, bg);
    }
};
pub fn input(r: Rect, ed: *shared.TextEdit, focused: bool) void {
    const p = wf.pal;
    wf.panel(r.x, r.y, r.w, r.h, 6, p.field_bg, if (focused) p.focus else p.border, if (focused) p.focus_w else p.border_w);
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
pub fn fieldKey(ed: *shared.TextEdit, ch: u8) bool {
    const k = shared.keyboard;
    if (ch == k.copy or ch == k.cut or ch == k.paste or ch == 3 or ch == 24 or ch == 22) {
        ed.typing = false;
        if (ch == k.paste or ch == 22) {
            if (clip.get()) |text| ed.paste(text);
        } else if (ed.low() != ed.high()) {
            if (clip.set(ed.buf[ed.low()..ed.high()]) and (ch == k.cut or ch == 24)) _ = ed.key(8);
        }
        return true;
    }
    return ed.key(if (ch == 26) k.undo else ch);
}
