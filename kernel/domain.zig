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
const pci = @import("pci.zig");
const pmem = @import("pmem.zig");
const sched = @import("sched.zig");
const shared = @import("shared");

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
    /// Every enumerated PCI device (root's boot grant; it forwards them
    /// to init, which hands each to the unit that drives it).
    grant_devices: bool = false,
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
    /// Every shm this domain has mapped holds a ref until teardown, so a
    /// dropped cap can never free frames that are still mapped here.
    mapped_shms: [max_mapped_shms]?*ipc.Shm = @splat(null),
    kobj: kalloc.Account = .{ .limit = 0 },
    user_mem: kalloc.Account = .{ .limit = 0 },
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

pub const max_mapped_shms = 16;

pub fn init() void {
    sched.user_thread_reaped = &onThreadReaped;
    ipc.domain_ctl_release = &onCtlReleased;
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
        };
        rec.encode(buf[n * shared.DomainRec.size ..][0..shared.DomainRec.size]);
        n += 1;
    }
    return n;
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
/// manifest grants, one thread started at the image entry. `name` null
/// takes the image's self-declared name (the syscall path); the kernel's
/// own drivers may override it for readable logs.
pub fn spawn(name: ?[]const u8, image: ImageSource, manifest: Manifest) Error!*Domain {
    const d = allocSlot() orelse return Error.NoDomainSlots;
    errdefer abortSpawn(d);
    d.name = name orelse "?";
    d.kobj = .{ .limit = manifest.kobj_limit };
    d.user_mem = .{ .limit = manifest.user_limit };
    if (manifest.parent) |p| {
        d.parent = p;
        d.kobj.parent = &p.kobj;
        d.user_mem.parent = &p.user_mem;
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
    if (manifest.grant_devices) {
        for (0..pci.count) |i| {
            _ = table.insert(.device, i) orelse return Error.CapTableFull;
        }
    }
    if (manifest.grant_bootfs and system_blob_len > 0) {
        // Shared read-only frames: the archive is immutable, so every
        // holder maps the kernel's one copy (unowned: teardown leaves it).
        const blob_base = d.shm_map_next;
        const npages = mem.alignUp(system_blob_len, mem.page_size) / mem.page_size;
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
        d.shm_map_next = blob_base + npages * mem.page_size;
        d.blob_va = blob_base;
        d.blob_len = system_blob_len;
    }
    d.init_arg = manifest.arg;
    d.supervisor = manifest.supervisor;
    d.auto_reap = manifest.auto_reap;
    d.watcher = manifest.watcher;
    if (manifest.watcher) |n| ipc.refNotification(n);

    d.state = .alive;
    d.threads_alive.store(1, .release);
    _ = sched.spawn(d.name, userThreadEntry, @intFromPtr(d), .{
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
    releaseMappedShms(d);
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
/// tagged unowned so teardown leaves the frames to the shm object, and
/// the domain holds a ref on the object for as long as the mapping
/// exists (there is no unmap; teardown releases it).
pub fn mapShm(d: *Domain, s: *ipc.Shm) !u64 {
    var slot: ?*?*ipc.Shm = null;
    for (&d.mapped_shms) |*m| {
        if (m.* == null) {
            slot = m;
            break;
        }
    }
    const held = slot orelse return Error.NoMapSlots;
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
    ipc.refShm(s);
    held.* = s;
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

/// Mapping refs come off only once the address space is gone (after
/// destroyUserSpace), so no frame is ever freed while still mapped.
fn releaseMappedShms(d: *Domain) void {
    for (&d.mapped_shms) |*m| {
        if (m.*) |s| {
            ipc.unrefShm(s);
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
