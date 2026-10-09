//! The compositor drill's client: it opens two windowed surfaces at
//! different positions in different colours, overlapping, so the display
//! server has to composite them — each in its place, the later (top) one
//! winning where they overlap, the ground showing between them. The host
//! screendumps and checks a pixel in each region.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");

comptime {
    asm (usys.imageHeader("compcli"));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

// B8G8R8X8 words (a screendump reads them back as RGB).
const red: u32 = 0x00CC_2222; // RGB(0xCC,0x22,0x22)
const green: u32 = 0x0022_CC22; // RGB(0x22,0xCC,0x22)

var disp: u64 = 0;

/// Create a w x h surface at (x,y), fill it with `colour`, and commit it.
fn window(x: u32, y: u32, w: u32, h: u32, colour: u32) bool {
    const cs = switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, disp, .{ .create_surface = .{ .xy = shared.packPair(x, y), .wh = shared.packPair(w, h) } }, 0)) {
        .ok => |ok| ok,
        .err => return false,
    };
    const surface = switch (cs.rep) {
        .created => |c| c.surface,
        else => return false,
    };
    if (cs.cap == 0) return false;
    const m = usys.shmMap(cs.cap);
    if (m.err != .ok) return false;
    const px: [*]volatile u32 = @ptrFromInt(m.data[0]);
    for (0..@as(usize, w) * h) |i| px[i] = colour;
    return switch (usys.callTyped(shared.GpuReq, shared.GpuResp, disp, .{ .commit = .{ .surface = surface, .xy = 0, .wh = shared.packPair(w, h) } }, 0)) {
        .ok => |rep| rep == .ok,
        .err => false,
    };
}

