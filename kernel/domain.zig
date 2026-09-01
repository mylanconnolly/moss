//! Domains: the unit of spawn, quota, sandboxing, and teardown.
//!
//! A domain owns a user address space (TTBR0 tree, tagged by ASID), a
//! capability table, its threads, and two quota accounts — kernel objects
//! (page tables, cap table, kernel stacks) and user memory (image + stack
//! pages). Spawning starts from a blank address space plus an explicit
//! manifest; there is no ambient authority to inherit. Teardown is one
//! revocation: every thread dies, every page returns, and both accounts are
//! verified back to zero.

const std = @import("std");
const cap = @import("cap.zig");
const ipc = @import("ipc.zig");
const kalloc = @import("kalloc.zig");
const log = @import("log.zig");
const mem = @import("mem.zig");
const mmu = @import("mmu.zig");
const sched = @import("sched.zig");
const shared = @import("shared");

const max_domains = 16;
const user_stack_pages = 4;
const user_stack_top: u64 = 0x800_0000; // 128MB, far above the image

/// Shared-memory mappings land here, bump-allocated per domain.
pub const shm_window_base: u64 = 0x1000_0000;

pub const Error = error{
    NoDomainSlots,
    BadImage,
    OutOfFrames,
    QuotaExceeded,
    NoThreadSlots,
    CapTableFull,
};

pub const State = enum {
    unused,
    alive,
    dying,
    dead,
};

/// The unit file, the sandbox, and (later) the remote-spawn request: what a
/// domain may consume and what it holds. Nothing not named here is granted.
pub const Manifest = struct {
    kobj_limit: usize = 1 << 20,
    user_limit: usize = 1 << 20,
    grant_debug_log: bool = false,
    /// Grant one channel end (its handle arrives in x1 at entry).
    grant_channel_a: ?*ipc.Channel = null,
    grant_channel_b: ?*ipc.Channel = null,
    /// Faults become messages on this channel (side A held by the
    /// supervisor); without one, a faulting domain is killed outright.
    supervisor: ?*ipc.Channel = null,
    /// Opaque argument delivered in x2 at entry (role tags etc.).
    arg: u64 = 0,
};

pub const Domain = struct {
    state: State = .unused,
    id: u32 = 0,
    asid: u16 = 0,
    name: []const u8 = "",
    kobj: kalloc.Account = .{ .limit = 0 },
    user_mem: kalloc.Account = .{ .limit = 0 },
    ttbr0_pa: u64 = 0,
    captable: ?*cap.Table = null,
    entry_va: u64 = 0,
    image_end_va: u64 = 0,
    stack_base: u64 = 0,
    stack_top: u64 = 0,
    init_handle: u64 = 0,
    init_handle2: u64 = 0,
    init_arg: u64 = 0,
    shm_map_next: u64 = shm_window_base,
    supervisor: ?*ipc.Channel = null,
    threads_alive: std.atomic.Value(u32) = .init(0),
    exit_code: u64 = 0,
};

var domains: [max_domains]Domain = @splat(.{});
var next_domain_id: u32 = 1;

pub fn init() void {
    sched.user_thread_reaped = &onThreadReaped;
}

fn onThreadReaped(ctx: *anyopaque) void {
    const d: *Domain = @ptrCast(@alignCast(ctx));
    _ = d.threads_alive.fetchSub(1, .acq_rel);
}

