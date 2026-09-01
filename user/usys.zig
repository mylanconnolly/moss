//! Userspace syscall wrappers. ABI: x8 = number, x0..x5 args, x0 = result
//! (a shared.Errno value). This is the seed of the Phase 5 runtime library.

const shared = @import("shared");

pub fn log(handle: u64, msg: []const u8) shared.Errno {
    return @enumFromInt(syscall3(.log, handle, @intFromPtr(msg.ptr), msg.len));
}

pub fn sleep(ticks: u64) void {
    _ = syscall3(.sleep, ticks, 0, 0);
}

pub fn yield() void {
    _ = syscall3(.yield, 0, 0, 0);
}

pub fn exit(code: u64) noreturn {
    _ = syscall3(.exit, code, 0, 0);
    unreachable;
}

pub const IpcResult = struct {
    err: shared.Errno,
    data: [4]u64,
    cap: u64,
};

/// Synchronous call: send a typed message (+ optional cap), block for the
/// typed reply. This is the client-side stub: encode/decode come straight
/// from the protocol types in shared/.
pub fn callTyped(
    comptime Req: type,
    comptime Rep: type,
    channel: u64,
    req: Req,
    send_cap: u64,
) union(enum) { ok: Rep, err: shared.Errno } {
    const words = shared.encodeMsg(Req, req);
    const r = syscall6(.call, channel, words[0], words[1], words[2], words[3], send_cap);
    if (r.err != .ok) return .{ .err = r.err };
    const rep = shared.decodeMsg(Rep, r.data) orelse return .{ .err = .bad_arg };
    return .{ .ok = rep };
}

/// Like callTyped but also surfaces a cap attached to the reply.
pub fn callTypedCap(
    comptime Req: type,
    comptime Rep: type,
    channel: u64,
    req: Req,
    send_cap: u64,
) union(enum) { ok: struct { rep: Rep, cap: u64 }, err: shared.Errno } {
    const words = shared.encodeMsg(Req, req);
    const r = syscall6(.call, channel, words[0], words[1], words[2], words[3], send_cap);
    if (r.err != .ok) return .{ .err = r.err };
    const rep = shared.decodeMsg(Rep, r.data) orelse return .{ .err = .bad_arg };
    return .{ .ok = .{ .rep = rep, .cap = r.cap } };
}

pub fn recvMsg(channel: u64) IpcResult {
    return syscall6(.recv, channel, 0, 0, 0, 0, 0);
}

pub fn spawn(spawner: u64, image: shared.ImageId, arg: u64, chan: u64, flags: u64) IpcResult {
    return syscall6(.spawn, spawner, @intFromEnum(image), arg, chan, flags, 0);
}

/// chan_create: data[0] = side A handle, data[1] = side B handle.
pub fn chanCreate() IpcResult {
    return syscall6(.chan_create, 0, 0, 0, 0, 0, 0);
}

/// domain_stat: data[0] = shared.DomainState, data[1] = exit code.
pub fn domainStat(ctl: u64) IpcResult {
    return syscall6(.domain_stat, ctl, 0, 0, 0, 0, 0);
}

pub fn domainDestroy(ctl: u64) shared.Errno {
    return @enumFromInt(syscall3(.domain_destroy, ctl, 0, 0));
}

pub fn watchDeaths(notif: u64) shared.Errno {
    return @enumFromInt(syscall3(.watch_deaths, notif, 0, 0));
}

pub fn capDrop(handle: u64) shared.Errno {
    return @enumFromInt(syscall3(.cap_drop, handle, 0, 0));
}

pub fn replyTyped(comptime Rep: type, channel: u64, rep: Rep, send_cap: u64) shared.Errno {
    const words = shared.encodeMsg(Rep, rep);
    return syscall6(.reply, channel, words[0], words[1], words[2], words[3], send_cap).err;
}

pub fn notifyCreate() IpcResult {
    return syscall6(.notify_create, 0, 0, 0, 0, 0, 0);
}

pub fn notifySignal(handle: u64, bits: u64) shared.Errno {
    return @enumFromInt(syscall3(.notify_signal, handle, bits, 0));
}

pub fn notifyWait(handle: u64) IpcResult {
    return syscall6(.notify_wait, handle, 0, 0, 0, 0, 0);
}

pub fn shmCreate(pages: u64) IpcResult {
    return syscall6(.shm_create, pages, 0, 0, 0, 0, 0);
}

pub fn shmMap(handle: u64) IpcResult {
    return syscall6(.shm_map, handle, 0, 0, 0, 0, 0);
}

fn syscall3(nr: shared.Syscall, a0: u64, a1: u64, a2: u64) u64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> u64),
        : [nr] "{x8}" (@intFromEnum(nr)),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
        : .{ .memory = true });
}

fn syscall6(nr: shared.Syscall, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) IpcResult {
    var r0: u64 = undefined;
    var r1: u64 = undefined;
    var r2: u64 = undefined;
    var r3: u64 = undefined;
    var r4: u64 = undefined;
    var r5: u64 = undefined;
    asm volatile ("svc #0"
        : [r0] "={x0}" (r0),
          [r1] "={x1}" (r1),
          [r2] "={x2}" (r2),
          [r3] "={x3}" (r3),
          [r4] "={x4}" (r4),
          [r5] "={x5}" (r5),
        : [nr] "{x8}" (@intFromEnum(nr)),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
          [a3] "{x3}" (a3),
          [a4] "{x4}" (a4),
          [a5] "{x5}" (a5),
        : .{ .memory = true });
    return .{ .err = @enumFromInt(r0), .data = .{ r1, r2, r3, r4 }, .cap = r5 };
}
