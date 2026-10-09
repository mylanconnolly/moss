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
const arch = @import("arch.zig");
const timer = @import("timer.zig");
const cap = @import("cap.zig");
const ipc = @import("ipc.zig");
const kalloc = @import("kalloc.zig");
const log = @import("log.zig");
const mem = @import("mem.zig");
const pci = @import("pci.zig");
const pmem = @import("pmem.zig");
const sched = @import("sched.zig");
const shared = @import("shared");
const lock = @import("lock.zig");
const trace = @import("trace.zig");

// 32, not 16: the base system is ~14 domains, and a script may now spawn
// workers (up to four each, itself a child of the shell) — nested
// spawning that 16 could not host. Each slot is a Domain (~3K, mostly its
// mappings table), so the headroom costs ~48K of static kernel memory.
const max_domains = 32;
/// The default user stack, 256K: a TLS 1.3 handshake (hybrid key share,
/// certificate chain) needs >120K; before it, mossfs's CoW rebuild set
/// the bar at 96K. An image that needs more says so in its header
/// (`stack_pages`, up to `max_user_stack_pages`): the interpreter hosts
/// ask for 512K, since a `fetch https://` from inside a script function
/// faulted in ECDSA's DER parse 4K below a 256K stack (2026-09-18), and
/// raising every domain's stack instead broke every budget sized to it.
const user_stack_pages = 64;
const max_user_stack_pages = 256;
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
    ParentDying,
};

