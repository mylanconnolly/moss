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
const pmem = @import("pmem.zig");
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
    /// Badge for the granted channel_b cap (view identity etc.).
    grant_channel_b_badge: u64 = 0,
    /// Read-only blob copied into the address space; its va/len arrive in
    /// x3/x4 at entry (the boot filesystem image, service configs, ...).
    grant_blob: ?[]const u8 = null,
    /// Faults become messages on this channel (side A held by the
    /// supervisor); without one, a faulting domain is killed outright.
    supervisor: ?*ipc.Channel = null,
    /// Opaque argument delivered in x2 at entry (role tags etc.).
    arg: u64 = 0,
    /// Grant spawn authority (root and init hold this; services never do).
    grant_spawner: bool = false,
    /// Driver grants: an MMIO window and/or an SPI range. Handle slots
    /// follow the fixed insert order (log, channel, spawner, mmio, irq).
    grant_mmio: ?struct { base: u64, pages: u64 } = null,
    grant_irq: ?struct { base: u32, count: u32 } = null,
    /// Parent in the domain tree (the spawning domain, for syscall spawns).
    parent: ?*Domain = null,
    /// Kernel reaper auto-finishes teardown and signals the watcher; off
    /// for kernel-test-driver domains that finish manually.
    auto_reap: bool = false,
    /// Notification signaled (with this domain's slot bit) when it dies.
    watcher: ?*ipc.Notification = null,
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
    blob_va: u64 = 0,
    blob_len: u64 = 0,
    shm_map_next: u64 = shm_window_base,
    supervisor: ?*ipc.Channel = null,
    threads_alive: std.atomic.Value(u32) = .init(0),
    exit_code: u64 = 0,
    auto_reap: bool = false,
    watcher: ?*ipc.Notification = null,
    /// This domain's registered death-watch (for domains IT spawns).
    death_watch: ?*ipc.Notification = null,
    /// Outstanding domain_ctl caps; a dead slot is reusable only at zero.
    ctl_refs: std.atomic.Value(u32) = .init(0),
    parent: ?*Domain = null,
};

var domains: [max_domains]Domain = @splat(.{});
var next_domain_id: u32 = 1;

/// Embedded user images, indexed by shared.ImageId. Registered by kmain.
var images: []const []const u8 = &.{};

pub fn init(image_table: []const []const u8) void {
    sched.user_thread_reaped = &onThreadReaped;
    ipc.domain_ctl_release = &onCtlReleased;
    images = image_table;
}

pub fn imageById(id: u64) ?[]const u8 {
    if (id >= images.len) return null;
    return images[@intCast(id)];
}

fn onCtlReleased(obj: u64) void {
    const d: *Domain = @ptrFromInt(obj);
    _ = d.ctl_refs.fetchSub(1, .acq_rel);
}

pub fn slotIndex(d: *const Domain) u6 {
    return @intCast((@intFromPtr(d) - @intFromPtr(&domains[0])) / @sizeOf(Domain));
}

/// The reaper: finishes teardown of drained auto-reap domains outside any
/// syscall context, then signals whoever watches for the death.
pub fn startReaper() void {
    _ = sched.spawn("reaper", reaperLoop, 0, .{}) catch @panic("spawn reaper");
}

fn reaperLoop(_: u64) void {
    while (true) {
        sched.sleep(1);
        for (&domains) |*d| {
            // Children must finish first: their credits cascade into the
            // parent's accounts, which the parent's teardown verifies.
            if (d.state == .dying and d.auto_reap and drained(d) and !hasUnfinishedChildren(d)) {
                finishTeardown(d);
                if (d.watcher) |n| {
                    d.watcher = null;
                    ipc.signal(n, @as(u64, 1) << slotIndex(d));
                    ipc.unrefNotification(n);
                }
            }
        }
    }
}

fn hasUnfinishedChildren(d: *const Domain) bool {
    for (&domains) |*c| {
        if (c.parent == d and (c.state == .alive or c.state == .dying)) return true;
    }
    return false;
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
    errdefer abortSpawn(d);
    d.name = name;
    d.kobj = .{ .limit = manifest.kobj_limit };
    d.user_mem = .{ .limit = manifest.user_limit };
    if (manifest.parent) |p| {
        d.parent = p;
        d.kobj.parent = &p.kobj;
        d.user_mem.parent = &p.user_mem;
    }

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
        const h = table.insertBadged(.channel_b, @intFromPtr(ch), manifest.grant_channel_b_badge) orelse
            return Error.CapTableFull;
        d.init_handle2 = @bitCast(h);
    }
    if (manifest.grant_spawner) {
        _ = table.insert(.spawner, 0) orelse return Error.CapTableFull;
    }
    if (manifest.grant_mmio) |m| {
        std.debug.assert(m.base % mem.page_size == 0 and m.pages < (1 << 16));
        _ = table.insert(.mmio, m.base | (m.pages << 48)) orelse return Error.CapTableFull;
    }
    if (manifest.grant_irq) |i| {
        _ = table.insert(.irq, @as(u64, i.base) | (@as(u64, i.count) << 32)) orelse
            return Error.CapTableFull;
    }
    if (manifest.grant_blob) |blob| {
        const blob_base = d.shm_map_next;
        var boff: u64 = 0;
        while (boff < blob.len) : (boff += mem.page_size) {
            const page = kalloc.allocPage(&d.user_mem) catch return Error.QuotaExceeded;
            const n = @min(blob.len - boff, mem.page_size);
            @memcpy(page[0..n], blob[boff..][0..n]);
            mmu.mapUserPage(
                d.ttbr0_pa,
                blob_base + boff,
                mem.virtToPhys(@intFromPtr(page)),
                .rodata,
                &d.kobj,
            ) catch return Error.QuotaExceeded;
        }
        d.shm_map_next = blob_base + mem.alignUp(blob.len, mem.page_size);
        d.blob_va = blob_base;
        d.blob_len = blob.len;
    }
    d.init_arg = manifest.arg;
    d.supervisor = manifest.supervisor;
    d.auto_reap = manifest.auto_reap;
    d.watcher = manifest.watcher;
    if (manifest.watcher) |n| ipc.refNotification(n);

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

