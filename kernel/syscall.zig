//! Syscall dispatch. Numbers and errnos live in shared/ (the IDL); the ABI
//! is x8 = number, x0..x5 = arguments, x0 = result.
//!
//! Authority comes from capabilities, not from being a process: sys_log
//! demands a debug_log cap from the caller's table, validated by slot,
//! generation, and type. A domain spawned without the grant cannot log,
//! full stop.

const std = @import("std");
const cap = @import("cap.zig");
const domain = @import("domain.zig");
const ipc = @import("ipc.zig");
const log = @import("log.zig");
const sched = @import("sched.zig");
const shared = @import("shared");
const trap = @import("trap.zig");

pub fn dispatch(frame: *trap.TrapFrame) void {
    const t = sched.thisCpu().current;
    const d: *domain.Domain = @ptrCast(@alignCast(t.user_ctx orelse {
        frame.regs[0] = errno(.nosys);
        return;
    }));
    const nr: shared.Syscall = @enumFromInt(frame.regs[8]);
    frame.regs[0] = switch (nr) {
        .log => sysLog(d, frame.regs[0], frame.regs[1], frame.regs[2]),
        .yield => blk: {
            sched.yield();
            break :blk errno(.ok);
        },
        .sleep => blk: {
            sched.sleep(@min(frame.regs[0], 60 * 10));
            break :blk errno(.ok);
        },
        .exit => sysExit(d, frame.regs[0]),
        .call => sysCall(d, frame),
        .recv => sysRecv(d, frame),
        .reply => sysReply(d, frame),
        .notify_create => sysNotifyCreate(d, frame),
        .notify_signal => sysNotifySignal(d, frame.regs[0], frame.regs[1]),
        .notify_wait => sysNotifyWait(d, frame),
        .shm_create => sysShmCreate(d, frame),
        .shm_map => sysShmMap(d, frame),
        .spawn => sysSpawn(d, frame),
        .chan_create => sysChanCreate(d, frame),
        .domain_stat => sysDomainStat(d, frame),
        .domain_destroy => sysDomainDestroy(d, frame.regs[0]),
        .watch_deaths => sysWatchDeaths(d, frame.regs[0]),
        .cap_drop => sysCapDrop(d, frame.regs[0]),
        _ => errno(.nosys),
    };
}

// ------------------------------------------------------- domain management

/// spawn(spawner, image, arg, chan, flags): create a domain from an
/// embedded image with exactly the named grants; returns a domain_ctl
/// handle. The caller's registered death-watch (if any) is signaled when
/// the child dies.
fn sysSpawn(d: *domain.Domain, frame: *trap.TrapFrame) u64 {
    const spawner_h: shared.Handle = @bitCast(frame.regs[0]);
    _ = d.captable.?.lookup(spawner_h, .spawner) orelse return errno(.bad_handle);
    const image = domain.imageById(frame.regs[1]) orelse return errno(.bad_arg);
    const name = if (std.enums.fromInt(shared.ImageId, frame.regs[1])) |id|
        @tagName(id)
    else
        "user";
    const flags = frame.regs[4];

    var manifest: domain.Manifest = .{
        .grant_debug_log = flags & shared.SpawnFlags.grant_log != 0,
        .grant_spawner = flags & shared.SpawnFlags.grant_spawner != 0,
        .arg = frame.regs[2],
        .auto_reap = true,
        .watcher = d.death_watch,
    };
    if (frame.regs[3] != 0) {
        const chan_h: shared.Handle = @bitCast(frame.regs[3]);
        if (flags & shared.SpawnFlags.chan_side_a != 0) {
            const obj = d.captable.?.lookup(chan_h, .channel_a) orelse return errno(.bad_handle);
            const ch: *ipc.Channel = @ptrFromInt(obj);
            ipc.refSide(ch, .a);
            manifest.grant_channel_a = ch;
        } else {
            const obj = d.captable.?.lookup(chan_h, .channel_b) orelse return errno(.bad_handle);
            const ch: *ipc.Channel = @ptrFromInt(obj);
            ipc.refSide(ch, .b);
            manifest.grant_channel_b = ch;
        }
    }

    const child = domain.spawn(name, image, manifest) catch |e| {
        if (manifest.grant_channel_a) |ch| ipc.unrefSide(ch, .a);
        if (manifest.grant_channel_b) |ch| ipc.unrefSide(ch, .b);
        return errno(switch (e) {
            domain.Error.QuotaExceeded => .no_space,
            domain.Error.BadImage => .bad_arg,
            else => .no_space,
        });
    };
    _ = child.ctl_refs.fetchAdd(1, .acq_rel);
    const h = d.captable.?.insert(.domain_ctl, @intFromPtr(child)) orelse {
        _ = child.ctl_refs.fetchSub(1, .acq_rel);
        domain.destroy(child);
        return errno(.no_space);
    };
    frame.regs[1] = @bitCast(h);
    return errno(.ok);
}