fn call(channel: u64, req: shared.GpuReq) shared.GpuResp {
    return switch (usys.callTyped(shared.GpuReq, shared.GpuResp, channel, req, 0)) {
        .ok => |rep| rep,
        .err => usys.exit(190),
    };
}
fn demand(ok: bool) void {
    if (!ok) usys.exit(191);
}
/// A second registered client channel (another badge), kept for the
/// not-the-owner checks.
var other_chan: u64 = 0;
fn other_disp() u64 {
    if (other_chan == 0) {
        other_chan = switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, disp, .register, 0)) {
            .ok => |rep| rep.cap,
            .err => usys.exit(192),
        };
        demand(other_chan != 0);
    }
    return other_chan;
}
fn probeSurface() u64 {
    const reply = switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, disp, .{ .create_surface = .{ .xy = 0, .wh = shared.packPair(1, 1) } }, 0)) {
        .ok => |rep| rep,
        .err => usys.exit(192),
    };
    demand(reply.rep == .created and reply.cap != 0);
    _ = usys.capDrop(reply.cap);
    return reply.rep.created.surface;
}
fn title(surface: u64, text: []const u8) void {
    const words = shared.strToWords(text);
    demand(call(disp, .{ .set_title = .{ .surface = surface, .a = words[0], .b = words[1] } }) == .ok);
}
fn snapshot() u64 {
    const reply = call(disp, .menu_info);
    demand(reply == .menu and reply.menu.token != 0);
    return reply.menu.token;
}
/// Real IPC authorization/lifecycle checks, before the pixel-compositing scene.
fn menuProbe(control: u64, log_h: u64) void {
    demand(control != 0);
    // The control endpoint is call/reply only: no surface, no parked read.
    demand(call(control, .{ .create_surface = .{ .xy = shared.packPair(10, 10), .wh = shared.packPair(64, 64) } }) == .gpu_err);
    demand(call(control, .next_input) == .gpu_err);
    const a = probeSurface();
    title(a, "Menu Probe");
    const close_key = shared.keyboard.close_window;
    demand(call(disp, .{ .set_menu = .{ .surface = a, .profile = 999, .enabled = 0 } }) == .gpu_err);
    demand(call(disp, .{ .set_menu = .{ .surface = a, .profile = @intFromEnum(shared.menus.Profile.editor), .enabled = shared.menus.bit(close_key) } }) == .ok);
    const first = snapshot();
    const other = switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, disp, .register, 0)) {
        .ok => |rep| rep,
        .err => usys.exit(193),
    };
    demand(other.rep == .registered and other.cap != 0);
    demand(call(other.cap, .{ .set_menu = .{ .surface = a, .profile = @intFromEnum(shared.menus.Profile.editor), .enabled = 0 } }) == .gpu_err);
    _ = usys.capDrop(other.cap);
    demand(call(disp, .{ .menu_invoke = .{ .token = first, .key = close_key } }) == .gpu_err);
    demand(call(disp, .{ .menu_restore = .{ .token = first } }) == .gpu_err);
    demand(call(control, .{ .menu_invoke = .{ .token = first, .key = shared.keyboard.save_document } }) == .gpu_err);
    demand(call(control, .{ .menu_invoke = .{ .token = first, .key = 'x' } }) == .gpu_err);
    const popup = probeSurface();
    demand(snapshot() == first); // titleless popup retains application identity
    demand(call(disp, .{ .menu_bar = .{ .surface = popup } }) == .gpu_err);
    demand(call(control, .{ .menu_bar = .{ .surface = popup } }) == .ok);
    // A custom menu: the owner publishes a title and two items (one label
    // in two parts), the bar reads them back by token, and the compositor
    // routes only the keys the mask enables.
    const custom = @intFromEnum(shared.menus.Profile.custom);
    const title_words = shared.strToWords("Probe");
    demand(call(other_disp(), .{ .set_menu_title = .{ .meta = shared.menus.packSlot(a, 0), .a = title_words[0], .b = title_words[1] } }) == .gpu_err); // not the owner
    demand(call(disp, .{ .set_menu_title = .{ .meta = shared.menus.packSlot(a, 0), .a = title_words[0], .b = title_words[1] } }) == .ok);
    demand(call(disp, .{ .set_menu_title = .{ .meta = shared.menus.packSlot(a, 9), .a = title_words[0], .b = title_words[1] } }) == .gpu_err); // no such slot
    // A label longer than 16 bytes travels in two parts, split at 16.
    const l0 = shared.strToWords("Increment count ");
    const l1 = shared.strToWords("by one, now");
    demand(call(disp, .{ .set_menu_item = .{ .meta = shared.menus.packItemMeta(.{ .surface = @intCast(a), .index = 0, .part = 0, .menu = 0, .key = shared.menus.appItemKey(0), .sub = 0 }), .a = l0[0], .b = l0[1] } }) == .ok);
    demand(call(disp, .{ .set_menu_item = .{ .meta = shared.menus.packItemMeta(.{ .surface = @intCast(a), .index = 0, .part = 1, .menu = 0, .key = shared.menus.appItemKey(0), .sub = 0 }), .a = l1[0], .b = l1[1] } }) == .ok);
    const sc = shared.strToWords("Cmd S");
    demand(call(disp, .{ .set_menu_item = .{ .meta = shared.menus.packItemMeta(.{ .surface = @intCast(a), .index = 0, .part = shared.menus.part_shortcut, .menu = 0, .key = shared.menus.appItemKey(0), .sub = 0 }), .a = sc[0], .b = sc[1] } }) == .ok);
    const l2 = shared.strToWords("Disabled");
    demand(call(disp, .{ .set_menu_item = .{ .meta = shared.menus.packItemMeta(.{ .surface = @intCast(a), .index = 1, .part = 0, .menu = 0, .key = shared.menus.appItemKey(1), .sub = 0 }), .a = l2[0], .b = l2[1] } }) == .ok);
    demand(call(disp, .{ .set_menu = .{ .surface = a, .profile = custom, .enabled = ~shared.menus.bit(shared.menus.appItemKey(1)) } }) == .ok);
    const custom_token = snapshot();
    demand(custom_token != 0);
    switch (call(control, .{ .menu_slot = .{ .meta = shared.menus.packSlot(custom_token, 0) } })) {
        .menu_title => |t| {
            var tb: [24]u8 = undefined;
            demand(std.mem.eql(u8, shared.wordsToStr(&tb, .{ t.a, t.b, 0 }), "Probe"));
        },
        else => usys.exit(194),
    }
    var label: [40]u8 = undefined;
    var label_len: usize = 0;
    for ([_]u1{ 0, 1 }) |part| switch (call(control, .{ .menu_item = .{ .meta = shared.menus.packItemMeta(.{ .surface = @intCast(custom_token), .index = 0, .part = part, .menu = 0, .key = 0, .sub = 0 }) } })) {
        .menu_item => |it| {
            const meta = shared.menus.unpackItemMeta(it.meta);
            demand(meta.surface == 1 and meta.key == shared.menus.appItemKey(0) and meta.sub == 0);
            var lb: [24]u8 = undefined;
            const s = shared.wordsToStr(&lb, .{ it.a, it.b, 0 });
            @memcpy(label[label_len .. label_len + s.len], s);
            label_len += s.len;
        },
        else => usys.exit(195),
    };
    demand(std.mem.eql(u8, label[0..label_len], "Increment count by one, now"));
    switch (call(control, .{ .menu_item = .{ .meta = shared.menus.packItemMeta(.{ .surface = @intCast(custom_token), .index = 0, .part = shared.menus.part_shortcut, .menu = 0, .key = 0, .sub = 0 }) } })) {
        .menu_item => |it| {
            var sb: [24]u8 = undefined;
            demand(std.mem.eql(u8, shared.wordsToStr(&sb, .{ it.a, it.b, 0 }), "Cmd S"));
        },
        else => usys.exit(197),
    }
    // A schema that shrinks: truncating at 1 leaves item 1 unused.
    demand(call(disp, .{ .set_menu_item = .{ .meta = shared.menus.packItemMeta(.{ .surface = @intCast(a), .index = 1, .part = shared.menus.part_truncate, .menu = 0, .key = 0, .sub = 0 }), .a = 0, .b = 0 } }) == .ok);
    const after_truncate = snapshot();
    switch (call(control, .{ .menu_item = .{ .meta = shared.menus.packItemMeta(.{ .surface = @intCast(after_truncate), .index = 1, .part = 0, .menu = 0, .key = 0, .sub = 0 }) } })) {
        .menu_item => |it| demand(shared.menus.unpackItemMeta(it.meta).surface == 0),
        else => usys.exit(198),
    }
    demand(call(control, .{ .menu_invoke = .{ .token = after_truncate, .key = shared.menus.appItemKey(1) } }) == .gpu_err); // disabled in the mask
    demand(call(control, .{ .menu_invoke = .{ .token = after_truncate, .key = shared.keyboard.save_document } }) == .gpu_err); // not the custom profile's
    // Back to a catalog profile: the schema is gone with it.
    demand(call(disp, .{ .set_menu = .{ .surface = a, .profile = @intFromEnum(shared.menus.Profile.editor), .enabled = shared.menus.bit(close_key) } }) == .ok);
    switch (call(control, .{ .menu_slot = .{ .meta = shared.menus.packSlot(snapshot(), 0) } })) {
        .menu_title => |t| demand(t.a == 0 and t.b == 0),
        else => usys.exit(196),
    }
    // The ground is chrome authority too: a window cannot repaint the desktop.
    demand(call(disp, .{ .set_ground = .{ .word = 0x101010 } }) == .gpu_err);
    demand(call(control, .{ .set_ground = .{ .word = 0x1000000 } }) == .gpu_err); // not a colour
    demand(call(control, .{ .set_ground = .{ .word = 0x202830 } }) == .ok);
    title(popup, "Second Probe");
    const second = snapshot();
    demand(second != first);
    demand(call(control, .{ .menu_restore = .{ .token = first } }) == .gpu_err);
    demand(call(control, .{ .menu_invoke = .{ .token = first, .key = close_key } }) == .gpu_err);
    demand(call(disp, .{ .destroy_surface = .{ .surface = popup } }) == .ok);
    const third = snapshot();
    demand(third != first and third != second);
    demand(call(control, .{ .menu_restore = .{ .token = second } }) == .gpu_err);
    demand(call(control, .{ .menu_restore = .{ .token = third } }) == .ok);
    // A busy owner may hold one accepted command; a second cannot overwrite it.
    demand(call(control, .{ .menu_invoke = .{ .token = third, .key = close_key } }) == .ok);
    demand(call(control, .{ .menu_invoke = .{ .token = third, .key = close_key } }) == .gpu_err);
    demand(call(disp, .{ .set_menu = .{ .surface = a, .profile = @intFromEnum(shared.menus.Profile.editor), .enabled = 0 } }) == .ok);
    demand(snapshot() != third);
    demand(call(control, .{ .menu_invoke = .{ .token = third, .key = close_key } }) == .gpu_err);
    demand(call(control, .{ .menu_invoke = .{ .token = snapshot(), .key = close_key } }) == .gpu_err);
    demand(call(disp, .{ .destroy_surface = .{ .surface = a } }) == .ok);
    const reused = probeSurface();
    demand(reused == a);
    title(reused, "Reused Probe");
    demand(call(control, .{ .menu_restore = .{ .token = first } }) == .gpu_err);
    demand(call(control, .{ .menu_restore = .{ .token = third } }) == .gpu_err);
    demand(call(disp, .{ .destroy_surface = .{ .surface = reused } }) == .ok);
    _ = usys.log(log_h, "comp: menu authority, disabled actions and stale tokens verified");
}

export fn umain(log_h: u64, chan_h: u64, _: u64) callconv(.c) noreturn {
    const setup = boot.take(chan_h);
    disp = setup.cap(.display);
    if (disp == 0) {
        _ = usys.log(log_h, "compcli: no display channel");
        usys.exit(169);
    }
    menuProbe(setup.cap(.display_control), log_h);
    // Two overlapping windows; the second (green) stacks over the first
    // (red) where they meet.
    if (!window(40, 40, 300, 200, red)) usys.exit(180);
    if (!window(200, 150, 300, 200, green)) usys.exit(181);
    _ = usys.log(log_h, "comp: surfaces up");
    usys.sleepMs(4000); // hold for the host's screendump
    usys.exit(0);
}
