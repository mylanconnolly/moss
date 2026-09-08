//! gui — the mshl GUI runtime, a hosted command family (like net/fs/http)
//! wired into a host that holds a `display` cap. A GUI is a *service*
//! written as two pure mshl functions and a declarative view:
//!
//!   gui {
//!     init:   { count: 0 }
//!     view:   (fn [state] { { kind: column, children: [
//!               { kind: label,  text: $"count ($state.count)" }
//!               { kind: button, id: "inc",  label: "increment" }
//!               { kind: button, id: "quit", label: "quit" }
//!             ] } })
//!     update: (fn [state, ev] { match $ev.id {
//!               "inc"  => { $state | merge { count: ($state.count + 1) } }
//!               "quit" => { $state | merge { done: true } }
//!               _      => $state
//!             } })
//!   }
//!
//! The runtime owns the surface: it renders `view state`, routes the
//! keyboard (Tab moves focus between the focusable widgets, Enter fires
//! the focused one), and on each fire calls `update state {id}`, threads
//! the returned state forward, and re-renders. The app never loops and
//! never blocks — it is a pure function of state and event, so it is a
//! supervised, crash-only, fabric-shippable service in the making (only
//! data — the view, the event id, the state — ever crosses). `update`
//! returning a state with `done: true` closes the window; `gui` answers
//! with the final state. Keyboard-only for now (no pointer yet).

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const mosslib = @import("mosslib");
const mshl = mosslib.mshl;
const Value = mshl.Value;
const font = shared.font8x16;

var display: u64 = 0; // the compositor channel (surface protocol + input)
var log_h: u64 = 0;

pub fn setup(display_cap: u64, log: u64) void {
    display = display_cap;
    log_h = log;
}

/// Whether the host holds a display — `gui` is offered only then.
pub fn on() bool {
    return display != 0;
}

pub fn signature(name: []const u8) ?mshl.Signature {
    if (std.mem.eql(u8, name, "gui")) {
        return .{ .params = &.{.{ .name = "spec", .shape = .record }}, .input = .{ .optional = .record }, .ret = .any };
    }
    return null;
}

// ------------------------------------------------------------ rendering

const gw = font.width; //  8
const gh = font.height; // 16

// A centred window on the 640x480 scanout.
const win_w = 400;
const win_h = 240;
const win_x = 120;
const win_y = 120;

// Colours as X<<24 | R<<16 | G<<8 | B, so a screendump reads them as RGB.
const c_bg: u32 = 0x0016_1a2e; // a deep slate window ground
const c_fg: u32 = 0x00E0_E0E0; // label text
const c_title: u32 = 0x0066_99FF; // the title line
const c_btn: u32 = 0x0088_BBFF; // an unfocused button
const c_focus_bg: u32 = 0x0022_66CC; // the focused widget's highlight
const c_focus_fg: u32 = 0x00FF_FFFF;
const c_field_bg: u32 = 0x0022_2838; // an unfocused field's value box

var px: [*]volatile u32 = undefined; // the mapped surface, win_w*win_h
var surf: u64 = 0;

// A focusable widget: its id, and whether it is a text field (which
// eats typing) or a button (which fires on Enter).
const Focus = struct { id: []const u8, is_field: bool };
var focusables: [16]Focus = undefined;

// The runtime owns the live text of each field (keyed by id), seeded from
// the view's `value` when the field first appears. The app's `update`
// sees the committed text only when a button fires (in the event's
// `fields`), so it stays a pure function of coarse events, not keystrokes.
const max_fields = 8;
const FieldBuf = struct {
    used: bool = false,
    id: [32]u8 = undefined,
    id_len: usize = 0,
    buf: [64]u8 = undefined,
    len: usize = 0,
};
var field_bufs: [max_fields]FieldBuf = @splat(.{});

fn resetFields() void {
    field_bufs = @splat(.{});
}

/// The edit buffer for a field id, created (seeded from `seed`) on first sight.
fn fieldFor(id: []const u8, seed: []const u8) *FieldBuf {
    for (&field_bufs) |*f| {
        if (f.used and std.mem.eql(u8, f.id[0..f.id_len], id)) return f;
    }
    for (&field_bufs) |*f| {
        if (!f.used) {
            f.used = true;
            f.id_len = @min(id.len, f.id.len);
            @memcpy(f.id[0..f.id_len], id[0..f.id_len]);
            f.len = @min(seed.len, f.buf.len);
            @memcpy(f.buf[0..f.len], seed[0..f.len]);
            return f;
        }
    }
    return &field_bufs[0]; // more than max_fields: reuse the first slot
}

fn fieldAppend(id: []const u8, ch: u8) void {
    const f = fieldFor(id, "");
    if (f.len < f.buf.len) {
        f.buf[f.len] = ch;
        f.len += 1;
    }
}

fn fieldBackspace(id: []const u8) void {
    const f = fieldFor(id, "");
    if (f.len > 0) f.len -= 1;
}