fn sysChanCreate(d: *domain.Domain, frame: *trap.TrapFrame) u64 {
    const ch = ipc.createChannel(1, 1) catch return errno(.no_space);
    const ha = d.captable.?.insert(.channel_a, @intFromPtr(ch)) orelse {
        ipc.unrefSide(ch, .a);
        ipc.unrefSide(ch, .b);
        return errno(.no_space);
    };
    const hb = d.captable.?.insert(.channel_b, @intFromPtr(ch)) orelse {
        _ = d.captable.?.remove(ha);
        ipc.unrefSide(ch, .a);
        ipc.unrefSide(ch, .b);
        return errno(.no_space);
    };
    frame.regs[1] = @bitCast(ha);
    frame.regs[2] = @bitCast(hb);
    return errno(.ok);
}

fn sysDomainStat(d: *domain.Domain, frame: *trap.TrapFrame) u64 {
    const h: shared.Handle = @bitCast(frame.regs[0]);
    const obj = d.captable.?.lookup(h, .domain_ctl) orelse return errno(.bad_handle);
    const child: *domain.Domain = @ptrFromInt(obj);
    frame.regs[1] = switch (child.state) {
        .alive => @intFromEnum(shared.DomainState.alive),
        .dying => @intFromEnum(shared.DomainState.dying),
        else => @intFromEnum(shared.DomainState.dead),
    };
    frame.regs[2] = child.exit_code;
    return errno(.ok);
}

fn sysDomainDestroy(d: *domain.Domain, handle_bits: u64) u64 {
    const h: shared.Handle = @bitCast(handle_bits);
    const obj = d.captable.?.lookup(h, .domain_ctl) orelse return errno(.bad_handle);
    domain.destroy(@ptrFromInt(obj));
    return errno(.ok);
}

fn sysWatchDeaths(d: *domain.Domain, handle_bits: u64) u64 {
    const h: shared.Handle = @bitCast(handle_bits);
    const obj = d.captable.?.lookup(h, .notification) orelse return errno(.bad_handle);
    const n: *ipc.Notification = @ptrFromInt(obj);
    d.death_watch = n;
    ipc.bindNotification(n, sched.thisCpu().current);
    return errno(.ok);
}

fn sysCapDrop(d: *domain.Domain, handle_bits: u64) u64 {
    const h: shared.Handle = @bitCast(handle_bits);
    if (h.slot >= cap.slots) return errno(.bad_handle);
    const e = &d.captable.?.entries[h.slot];
    if (e.generation != h.generation or e.cap_type == .empty) return errno(.bad_handle);
    const ct = e.cap_type;
    const obj = e.object;
    _ = d.captable.?.remove(h);
    ipc.releaseCap(ct, obj);
    return errno(.ok);
}

// --------------------------------------------------------------- channels

