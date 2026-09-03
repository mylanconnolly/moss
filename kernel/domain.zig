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
const its = @import("its.zig");
const kalloc = @import("kalloc.zig");
const log = @import("log.zig");
const mem = @import("mem.zig");
const mmu = @import("mmu.zig");
const pci = @import("pci.zig");
const pmem = @import("pmem.zig");
const smmu = @import("smmu.zig");
const vm = @import("vm.zig");
const sched = @import("sched.zig");
const shared = @import("shared");
const lock = @import("lock.zig");
const trace = @import("trace.zig");

const max_domains = 16;
const user_stack_pages = 24; // mossfs's CoW rebuild keeps 4K frames per tree level; ReleaseSafe inlining stacks several
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
    NoMapSlots,
    BadMapping,
    CoresBusy,
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
    /// CPU budget: permille of one core per period (0 = no limit of its
    /// own; the parent's still bounds it). 1000 = one core, 4000 = four.
    cpu_permille: u64 = 0,
    /// A partition: a mask of cores reserved for this domain alone (its
    /// threads run only there; nothing else is placed there). 0 = none.
    cores: u64 = 0,
    grant_debug_log: bool = false,
    /// Grant one channel end (its handle arrives in x1 at entry).
    grant_channel_a: ?*ipc.Channel = null,
    grant_channel_b: ?*ipc.Channel = null,
    /// Badge for the granted channel_b cap (view identity etc.).
    grant_channel_b_badge: u64 = 0,
    /// Map the boot archive (read-only, shared: every holder sees the
    /// same frames, no copy, no user-memory charge); its va/len arrive in
    /// x3/x4 at entry. Spawners read program images out of it.
    grant_bootfs: bool = false,
    /// Faults become messages on this channel (side A held by the
    /// supervisor); without one, a faulting domain is killed outright.
    supervisor: ?*ipc.Channel = null,
    /// Opaque argument delivered in x2 at entry (role tags etc.).
    arg: u64 = 0,
    /// Grant spawn authority (root and init hold this; services never do).
    grant_spawner: bool = false,
    /// Handle slots follow the fixed insert order (log, channel, spawner,
    /// entropy, introspect, devices).
    /// The platform windows (ECAM, MMIO) — root's boot grant; it hands
    /// them to the enumerator and forwards the devices that registers.
    grant_windows: bool = false,
    /// Authority to create virtual machines.
    grant_hypervisor: bool = false,
    /// Grant the right to seed the kernel entropy pool (the rng driver).
    grant_entropy: bool = false,
    /// Grant read-only introspection (domain_list/sysinfo) — what a
    /// spawner cap also carries, without the power to spawn.
    grant_introspect: bool = false,
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
    /// Backing for names taken from an image header (points into self).
    name_buf: [16]u8 = @splat(0),
    /// The window: every mapping in [shm_window_base, ...) — shm buffers
    /// (each holding a ref on its object for as long as it is mapped, so
    /// a dropped cap can never free frames still mapped here), the boot
    /// archive, DMA and device frames. First-fit placement, so an
    /// unmapped buffer's addresses are reused. The kernel's own copies
    /// consult it (windowRangeOk) and pin it (uaccess_users) while they
    /// run, so an unmap on another core waits for them.
    mappings: [max_mappings]?Mapping = @splat(null),
    windows_lock: lock.SpinLock = .{},
    uaccess_users: std.atomic.Value(u32) = .init(0),
    kobj: kalloc.Account = .{ .limit = 0 },
    user_mem: kalloc.Account = .{ .limit = 0 },
    cpu: CpuAccount = .{},
    cores: u64 = 0,
    ttbr0_pa: u64 = 0,
    captable: ?*cap.Table = null,
    entry_va: u64 = 0,
    /// End of the R+X text pages; [text_end_va, image_end_va) is RW data.
    text_end_va: u64 = 0,
    image_end_va: u64 = 0,
    stack_base: u64 = 0,
    stack_top: u64 = 0,
    init_handle: u64 = 0,
    init_handle2: u64 = 0,
    init_arg: u64 = 0,
    blob_va: u64 = 0,
    blob_len: u64 = 0,
    msi_doorbell_mapped: bool = false,
    supervisor: ?*ipc.Channel = null,
    threads_alive: std.atomic.Value(u32) = .init(0),
    exit_code: u64 = 0,
    auto_reap: bool = false,
    watcher: ?*ipc.Notification = null,
    /// This domain's registered death-watch (for domains IT spawns).
    death_watch: ?*ipc.Notification = null,
    /// Outstanding domain_ctl caps; a dead slot is reusable only at zero.
    ctl_refs: std.atomic.Value(u32) = .init(0),
    /// A ctl cap was minted for it (spawn syscall): its slot recycles
    /// once dead and unreferenced. A domain the kernel's own drivers
    /// spawned has no ctl cap and stays dead — they read its state and
    /// exit code afterwards.
    ctl_governed: bool = false,
    /// Someone is inside destroy(): threads being killed and caps being
    /// released. A domain does not count as drained until they are done,
    /// or the reaper could free the cap table under the revoker's feet —
    /// the killed threads die at their safe points while the revoker is
    /// still walking the table, and the last death drains the domain.
    destroying: std.atomic.Value(bool) = .init(false),
    parent: ?*Domain = null,
    /// Start records for extra user threads (thread_create).
    starts: [max_domain_threads]ThreadStart = @splat(.{}),
};