fn fillAll(word: u32) void {
    for (0..win_w * win_h) |i| px[i] = word;
}

fn fillRect(x: usize, y: usize, w: usize, h: usize, word: u32) void {
    var yy = y;
    while (yy < y + h and yy < win_h) : (yy += 1) {
        var xx = x;
        while (xx < x + w and xx < win_w) : (xx += 1) px[yy * win_w + xx] = word;
    }
}

/// Blit a string at (x, y) with a foreground and background colour.
/// Clipped to the window; a character out of the font's range is blank.
fn drawText(x: usize, y: usize, s: []const u8, fg: u32, bg: u32) void {
    for (s, 0..) |ch, i| {
        const cx = x + i * gw;
        if (cx + gw > win_w or y + gh > win_h) break;
        const g: usize = if (ch < font.first or ch > font.last) 0 else ch - font.first;
        const bitmap = font.glyphs[g];
        for (0..gh) |gy| {
            const bits = bitmap[gy];
            const base = (y + gy) * win_w + cx;
            for (0..gw) |gx| {
                px[base + gx] = if (bits & (@as(u8, 0x80) >> @intCast(gx)) != 0) fg else bg;
            }
        }
    }
}

/// Render one view tree. Fills the window, draws the title and each child
/// of the (single, column) layout, highlighting the focused button, and
/// returns the focusable widgets' ids in order (into `ids_buf`).
fn strField(rec: mshl.Record, key: []const u8) []const u8 {
    return if (rec.get(key)) |v| (if (v == .str) v.str else "") else "";
}

/// Render one view tree into `focusables`, highlight the focused widget,
/// and return the number of focusable widgets.
fn renderTree(tree: Value, title: []const u8, focus: usize) usize {
    fillAll(c_bg);
    var y: usize = 12;
    if (title.len > 0) {
        drawText(12, y, title, c_title, c_bg);
        y += gh + 8;
    }
    var n: usize = 0;
    const children: []const Value = kids: {
        if (tree != .record) break :kids &.{};
        const c = tree.record.get("children") orelse break :kids &.{};
        break :kids if (c == .list) c.list else &.{};
    };
    for (children) |child| {
        if (child != .record) continue;
        const rec = child.record;
        const kind = strField(rec, "kind");
        const focused = n < focusables.len and n == focus;
        if (std.mem.eql(u8, kind, "label")) {
            drawText(12, y, strField(rec, "text"), c_fg, c_bg);
            y += gh + 4;
        } else if (std.mem.eql(u8, kind, "button")) {
            const label = strField(rec, "label");
            if (focused) {
                fillRect(8, y - 3, label.len * gw + 8, gh + 6, c_focus_bg);
                drawText(12, y, label, c_focus_fg, c_focus_bg);
            } else {
                drawText(12, y, label, c_btn, c_bg);
            }
            if (n < focusables.len) {
                focusables[n] = .{ .id = strField(rec, "id"), .is_field = false };
                n += 1;
            }
            y += gh + 10;
        } else if (std.mem.eql(u8, kind, "field")) {
            const label = strField(rec, "label");
            const id = strField(rec, "id");
            const fb = fieldFor(id, strField(rec, "value"));
            // "label:" then a boxed value area holding the live text (a
            // cursor when focused). Password fields show dots.
            drawText(12, y, label, c_fg, c_bg);
            const vx = 12 + (label.len + 1) * gw;
            const box_bg = if (focused) c_focus_bg else c_field_bg;
            fillRect(vx - 2, y - 2, win_w - vx - 8, gh + 4, box_bg);
            const secret = rec.get("secret") != null and (rec.get("secret").?).asBool();
            if (secret) {
                var dots: [64]u8 = undefined;
                const m = @min(fb.len, dots.len);
                for (0..m) |i| dots[i] = '*';
                drawText(vx, y, dots[0..m], c_fg, box_bg);
            } else {
                drawText(vx, y, fb.buf[0..fb.len], c_fg, box_bg);
            }
            if (focused) drawText(vx + fb.len * gw, y, "_", c_focus_fg, box_bg);
            if (n < focusables.len) {
                focusables[n] = .{ .id = id, .is_field = true };
                n += 1;
            }
            y += gh + 10;
        }
    }
    return n;
}

// ---------------------------------------------------- surface + input

fn openSurface() bool {
    const cs = switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, display, .{ .create_surface = .{ .xy = shared.packPair(win_x, win_y), .wh = shared.packPair(win_w, win_h) } }, 0)) {
        .ok => |ok| ok,
        .err => return false,
    };
    surf = switch (cs.rep) {
        .created => |c| c.surface,
        else => return false,
    };
    if (cs.cap == 0) return false;
    const m = usys.shmMap(cs.cap);
    if (m.err != .ok) return false;
    px = @ptrFromInt(m.data[0]);
    return true;
}