fn sysCall(d: *domain.Domain, frame: *trap.TrapFrame) u64 {
    const handle: shared.Handle = @bitCast(frame.regs[0]);
    const obj = d.captable.?.lookup(handle, .channel_b) orelse return errno(.bad_handle);
    const ch: *ipc.Channel = @ptrFromInt(obj);

    var msg: ipc.Msg = .{ .data = frame.regs[1..5].* };
    if (frame.regs[5] != 0) {
        if (attachCap(d, frame.regs[5], &msg)) |e| return errno(e);
    }
    const res = ipc.call(ch, msg);
    if (res.err != .ok) {
        dropAttachment(res.msg);
        return errno(res.err);
    }
    deliver(d, res.msg, frame);
    return errno(.ok);
}

fn sysRecv(d: *domain.Domain, frame: *trap.TrapFrame) u64 {
    const handle: shared.Handle = @bitCast(frame.regs[0]);
    const obj = d.captable.?.lookup(handle, .channel_a) orelse return errno(.bad_handle);
    const ch: *ipc.Channel = @ptrFromInt(obj);
    var msg: ipc.Msg = .{};
    const e = ipc.recv(ch, &msg);
    if (e != .ok) return errno(e);
    deliver(d, msg, frame);
    return errno(.ok);
}

fn sysReply(d: *domain.Domain, frame: *trap.TrapFrame) u64 {
    const handle: shared.Handle = @bitCast(frame.regs[0]);
    const obj = d.captable.?.lookup(handle, .channel_a) orelse return errno(.bad_handle);
    const ch: *ipc.Channel = @ptrFromInt(obj);
    var msg: ipc.Msg = .{ .data = frame.regs[1..5].* };
    if (frame.regs[5] != 0) {
        if (attachCap(d, frame.regs[5], &msg)) |e| return errno(e);
    }
    return errno(ipc.reply(ch, msg));
}

/// Resolve a handle the sender wants to attach; the object gains a ref that
/// the receiver's new cap (or a failed delivery) later releases. Only
/// shareable object caps may travel for now.
fn attachCap(d: *domain.Domain, handle_bits: u64, msg: *ipc.Msg) ?shared.Errno {
    const handle: shared.Handle = @bitCast(handle_bits);
    if (d.captable.?.lookup(handle, .shm)) |obj| {
        ipc.refShm(@ptrFromInt(obj));
        msg.cap_type = @intFromEnum(cap.CapType.shm);
        msg.cap_obj = obj;
        return null;
    }
    if (d.captable.?.lookup(handle, .notification)) |obj| {
        ipc.refNotification(@ptrFromInt(obj));
        msg.cap_type = @intFromEnum(cap.CapType.notification);
        msg.cap_obj = obj;
        return null;
    }
    if (d.captable.?.lookup(handle, .channel_b)) |obj| {
        ipc.refSide(@ptrFromInt(obj), .b);
        msg.cap_type = @intFromEnum(cap.CapType.channel_b);
        msg.cap_obj = obj;
        return null;
    }
    if (d.captable.?.lookup(handle, .channel_a)) |obj| {
        ipc.refSide(@ptrFromInt(obj), .a);
        msg.cap_type = @intFromEnum(cap.CapType.channel_a);
        msg.cap_obj = obj;
        return null;
    }
    return .denied;
}

/// Hand a received message to user registers, translating any attached cap
/// into the receiving domain's table.
fn deliver(d: *domain.Domain, msg: ipc.Msg, frame: *trap.TrapFrame) void {
    frame.regs[1..5].* = msg.data;
    frame.regs[5] = 0;
    if (msg.cap_type != 0) {
        const ct: cap.CapType = @enumFromInt(msg.cap_type);
        if (d.captable.?.insert(ct, msg.cap_obj)) |h| {
            frame.regs[5] = @bitCast(h);
        } else {
            dropAttachment(msg); // table full: the grant is dropped, not leaked
        }
    }
}