pub const max_domain_threads = 8;

const ThreadStart = struct {
    used: bool = false,
    d: ?*Domain = null,
    entry: u64 = 0,
    sp: u64 = 0,
    x0: u64 = 0,
    x1: u64 = 0,
};

/// Another thread in `d`: same address space and cap table, entering
/// `entry` with x0/x1 on a user-supplied stack. Counted in threads_alive
/// like the first thread, so teardown drains it the same way.
pub fn createThread(d: *Domain, entry: u64, sp: u64, x0: u64, x1: u64) Error!void {
    var slot: ?*ThreadStart = null;
    for (&d.starts) |*ts| {
        if (!ts.used) {
            slot = ts;
            break;
        }
    }
    const ts = slot orelse return Error.NoThreadSlots;
    ts.* = .{ .used = true, .d = d, .entry = entry, .sp = sp, .x0 = x0, .x1 = x1 };
    _ = d.threads_alive.fetchAdd(1, .acq_rel);
    _ = sched.spawn(d.name, extraThreadEntry, @intFromPtr(ts), .{
        .cpu_mask = d.cores,
        .user_ttbr0 = d.ttbr0_pa,
        .asid = d.asid,
        .user_ctx = d,
        .captable = d.captable.?,
        .stack_account = &d.kobj,
    }) catch |e| {
        _ = d.threads_alive.fetchSub(1, .acq_rel);
        ts.* = .{};
        return switch (e) {
            sched.Error.NoThreadSlots => Error.NoThreadSlots,
            sched.Error.OutOfFrames => Error.OutOfFrames,
            sched.Error.QuotaExceeded => Error.QuotaExceeded,
        };
    };
}

fn extraThreadEntry(arg: u64) void {
    const ts: *ThreadStart = @ptrFromInt(arg);
    const entry = ts.entry;
    const sp = ts.sp;
    const x0 = ts.x0;
    const x1 = ts.x1;
    ts.* = .{}; // the record is free once its values are in registers
    enterUser(entry, sp, .{ x0, x1, 0, 0, 0 });
}

var domains: [max_domains]Domain = @splat(.{});
var next_domain_id: u32 = 1;
/// Slot allocation and release (spawners run on every core).
var slots_lock: lock.SpinLock = .{};

pub const max_mappings = 64;

/// One mapping in the window. `shm` is set for buffers (the only kind
/// that is ever unmapped); `writable` tells the kernel's copies whether
/// a store there is allowed (the archive is read-only to EL1 too).
pub const Mapping = struct {
    va: u64,
    npages: u64,
    shm: ?*ipc.Shm,
    writable: bool,
    /// Buffers only. A thread of a domain being revoked can be reaped
    /// at any tick, mid-syscall; the table must tell teardown the
    /// truth at every instant: `reserved` = pages going in, no ref
    /// taken yet; `live` = mapped and ref'd; `unmapping` = pages going
    /// out, ref still held. The ref changes hands only under the
    /// window lock (IRQs masked: no reap between the two steps).
    state: enum { reserved, live, unmapping } = .live,
};

