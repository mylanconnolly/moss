//! The palette: a GUI's look is a set of SEMANTIC tokens, not scattered
//! literals, so the same widget code renders every theme. The tokens are
//! resolved from three composable appearance axes — theme dark/light,
//! contrast normal/high, colours default/colourblind-safe — that the
//! settings layer serves system-wide (fontsvc's appearance flags; the
//! frame maps the wire's enums to these at its boundary). Colours are
//! 0x00RRGGBB (XRGB, read straight by a screendump).
const std = @import("std");

pub const Theme = enum(u8) { dark = 0, light = 1 };
pub const Contrast = enum(u8) { normal = 0, high = 1 };
pub const ColorMode = enum(u8) { default = 0, cb_safe = 1 };

pub const Palette = struct {
    bg: u32, // the window ground
    surface: u32, // an elevated area (titlebar, cards)
    surface_hi: u32, // a raised element's fill (a default button)
    text: u32, // body text
    text_muted: u32, // secondary text (field labels, hints)
    title: u32, // the title / strong heading
    border: u32, // element outlines, the titlebar rule
    window_border: u32, // neutral active-window outline
    focus: u32, // the focus ring (never the only cue — focus also lifts)
    primary: u32, // the primary action's fill
    primary_ink: u32, // text on `primary`
    danger: u32, // a destructive action's fill
    danger_ink: u32, // text on `danger`
    field_bg: u32, // an inset text field
    border_w: usize, // outline thickness (thicker at high contrast)
    focus_w: usize, // focus-ring thickness
};

/// Scale each RGB channel of an XRGB colour by num/den (clamped) — for a
/// raised element's highlight (>1) and shade (<1) edges, so buttons read
/// with a little depth without a gradient.
pub fn shade(c: u32, num: u32, den: u32) u32 {
    const r: u32 = @min(((c >> 16) & 0xff) * num / den, 255);
    const g: u32 = @min(((c >> 8) & 0xff) * num / den, 255);
    const b: u32 = @min((c & 0xff) * num / den, 255);
    return (r << 16) | (g << 8) | b;
}

pub fn resolve(theme: Theme, contrast: Contrast, cmode: ColorMode) Palette {
    // Semantic accent/danger: a normal set, or the Okabe-Ito colourblind-
    // safe set (blue vs vermillion, distinguishable across common CVDs —
    // no red/green cue). Meaning is never carried by colour alone; the
    // labels and the raised shape say what a control is too.
    const cb = cmode == .cb_safe;
    var p: Palette = switch (theme) {
        .dark => .{
            .bg = 0x17191d,
            .surface = 0x22252a,
            .surface_hi = 0x30343b,
            .text = 0xe6e9f0,
            .text_muted = 0xa9afb9,
            .title = 0xf0f3fa,
            .border = 0x3b4049,
            .window_border = 0x565c66,
            .focus = if (cb) 0x56b4e9 else 0x5aa2ff,
            .primary = if (cb) 0x0072b2 else 0x3d7dff,
            .primary_ink = 0xffffff,
            .danger = if (cb) 0xd55e00 else 0xe5484d,
            .danger_ink = 0xffffff,
            .field_bg = 0x1b1e23,
            .border_w = 1,
            .focus_w = 3,
        },
        .light => .{
            .bg = 0xf3f3f1,
            .surface = 0xffffff,
            .surface_hi = 0xedeef0,
            .text = 0x1a1f2b,
            .text_muted = 0x5c6577,
            .title = 0x17191d,
            .border = 0xd3d5d9,
            .window_border = 0xaeb2b9,
            .focus = if (cb) 0x0072b2 else 0x2563eb,
            .primary = if (cb) 0x0072b2 else 0x2563eb,
            .primary_ink = 0xffffff,
            .danger = if (cb) 0xd55e00 else 0xdc2626,
            .danger_ink = 0xffffff,
            .field_bg = 0xffffff,
            .border_w = 1,
            .focus_w = 3,
        },
    };
    // High contrast: push ground and ink to the extremes, bolden the
    // outlines and the focus ring, and keep the accents bright and pure.
    if (contrast == .high) {
        const dark = theme == .dark;
        p.bg = if (dark) 0x000000 else 0xffffff;
        p.surface = p.bg;
        p.surface_hi = p.bg;
        p.field_bg = p.bg;
        p.text = if (dark) 0xffffff else 0x000000;
        p.text_muted = p.text;
        p.title = p.text;
        p.border = p.text;
        p.window_border = p.text;
        p.focus = if (dark) 0xffff00 else 0x0000ff;
        p.primary = if (cb) 0x009e73 else (if (dark) 0x2ea3ff else 0x0000cc);
        p.primary_ink = if (dark) 0x000000 else 0xffffff;
        p.danger = if (cb) 0xd55e00 else (if (dark) 0xff5b5b else 0xcc0000);
        p.danger_ink = if (dark) 0x000000 else 0xffffff;
        p.border_w = 2;
        p.focus_w = 5;
    }
    return p;
}

/// Perceived luminance, 0..255, for contrast checks.
fn luma(c: u32) u32 {
    return (((c >> 16) & 0xff) * 299 + ((c >> 8) & 0xff) * 587 + (c & 0xff) * 114) / 1000;
}

test "every palette keeps ink legible on its grounds and high contrast at the extremes" {
    inline for (.{ Theme.dark, Theme.light }) |theme| {
        inline for (.{ Contrast.normal, Contrast.high }) |contrast| {
            inline for (.{ ColorMode.default, ColorMode.cb_safe }) |cmode| {
                const p = resolve(theme, contrast, cmode);
                const d = @max(luma(p.text), luma(p.bg)) - @min(luma(p.text), luma(p.bg));
                try std.testing.expect(d >= 150); // body text over the ground
                const pd = @max(luma(p.primary_ink), luma(p.primary)) - @min(luma(p.primary_ink), luma(p.primary));
                try std.testing.expect(pd >= 90); // a label on the primary fill
                try std.testing.expect(p.focus != p.bg and p.border != p.bg);
                if (contrast == .high) {
                    try std.testing.expect(p.bg == 0 or p.bg == 0xffffff);
                    try std.testing.expect(p.border_w > resolve(theme, .normal, cmode).border_w);
                    try std.testing.expect(p.focus_w > resolve(theme, .normal, cmode).focus_w);
                }
            }
        }
    }
}

test "colourblind-safe accents avoid a red/green cue and shade clamps" {
    const p = resolve(.dark, .normal, .cb_safe);
    try std.testing.expect(p.primary != resolve(.dark, .normal, .default).primary);
    try std.testing.expectEqual(@as(u32, 0xffffff), shade(0xffffff, 3, 2));
    try std.testing.expectEqual(@as(u32, 0x7f4020), shade(0xff8040, 1, 2));
}