pub const State = enum {
    unused,
    alive,
    dying,
    dead,
    constructing, // exclusively reserved; never a live/reapable domain yet
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
    /// Handle slots follow the fixed insert order the grants are applied
    /// in (see `applyManifest`): log, channel, spawner, entropy,
    /// introspect, clock, the two platform windows, hypervisor, then the
    /// devices — user programs name their slots by this order.
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
    /// Grant the right to set the wall clock (the time service).
    grant_clock: bool = false,
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
    user_root_pa: u64 = 0,
    captable: ?*cap.Table = null,
    entry_va: u64 = 0,
    /// End of the R+X text pages; [text_end_va, image_end_va) is RW data.
    text_end_va: u64 = 0,
    image_end_va: u64 = 0,
    stack_base: u64 = 0,
    stack_top: u64 = 0,
    /// The image's pages past load_size that spawn left unmapped (a port
    /// with `arch.mmu.demand_zero`): .bss, populated with a zero frame on
    /// first touch — from EL0 by the data abort, from the kernel by the
    /// user-range checks before a copy — against a budget charged whole
    /// at spawn. `lazy_left` counts the pages never touched, credited
    /// back at teardown so the account returns to zero as before.
    lazy_base: u64 = 0,
    lazy_end: u64 = 0,
    lazy_left: u64 = 0,
    lazy_lock: lock.SpinLock = .{},
    init_handle: u64 = 0,
    init_handle2: u64 = 0,
    init_arg: u64 = 0,
    blob_va: u64 = 0,
    blob_len: u64 = 0,
    msi_doorbell_mapped: bool = false,
    supervisor: ?*ipc.Channel = null,
    threads_alive: std.atomic.Value(u32) = .init(0),
    exit_code: u64 = 0,
    /// The first thread to exit (or fault) names the exit code; a
    /// straggler's later exit — a VMM's second vCPU thread finding its
    /// VM gone after the first asked to power off — does not rewrite it.
    exit_claimed: bool = false,
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
    // Published under the slots lock, as `spawn` publishes a domain: a
    // teardown that has walked this domain's threads must not find a new
    // one created after its pass (it would never be marked, and the
    // domain would never drain).
    const publish_irqs = slots_lock.lockIrqSave();
    defer slots_lock.unlockRestore(publish_irqs);
    if (@atomicLoad(State, &d.state, .acquire) != .alive) return Error.NoThreadSlots;
    // Claim a start record with one atomic exchange: two threads of the
    // domain creating threads at once cannot take the same slot, and the
    // acquire orders this core's writes below after the loads of whoever
    // released the slot (extraThreadEntry's, on another core).
    var slot: ?*ThreadStart = null;
    for (&d.starts) |*ts| {
        if (@cmpxchgStrong(bool, &ts.used, false, true, .acq_rel, .acquire) == null) {
            slot = ts;
            break;
        }
    }
    const ts = slot orelse return Error.NoThreadSlots;
    ts.d = d;
    ts.entry = entry;
    ts.sp = sp;
    ts.x0 = x0;
    ts.x1 = x1;
    _ = d.threads_alive.fetchAdd(1, .acq_rel);
    _ = sched.spawn(d.name, extraThreadEntry, @intFromPtr(ts), .{
        .cpu_mask = d.cores,
        .user_root = d.user_root_pa,
        .asid = d.asid,
        .user_ctx = d,
        .captable = d.captable.?,
        .stack_account = &d.kobj,
    }) catch |e| {
        _ = d.threads_alive.fetchSub(1, .acq_rel);
        @atomicStore(bool, &ts.used, false, .release);
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
    // The record is free once its values are in registers — released
    // with ONE store, after the loads. It used to be zeroed whole: on
    // weakly ordered hardware the `used = false` store could reach the
    // creator (still in its loop on another core) before the `sp = 0`
    // store, so the creator claimed the slot, wrote the next thread's
    // values, and the straggling zero then landed on its `sp` — that
    // thread entered user mode on a null stack. A four-vCPU guest under
    // a busy host showed it (2026-09-18); nothing else ran a creator
    // and its new thread close enough together.
    @atomicStore(bool, &ts.used, false, .release);
    arch.thread.enterUser(entry, sp, .{ x0, x1, 0, 0, 0 });
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
    if (cntfrq == 0) cntfrq = arch.cpu.cycleHz();
    // One period is cpu_period_ticks ticks.
    return cntfrq * sched.cpu_period_ticks / timer.ticks_per_second * permille / 1000;
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
        if (d.state == .unused or d.state == .constructing) continue;
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
        if (d.state == .unused or d.state == .constructing) continue;
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
            .cpu_budget = d.cpu.permille | (d.cores << 16),
            .parent = if (d.parent) |p| p.id else 0,
            .cpu_total = d.cpu.total.load(.monotonic),
        };
        rec.encode(buf[n * shared.DomainRec.size ..][0..shared.DomainRec.size]);
        n += 1;
    }
    return n;
}