pub fn init() void {
    sched.user_thread_reaped = &onThreadReaped;
    ipc.domain_ctl_release = &onCtlReleased;
    sched.cpu_charge = &chargeCpu;
    sched.cpu_over_budget = &cpuOverBudget;
    sched.cpu_period_reset = &cpuPeriodReset;
    ipc.vm_release = &onVmReleased;
}

/// Where a program image comes from: a kernel-visible byte slice (the
/// boot drivers reading the archive) or an shm buffer a spawner staged
/// (the syscall path). The loader only ever copies, page by page.
pub const ImageSource = union(enum) {
    blob: []const u8,
    shm: *ipc.Shm,

    fn len(self: ImageSource) usize {
        return switch (self) {
            .blob => |b| b.len,
            .shm => |s| s.npages * mem.page_size,
        };
    }

    /// Copy bytes [off, off+dst.len) of the image into dst (in bounds).
    fn read(self: ImageSource, off: usize, dst: []u8) void {
        switch (self) {
            .blob => |b| @memcpy(dst, b[off..][0..dst.len]),
            .shm => |s| {
                var done: usize = 0;
                while (done < dst.len) {
                    const at = off + done;
                    const page = mem.physToPtr([*]const u8, s.pages[at / mem.page_size]);
                    const in_page = at % mem.page_size;
                    const n = @min(dst.len - done, mem.page_size - in_page);
                    @memcpy(dst[done .. done + n], page[in_page .. in_page + n]);
                    done += n;
                }
            },
        }
    }
};

/// Fill `buf` with shared.DomainRec records for every live slot (the
/// domain_list syscall's worker). Returns the record count.
/// The third budget: CPU time, as cycles spent in the current period,
/// charged up the parent chain like the memory accounts. A domain is
/// over budget when any account in its chain with a limit has spent it;
/// the scheduler then parks its threads until the period resets.
pub const CpuAccount = struct {
    limit: u64 = 0, // cycles per period; 0 = unlimited here
    permille: u64 = 0,
    used: std.atomic.Value(u64) = .init(0),
    /// What the last completed period spent, for introspection.
    last: u64 = 0,
    total: std.atomic.Value(u64) = .init(0),
    parent: ?*CpuAccount = null,

    fn charge(self: *CpuAccount, cyc: u64) void {
        _ = self.used.fetchAdd(cyc, .monotonic);
        _ = self.total.fetchAdd(cyc, .monotonic);
        if (self.parent) |p| p.charge(cyc);
    }

    fn over(self: *const CpuAccount) bool {
        if (self.limit != 0 and self.used.load(.monotonic) >= self.limit) return true;
        return if (self.parent) |p| p.over() else false;
    }
};

var cntfrq: u64 = 0;

fn cpuLimitCycles(permille: u64) u64 {
    if (permille == 0) return 0;
    if (cntfrq == 0) cntfrq = asm ("mrs %[v], cntfrq_el0"
        : [v] "=r" (-> u64),
    );
    // One period is cpu_period_ticks x 100ms.
    return cntfrq * sched.cpu_period_ticks / 10 * permille / 1000;
}

fn chargeCpu(ctx: *anyopaque, cyc: u64) void {
    const d: *Domain = @ptrCast(@alignCast(ctx));
    d.cpu.charge(cyc);
}

fn cpuOverBudget(ctx: *anyopaque) bool {
    const d: *Domain = @ptrCast(@alignCast(ctx));
    return d.cpu.over();
}

fn cpuPeriodReset() void {
    for (&domains) |*d| {
        if (d.state == .unused) continue;
        // A domain that overran (enforcement is tick-grained: a thread
        // per core can run a whole tick past its limit) starts the next
        // period in debt, so its average converges on the limit.
        const spent = d.cpu.used.load(.monotonic);
        d.cpu.last = spent;
        const carry = if (d.cpu.limit != 0 and spent > d.cpu.limit) spent - d.cpu.limit else 0;
        d.cpu.used.store(carry, .monotonic);
    }
}

/// Lifetime spend as permille of one core over `elapsed` cycles.
pub fn cpuPermilleAvg(d: *const Domain, elapsed: u64) u64 {
    if (elapsed == 0) return 0;
    return d.cpu.total.load(.monotonic) * 1000 / elapsed;
}

/// Last period's spend as permille of one core.
pub fn cpuPermilleUsed(d: *const Domain) u64 {
    const per_period = cpuLimitCycles(1000);
    if (per_period == 0) return 0;
    return d.cpu.last * 1000 / per_period;
}

