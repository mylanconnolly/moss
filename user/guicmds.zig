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
const workcmds = @import("workcmds.zig");
const mosslib = @import("mosslib");
const mshl = mosslib.mshl;
const Value = mshl.Value;
const font = shared.font8x16;

var display: u64 = 0; // the compositor channel (surface protocol + input)
var chan: u64 = 0; // the channel a session drives: `display`, or a trusted one
var log_h: u64 = 0;
var trust_token: u64 = 0; // the trusted-path token, if the host was given one

// Crash-isolation of `update` (opt-in `gui { isolate: true }`): the app's
// `update` runs in a worker domain, so a fault or panic in it kills only
// that domain — the runtime detects the dead worker, re-spawns it, drops
// the offending event, and carries on. `iso_src` is the reconstructed
// worker script (kept for re-spawn); `iso_conn` the live worker, if any.
var iso_conn: ?workcmds.Conn = null;
var iso_src: []const u8 = "";

pub fn setup(display_cap: u64, log: u64, secret: []const u8) void {
    display = display_cap;
    log_h = log;
    if (secret.len >= 8) trust_token = std.mem.readInt(u64, secret[0..8], .little);
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

// The font is the shared 8x16 bitmap, drawn at 2x with an EPX/Scale2x
// smoothing pass (`drawGlyph`): each source pixel becomes 2x2, and a
// diagonal edge rounds its corner instead of stair-stepping, so text is
// larger and far less blocky than a raw blit. A glyph cell is thus 16x32.
const fsw = font.width; //  8, source
const fsh = font.height; // 16, source
const gw = fsw * 2; // 16, drawn
const gh = fsh * 2; // 32, drawn

// A centred window on the 1024x768 scanout, with room to breathe.
const win_w = 680;
const win_h = 460;
const win_x = (1024 - win_w) / 2; // 172
const win_y = (768 - win_h) / 2; // 154

const pad = 24; // window inset for content

// Colours as X<<24 | R<<16 | G<<8 | B, so a screendump reads them as RGB.
const c_bg: u32 = 0x0016_1a2e; // a deep slate window ground
const c_fg: u32 = 0x00E0_E0E0; // label text
const c_title: u32 = 0x0066_99FF; // the title line
const c_rule: u32 = 0x0033_3d55; // the rule under the title
const c_btn: u32 = 0x0088_BBFF; // an unfocused button's label + outline
const c_btn_bg: u32 = 0x001e_2740; // an unfocused button's fill
const c_focus_bg: u32 = 0x0022_66CC; // the focused widget's highlight
const c_focus_fg: u32 = 0x00FF_FFFF;
const c_field_bg: u32 = 0x0022_2838; // an unfocused field's value box
const c_field_edge: u32 = 0x003a_445e; // a field/button box outline

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

fn putPx(x: usize, y: usize, word: u32) void {
    if (x < win_w and y < win_h) px[y * win_w + x] = word;
}

fn fillRect(x: usize, y: usize, w: usize, h: usize, word: u32) void {
    var yy = y;
    while (yy < y + h and yy < win_h) : (yy += 1) {
        var xx = x;
        while (xx < x + w and xx < win_w) : (xx += 1) px[yy * win_w + xx] = word;
    }
}

/// A `thick`-pixel outline around the rect (x, y, w, h).
fn strokeRect(x: usize, y: usize, w: usize, h: usize, word: u32, thick: usize) void {
    fillRect(x, y, w, thick, word); // top
    if (h > thick) fillRect(x, y + h - thick, w, thick, word); // bottom
    fillRect(x, y, thick, h, word); // left
    if (w > thick) fillRect(x + w - thick, y, thick, h, word); // right
}

/// Draw one glyph at (cx, cy), scaled 2x crisp: each source pixel becomes
/// a solid 2x2 block — no smoothing, so the letterforms stay sharp (a
/// clean pixel font, not blurred or rounded). The whole 16x32 cell is
/// painted, `on` pixels `fg` and the rest `bg` (no stale pixels behind).
fn drawGlyph(cx: usize, cy: usize, ch: u8, fg: u32, bg: u32) void {
    const g: usize = if (ch < font.first or ch > font.last) 0 else ch - font.first;
    const bmp = font.glyphs[g];
    var sy: usize = 0;
    while (sy < fsh) : (sy += 1) {
        const bits = bmp[sy];
        var sx: usize = 0;
        while (sx < fsw) : (sx += 1) {
            const word = if (bits & (@as(u8, 0x80) >> @intCast(sx)) != 0) fg else bg;
            const ox = cx + sx * 2;
            const oy = cy + sy * 2;
            putPx(ox, oy, word);
            putPx(ox + 1, oy, word);
            putPx(ox, oy + 1, word);
            putPx(ox + 1, oy + 1, word);
        }
    }
}

/// Draw a string at (x, y) with a foreground and background colour, one
/// 16x32 glyph cell per character, clipped to the window.
fn drawText(x: usize, y: usize, s: []const u8, fg: u32, bg: u32) void {
    for (s, 0..) |ch, i| {
        const cx = x + i * gw;
        if (cx + gw > win_w or y + gh > win_h) break;
        drawGlyph(cx, y, ch, fg, bg);
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
    var y: usize = pad;
    if (title.len > 0) {
        drawText(pad, y, title, c_title, c_bg);
        y += gh + 12;
        fillRect(pad, y, win_w - 2 * pad, 2, c_rule); // a rule under the title
        y += 20;
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
            drawText(pad, y, strField(rec, "text"), c_fg, c_bg);
            y += gh + 12;
        } else if (std.mem.eql(u8, kind, "button")) {
            // A padded, outlined box; filled and brightly outlined when
            // focused, a quiet fill otherwise — a button that reads as one.
            const label = strField(rec, "label");
            const bpx = 18; // horizontal padding inside the button
            const bpy = 8; // vertical padding
            const bw = label.len * gw + 2 * bpx;
            const bh = gh + 2 * bpy;
            const fill = if (focused) c_focus_bg else c_btn_bg;
            const edge = if (focused) c_focus_fg else c_field_edge;
            const ink = if (focused) c_focus_fg else c_btn;
            fillRect(pad, y, bw, bh, fill);
            strokeRect(pad, y, bw, bh, edge, 2);
            drawText(pad + bpx, y + bpy, label, ink, fill);
            if (n < focusables.len) {
                focusables[n] = .{ .id = strField(rec, "id"), .is_field = false };
                n += 1;
            }
            y += bh + 16;
        } else if (std.mem.eql(u8, kind, "field")) {
            // A label over a full-width, outlined value box holding the
            // live text (a cursor when focused). Password fields show dots.
            const label = strField(rec, "label");
            const id = strField(rec, "id");
            const fb = fieldFor(id, strField(rec, "value"));
            drawText(pad, y, label, c_fg, c_bg);
            y += gh + 6;
            const fpy = 8; // vertical padding inside the box
            const bh = gh + 2 * fpy;
            const bw = win_w - 2 * pad;
            const box_bg = if (focused) c_focus_bg else c_field_bg;
            fillRect(pad, y, bw, bh, box_bg);
            strokeRect(pad, y, bw, bh, if (focused) c_focus_fg else c_field_edge, 2);
            const tx = pad + 12;
            const ty = y + fpy;
            const secret = rec.get("secret") != null and (rec.get("secret").?).asBool();
            var shown: usize = fb.len;
            if (secret) {
                var dots: [64]u8 = undefined;
                const m = @min(fb.len, dots.len);
                for (0..m) |i| dots[i] = '*';
                drawText(tx, ty, dots[0..m], c_fg, box_bg);
                shown = m;
            } else {
                drawText(tx, ty, fb.buf[0..fb.len], c_fg, box_bg);
            }
            if (focused) drawText(tx + shown * gw, ty, "_", c_focus_fg, box_bg);
            if (n < focusables.len) {
                focusables[n] = .{ .id = id, .is_field = true };
                n += 1;
            }
            y += bh + 16;
        }
    }
    return n;
}

// ---------------------------------------------------- surface + input

/// Claim the trusted path: present the token and switch `chan` to the
/// badged channel the compositor mints, so surfaces made over it are the
/// login surface. False if there is no token or the compositor refuses.
fn attachTrusted() bool {
    if (trust_token == 0) return false;
    switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, display, .{ .attach_trusted = .{ .token = trust_token } }, 0)) {
        .ok => |ok| switch (ok.rep) {
            .trusted => {
                if (ok.cap == 0) return false;
                chan = ok.cap;
                return true;
            },
            else => return false,
        },
        .err => return false,
    }
}