/// Spawn a domain from a flat MOSS image and a manifest: blank address
/// space, image + stack mapped W^X, cap table populated only with what the
/// manifest grants, one thread started at the image entry.
pub fn spawn(name: []const u8, image: []const u8, manifest: Manifest) Error!*Domain {
    const d = allocSlot() orelse return Error.NoDomainSlots;
    errdefer d.state = .unused;
    d.name = name;
    d.kobj = .{ .limit = manifest.kobj_limit };
    d.user_mem = .{ .limit = manifest.user_limit };

    // Header check.
    if (image.len < @sizeOf(shared.UserImageHeader)) return Error.BadImage;
    var header: shared.UserImageHeader = undefined;
    @memcpy(std.mem.asBytes(&header), image[0..@sizeOf(shared.UserImageHeader)]);
    if (header.magic != shared.UserImageHeader.expected_magic) return Error.BadImage;
    if (header.text_size > header.mem_size or header.load_size > header.mem_size)
        return Error.BadImage;
    if (header.load_size < image.len) return Error.BadImage;
    if (header.mem_size > (64 << 20)) return Error.BadImage;

    // Address space root.
    const root_page = try kalloc.allocPage(&d.kobj);
    d.ttbr0_pa = mem.virtToPhys(@intFromPtr(root_page));

    // Image pages: copy from the blob (zero-filled past load_size for BSS),
    // text pages mapped R+X, the rest RW.
    const base = shared.user_image_base;
    var off: u64 = 0;
    while (off < header.mem_size) : (off += mem.page_size) {
        const page = try kalloc.allocPage(&d.user_mem);
        if (off < image.len) {
            const n = @min(image.len - off, mem.page_size);
            @memcpy(page[0..n], image[off..][0..n]);
        }
        const perms: mmu.UserPerms = if (off < header.text_size) .code else .data;
        mmu.mapUserPage(
            d.ttbr0_pa,
            base + off,
            mem.virtToPhys(@intFromPtr(page)),
            perms,
            &d.kobj,
        ) catch return Error.QuotaExceeded;
    }
    d.entry_va = base + @sizeOf(shared.UserImageHeader);
    d.image_end_va = base + header.mem_size;

    // User stack.
    d.stack_top = user_stack_top;
    d.stack_base = user_stack_top - user_stack_pages * mem.page_size;
    var sp = d.stack_base;
    while (sp < d.stack_top) : (sp += mem.page_size) {
        const page = try kalloc.allocPage(&d.user_mem);
        mmu.mapUserPage(
            d.ttbr0_pa,
            sp,
            mem.virtToPhys(@intFromPtr(page)),
            .data,
            &d.kobj,
        ) catch return Error.QuotaExceeded;
    }

    // Capability table: only what the manifest names.
    const ct_page = try kalloc.allocPage(&d.kobj);
    const table: *cap.Table = @ptrCast(@alignCast(ct_page));
    table.init();
    d.captable = table;
    if (manifest.grant_debug_log) {
        const h = table.insert(.debug_log, 0) orelse return Error.CapTableFull;
        d.init_handle = @bitCast(h);
    }
    if (manifest.grant_channel_a) |ch| {
        const h = table.insert(.channel_a, @intFromPtr(ch)) orelse return Error.CapTableFull;
        d.init_handle2 = @bitCast(h);
    } else if (manifest.grant_channel_b) |ch| {
        const h = table.insert(.channel_b, @intFromPtr(ch)) orelse return Error.CapTableFull;
        d.init_handle2 = @bitCast(h);
    }
    d.init_arg = manifest.arg;
    d.supervisor = manifest.supervisor;

    d.state = .alive;
    d.threads_alive.store(1, .release);
    _ = sched.spawn(name, userThreadEntry, @intFromPtr(d), .{
        .user_ttbr0 = d.ttbr0_pa,
        .asid = d.asid,
        .user_ctx = d,
        .captable = table,
        .stack_account = &d.kobj,
    }) catch |e| {
        d.threads_alive.store(0, .release);
        return switch (e) {
            sched.Error.NoThreadSlots => Error.NoThreadSlots,
            sched.Error.OutOfFrames => Error.OutOfFrames,
            sched.Error.QuotaExceeded => Error.QuotaExceeded,
        };
    };
    return d;
}

/// The single revocation: mark the domain dying, kill its threads, and
/// release every cap it held — closing channel sides, which is what
/// delivers peer_dead to whoever is blocked on the other end. Threads
/// running on other cores die at their next preemption; once drained()
/// reports true, finishTeardown() reclaims the rest.
pub fn destroy(d: *Domain) void {
    if (d.state != .alive) return;
    d.state = .dying;
    const freed = sched.destroyThreadsOf(d);
    if (freed > 0) _ = d.threads_alive.fetchSub(freed, .acq_rel);
    // Threads are gone (or marked dead); now the authority dies with them.
    for (&d.captable.?.entries) |*e| {
        if (e.cap_type != .empty) {
            ipc.releaseCap(e.cap_type, e.object);
            e.cap_type = .empty;
            e.generation +%= 1;
        }
    }
    // A supervised domain counts as a live client of its fault channel.
    if (d.supervisor) |ch| {
        d.supervisor = null;
        ipc.unrefSide(ch, .b);
    }
}