fn commitSurface() bool {
    return switch (usys.callTyped(shared.GpuReq, shared.GpuResp, display, .{ .commit = .{ .surface = surf, .xy = 0, .wh = shared.packPair(win_w, win_h) } }, 0)) {
        .ok => true,
        .err => false,
    };
}

fn closeSurface() void {
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, display, .{ .destroy_surface = .{ .surface = surf } }, 0);
}

/// The next keystroke routed to our surface, or null if the channel died.
fn nextInput() ?u8 {
    return switch (usys.callTyped(shared.GpuReq, shared.GpuResp, display, .next_input, 0)) {
        .ok => |rep| switch (rep) {
            .input => |x| @intCast(x.ch & 0xff),
            else => 0,
        },
        .err => null,
    };
}

// ------------------------------------------------------------ the app

/// The event for a fired button: `{ id, fields: { <field id>: <text> } }`.
/// The field values are the runtime's live buffers — this is where the
/// text a user typed reaches the app, and the only place it does.
fn mkEvent(it: *mshl.Interp, id: []const u8) mshl.Error!Value {
    var nf: usize = 0;
    for (field_bufs) |f| {
        if (f.used) nf += 1;
    }
    const fkeys = try it.arena.alloc([]const u8, nf);
    const fvals = try it.arena.alloc(Value, nf);
    var i: usize = 0;
    for (field_bufs) |f| {
        if (!f.used) continue;
        fkeys[i] = try it.arena.dupe(u8, f.id[0..f.id_len]);
        fvals[i] = .{ .str = try it.arena.dupe(u8, f.buf[0..f.len]) };
        i += 1;
    }
    const fields = Value{ .record = .{ .keys = fkeys, .vals = fvals } };

    const keys = try it.arena.alloc([]const u8, 2);
    keys[0] = "id";
    keys[1] = "fields";
    const vals = try it.arena.alloc(Value, 2);
    vals[0] = .{ .str = try it.arena.dupe(u8, id) };
    vals[1] = fields;
    return .{ .record = .{ .keys = keys, .vals = vals } };
}

fn isDone(state: Value) bool {
    if (state != .record) return false;
    const d = state.record.get("done") orelse return false;
    return d.asBool();
}

pub fn call(it: *mshl.Interp, name: []const u8, args: []const Value, input: ?Value) mshl.Error!?Value {
    if (!std.mem.eql(u8, name, "gui")) return null;
    const spec: mshl.Record = if (args.len > 0 and args[0] == .record)
        args[0].record
    else if (input != null and input.? == .record)
        input.?.record
    else
        return it.fail("gui: a record {{ init, update, view }} expected", .{});

    const view = spec.get("view") orelse return it.fail("gui: `view` (a fn) is required", .{});
    const update = spec.get("update") orelse return it.fail("gui: `update` (a fn) is required", .{});
    if (view != .func or update != .func) return it.fail("gui: `view` and `update` must be functions", .{});
    var state = spec.get("init") orelse Value.nothing;
    const title = if (spec.get("title")) |t| (if (t == .str) t.str else "") else "";

    if (!openSurface()) return it.fail("gui: cannot open a surface", .{});
    defer closeSurface();
    resetFields();

    var focus: usize = 0;
    var announced = false;
    while (true) {
        const tree = try it.callValue(view, &.{state}, null, null);
        const nfocus = renderTree(tree, title, focus);
        if (nfocus > 0 and focus >= nfocus) focus = nfocus - 1;
        if (!commitSurface()) return it.fail("gui: commit failed", .{});
        if (!announced) {
            _ = usys.log(log_h, "gui: ready");
            announced = true;
        }

        // Wait for a key. Tab moves focus; a printable key or backspace
        // edits the focused field; Enter fires a focused button (with the
        // fields' text) or advances past a focused field. Each break
        // re-renders — the buffer, the focus, or the new state.
        var fired: ?[]const u8 = null;
        input: while (true) {
            const ch = nextInput() orelse return it.fail("gui: the display channel closed", .{});
            const cur: ?Focus = if (nfocus > 0) focusables[focus] else null;
            switch (ch) {
                '\t' => {
                    if (nfocus > 0) focus = (focus + 1) % nfocus;
                    break :input;
                },
                '\n' => {
                    if (cur) |c| {
                        if (c.is_field) {
                            focus = (focus + 1) % nfocus; // advance past a field
                        } else {
                            fired = c.id; // a button submits
                        }
                        break :input;
                    }
                },
                8 => { // backspace
                    if (cur) |c| if (c.is_field) {
                        fieldBackspace(c.id);
                        break :input;
                    };
                },
                else => {
                    if (ch >= 32 and ch < 127) {
                        if (cur) |c| if (c.is_field) {
                            fieldAppend(c.id, ch);
                            break :input;
                        };
                    }
                },
            }
        }
        if (fired) |id| {
            const ev = try mkEvent(it, id);
            state = try it.callValue(update, &.{ state, ev }, null, null);
            if (isDone(state)) break;
        }
    }
    _ = usys.log(log_h, "gui: closed");
    return state;
}
