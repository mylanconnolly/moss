//! Reusable native document/session tabs. This widget does not own documents.
const wf = @import("windowframe.zig");
const model = @import("mosslib").ui.tabs;
pub const State = model.State;
pub const Hit = model.Hit;
pub const Item = struct { label: []const u8, dirty: bool = false, closable: bool = true };
pub fn height() usize {
    return @max(wf.lineOf(wf.R_UI), wf.iconSize()) + 16;
}
fn desired(item: Item, h: usize) usize {
    return @min(@max(wf.strW(wf.R_UI, item.label) + 24 + (if (item.dirty) h / 3 else @as(usize, 0)) + (if (item.closable) h else @as(usize, 0)), h * 2), h * 6);
}
fn layout(r: wf.Rect, items: []const Item, state: State) model.Layout {
    var total: usize = 0;
    for (items) |item| total +|= desired(item, r.h);
    return model.Layout.init(r.w, r.h, total > r.w or state.first > 0);
}
fn boundedFirst(state: State, count: usize) usize {
    return @min(state.first, count -| 1);
}
fn arrow(r: wf.Rect, span: model.Span, forward: bool, enabled: bool) void {
    if (span.w == 0) return;
    const size = @min(wf.iconSize(), span.w -| 8);
    if (size < 4) return;
    // The forward arrow is drawn from the same simple stroke geometry as
    // the back arrow, so no new icon asset is required for navigation.
    const ink = if (enabled) wf.pal.text else wf.pal.text_muted;
    const cx = r.x + span.x + span.w / 2;
    const cy = r.y + r.h / 2;
    if (!forward) {
        wf.drawIcon(cx -| (size / 2), cy -| (size / 2), size, "back", ink);
    } else {
        const half = size / 3;
        const thick = @max(1, size / 12);
        wf.fillRect(cx -| half, cy -| (thick / 2), half * 2, thick, ink);
        for (0..half) |i| {
            wf.fillRect(cx + half - i, cy -| i, thick, thick, ink);
            wf.fillRect(cx + half - i, cy + i, thick, thick, ink);
        }
    }
}
pub fn draw(r: wf.Rect, items: []const Item, selected: usize, state: *State) void {
    state.resize(r.w, r.h, selected);
    state.first = boundedFirst(state.*, items.len);
    if (r.w == 0 or r.h == 0) return;
    // Labels can grow without a viewport resize (Save As or a dirty badge).
    // Preserve selection only if it was visible before; explicit scrolling
    // is still allowed to put the active document outside the viewport.
    var preview = layout(r, items, state.*);
    var visible = false;
    for (items[state.first..], state.first..) |item, index| {
        _ = preview.put(desired(item, r.h), item.closable) orelse break;
        if (index == selected) {
            visible = true;
            break;
        }
    }
    state.preserveVisibility(visible, selected);
    var total: usize = 0;
    for (items) |item| total +|= desired(item, r.h);
    if (total <= r.w) {
        state.first = 0;
    } else if (state.reveal_pending and items.len > 0) {
        // Fill available space before the newly selected document as well:
        // switching to the last tab should not leave a mostly empty strip.
        const viewport = model.Layout.init(r.w, r.h, true).content.w;
        var used = @min(desired(items[state.first], r.h), viewport);
        while (state.first > 0) {
            const preceding = desired(items[state.first - 1], r.h);
            if (preceding > viewport - used) break;
            used += preceding;
            state.first -= 1;
        }
    }
    state.reveal_pending = false;
    var row = layout(r, items, state.*);
    wf.fillRect(r.x, r.y, r.w, r.h, wf.pal.surface_hi);
    var end = state.first;
    for (items[state.first..], state.first..) |item, index| {
        const tab = row.put(desired(item, r.h), item.closable) orelse break;
        end = index + 1;
        const bg = if (index == selected) wf.pal.surface else wf.pal.surface_hi;
        const ink = if (index == selected) wf.pal.text else wf.pal.text_muted;
        wf.fillRect(r.x + tab.body.x, r.y, tab.body.w, r.h, bg);
        if (index == selected) wf.fillRect(r.x + tab.body.x, r.y + r.h -| 2, tab.body.w, @min(2, r.h), wf.pal.focus);
        var inset: usize = @min(12, tab.body.w);
        if (item.dirty and tab.body.w > r.h) {
            const radius = @max(2, r.h / 14);
            wf.fillDot(r.x + tab.body.x + inset + radius, r.y + r.h / 2, radius, ink);
            inset += r.h / 3;
        }
        wf.drawStrTrunc(r.x + tab.body.x + inset, r.y + (r.h -| wf.lineOf(wf.R_UI)) / 2, wf.R_UI, item.label, tab.body.w -| (inset + tab.close.w + 8), ink, bg);
        if (tab.close.w > 0) {
            const size = @min(wf.iconSize(), tab.close.w -| 16);
            wf.drawIcon(r.x + tab.close.x + (tab.close.w - size) / 2, r.y + (r.h -| size) / 2, size, "close", ink);
        }
    }
    arrow(r, row.previous, false, state.first > 0);
    arrow(r, row.next, true, end < items.len);
    state.selection_visible = selected >= state.first and selected < end;
}
pub fn hit(r: wf.Rect, items: []const Item, state: State, x: usize, y: usize) Hit {
    if (x < r.x or y < r.y or x - r.x >= r.w or y - r.y >= r.h) return .none;
    const local = x - r.x;
    const first = boundedFirst(state, items.len);
    var row = layout(r, items, .{ .first = first });
    if (row.previous.contains(local)) return if (first > 0) .previous else .none;
    var end = first;
    for (items[first..], first..) |item, index| {
        const tab = row.put(desired(item, r.h), item.closable) orelse break;
        end = index + 1;
        const result = tab.hit(index, local);
        if (result != .none) return result;
    }
    if (row.next.contains(local) and end < items.len) return .next;
    return .none;
}
