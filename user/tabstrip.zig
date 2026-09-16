//! Reusable native document/session tabs, bound to this frame: the strip
//! itself is the toolkit's (lib/ui/paint.zig), painted with `wf.brush()`.
//! This widget does not own documents.
const wf = @import("windowframe.zig");
const ui = @import("mosslib").ui;
pub const State = ui.tabs.State;
pub const Hit = ui.tabs.Hit;
pub const Item = ui.paint.TabItem;
pub fn height() usize {
    return ui.paint.controlHeight(wf.brush());
}
pub fn draw(r: wf.Rect, items: []const Item, selected: usize, state: *State) void {
    ui.paint.tabStrip(wf.brush(), r, items, selected, state);
}
pub fn hit(r: wf.Rect, items: []const Item, state: State, x: usize, y: usize) Hit {
    return ui.paint.tabStripHit(wf.brush(), r, items, state, x, y);
}
