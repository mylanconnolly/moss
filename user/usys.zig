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
    /// recv only: the badge of the cap the caller invoked.
    badge: u64 = 0,
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

/// Raw-word call/reply for proxies that forward messages verbatim.
pub fn callRaw(channel: u64, w: [4]u64, send_cap: u64) IpcResult {
    return syscall6(.call, channel, w[0], w[1], w[2], w[3], send_cap);
}

pub fn replyRaw(channel: u64, w: [4]u64, send_cap: u64) shared.Errno {
    return syscall6(.reply, channel, w[0], w[1], w[2], w[3], send_cap).err;
}

/// limits: kobj KB | user KB << 32 (0 = defaults); the child's budgets are
/// a slice of the caller's.
pub fn spawn(spawner: u64, image: shared.ImageId, arg: u64, chan: u64, flags: u64, limits: u64) IpcResult {
    return syscall6(.spawn, spawner, @intFromEnum(image), arg, chan, flags, limits);
}

pub fn kbLimits(kobj_kb: u64, user_kb: u64) u64 {
    return kobj_kb | (user_kb << 32);
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

/// mmio_map: data[0] = va, data[1] = bytes.
pub fn mmioMap(handle: u64) IpcResult {
    return syscall6(.mmio_map, handle, 0, 0, 0, 0, 0);
}

pub fn irqBind(handle: u64, notif: u64, offset: u64) shared.Errno {
    return @enumFromInt(syscall3(.irq_bind, handle, notif, offset));
}

pub fn irqAck(handle: u64, offset: u64) shared.Errno {
    return @enumFromInt(syscall3(.irq_ack, handle, offset, 0));
}

/// dma_alloc: data[0] = va, data[1] = device address.
pub fn dmaAlloc(pages: u64) IpcResult {
    return syscall6(.dma_alloc, pages, 0, 0, 0, 0, 0);
}

pub fn notifyBind(handle: u64) shared.Errno {
    return @enumFromInt(syscall3(.notify_bind, handle, 0, 0));
}

/// chan_mint: data[1] = the badged channel_b handle.
pub fn chanMint(chan_a: u64, badge: u64) IpcResult {
    return syscall6(.chan_mint, chan_a, badge, 0, 0, 0, 0);
}

/// Virtual counter ticks (EL0 access enabled by the kernel).
pub fn cycles() u64 {
    return asm volatile (
        \\isb
        \\mrs %[v], cntvct_el0
        : [v] "=r" (-> u64),
    );
}

pub fn cycleHz() u64 {
    return asm ("mrs %[v], cntfrq_el0"
        : [v] "=r" (-> u64),
    );
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

/// domain_list: data[0] = DomainRec count written into buf.
pub fn domainList(spawner_h: u64, buf: []u8) IpcResult {
    return syscall6(.domain_list, spawner_h, @intFromPtr(buf.ptr), buf.len, 0, 0, 0);
}

/// sysinfo: data[0] = pmem free bytes, data[1] = total bytes,
/// data[2] = online cores, data[3] = uptime ticks.
pub fn sysInfo(spawner_h: u64) IpcResult {
    return syscall6(.sysinfo, spawner_h, 0, 0, 0, 0, 0);
}

/// getrandom: fill buf (1..rng_max_request bytes) from the kernel CSPRNG.
/// bad_state until the entropy driver has seeded the pool.
pub fn getrandom(buf: []u8) shared.Errno {
    return @enumFromInt(syscall3(.getrandom, @intFromPtr(buf.ptr), buf.len, 0));
}

/// rng_seed: feed hardware entropy into the kernel pool (entropy cap).
pub fn rngSeed(entropy_h: u64, bytes: []const u8) shared.Errno {
    return @enumFromInt(syscall3(.rng_seed, entropy_h, @intFromPtr(bytes.ptr), bytes.len));
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
    var r6: u64 = undefined;
    asm volatile ("svc #0"
        : [r0] "={x0}" (r0),
          [r1] "={x1}" (r1),
          [r2] "={x2}" (r2),
          [r3] "={x3}" (r3),
          [r4] "={x4}" (r4),
          [r5] "={x5}" (r5),
          [r6] "={x6}" (r6),
        : [nr] "{x8}" (@intFromEnum(nr)),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
          [a3] "{x3}" (a3),
          [a4] "{x4}" (a4),
          [a5] "{x5}" (a5),
        : .{ .memory = true });
    return .{ .err = @enumFromInt(r0), .data = .{ r1, r2, r3, r4 }, .cap = r5, .badge = r6 };
}