pub fn drained(d: *const Domain) bool {
    return d.threads_alive.load(.acquire) == 0;
}

/// Reclaim address space, page tables, and cap table; verify both quota
/// accounts return to zero. Call only after destroy() and drained().
pub fn finishTeardown(d: *Domain) void {
    std.debug.assert(d.state == .dying and drained(d));
    mmu.destroyUserSpace(d.ttbr0_pa, &d.user_mem, &d.kobj, d.asid);
    kalloc.freePage(&d.kobj, @ptrCast(d.captable.?));
    d.captable = null;
    const kobj_left = d.kobj.balance();
    const user_left = d.user_mem.balance();
    if (kobj_left != 0 or user_left != 0) {
        std.debug.panic("domain {s}: leak — kobj={d} user={d}", .{
            d.name, kobj_left, user_left,
        });
    }
    d.state = .dead;
}

fn allocSlot() ?*Domain {
    for (&domains, 0..) |*d, i| {
        if (d.state == .unused or d.state == .dead) {
            d.* = .{ .id = next_domain_id, .asid = @intCast(i + 1), .state = .unused };
            next_domain_id += 1;
            return d;
        }
    }
    return null;
}

/// Kernel-thread entry for a domain's initial thread: drop to EL0 at the
/// image entry, with the manifest's initial handle (or 0) in x0.
/// Map an shm object into the calling domain's window; the mapping is
/// tagged unowned so teardown leaves the frames to the shm object.
pub fn mapShm(d: *Domain, s: *ipc.Shm) !u64 {
    const base = d.shm_map_next;
    for (0..s.npages) |i| {
        try mmu.mapUserPageTagged(
            d.ttbr0_pa,
            base + i * mem.page_size,
            s.pages[i],
            .data,
            &d.kobj,
            false,
        );
    }
    d.shm_map_next = base + s.npages * mem.page_size;
    return base;
}

/// Fault-as-message: park the faulting thread as a caller on the supervisor
/// channel; the supervisor's verdict is domain teardown, so the call only
/// ever completes by the thread being destroyed. Returns false when the
/// domain has no supervisor (caller kills the domain instead).
pub fn reportFaultToSupervisor(d: *Domain, esr: u64, far: u64, elr: u64) bool {
    const ch = d.supervisor orelse return false;
    const msg: ipc.Msg = .{
        .data = shared.encodeMsg(shared.FaultMsg, .{
            .fault = .{ .esr = esr, .far = far, .elr = elr },
        }),
    };
    _ = ipc.call(ch, msg);
    // Reached only if the supervisor is already gone (peer_dead): nobody is
    // left to decide, so the domain dies the direct way.
    destroy(d);
    sched.exit();
}

fn userThreadEntry(arg: u64) void {
    const d: *Domain = @ptrFromInt(arg);
    enterUser(d.entry_va, d.stack_top, d.init_handle, d.init_handle2, d.init_arg);
}

fn enterUser(entry: u64, sp: u64, arg0: u64, arg1: u64, arg2: u64) noreturn {
    asm volatile (
        \\msr daifset, #0xf
        \\msr elr_el1, %[e]
        \\msr sp_el0, %[s]
        \\msr spsr_el1, xzr
        \\mov x0, %[a0]
        \\mov x1, %[a1]
        \\mov x2, %[a2]
        \\eret
        :
        : [e] "r" (entry),
          [s] "r" (sp),
          [a0] "r" (arg0),
          [a1] "r" (arg1),
          [a2] "r" (arg2),
        : .{ .x0 = true, .x1 = true, .x2 = true, .memory = true });
    unreachable;
}