pub fn fillRecs(buf: []u8) usize {
    var n: usize = 0;
    for (&domains) |*d| {
        if (d.state == .unused) continue;
        if ((n + 1) * shared.DomainRec.size > buf.len) break;
        var name: [16]u8 = @splat(0);
        const len = @min(d.name.len, 16);
        @memcpy(name[0..len], d.name[0..len]);
        const rec: shared.DomainRec = .{
            .id = d.id,
            .state = switch (d.state) {
                .alive => .alive,
                .dying => .dying,
                else => .dead,
            },
            .threads = @intCast(@min(d.threads_alive.load(.acquire), 255)),
            .name = name,
            .exit_code = d.exit_code,
            .kobj_kb = ((d.kobj.balance() / 1024) << 32) | (d.kobj.limit / 1024),
            .user_kb = ((d.user_mem.balance() / 1024) << 32) | (d.user_mem.limit / 1024),
            .cpu = (cpuPermilleUsed(d) << 32) | d.cpu.permille | (d.cores << 16),
        };
        rec.encode(buf[n * shared.DomainRec.size ..][0..shared.DomainRec.size]);
        n += 1;
    }
    return n;
}

fn onVmReleased(idx: u64) void {
    if (vm.byIndex(idx)) |m| vm.destroy(m);
}

fn onCtlReleased(obj: u64) void {
    const d: *Domain = @ptrFromInt(obj);
    if (d.ctl_refs.fetchSub(1, .acq_rel) == 1) releaseSlotIfUnreferenced(d);
}

