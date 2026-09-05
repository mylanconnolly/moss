//! A text console on the linear framebuffer firmware hands over: the
//! same lines the serial console carries, drawn with the 8x16 font in
//! `font/`, so a machine with a screen and no serial port still shows
//! the kernel booting and, when it comes to it, panicking. The port's
//! platform reports the framebuffer (`Framebuffer`), the port's mmu maps
//! it write-combining (`mapFramebuffer`), and `attach` takes it over.
//!
//! Character cells are the unit: a shadow of the text keeps what is on
//! screen, and a scroll redraws every row from it — no reads of the
//! framebuffer, which through a write-combining mapping are slow, and no
//! second pixel buffer. 32 bits per pixel, RGB with byte-sized channels
//! at any shift; other formats are declined and the serial console
//! stays alone. The log is UTF-8 and the font is ASCII: a multibyte
//! sequence draws as one stand-in (a dash for the dashes, an angle
//! bracket for an arrow, `?` for the rest), never as its bytes.
//! Writes take a spinlock with IRQs masked and a bounded
//! spin: a core panicking while another holds the lock drops its line
//! on the screen rather than hanging (the serial console already has
//! it).

const std = @import("std");
const arch = @import("arch.zig");
const font = @import("font/console8x16.zig");
const mem = @import("mem.zig");

pub const Framebuffer = struct {
    /// Physical base; the console maps it itself.
    pa: u64,
    width: u32,
    height: u32,
    /// Bytes per scanline.
    pitch: u32,
    bpp: u16,
    red_shift: u8,
    green_shift: u8,
    blue_shift: u8,
    red_size: u8 = 8,
    green_size: u8 = 8,
    blue_size: u8 = 8,
};

const max_cols = 256;
const max_rows = 128;

var fb: Framebuffer = undefined;
var pixels: [*]volatile u32 = undefined;
var stride: u32 = 0; // pixels per scanline
pub var cols: u32 = 0;
pub var rows: u32 = 0;
var col: u32 = 0;
var row: u32 = 0;
var fg: u32 = 0;
var bg: u32 = 0;
var text: [max_rows][max_cols]u8 = undefined;
var active = std.atomic.Value(bool).init(false);
/// A UTF-8 sequence in progress: the code point so far, bytes to come.
var utf8_cp: u32 = 0;
var utf8_left: u8 = 0;
var lock_word = std.atomic.Value(u32).init(0);

/// Map the framebuffer and clear it; true when this console is now
/// drawing. False (with the reason logged by the caller) for a format
/// the console does not draw.
pub fn attach(f: Framebuffer) bool {
    if (f.bpp != 32 or f.red_size != 8 or f.green_size != 8 or f.blue_size != 8) return false;
    if (f.pitch % 4 != 0 or f.width < font.width or f.height < font.height) return false;
    const size = @as(u64, f.pitch) * f.height;
    arch.mmu.mapFramebuffer(f.pa, size) catch return false;
    fb = f;
    pixels = @ptrFromInt(mem.physToVirt(f.pa));
    stride = f.pitch / 4;
    cols = @min(f.width / font.width, max_cols);
    rows = @min(f.height / font.height, max_rows);
    fg = pixel(0xd8, 0xd8, 0xd0);
    bg = pixel(0x10, 0x12, 0x18);
    for (0..f.height) |y| {
        const line = pixels[y * stride ..][0..f.width];
        for (line) |*p| p.* = bg;
    }
    for (&text) |*r| @memset(r, ' ');
    col = 0;
    row = 0;
    active.store(true, .release);
    return true;
}

fn pixel(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << @intCast(fb.red_shift)) | (@as(u32, g) << @intCast(fb.green_shift)) | (@as(u32, b) << @intCast(fb.blue_shift));
}

pub fn write(bytes: []const u8) void {
    if (!active.load(.acquire)) return;
    const irqs = arch.cpu.irqSave();
    var spins: u32 = 0;
    while (lock_word.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) : (spins += 1) {
        if (spins == 1 << 24) {
            arch.cpu.irqRestore(irqs);
            return;
        }
        std.atomic.spinLoopHint();
    }
    defer {
        lock_word.store(0, .release);
        arch.cpu.irqRestore(irqs);
    }
    for (bytes) |b| put(b);
}

fn put(b: u8) void {
    switch (b) {
        '\n' => newline(),
        '\r' => col = 0,
        '\t' => {
            col = (col + 8) & ~@as(u32, 7);
            if (col >= cols) newline();
        },
        else => {
            if (b >= 0x80) {
                // UTF-8: gather the sequence, draw a stand-in for it.
                if (b & 0xc0 == 0x80) {
                    if (utf8_left == 0) return; // a stray continuation
                    utf8_cp = (utf8_cp << 6) | (b & 0x3f);
                    utf8_left -= 1;
                    if (utf8_left == 0) glyph(standIn(utf8_cp));
                } else if (b & 0xe0 == 0xc0) {
                    utf8_cp = b & 0x1f;
                    utf8_left = 1;
                } else if (b & 0xf0 == 0xe0) {
                    utf8_cp = b & 0x0f;
                    utf8_left = 2;
                } else {
                    utf8_cp = b & 0x07;
                    utf8_left = 3;
                }
                return;
            }
            utf8_left = 0;
            glyph(if (b < font.first or b > font.last) '?' else b);
        },
    }
}

fn glyph(ch: u8) void {
    if (col == cols) newline();
    text[row][col] = ch;
    draw(col, row, ch);
    col += 1;
}

fn standIn(cp: u32) u8 {
    return switch (cp) {
        0x2010...0x2015, 0x2212 => '-', // dashes, minus
        0x2018, 0x2019 => '\'',
        0x201c, 0x201d => '"',
        0x2026 => '.', // ellipsis
        0x2022, 0x00b7 => '*', // bullets
        0x2190 => '<',
        0x2192 => '>',
        0x00d7 => 'x',
        0x2713, 0x2714, 0x2705 => 'v', // check marks
        0x00a0 => ' ',
        else => '?',
    };
}

fn newline() void {
    col = 0;
    if (row + 1 < rows) {
        row += 1;
    } else scroll();
}

/// Every row up by one, the last cleared, the screen redrawn from the
/// shadow: a screenful of write-combined stores, no reads.
fn scroll() void {
    for (1..rows) |r| text[r - 1] = text[r];
    @memset(&text[rows - 1], ' ');
    for (0..rows) |r| {
        for (0..cols) |c| draw(@intCast(c), @intCast(r), text[r][c]);
    }
}

/// One full redraw of the screen from the shadow, timed in cycles: what
/// a scroll costs, reported at attach so a slow framebuffer (trapped
/// MMIO under a hypervisor, an uncached mapping) shows itself.
pub fn redrawCycles() u64 {
    const t0 = arch.cpu.cycles();
    for (0..rows) |r| {
        for (0..cols) |c| draw(@intCast(c), @intCast(r), text[r][c]);
    }
    return arch.cpu.cycles() - t0;
}

fn draw(c: u32, r: u32, ch: u8) void {
    const bitmap = &font.glyphs[ch - font.first];
    var p: usize = @as(usize, r) * font.height * stride + @as(usize, c) * font.width;
    for (bitmap) |bits| {
        const line = pixels[p..][0..font.width];
        inline for (0..font.width) |x| line[x] = if (bits & (@as(u8, 0x80) >> x) != 0) fg else bg;
        p += stride;
    }
}
