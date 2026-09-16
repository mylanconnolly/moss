//! The UI toolkit: the pure, host-tested half of every graphical program.
//!
//! Everything here is allocation-free, freestanding-safe and knows nothing
//! about the display server, the font service or the wire: no capability,
//! no key byte, no pixel buffer. It is models and arithmetic — geometry
//! and spacing tokens, the row flow and proportional tracks a view is
//! laid out with, scroll state, double-click timing, the single-line
//! text editor, tab-strip and breadcrumb layout, application search, the
//! icon catalog with its compile-time SVG decoder, and the rounded window
//! shape the compositor and the frame must agree on. Each module carries
//! its own tests; `zig build test` runs them on the host.
//!
//! What stays out, by design: key *bytes* are the wire contract between
//! inputsvc, the compositor and applications (shared/keyboard.zig), so
//! the text editor takes semantic `text.Command`s and the user-side
//! binding (user/widgets.zig) maps bytes to them; menu profiles and
//! display modes are likewise wire (shared/menus.zig, shared/display.zig).
//! Painting goes through a `Canvas` (pixels, clip, scroll offset and the
//! primitives), a `Typeface` the frame implements over the font service
//! and a test implements over fixed cells, the `Palette`, and the widget
//! painters in `paint` that take all three as a `Brush` — so a button's
//! pixels can be asserted on the host. What the frame keeps for itself
//! is the surface, the glyph atlas and the window chrome.
pub const geometry = @import("ui/geometry.zig");
pub const Rect = geometry.Rect;
pub const Size = geometry.Size;
pub const Placement = geometry.Placement;
pub const contains = geometry.contains;
pub const space = geometry.space;
pub const control = geometry.control;
pub const flow = @import("ui/flow.zig");
pub const scroll = @import("ui/scroll.zig");
pub const pointer = @import("ui/pointer.zig");
pub const text = @import("ui/text.zig");
pub const tabs = @import("ui/tabs.zig");
pub const breadcrumbs = @import("ui/breadcrumbs.zig");
pub const search = @import("ui/search.zig");
pub const icons = @import("ui/icons.zig");
pub const shape = @import("ui/shape.zig");
pub const canvas = @import("ui/canvas.zig");
pub const Canvas = canvas.Canvas;
pub const typeface = @import("ui/typeface.zig");
pub const Typeface = typeface.Typeface;
pub const palette = @import("ui/palette.zig");
pub const Palette = palette.Palette;
pub const paint = @import("ui/paint.zig");
pub const Brush = paint.Brush;
pub const layout = @import("ui/layout.zig");

test {
    _ = geometry;
    _ = flow;
    _ = scroll;
    _ = pointer;
    _ = text;
    _ = tabs;
    _ = breadcrumbs;
    _ = search;
    _ = icons;
    _ = shape;
    _ = canvas;
    _ = typeface;
    _ = palette;
    _ = paint;
    _ = layout;
}