/// A dead domain's slot is free only once nothing names it: a ctl cap is
/// a raw reference, and a slot reused under one would let its holder
/// read a stranger's state (a session manager once polled a dead
/// session's ctl and saw the next spawn, alive, forever). Called by
/// whichever comes last — the teardown or the last ctl drop.
fn releaseSlotIfUnreferenced(d: *Domain) void {
    const daif = slots_lock.lockIrqSave();
    defer slots_lock.unlockRestore(daif);
    if (d.state == .dead and d.ctl_refs.load(.acquire) == 0) d.state = .unused;
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
                // Everything needed after the teardown is taken BEFORE
                // it: finishTeardown may free the slot, and a spawn on
                // another core can own it the next instant. The first
                // cut read d.watcher afterwards and once found — and
                // signaled, and nulled — the watcher of the domain that
                // had just been spawned into the same slot.
                const watcher = d.watcher;
                const id = d.id;
                const bit = @as(u64, 1) << slotIndex(d);
                d.watcher = null;
                finishTeardown(d);
                if (watcher) |n| {
                    trace.record(.reaper_signal, id, bit);
                    ipc.signal(n, bit);
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
/// manifest grants, one thread started at the image entry. `name` null
/// takes the image's self-declared name (the syscall path); the kernel's
/// own drivers may override it for readable logs.
pub fn spawn(name: ?[]const u8, image: ImageSource, manifest: Manifest) Error!*Domain {
    const d = allocSlot() orelse return Error.NoDomainSlots;
    errdefer abortSpawn(d);
    d.name = name orelse "?";
    d.kobj = .{ .limit = manifest.kobj_limit };
    d.user_mem = .{ .limit = manifest.user_limit };
    d.cpu = .{ .limit = cpuLimitCycles(manifest.cpu_permille), .permille = manifest.cpu_permille };
    d.cores = manifest.cores;
    if (d.cores != 0 and !sched.reserveCores(d.cores, @ptrCast(d))) {
        d.* = .{ .id = d.id, .asid = d.asid, .state = .unused };
        return Error.CoresBusy;
    }
    if (manifest.parent) |p| {
        d.parent = p;
        d.kobj.parent = &p.kobj;
        d.user_mem.parent = &p.user_mem;
        d.cpu.parent = &p.cpu;
    }

    // Header check.
    if (image.len() < @sizeOf(shared.UserImageHeader)) return Error.BadImage;
    var header: shared.UserImageHeader = undefined;
    image.read(0, std.mem.asBytes(&header));
    if (header.magic != shared.UserImageHeader.expected_magic) return Error.BadImage;
    if (header.text_size > header.mem_size or header.load_size > header.mem_size)
        return Error.BadImage;
    if (header.mem_size > (64 << 20)) return Error.BadImage;
    // objcopy trims trailing zero padding, so an archive image may be
    // shorter than load_size: the missing tail is zeros (fresh pages).
    const avail = @min(header.load_size, image.len());
    if (header.text_size % mem.page_size != 0 or header.load_size % mem.page_size != 0 or
        header.mem_size % mem.page_size != 0) return Error.BadImage;
    if (name == null) {
        const hn = header.nameSlice();
        if (hn.len == 0) return Error.BadImage;
        @memcpy(d.name_buf[0..hn.len], hn);
        d.name = d.name_buf[0..hn.len];
    }

    // Address space root.
    const root_page = try kalloc.allocPage(&d.kobj);
    d.ttbr0_pa = mem.virtToPhys(@intFromPtr(root_page));

    // Image pages: copy from the blob (zero-filled past load_size for BSS),
    // text pages mapped R+X, the rest RW.
    const base = shared.user_image_base;
    var off: u64 = 0;
    while (off < header.mem_size) : (off += mem.page_size) {
        const page = try kalloc.allocPage(&d.user_mem);
        if (off < avail) {
            const n = @min(avail - off, mem.page_size);
            image.read(@intCast(off), page[0..n]);
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
    d.text_end_va = base + header.text_size;
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
    if (manifest.grant_entropy) {
        _ = table.insert(.entropy, 0) orelse return Error.CapTableFull;
    }
    if (manifest.grant_introspect) {
        _ = table.insert(.introspect, 0) orelse return Error.CapTableFull;
    }
    if (manifest.grant_windows and pci.have_host) {
        _ = table.insert(.window, 0) orelse return Error.CapTableFull;
        _ = table.insert(.window, 1) orelse return Error.CapTableFull;
    }
    if (manifest.grant_hypervisor) {
        _ = table.insert(.hypervisor, 0) orelse return Error.CapTableFull;
    }
    if (manifest.grant_bootfs and system_blob_len > 0) {
        // Shared read-only frames: the archive is immutable, so every
        // holder maps the kernel's one copy (unowned: teardown leaves it).
        const npages = mem.alignUp(system_blob_len, mem.page_size) / mem.page_size;
        const blob_base = reserveWindow(d, npages, null, false) catch return Error.NoMapSlots;
        for (0..npages) |i| {
            mmu.mapUserPageTagged(
                d.ttbr0_pa,
                blob_base + i * mem.page_size,
                system_blob_pa + i * mem.page_size,
                .rodata,
                &d.kobj,
                false,
            ) catch return Error.QuotaExceeded;
        }
        d.blob_va = blob_base;
        d.blob_len = system_blob_len;
    }
    d.init_arg = manifest.arg;
    d.supervisor = manifest.supervisor;
    d.auto_reap = manifest.auto_reap;
    d.watcher = manifest.watcher;
    if (manifest.watcher) |n| ipc.refNotification(n);
    trace.record(.spawn, d.id, @intFromBool(manifest.watcher != null));

    d.state = .alive;
    d.threads_alive.store(1, .release);
    _ = sched.spawn(d.name, userThreadEntry, @intFromPtr(d), .{
        .cpu_mask = d.cores,
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
    releaseMappedShms(d);
    if (d.cores != 0) sched.releaseCores(@ptrCast(d));
    if (d.kobj.balance() != 0 or d.user_mem.balance() != 0)
        std.debug.panic("domain {s} teardown leak: kobj={d}B user={d}B", .{
            d.name, d.kobj.balance(), d.user_mem.balance(),
        });
    d.state = .unused;
}

/// The single revocation: mark the domain dying, kill its threads, and
/// release every cap it held — closing channel sides, which is what
/// delivers peer_dead to whoever is blocked on the other end. Threads
/// running on other cores die at their next preemption; once drained()
/// reports true, finishTeardown() reclaims the rest.
pub fn destroy(d: *Domain) void {
    // One claimant: a domain exiting on its own core and a parent (or
    // holder of its ctl cap) revoking it on another may arrive together,
    // and only one of them may walk the threads and the cap table.
    if (@cmpxchgStrong(State, &d.state, .alive, .dying, .acq_rel, .acquire) != null) return;
    trace.record(.destroy, d.id, 0);
    d.destroying.store(true, .release);
    defer d.destroying.store(false, .release);
    // The subtree dies with the parent: one revocation, transitively.
    for (&domains) |*c| {
        if (c.parent == d and c.state == .alive) destroy(c);
    }
    const freed = sched.destroyThreadsOf(d);
    if (freed > 0) _ = d.threads_alive.fetchSub(freed, .acq_rel);
    // Threads are gone (or marked dead); now the authority dies with them.
    // A held device is unbound from these tables first: they are freed
    // in finishTeardown and the SMMU must never walk them afterwards.
    for (&d.captable.?.entries) |*e| {
        if (e.cap_type != .empty) {
            if (e.cap_type == .device) smmu.detachIfHolder(e.object, @ptrCast(d), d.asid);
            ipc.releaseCap(e.cap_type, e.object, e.badge);
            e.cap_type = .empty;
            e.generation +%= 1;
        }
    }
    // A supervised domain counts as a live client of its fault channel.
    if (d.supervisor) |ch| {
        d.supervisor = null;
        ipc.unrefSide(ch, .b, 0);
    }
}

/// Debug: every domain slot in use — for the hang watchdog, beside the
/// thread dump: a dying domain that never drains names its leak.
pub fn debugDump() void {
    for (&domains) |*d| {
        if (d.state == .unused) continue;
        log.info("domain {s}#{d}: {t} threads_alive={d} ctl_refs={d} auto_reap={} parent={s} exit={d}", .{
            d.name,                            d.id,
            d.state,                           d.threads_alive.load(.acquire),
            d.ctl_refs.load(.acquire),         d.auto_reap,
            if (d.parent) |p| p.name else "-", d.exit_code,
        });
    }
}

/// Nothing of the domain runs any more, and nobody is still inside
/// destroy(): only then may finishTeardown reclaim it.
pub fn drained(d: *const Domain) bool {
    return d.threads_alive.load(.acquire) == 0 and !d.destroying.load(.acquire);
}

/// Reclaim address space, page tables, and cap table; verify both quota
/// accounts return to zero. Call only after destroy() and drained().
pub fn finishTeardown(d: *Domain) void {
    std.debug.assert(d.state == .dying and drained(d));
    if (d.destroying.load(.acquire)) std.debug.panic("domain {s}: finishTeardown while destroy() is still running", .{d.name});
    mmu.destroyUserSpace(d.ttbr0_pa, &d.user_mem, &d.kobj, d.asid);
    kalloc.freePage(&d.kobj, @ptrCast(d.captable.?));
    d.captable = null;
    releaseMappedShms(d);
    const kobj_left = d.kobj.balance();
    const user_left = d.user_mem.balance();
    if (kobj_left != 0 or user_left != 0) {
        std.debug.panic("domain {s}: leak — kobj={d} user={d}", .{
            d.name, kobj_left, user_left,
        });
    }
    d.state = .dead;
    // Only domains governed by ctl caps recycle their slot; a domain the
    // kernel's own drivers spawned and tore down stays dead, so its
    // state and exit code remain theirs to read afterwards.
    if (d.ctl_governed) releaseSlotIfUnreferenced(d);
}

fn allocSlot() ?*Domain {
    const daif = slots_lock.lockIrqSave();
    defer slots_lock.unlockRestore(daif);
    for (&domains, 0..) |*d, i| {
        if (d.state == .unused) {
            d.* = .{ .id = next_domain_id, .asid = @intCast(i + 1), .state = .unused };
            next_domain_id += 1;
            return d;
        }
    }
    return null;
}

/// Kernel-thread entry for a domain's initial thread: drop to EL0 at the
/// image entry, with the manifest's initial handle (or 0) in x0.
/// Reserve `npages` of the window: the lowest address where nothing is
/// mapped (first fit over the table), recorded before any page is
/// mapped so two threads mapping at once never collide.
fn reserveWindow(d: *Domain, npages: u64, s: ?*ipc.Shm, writable: bool) !u64 {
    const bytes = npages * mem.page_size;
    const daif = d.windows_lock.lockIrqSave();
    defer d.windows_lock.unlockRestore(daif);
    var free: ?*?Mapping = null;
    for (&d.mappings) |*m| {
        if (m.* == null) {
            free = m;
            break;
        }
    }
    const slot = free orelse return Error.NoMapSlots;
    var base: u64 = shm_window_base;
    var moved = true;
    while (moved) {
        moved = false;
        for (&d.mappings) |*m| {
            const x = m.* orelse continue;
            const x_end = x.va + x.npages * mem.page_size;
            if (base < x_end and base + bytes > x.va) {
                base = x_end;
                moved = true;
            }
        }
    }
    slot.* = .{ .va = base, .npages = npages, .shm = s, .writable = writable, .state = if (s != null) .reserved else .live };
    return base;
}

fn forgetWindow(d: *Domain, va: u64) void {
    const daif = d.windows_lock.lockIrqSave();
    defer d.windows_lock.unlockRestore(daif);
    for (&d.mappings) |*m| {
        if (m.*) |x| {
            if (x.va == va) m.* = null;
        }
    }
}

/// Map an shm object into the calling domain's window; the mapping is
/// tagged unowned so teardown leaves the frames to the shm object, and
/// the domain holds a ref on the object for as long as the mapping
/// exists (unmapShm or teardown releases it).
pub fn mapShm(d: *Domain, s: *ipc.Shm) !u64 {
    const base = try reserveWindow(d, s.npages, s, true);
    for (0..s.npages) |i| {
        mmu.mapUserPageTagged(
            d.ttbr0_pa,
            base + i * mem.page_size,
            s.pages[i],
            .data,
            &d.kobj,
            false,
        ) catch |e| {
            mmu.unmapUserPages(d.ttbr0_pa, base, i, d.asid);
            forgetWindow(d, base);
            return e;
        };
    }
    // Ref and publish as one step: reaped before it, the entry says
    // "reserved" and teardown leaves the ref alone; after it, "live".
    const daif = d.windows_lock.lockIrqSave();
    defer d.windows_lock.unlockRestore(daif);
    ipc.refShm(s);
    for (&d.mappings) |*m| {
        if (m.*) |*x| {
            if (x.va == base) x.state = .live;
        }
    }
    return base;
}

/// Undo mapShm at `va`: the entry leaves the table first (so no new
/// kernel copy can be aimed at it), in-flight copies are waited out,
/// then the pages go and the mapping's ref is released — the frames can
/// only be freed once nothing maps them, on any core or in any device.
pub fn unmapShm(d: *Domain, va: u64) !void {
    var found: ?Mapping = null;
    {
        const daif = d.windows_lock.lockIrqSave();
        defer d.windows_lock.unlockRestore(daif);
        for (&d.mappings) |*m| {
            if (m.*) |*x| {
                if (x.va == va and x.shm != null and x.state == .live) {
                    x.state = .unmapping; // no new copy can be aimed at it
                    found = x.*;
                    break;
                }
            }
        }
    }
    const x = found orelse return Error.BadMapping;
    while (d.uaccess_users.load(.acquire) != 0) sched.yield();
    mmu.unmapUserPages(d.ttbr0_pa, x.va, x.npages, d.asid);
    smmu.invalidateAsid(d.asid);
    // Forget and unref as one step (see Mapping.state): reaped before
    // it, teardown releases the ref of an "unmapping" entry; after it,
    // there is nothing left to release.
    const daif = d.windows_lock.lockIrqSave();
    defer d.windows_lock.unlockRestore(daif);
    for (&d.mappings) |*m| {
        if (m.*) |y| {
            if (y.va == va) m.* = null;
        }
    }
    ipc.unrefShm(x.shm.?);
}

/// Is [ptr, ptr+len) inside one live window mapping (writable, if the
/// caller means to store)? Call with the window pinned (uaccessEnter)
/// or the answer may be stale by the time the copy runs.
pub fn windowRangeOk(d: *Domain, ptr: u64, len: u64, writable: bool) bool {
    const end = ptr +% len;
    if (end < ptr) return false;
    const daif = d.windows_lock.lockIrqSave();
    defer d.windows_lock.unlockRestore(daif);
    for (&d.mappings) |*m| {
        const x = m.* orelse continue;
        if (x.state != .live) continue;
        if (ptr >= x.va and end <= x.va + x.npages * mem.page_size) return !writable or x.writable;
    }
    return false;
}

/// Pin the window against unmap while a kernel copy runs: increment
/// BEFORE the range check, so an unmap that removed the mapping first
/// is seen by the check, and one that comes later waits for the copy.
pub fn uaccessEnter(d: *Domain) void {
    _ = d.uaccess_users.fetchAdd(1, .acq_rel);
}

pub fn uaccessLeave(d: *Domain) void {
    _ = d.uaccess_users.fetchSub(1, .acq_rel);
}

/// Map an MMIO window (device attributes, unowned: teardown must never
/// hand MMIO addresses to the frame allocator).
pub fn mapMmio(d: *Domain, base_pa: u64, pages: u64) !u64 {
    return mapFrames(d, base_pa, pages, .device);
}

/// A device this domain holds signals interrupts by writing the ITS
/// doorbell; that write is DMA through the domain's tables, so the
/// doorbell page is mapped at its own address, privileged-only.
pub fn ensureMsiDoorbell(d: *Domain) void {
    if (d.msi_doorbell_mapped or !its.active) return;
    const pa = its.doorbellPage();
    mmu.mapUserPageTagged(d.ttbr0_pa, pa, pa, .msi_doorbell, &d.kobj, false) catch return;
    asm volatile ("dsb ishst");
    d.msi_doorbell_mapped = true;
}

/// Map frames some other object owns (device windows, a VM's RAM) into
/// the domain, unowned: teardown leaves their frames to their owner.
pub fn mapFrames(d: *Domain, base_pa: u64, pages: u64, perms: mmu.UserPerms) !u64 {
    const base = try reserveWindow(d, pages, null, true);
    for (0..pages) |i| {
        try mmu.mapUserPageTagged(
            d.ttbr0_pa,
            base + i * mem.page_size,
            base_pa + i * mem.page_size,
            perms,
            &d.kobj,
            false,
        );
    }
    return base;
}

/// DMA grant: physically contiguous, zeroed, owned pages; returns the VA
/// and the device address — the VA itself when the SMMU translates the
/// holder's devices through these very tables, the physical address on
/// a machine without one.
pub fn mapDma(d: *Domain, npages: u64) !struct { va: u64, dev: u64 } {
    const pa = pmem.allocContiguous(@intCast(npages)) orelse return Error.OutOfFrames;
    errdefer pmem.freeContiguous(pa, @intCast(npages));
    try d.user_mem.charge(npages * mem.page_size);
    errdefer d.user_mem.credit(npages * mem.page_size);
    const bytes = mem.physToPtr([*]u8, pa);
    @memset(bytes[0 .. npages * mem.page_size], 0);
    const base = try reserveWindow(d, npages, null, true);
    for (0..npages) |i| {
        try mmu.mapUserPage(
            d.ttbr0_pa,
            base + i * mem.page_size,
            pa + i * mem.page_size,
            .data,
            &d.kobj,
        );
    }
    asm volatile ("dsb ishst"); // the SMMU walks these tables too
    return .{ .va = base, .dev = if (smmu.active) base else pa };
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

/// Mapping refs come off only once the address space is gone (after
/// destroyUserSpace), so no frame is ever freed while still mapped.
fn releaseMappedShms(d: *Domain) void {
    for (&d.mappings) |*m| {
        if (m.*) |x| {
            // A reserved buffer never took its ref (its thread was reaped
            // between reserving and mapping); live and unmapping did.
            if (x.shm) |s| {
                if (x.state != .reserved) ipc.unrefShm(s);
            }
            m.* = null;
        }
    }
}

/// The boot archive (bootfs MARC): the one blob the kernel embeds. Copied
/// once at boot into page-aligned contiguous frames so every domain that
/// is granted it maps the same physical pages read-only.
var system_blob_pa: u64 = 0;
var system_blob_len: usize = 0;

pub fn setSystemBlob(blob: []const u8) void {
    const npages = mem.alignUp(blob.len, mem.page_size) / mem.page_size;
    const pa = pmem.allocContiguous(@intCast(npages)) orelse @panic("boot archive: out of frames");
    const dst = mem.physToPtr([*]u8, pa);
    @memset(dst[0 .. npages * mem.page_size], 0);
    @memcpy(dst[0..blob.len], blob);
    system_blob_pa = pa;
    system_blob_len = blob.len;
}

pub fn systemBlob() []const u8 {
    if (system_blob_len == 0) return &.{};
    return mem.physToPtr([*]const u8, system_blob_pa)[0..system_blob_len];
}

/// A program image out of the boot archive, for the kernel's own boot
/// drivers (userspace spawners read the same archive themselves).
pub fn bootImage(path: []const u8) ?[]const u8 {
    return shared.marcFind(systemBlob(), path);
}