fn onVmReleased(idx: u64) void {
    if (arch.vm.byIndex(idx)) |m| arch.vm.destroy(m);
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
    const irqs = slots_lock.lockIrqSave();
    defer slots_lock.unlockRestore(irqs);
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
        if (c.parent == d and (c.state == .constructing or c.state == .alive or c.state == .dying)) return true;
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
    const d = try allocSlot(manifest.parent);
    errdefer abortSpawn(d);
    d.name = name orelse "?";
    d.kobj = .{ .limit = manifest.kobj_limit };
    d.user_mem = .{ .limit = manifest.user_limit };
    d.cpu = .{ .limit = cpuLimitCycles(manifest.cpu_permille), .permille = manifest.cpu_permille };
    d.cores = manifest.cores;
    if (d.cores != 0 and !sched.reserveCores(d.cores, @ptrCast(d))) {
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
    // A sanity bound on the header, not a budget (the budget is the
    // spawner's): the page domain carries 70 MB of arenas since the
    // script engine moved in (2026-09-25), so 64 was too small.
    if (header.mem_size > (128 << 20)) return Error.BadImage;
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
    d.user_root_pa = mem.virtToPhys(@intFromPtr(root_page));

    // Image pages: copy from the blob (zero-filled past load_size for BSS),
    // text pages mapped R+X, the rest RW. A port with demand_zero maps
    // only what the blob fills; .bss is charged now and populated as it
    // is touched (the page domain's 117 MB took 110 ms to zero and map
    // per spawn, most of it never read, 2026-10-08).
    const base = shared.user_image_base;
    d.lazy_base = 0;
    d.lazy_end = 0;
    d.lazy_left = 0;
    d.exit_claimed = false;
    const eager_end: u64 = if (comptime arch.mmu.demand_zero) header.load_size else header.mem_size;
    var off: u64 = 0;
    while (off < eager_end) : (off += mem.page_size) {
        const page = try kalloc.allocPage(&d.user_mem);
        if (off < avail) {
            const n = @min(avail - off, mem.page_size);
            image.read(@intCast(off), page[0..n]);
        }
        const perms: arch.mmu.UserPerms = if (off < header.text_size) .code else .data;
        arch.mmu.mapUserPage(
            d.user_root_pa,
            base + off,
            mem.virtToPhys(@intFromPtr(page)),
            perms,
            &d.kobj,
        ) catch return Error.QuotaExceeded;
    }
    if (eager_end < header.mem_size) {
        const lazy_bytes = header.mem_size - eager_end;
        d.user_mem.charge(lazy_bytes) catch return Error.QuotaExceeded;
        d.lazy_base = base + eager_end;
        d.lazy_end = base + header.mem_size;
        d.lazy_left = lazy_bytes / mem.page_size;
    }
    d.entry_va = base + @sizeOf(shared.UserImageHeader);
    d.text_end_va = base + header.text_size;
    d.image_end_va = base + header.mem_size;

    // User stack.
    const stack_pages: u64 = if (header.stack_pages != 0) @min(header.stack_pages, max_user_stack_pages) else user_stack_pages;
    d.stack_top = user_stack_top;
    d.stack_base = user_stack_top - stack_pages * mem.page_size;
    var sp = d.stack_base;
    while (sp < d.stack_top) : (sp += mem.page_size) {
        const page = try kalloc.allocPage(&d.user_mem);
        arch.mmu.mapUserPage(
            d.user_root_pa,
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
    if (manifest.grant_clock) {
        _ = table.insert(.clock, 0) orelse return Error.CapTableFull;
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
            arch.mmu.mapUserPageTagged(
                d.user_root_pa,
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

    // Publish and enqueue as one transaction relative to parent revocation.
    // A parent already dying cannot acquire a new child after its subtree
    // walk. The reserved child keeps its parent's accounts alive on rollback.
    const publish_irqs = slots_lock.lockIrqSave();
    defer slots_lock.unlockRestore(publish_irqs);
    if (d.parent) |parent| if (parent.state != .alive) return Error.ParentDying;
    d.threads_alive.store(1, .release);
    @atomicStore(State, &d.state, .alive, .release);
    _ = sched.spawn(d.name, userThreadEntry, @intFromPtr(d), .{
        .cpu_mask = d.cores,
        .user_root = d.user_root_pa,
        .asid = d.asid,
        .user_ctx = d,
        .captable = table,
        .stack_account = &d.kobj,
    }) catch |e| {
        @atomicStore(State, &d.state, .constructing, .release);
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
    if (d.user_root_pa != 0) {
        arch.mmu.destroyUserSpace(d.user_root_pa, &d.user_mem, &d.kobj, d.asid);
        d.user_root_pa = 0;
    }
    creditUntouched(d);
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
    const irqs = slots_lock.lockIrqSave();
    defer slots_lock.unlockRestore(irqs);
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
    const irqs = slots_lock.lockIrqSave();
    if (@cmpxchgStrong(State, &d.state, .alive, .dying, .acq_rel, .acquire) != null) {
        slots_lock.unlockRestore(irqs);
        return;
    }
    d.destroying.store(true, .release);
    slots_lock.unlockRestore(irqs);
    trace.record(.destroy, d.id, 0);
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
            if (e.cap_type == .device) arch.iommu.detachIfHolder(e.object, @ptrCast(d), d.asid);
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
        // A slot still constructing is exactly the state a stuck spawn
        // leaves behind; it belongs in the hang dump.
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
    arch.mmu.destroyUserSpace(d.user_root_pa, &d.user_mem, &d.kobj, d.asid);
    creditUntouched(d);
    // Stragglers: destroy() releases the cap table while threads on other
    // cores are only marked to die and may still be finishing a syscall.
    // One that inserts a cap after that walk — shm_create's cap between
    // createShm and the table insert, say — leaves it in the table for
    // nobody to release, and the buffer's ref leaks (an early-logged-out
    // session, about one users run in eight). Every thread is truly dead
    // by now (drained), so no more can be inserted: release whatever the
    // walk in destroy() could have missed.
    for (&d.captable.?.entries) |*e| {
        if (e.cap_type != .empty) {
            if (e.cap_type == .device) arch.iommu.detachIfHolder(e.object, @ptrCast(d), d.asid);
            ipc.releaseCap(e.cap_type, e.object, e.badge);
            e.cap_type = .empty;
            e.generation +%= 1;
        }
    }
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
    // A partition's cores go back with the domain: a reservation held by a
    // dead slot kept a core idle (or handed it to the slot's next owner).
    if (d.cores != 0) sched.releaseCores(@ptrCast(d));
    d.state = .dead;
    // Only domains governed by ctl caps recycle their slot; a domain the
    // kernel's own drivers spawned and tore down stays dead, so its
    // state and exit code remain theirs to read afterwards.
    if (d.ctl_governed) releaseSlotIfUnreferenced(d);
}

fn allocSlot(parent: ?*Domain) Error!*Domain {
    const irqs = slots_lock.lockIrqSave();
    defer slots_lock.unlockRestore(irqs);
    if (parent) |p| if (p.state != .alive) return Error.ParentDying;
    for (&domains, 0..) |*d, i| {
        if (d.state == .unused) {
            d.* = .{ .id = next_domain_id, .asid = @intCast(i + 1), .state = .constructing, .parent = parent };
            next_domain_id += 1;
            return d;
        }
    }
    return Error.NoDomainSlots;
}

/// Domain drill: model the exact preemption point between reservation and
/// page-table construction, without relying on a lucky scheduler interleave.
pub fn testSpawnReservations() void {
    const first = allocSlot(null) catch @panic("reserve first domain");
    const id = first.id;
    const second = allocSlot(null) catch @panic("reserve second domain");
    std.debug.assert(first != second and first.id == id);
    std.debug.assert(first.state == .constructing and second.state == .constructing);
    abortSpawn(first);
    const reused = allocSlot(null) catch @panic("reuse rolled back domain");
    std.debug.assert(reused == first and reused.id != id);
    abortSpawn(reused);
    abortSpawn(second);
    // The early core-reservation refusal must unwind before re-exposing its
    // slot; its errdefer used to run after an eager .unused reset.
    if (spawn("refused", .{ .blob = &.{} }, .{ .cores = 1 })) |_| {
        @panic("reserved core zero");
    } else |err| std.debug.assert(err == Error.CoresBusy);
    if (spawn("bad-image", .{ .blob = &.{} }, .{})) |_| {
        @panic("accepted empty image");
    } else |err| std.debug.assert(err == Error.BadImage);
    const after_failure = allocSlot(null) catch @panic("reuse failed spawn");
    std.debug.assert(after_failure == first);
    abortSpawn(after_failure);
}

/// Kernel-thread entry for a domain's initial thread: drop to EL0 at the
/// image entry, with the manifest's initial handle (or 0) in x0.
/// Reserve `npages` of the window: the lowest address where nothing is
/// mapped (first fit over the table), recorded before any page is
/// mapped so two threads mapping at once never collide.
fn reserveWindow(d: *Domain, npages: u64, s: ?*ipc.Shm, writable: bool) !u64 {
    const bytes = npages * mem.page_size;
    const irqs = d.windows_lock.lockIrqSave();
    defer d.windows_lock.unlockRestore(irqs);
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
    const irqs = d.windows_lock.lockIrqSave();
    defer d.windows_lock.unlockRestore(irqs);
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
        arch.mmu.mapUserPageTagged(
            d.user_root_pa,
            base + i * mem.page_size,
            s.pages[i],
            .data,
            &d.kobj,
            false,
        ) catch |e| {
            arch.mmu.unmapUserPages(d.user_root_pa, base, i, d.asid);
            forgetWindow(d, base);
            return e;
        };
    }
    // Ref and publish as one step: reaped before it, the entry says
    // "reserved" and teardown leaves the ref alone; after it, "live".
    const irqs = d.windows_lock.lockIrqSave();
    defer d.windows_lock.unlockRestore(irqs);
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
        const irqs = d.windows_lock.lockIrqSave();
        defer d.windows_lock.unlockRestore(irqs);
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
    arch.mmu.unmapUserPages(d.user_root_pa, x.va, x.npages, d.asid);
    arch.iommu.invalidateAsid(d.asid);
    // Forget and unref as one step (see Mapping.state): reaped before
    // it, teardown releases the ref of an "unmapping" entry; after it,
    // there is nothing left to release.
    const irqs = d.windows_lock.lockIrqSave();
    defer d.windows_lock.unlockRestore(irqs);
    for (&d.mappings) |*m| {
        if (m.*) |y| {
            if (y.va == va) m.* = null;
        }
    }
    ipc.unrefShm(x.shm.?);
}

/// Set the exit code if no thread of the domain has yet: the first
/// exit or fault is the domain's story, later ones are its stragglers'.
pub fn claimExit(d: *Domain, code: u64) void {
    if (@cmpxchgStrong(bool, &d.exit_claimed, false, true, .acq_rel, .acquire) == null) d.exit_code = code;
}

/// The .bss pages never touched go back to the budget (teardown freed
/// and credited the touched ones frame by frame).
fn creditUntouched(d: *Domain) void {
    const total = (d.lazy_end -| d.lazy_base) / mem.page_size;
    // A census for the big images (the page domain's 114 MB of arenas):
    // how much of what spawn no longer zeroes was faulted in after all.
    if (total >= 256) log.info("domain {s}: touched {d} of {d} lazy pages ({d} KB)", .{ d.name, total - d.lazy_left, total, (total - d.lazy_left) * mem.page_size / 1024 });
    if (d.lazy_left != 0) d.user_mem.credit(d.lazy_left * mem.page_size);
    d.lazy_left = 0;
    d.lazy_base = 0;
    d.lazy_end = 0;
}

/// A touch of an unpopulated .bss page: map a zero frame there. False
/// when `va` is not a lazy page of this domain (a real fault), or no
/// frame or table could be had — the log names which, and the caller
/// treats it as the fault it is.
pub fn faultIn(d: *Domain, va: u64) bool {
    if (comptime !arch.mmu.demand_zero) return false;
    if (va < d.lazy_base or va >= d.lazy_end) return false;
    const page_va = va & ~@as(u64, mem.page_size - 1);
    const irqs = d.lazy_lock.lockIrqSave();
    defer d.lazy_lock.unlockRestore(irqs);
    // Another thread of the domain may have taken the same fault first.
    if (arch.mmu.userPagePresent(d.user_root_pa, page_va)) return true;
    const pa = pmem.allocZeroed() orelse {
        log.warn("domain {s}: no frame for a .bss page at 0x{x} ({d} KB of its budget untouched)", .{ d.name, page_va, d.lazy_left * mem.page_size / 1024 });
        return false;
    };
    // The frame is already in the budget (charged whole at spawn); only
    // a page table may still be needed, from the kernel-object account.
    arch.mmu.mapUserPage(d.user_root_pa, page_va, pa, .data, &d.kobj) catch {
        pmem.free(pa);
        log.warn("domain {s}: no room in its kernel-object budget for a page table (.bss page at 0x{x})", .{ d.name, page_va });
        return false;
    };
    arch.mmu.settleMappings();
    d.lazy_left -= 1;
    return true;
}

/// Before the kernel touches [ptr, ptr+len) of a domain's image: the
/// lazy pages in it are populated (a kernel store into an unmapped page
/// would be an EL1 abort — a panic the caller could provoke). False
/// when a page could not be had.
pub fn touchRange(d: *Domain, ptr: u64, len: u64) bool {
    if (comptime !arch.mmu.demand_zero) return true;
    if (d.lazy_left == 0) return true;
    const lo = @max(ptr, d.lazy_base);
    const hi = @min(ptr +| len, d.lazy_end);
    if (lo >= hi) return true;
    var va = lo & ~@as(u64, mem.page_size - 1);
    while (va < hi) : (va += mem.page_size) if (!faultIn(d, va)) return false;
    return true;
}

/// A device is about to translate through this domain's tables (the
/// IOMMU shares them, and a DMA into an unmapped page is a refused
/// transaction, not a fault to fill): every page left is populated
/// first. False when one could not be.
pub fn populateLazy(d: *Domain) bool {
    if (comptime !arch.mmu.demand_zero) return true;
    var va = d.lazy_base;
    while (va < d.lazy_end) : (va += mem.page_size) if (!faultIn(d, va)) return false;
    return true;
}

/// Is [ptr, ptr+len) inside one live window mapping (writable, if the
/// caller means to store)? Call with the window pinned (uaccessEnter)
/// or the answer may be stale by the time the copy runs.
pub fn windowRangeOk(d: *Domain, ptr: u64, len: u64, writable: bool) bool {
    const end = ptr +% len;
    if (end < ptr) return false;
    const irqs = d.windows_lock.lockIrqSave();
    defer d.windows_lock.unlockRestore(irqs);
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
    if (!arch.msi.isActive()) return;
    // Check and map under the windows lock: two threads attaching devices
    // at once would otherwise map the page twice.
    const irqs = d.windows_lock.lockIrqSave();
    defer d.windows_lock.unlockRestore(irqs);
    if (d.msi_doorbell_mapped) return;
    const pa = arch.msi.doorbellPage();
    arch.mmu.mapUserPageTagged(d.user_root_pa, pa, pa, .msi_doorbell, &d.kobj, false) catch return;
    arch.mmu.publishTables();
    d.msi_doorbell_mapped = true;
}

/// Map frames some other object owns (device windows, a VM's RAM) into
/// the domain, unowned: teardown leaves their frames to their owner.
pub fn mapFrames(d: *Domain, base_pa: u64, pages: u64, perms: arch.mmu.UserPerms) !u64 {
    const base = try reserveWindow(d, pages, null, true);
    for (0..pages) |i| {
        try arch.mmu.mapUserPageTagged(
            d.user_root_pa,
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
    pmem.zeroPages(bytes, npages * mem.page_size);
    const base = try reserveWindow(d, npages, null, true);
    for (0..npages) |i| {
        try arch.mmu.mapUserPage(
            d.user_root_pa,
            base + i * mem.page_size,
            pa + i * mem.page_size,
            .data,
            &d.kobj,
        );
    }
    arch.mmu.publishTables(); // the IOMMU walks these tables too
    return .{ .va = base, .dev = if (arch.iommu.active) base else pa };
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
    arch.thread.enterUser(d.entry_va, d.stack_top, .{
        d.init_handle, d.init_handle2, d.init_arg, d.blob_va, d.blob_len,
    });
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
    pmem.zeroPages(dst, npages * mem.page_size);
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