/// Unwind a partially-built domain when spawn fails: everything allocated
/// so far returns, and the accounts (and their parents) balance again.
fn abortSpawn(d: *Domain) void {
    if (d.captable) |ct| {
        kalloc.freePage(&d.kobj, @ptrCast(ct));
        d.captable = null;
    }
    if (d.ttbr0_pa != 0) {
        mmu.destroyUserSpace(d.ttbr0_pa, &d.user_mem, &d.kobj, d.asid);
        d.ttbr0_pa = 0;
    }
    if (d.watcher) |n| {
        d.watcher = null;
        ipc.unrefNotification(n);
    }
    std.debug.assert(d.kobj.balance() == 0 and d.user_mem.balance() == 0);
    d.state = .unused;
}

/// The single revocation: mark the domain dying, kill its threads, and
/// release every cap it held — closing channel sides, which is what
/// delivers peer_dead to whoever is blocked on the other end. Threads
/// running on other cores die at their next preemption; once drained()
/// reports true, finishTeardown() reclaims the rest.
pub fn destroy(d: *Domain) void {
    if (d.state != .alive) return;
    d.state = .dying;
    // The subtree dies with the parent: one revocation, transitively.
    for (&domains) |*c| {
        if (c.parent == d and c.state == .alive) destroy(c);
    }
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

/// Map an MMIO window (device attributes, unowned: teardown must never
/// hand MMIO addresses to the frame allocator).
pub fn mapMmio(d: *Domain, base_pa: u64, pages: u64) !u64 {
    const base = d.shm_map_next;
    for (0..pages) |i| {
        try mmu.mapUserPageTagged(
            d.ttbr0_pa,
            base + i * mem.page_size,
            base_pa + i * mem.page_size,
            .device,
            &d.kobj,
            false,
        );
    }
    d.shm_map_next = base + pages * mem.page_size;
    return base;
}

/// DMA grant: physically contiguous, zeroed, owned pages; returns the VA
/// and the device address (== physical until an IOMMU arrives — the API
/// shape is the IOMMU's).
pub fn mapDma(d: *Domain, npages: u64) !struct { va: u64, dev: u64 } {
    const pa = pmem.allocContiguous(@intCast(npages)) orelse return Error.OutOfFrames;
    errdefer pmem.freeContiguous(pa, @intCast(npages));
    try d.user_mem.charge(npages * mem.page_size);
    errdefer d.user_mem.credit(npages * mem.page_size);
    const bytes = mem.physToPtr([*]u8, pa);
    @memset(bytes[0 .. npages * mem.page_size], 0);
    const base = d.shm_map_next;
    for (0..npages) |i| {
        try mmu.mapUserPage(
            d.ttbr0_pa,
            base + i * mem.page_size,
            pa + i * mem.page_size,
            .data,
            &d.kobj,
        );
    }
    d.shm_map_next = base + npages * mem.page_size;
    return .{ .va = base, .dev = pa };
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
    _ = ipc.call(ch, msg, 0);
    // Reached only if the supervisor is already gone (peer_dead): nobody is
    // left to decide, so the domain dies the direct way.
    destroy(d);
    sched.exit();
}

fn userThreadEntry(arg: u64) void {
    const d: *Domain = @ptrFromInt(arg);
    enterUser(d.entry_va, d.stack_top, .{
        d.init_handle, d.init_handle2, d.init_arg, d.blob_va, d.blob_len,
    });
}

fn enterUser(entry: u64, sp: u64, args: [5]u64) noreturn {
    asm volatile (
        \\msr daifset, #0xf
        \\msr elr_el1, %[e]
        \\msr sp_el0, %[s]
        \\msr spsr_el1, xzr
        \\mov x0, %[a0]
        \\mov x1, %[a1]
        \\mov x2, %[a2]
        \\mov x3, %[a3]
        \\mov x4, %[a4]
        \\eret
        :
        : [e] "r" (entry),
          [s] "r" (sp),
          [a0] "r" (args[0]),
          [a1] "r" (args[1]),
          [a2] "r" (args[2]),
          [a3] "r" (args[3]),
          [a4] "r" (args[4]),
        : .{ .x0 = true, .x1 = true, .x2 = true, .x3 = true, .x4 = true, .memory = true });
    unreachable;
}

/// The system boot blob (bootfs archive), grantable via SpawnFlags.
var system_blob: []const u8 = &.{};

pub fn setSystemBlob(blob: []const u8) void {
    system_blob = blob;
}

pub fn systemBlob() []const u8 {
    return system_blob;
}