fn dropAttachment(msg: ipc.Msg) void {
    if (msg.cap_type != 0) {
        ipc.releaseCap(@enumFromInt(msg.cap_type), msg.cap_obj);
    }
}

// ---------------------------------------------------- notifications & shm

fn sysNotifyCreate(d: *domain.Domain, frame: *trap.TrapFrame) u64 {
    const n = ipc.createNotification() catch return errno(.no_space);
    const h = d.captable.?.insert(.notification, @intFromPtr(n)) orelse {
        ipc.unrefNotification(n);
        return errno(.no_space);
    };
    frame.regs[1] = @bitCast(h);
    return errno(.ok);
}

fn sysNotifySignal(d: *domain.Domain, handle_bits: u64, bits: u64) u64 {
    const handle: shared.Handle = @bitCast(handle_bits);
    const obj = d.captable.?.lookup(handle, .notification) orelse return errno(.bad_handle);
    ipc.signal(@ptrFromInt(obj), bits);
    return errno(.ok);
}

fn sysNotifyWait(d: *domain.Domain, frame: *trap.TrapFrame) u64 {
    const handle: shared.Handle = @bitCast(frame.regs[0]);
    const obj = d.captable.?.lookup(handle, .notification) orelse return errno(.bad_handle);
    const res = ipc.wait(@ptrFromInt(obj));
    frame.regs[1] = res.bits;
    return errno(res.err);
}

fn sysShmCreate(d: *domain.Domain, frame: *trap.TrapFrame) u64 {
    const npages = frame.regs[0];
    if (npages == 0 or npages > ipc.shm_max_pages) return errno(.bad_arg);
    const s = ipc.createShm(@intCast(npages)) orelse return errno(.no_space);
    const h = d.captable.?.insert(.shm, @intFromPtr(s)) orelse {
        ipc.unrefShm(s);
        return errno(.no_space);
    };
    frame.regs[1] = @bitCast(h);
    return errno(.ok);
}

fn sysShmMap(d: *domain.Domain, frame: *trap.TrapFrame) u64 {
    const handle: shared.Handle = @bitCast(frame.regs[0]);
    const obj = d.captable.?.lookup(handle, .shm) orelse return errno(.bad_handle);
    const s: *ipc.Shm = @ptrFromInt(obj);
    const va = domain.mapShm(d, s) catch return errno(.no_space);
    frame.regs[1] = va;
    return errno(.ok);
}

fn sysLog(d: *domain.Domain, handle_bits: u64, ptr: u64, len: u64) u64 {
    const handle: shared.Handle = @bitCast(handle_bits);
    _ = d.captable.?.lookup(handle, .debug_log) orelse return errno(.bad_handle);
    if (len == 0 or len > 256) return errno(.bad_arg);
    if (!userRangeOk(d, ptr, len)) return errno(.fault);
    // No PAN on ARMv8.0 (and TTBR0 is live during this exception), so the
    // kernel can read the buffer through the user mapping directly.
    const bytes = @as([*]const u8, @ptrFromInt(ptr))[0..len];
    log.print("[{s}] {s}\n", .{ d.name, bytes });
    return errno(.ok);
}

fn sysExit(d: *domain.Domain, code: u64) noreturn {
    d.exit_code = code;
    domain.destroy(d); // marks this very thread exited
    sched.exit();
}

fn userRangeOk(d: *domain.Domain, ptr: u64, len: u64) bool {
    const end = ptr +% len;
    if (end < ptr) return false;
    const in_image = ptr >= shared.user_image_base and end <= d.image_end_va;
    const in_stack = ptr >= d.stack_base and end <= d.stack_top;
    const in_shm = ptr >= domain.shm_window_base and end <= d.shm_map_next;
    return in_image or in_stack or in_shm;
}

fn errno(e: shared.Errno) u64 {
    return @intFromEnum(e);
}
