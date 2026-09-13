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