fn openSurface() bool {
    const cs = switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, chan, .{ .create_surface = .{ .xy = shared.packPair(win_x, win_y), .wh = shared.packPair(win_w, win_h) } }, 0)) {
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
    return switch (usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .{ .commit = .{ .surface = surf, .xy = 0, .wh = shared.packPair(win_w, win_h) } }, 0)) {
        .ok => true,
        .err => false,
    };
}

fn closeSurface() void {
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .{ .destroy_surface = .{ .surface = surf } }, 0);
}

/// The next keystroke routed to our surface, or null if the channel died.
fn nextInput() ?u8 {
    return switch (usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .next_input, 0)) {
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

// ------------------------------------------------- crash-isolated update

/// Reconstruct `update` (a `fn [stateParam, evParam] body`) as a worker
/// script that reads `$in`: bind each param, by position, from the
/// `{ state, ev }` record the runtime sends, then run the body verbatim.
/// Only data crosses — no captures — so the worker is a pure function of
/// the pair, exactly the GUI-as-a-service contract. The two params are
/// bound from the input's fixed `state`/`ev` fields regardless of how the
/// app named them. Returns null if `update` is not the expected 2-arg
/// shape (then the caller runs it in-process, unisolated). Arena-held, so
/// it survives across re-spawns within this `gui` call.
fn buildUpdateSrc(it: *mshl.Interp, cl: *const mshl.Closure) mshl.Error!?[]const u8 {
    if (cl.params.len != 2) return null;
    const in_keys = [_][]const u8{ "state", "ev" };
    var s: std.ArrayList(u8) = .empty;
    for (cl.params, in_keys) |p, key| {
        try s.appendSlice(it.arena, "let ");
        try s.appendSlice(it.arena, p);
        try s.appendSlice(it.arena, " = $in.");
        try s.appendSlice(it.arena, key);
        try s.append(it.arena, '\n');
    }
    try s.appendSlice(it.arena, cl.src);
    return s.items;
}

/// The `{ state, ev }` record a worker update reads as `$in`.
fn wrapStateEv(it: *mshl.Interp, state: Value, ev: Value) mshl.Error!Value {
    const keys = try it.arena.alloc([]const u8, 2);
    keys[0] = "state";
    keys[1] = "ev";
    const vals = try it.arena.alloc(Value, 2);
    vals[0] = state;
    vals[1] = ev;
    return .{ .record = .{ .keys = keys, .vals = vals } };
}

/// Run `update state ev`. Isolated in a worker when one is live: a clean
/// reply is the new state; if the app's update misbehaves — raises an
/// error, or faults its whole domain — the runtime logs it, drops the
/// offending event, keeps the state as it was, and (on a dead domain)
/// re-spawns a fresh worker, so it survives and keeps rendering. That is
/// the let-it-crash contract: an app bug takes down only the worker.
/// With no worker (isolation off, or a re-spawn that failed) it runs
/// `update` in-process, the old behaviour.
fn callUpdate(it: *mshl.Interp, update: Value, state: Value, ev: Value) mshl.Error!Value {
    if (iso_conn) |c| {
        const in = try wrapStateEv(it, state, ev);
        const good: ?Value = switch (try workcmds.callConn(it, c, in)) {
            .value => |v| v,
            .raised, .crashed => null,
        };
        if (good) |v| return v;
        // The update misbehaved (raised, or faulted its domain). Tear the
        // worker down and start a fresh one — a runaway leaves the old
        // worker's heap spent, so we never reuse it — drop the offending
        // event, and keep the last good state. The runtime lives on.
        _ = usys.log(log_h, "gui: update crashed — recovering");
        workcmds.close(c);
        iso_conn = workcmds.spawnBlock(it, iso_src);
        if (iso_conn == null) _ = usys.log(log_h, "gui: could not re-spawn the update worker; running in-process");
        return state;
    }
    return it.callValue(update, &.{ state, ev }, null, null);
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
    const want_trusted = spec.get("trusted") != null and (spec.get("trusted").?).asBool();
    const want_isolate = spec.get("isolate") != null and (spec.get("isolate").?).asBool();

    // Crash-isolate `update` in a worker domain when asked and able: an
    // app fault then kills only the worker, not the display runtime. The
    // worker lives for the whole session; `callUpdate` re-spawns it if it
    // dies. Best-effort — no spawner, or a 2-arg `update` we cannot
    // reconstruct, and we run `update` in-process as before.
    iso_conn = null;
    if (want_isolate and workcmds.canSpawn()) {
        if (try buildUpdateSrc(it, update.func)) |src| {
            iso_src = src;
            iso_conn = workcmds.spawnBlock(it, iso_src);
            if (iso_conn == null) _ = usys.log(log_h, "gui: could not spawn the update worker; running in-process");
        }
    }
    defer if (iso_conn) |c| workcmds.close(c);

    // A `trusted: true` GUI is a login greeter: claim the trusted path so
    // the compositor makes this the login surface — the secure strip is
    // shown while it holds focus and its keystrokes reach nobody else. It
    // needs the boot-provisioned token (a `secret` give); without it the
    // compositor refuses, and so do we.
    chan = display;
    if (want_trusted) {
        if (!attachTrusted()) return it.fail("gui: the trusted path was refused (no token, or the wrong one)", .{});
    }

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
            state = try callUpdate(it, update, state, ev);
            if (isDone(state)) break;
        }
    }
    _ = usys.log(log_h, "gui: closed");
    return state;
}
