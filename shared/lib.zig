//! Cross-boundary ABI and protocol types shared by the kernel, userspace,
//! host-side tests, and (eventually) MCU leaf nodes. This module is the IDL:
//! everything here must compile identically for every target, so it may not
//! import kernel or userspace code and may not allocate.

const std = @import("std");

pub const version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 };

/// Generational handle: the only form in which kernel object identity crosses
/// the ABI. Slot indexes a domain's cap table; the generation is bumped on
/// slot reuse so a stale handle can never resurrect authority. 40 bits of
/// generation means a slot reused once per microsecond takes ~35 years to
/// wrap.
pub const Handle = packed struct(u64) {
    slot: u24,
    generation: u40,

    pub const invalid: Handle = .{ .slot = 0, .generation = 0 };

    pub fn eql(a: Handle, b: Handle) bool {
        return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
    }
};

/// Syscall numbers. aarch64: x8 the number, x0..x5 arguments, x0 the
/// result; x86_64: rax the number, rdi rsi rdx r10 r8 r9 the arguments
/// and results (slot 0 the result). The slot names below (x1, x2 …)
/// are the aarch64 spelling of "result slot 1, 2 …".
/// IPC calls additionally return message words in x1..x4 and a received cap
/// handle (or 0) in x5.
pub const Syscall = enum(u64) {
    log = 1,
    yield = 2,
    sleep = 3,
    exit = 4,
    /// call(channel, w0..w3, cap) -> reply w0..w3, cap
    call = 5,
    /// recv(channel) -> msg w0..w3, cap; x6 = caller badge, x7 = reply
    /// token. A server may recv again before replying (up to 8 callers
    /// pending) — deferred replies, each answered by its token. Errno
    /// client_dead (x6 = the badge) reports a minted identity whose
    /// last cap died: free what was kept for it.
    recv = 6,
    /// reply(channel, w0..w3, cap; x6 = token, 0 = the oldest pending)
    reply = 7,
    notify_create = 8,
    notify_signal = 9,
    /// notify_wait(notification) -> x1 = accumulated bits (cleared)
    notify_wait = 10,
    /// shm_create(pages) -> x1 = handle
    shm_create = 11,
    /// shm_map(handle) -> x1 = va, x2 = pages. The mapping holds a ref
    /// on the buffer until shm_unmap or teardown.
    shm_map = 12,
    /// spawn(spawner, image_shm, arg, chan, flags, limits) -> x1 =
    /// domain_ctl handle. The image is a MOSS image staged in an shm
    /// buffer the caller holds; the kernel copies it into the child (no
    /// kernel image table, no path lookup). The child's name comes from
    /// the image header.
    /// x6 = CPU: permille of one core per period (low 16 bits) | partition
    /// core mask << 16 (reserved for the child alone); 0 = neither.
    spawn = 13,
    /// chan_create() -> x1 = side A handle, x2 = side B handle
    chan_create = 14,
    /// domain_stat(ctl) -> x1 = DomainState, x2 = exit code
    domain_stat = 15,
    /// domain_destroy(ctl) — the one revocation
    domain_destroy = 16,
    /// watch_deaths(notification): deaths of domains this domain spawns are
    /// signaled here; also binds the calling thread so a signal interrupts
    /// its blocked recv (Errno.interrupted)
    watch_deaths = 17,
    /// cap_drop(handle): release one capability
    cap_drop = 18,
    /// mmio_map(device_handle) -> x1 = BAR va, x2 = BAR bytes, x3 = the
    /// function's PCI config page va, x4 = the BAR's index (device-
    /// attribute mappings)
    mmio_map = 19,
    /// irq_bind(device_handle, notif_handle, 0): the device's interrupt
    /// line signals the notification; the line is masked until irq_ack
    irq_bind = 20,
    /// irq_ack(device_handle, 0): re-enable the line after handling
    irq_ack = 21,
    /// dma_alloc(pages) -> x1 = va, x2 = device address (physically
    /// contiguous; device address == physical until an IOMMU arrives)
    dma_alloc = 22,
    /// notify_bind(notification): a signal interrupts this thread's
    /// blocked recv (Errno.interrupted) — the ring doorbell hook
    notify_bind = 23,
    /// chan_mint(chan_a, badge) -> x2 = badged channel_b handle. Serving
    /// side only; recv delivers the caller's badge in x6.
    chan_mint = 24,
    /// domain_list(spawner, buf_va, buf_len) -> x1 = record count. Fills
    /// buf with DomainRec records; spawn authority gates seeing the tree.
    domain_list = 25,
    /// sysinfo(spawner) -> x1 = pmem free bytes, x2 = pmem total bytes,
    /// x3 = online cores, x4 = uptime ticks.
    sysinfo = 26,
    /// getrandom(buf_va, len): fill buf with 1..rng_max_request bytes from
    /// the kernel CSPRNG. Ungated — randomness is not authority over any
    /// object (the same standing as reading the counter). Fail-closed:
    /// bad_state until the entropy driver has seeded the pool.
    getrandom = 27,
    /// rng_seed(entropy_handle, buf_va, len): feed rng_min_seed..
    /// rng_max_request bytes of hardware entropy into the kernel pool.
    /// The entropy cap gates it (the virtio-rng driver holds one).
    rng_seed = 28,
    /// timer_arm(notification, period_ticks, bits): signal the
    /// notification with `bits` every `period_ticks` (100ms ticks); 0
    /// disarms. A clock as a notification — the same wake path as an
    /// IRQ, so a serving thread's recv is interrupted on time.
    timer_arm = 29,
    /// thread_create(entry, x0, x1, stack_top): another thread in this
    /// domain, entering `entry` with x0/x1 on a stack the domain supplies
    /// (its own memory); it shares the cap table. Threads are how a
    /// service makes blocking calls on others' behalf without stalling.
    thread_create = 30,
    /// thread_exit(): end the calling thread only (exit ends the domain).
    thread_exit = 31,
    /// device_info(device_handle) -> x1 = DeviceKind, x2 = requester id
    /// (bus<<8|slot<<3|fn), x3 = BAR bytes
    device_info = 32,
    /// vm_create(hypervisor_handle, ram_pages, vcpus) -> x1 = vm handle,
    /// x2 = the guest RAM mapped into the caller (RW). The guest sees it
    /// at IPA vm_ram_ipa; vCPU 0 runs first, the others come online by
    /// PSCI CPU_ON (a cpu_on exit tells the VMM to run them).
    vm_create = 33,
    /// vm_run(vm_handle, vcpu, resume_value) -> x1 = VmExit, x2..x5 = exit
    /// details; `resume_value` completes a pending mmio_read.
    vm_run = 34,
    /// vm_set(vm_handle, pc, x0, a, b, vcpu): the vCPU's entry point and
    /// first argument; a port may take more (x86_64: a = the guest's page
    /// tables, 0 for the VM's shared ones; b = its stack). vcpu defaults
    /// to 0.
    vm_set = 35,
    /// vm_attach_device(vm_handle, device_handle, bar_ipa, vintid): pass a
    /// device through to the guest — its BAR mapped at bar_ipa in the
    /// guest's stage 2, its DMA translated through the guest's stage 2 by
    /// the SMMU, its interrupt injected as virtual SPI `vintid`.
    vm_attach_device = 36,
    /// window_map(window_handle, page_offset, pages) -> x1 = va (0 when
    /// pages = 0: an enquiry), x2 = the window's physical base, x3 = size.
    window_map = 37,
    /// device_register(ecam_window_handle, requester_id, kind, bar_pa,
    /// bar_len, pin | bar_index << 8 | msix << 16) -> x1 = device handle,
    /// x2 = the message interrupt routed for it (only when the enumerator
    /// set the msix bit — it has a usable MSI-X table — and the platform
    /// routes messages: 0 otherwise, and the device's INTx line is its
    /// interrupt), x3 = the doorbell address the device's MSI-X entry must
    /// target. The ECAM holder's authority.
    /// -> x4 = the MSI data word the device writes (the ITS event id
    /// on aarch64, the vector on x86_64).
    device_register = 38,
    /// vm_cpu_on(vm_handle, vcpu, entry, context): reset that vCPU at
    /// `entry` with `context` in x0 and mark it online — the mechanics
    /// of PSCI CPU_ON; the policy (answering the guest) is the VMM's.
    /// busy = already online, bad_arg = no such vCPU.
    vm_cpu_on = 39,
    /// cycle_hz() -> slot 1 = the cycle counter's rate in Hz (not
    /// authority, like the counter itself: ungated).
    cycle_hz = 41,
    /// clock_get() -> x1 = the Unix time of boot in milliseconds (0 when
    /// unknown), x2 = its source (ClockSource); wall time is x1 plus the
    /// cycle counter's milliseconds. Reading time is not authority.
    clock_get = 42,
    /// clock_set(clock_handle, boot_epoch_ms): the time service sets what
    /// it learned (SNTP); the `clock` grant is the authority.
    clock_set = 43,
    /// shm_unmap(va): undo an shm_map at `va` — the pages leave this
    /// address space and the mapping's ref on the buffer is released.
    /// bad_arg when `va` is not the base of one of this domain's shm
    /// mappings.
    shm_unmap = 40,
    _,
};

/// The enumerator's service: `next` hands over the next device cap.
pub const PciReq = union(enum(u64)) {
    next: void,
};

pub const PciResp = union(enum(u64)) {
    /// + cap attachment: a device, of this DeviceKind.
    device: struct { kind: u64 },
    done: void,
};

/// Why a guest stopped (vm_run's x1).
pub const VmExit = enum(u64) {
    none = 0,
    /// x2 = IPA, x3 = size, x4 = register index (the next vm_run's
    /// resume_value is the loaded value).
    mmio_read = 1,
    /// x2 = IPA, x3 = size, x4 = value.
    mmio_write = 2,
    /// x2 = 0 for WFI, 1 for WFE.
    wfi = 3,
    /// A hypercall (HVC): x2..x5 = the guest's x0..x3. The next vm_run's
    /// resume_value becomes the guest's x0 — the VMM answers it (PSCI
    /// included: the kernel speaks none of it).
    hvc = 4,
    /// x2 = ESR, x3 = the guest's ELR, x4 = its ESR: something the
    /// hypervisor does not handle.
    fault = 6,
    /// A host interrupt; just run again.
    interrupted = 7,
    /// A trapped SMC, answered like an HVC (x2..x5 = x0..x3, resume_value
    /// -> x0).
    smc = 9,
    /// Port I/O (x86_64): x2 = port, x3 = size; a read's value is the
    /// next vm_run's resume_value, a write's value is x4.
    pio_read = 10,
    pio_write = 11,
};

pub const vm_ram_ipa: u64 = 0x4000_0000;

pub const SpawnFlags = struct {
    pub const grant_log: u64 = 1 << 0;
    pub const grant_spawner: u64 = 1 << 1;
    /// Grant the A (serving) side of the channel in x3 instead of B.
    pub const chan_side_a: u64 = 1 << 2;
    /// Grant the system boot blob (bootfs archive); va/len arrive in x3/x4.
    pub const grant_bootfs: u64 = 1 << 3;
    /// Grant read-only introspection (domain_list, sysinfo) WITHOUT spawn
    /// authority — for tools that look but never create.
    pub const grant_introspect: u64 = 1 << 4;
    /// Grant the right to set the wall clock (the time service).
    pub const grant_clock: u64 = 1 << 5;
};

/// Where the kernel's idea of wall time came from.
pub const ClockSource = enum(u64) { none = 0, rtc = 1, set = 2 };

/// Domain lifecycle as reported by domain_stat.
pub const DomainState = enum(u64) {
    alive = 0,
    dying = 1,
    dead = 2,
};

/// One row of domain_list: fixed 48-byte little-endian record, written
/// into the caller's buffer by the kernel and decoded with the helpers
/// below — typed introspection, no text scraping.
pub const DomainRec = struct {
    id: u32,
    state: DomainState,
    threads: u8,
    name: [16]u8, // NUL-padded
    exit_code: u64,
    kobj_kb: u64, // used KB << 32 | limit KB
    user_kb: u64, // used KB << 32 | limit KB
    /// Last period's CPU spend in permille of one core << 32 | the
    /// domain's permille limit (0 = none) | its partition core mask << 16.
    cpu: u64,

    pub const size = 56;

    pub fn encode(r: *const DomainRec, out: *[size]u8) void {
        std.mem.writeInt(u32, out[0..4], r.id, .little);
        out[4] = @intCast(@intFromEnum(r.state));
        out[5] = r.threads;
        out[6] = 0;
        out[7] = 0;
        @memcpy(out[8..24], &r.name);
        std.mem.writeInt(u64, out[24..32], r.exit_code, .little);
        std.mem.writeInt(u64, out[32..40], r.kobj_kb, .little);
        std.mem.writeInt(u64, out[40..48], r.user_kb, .little);
        std.mem.writeInt(u64, out[48..56], r.cpu, .little);
    }

    pub fn decode(b: *const [size]u8) DomainRec {
        return .{
            .id = std.mem.readInt(u32, b[0..4], .little),
            .state = std.enums.fromInt(DomainState, b[4]) orelse .dead,
            .threads = b[5],
            .name = b[8..24].*,
            .exit_code = std.mem.readInt(u64, b[24..32], .little),
            .kobj_kb = std.mem.readInt(u64, b[32..40], .little),
            .user_kb = std.mem.readInt(u64, b[40..48], .little),
            .cpu = std.mem.readInt(u64, b[48..56], .little),
        };
    }

    pub fn nameSlice(r: *const DomainRec) []const u8 {
        var n: usize = 0;
        while (n < r.name.len and r.name[n] != 0) n += 1;
        return r.name[0..n];
    }
};

test "DomainRec codec round trip" {
    var name: [16]u8 = @splat(0);
    @memcpy(name[0..5], "fssvc");
    const r: DomainRec = .{
        .id = 7,
        .state = .alive,
        .threads = 2,
        .name = name,
        .exit_code = 0,
        .kobj_kb = (123 << 32) | 1024,
        .user_kb = (2048 << 32) | 4096,
        .cpu = (250 << 32) | 500,
    };
    var buf: [DomainRec.size]u8 = undefined;
    r.encode(&buf);
    const d = DomainRec.decode(&buf);
    try std.testing.expectEqual(r.id, d.id);
    try std.testing.expectEqual(r.state, d.state);
    try std.testing.expectEqual(r.threads, d.threads);
    try std.testing.expectEqualStrings("fssvc", d.nameSlice());
    try std.testing.expectEqual(r.kobj_kb, d.kobj_kb);
    try std.testing.expectEqual(r.user_kb, d.user_kb);
}

/// Syscall results: 0 is success, anything else is one of these.
pub const Errno = enum(u64) {
    ok = 0,
    bad_handle = 1,
    denied = 2,
    fault = 3,
    bad_arg = 4,
    nosys = 5,
    /// The other end of the channel is gone. In-flight operations complete
    /// with this — a blocked call returns it the moment the peer dies.
    peer_dead = 6,
    busy = 7,
    bad_state = 8,
    no_space = 9,
    /// A bound notification fired while this thread was blocked in recv;
    /// drain it with notify_wait, then resume receiving.
    interrupted = 10,
    /// recv only: the last cap carrying a badge this server minted is
    /// gone (x6 = the badge). The side is still open — other clients
    /// live on — but this one will never call again: release its
    /// buffer and state, then the badge may be minted afresh.
    client_dead = 11,
    _,
};

/// The catalog of program images. The kernel holds no image table: every
/// program lives in the boot archive at `img/<name>` (imagePath), and a
/// spawner stages the bytes it wants to run into a shared buffer the
/// kernel copies from (see spawn). The numbering exists so the fabric
/// wire, certificate image masks, and init's topology can name an image
/// compactly; it couples to nothing in the kernel.
pub const ImageId = enum(u64) {
    hello = 0,
    pingpong = 1,
    root = 2,
    init = 3,
    services = 4,
    sandbox = 5,
    blk = 6,
    fs = 7,
    net = 8,
    fabric = 9,
    cons = 10,
    shell = 11,
    rng = 12,
    ps = 13,
    ls = 14,
    vmm = 15,
    pcisvc = 16,
    users = 17,
    mshrun = 18,
    dnsd = 19,
    clock = 20,
    dotd = 21,
    gpusvc = 22,
    gpucli = 23,
    term = 24,
    inputsvc = 25,
    gsh = 26,
    compcli = 27,
    focuscli = 28,
    trustcli = 29,
    readercli = 30,
    fontsvc = 31,
    fontcli = 32,
    ptrcli = 33,
    fontpush = 34,
    localeupd = 35,
    localesvc = 36,
};

/// Services init knows how to activate. Discovery is by protocol id over
/// init's channel — never by global name.
/// Encode a message union into the four IPC data words: word 0 is the tag,
/// words 1..3 the payload fields (u64s, at most three). This is the seed of
/// the comptime IDL: protocol types written once here compile identically
/// into both sides' stubs.
pub fn encodeMsg(comptime T: type, val: T) [4]u64 {
    var out: [4]u64 = @splat(0);
    out[0] = @intFromEnum(val);
    switch (val) {
        inline else => |payload| {
            const P = @TypeOf(payload);
            if (P != void) {
                const fields = @typeInfo(P).@"struct".fields;
                comptime std.debug.assert(fields.len <= 3);
                comptime var i = 1;
                inline for (fields) |f| {
                    comptime std.debug.assert(f.type == u64);
                    out[i] = @field(payload, f.name);
                    i += 1;
                }
            }
        },
    }
    return out;
}

pub fn decodeMsg(comptime T: type, words: [4]u64) ?T {
    const Tag = @typeInfo(T).@"union".tag_type.?;
    const tag = std.enums.fromInt(Tag, words[0]) orelse return null;
    switch (tag) {
        inline else => |t| {
            const P = @FieldType(T, @tagName(t));
            if (P == void) return @unionInit(T, @tagName(t), {});
            var p: P = undefined;
            comptime var i = 1;
            inline for (@typeInfo(P).@"struct".fields) |f| {
                @field(p, f.name) = words[i];
                i += 1;
            }
            return @unionInit(T, @tagName(t), p);
        },
    }
}

/// The first typed protocol: a trivial calculator, used by the Phase 4
/// demo. A request may carry a shared-memory cap with a greeting.
pub const CalcRequest = union(enum(u64)) {
    add: struct { a: u64, b: u64 },
    greet: void,
};

pub const CalcReply = union(enum(u64)) {
    sum: struct { value: u64 },
    hi: void,
};

/// Fault messages delivered to a supervisor channel (fault-as-message).
pub const FaultMsg = union(enum(u64)) {
    fault: struct { esr: u64, far: u64, elr: u64 },
};

/// Init's front-channel protocol: ask to be connected to a service; the
/// reply attaches a fresh channel-B cap for it.
pub const InitRequest = union(enum(u64)) {
    /// Connect to a service UNIT by NAME (two words, up to 16 bytes),
    /// lazily starting it (or restarting a stopped one) and supervising
    /// it — `start NAME` and `dial NAME` both reach a unit this way.
    connect_named: struct { a: u64, b: u64 },
    /// Deliberate stop by name: the instance is destroyed and supervision
    /// will not restart it (a connect starts it again).
    stop_named: struct { a: u64, b: u64 },
    /// + a buffer cap: fill it with `UnitRec`s for every unit init knows,
    /// and reply `listed { n }`. `svc` reads the table this way — no fixed
    /// catalog of service ids.
    list: void,
    /// Install the boot archive's programs into the attached `img/` view
    /// (+ view cap): content-addressed `img/<digest>` files plus the
    /// manifests beside them (`img/<name>.msh`). Idempotent — present images are skipped.
    install: void,
};

pub const InitReply = union(enum(u64)) {
    connected: void,
    failed: struct { err: u64 },
    listed: struct { n: u64 },
    stopped: void,
    installed: struct { n: u64 },
};

/// One unit as `svc` sees it, packed into a buffer by init's `list`.
pub const UnitRec = struct {
    name: [16]u8, // NUL-padded
    up: u8,
    restarts: u32,
    max_restarts: u32,

    pub const size = 28;

    pub fn encode(r: *const UnitRec, out: *[size]u8) void {
        @memcpy(out[0..16], &r.name);
        out[16] = r.up;
        out[17] = 0;
        out[18] = 0;
        out[19] = 0;
        std.mem.writeInt(u32, out[20..24], r.restarts, .little);
        std.mem.writeInt(u32, out[24..28], r.max_restarts, .little);
    }

    pub fn decode(b: *const [size]u8) UnitRec {
        return .{
            .name = b[0..16].*,
            .up = b[16],
            .restarts = std.mem.readInt(u32, b[20..24], .little),
            .max_restarts = std.mem.readInt(u32, b[24..28], .little),
        };
    }
};

// ----------------------------------------------------------------- users
//
// Users are a userspace notion: a user is an Ed25519 identity kept in a
// record (`conf/users/<name>.msh`, lib/usercred.zig), a session is a
// domain the session manager (usersvc) spawns under the user's budgets
// with a view of the user's home and nothing else, and logging out is
// destroying that domain. The manager holds the unlocked identity for
// the session's lifetime (custody); the session never sees the seed.
// Names and passphrases travel through the client's attached buffer.

pub const SessReq = union(enum(u64)) {
    attach_buf: void, // + shm cap
    /// Authenticate and start a session; the reply names it.
    login: struct { name: u64, pass: u64 }, // each word: off | len<<32
    /// Block until the session's domain exits; it is torn down on reply.
    wait: struct { sid: u64 },
    /// Destroy the session now.
    logout: struct { sid: u64 },
    // Sharing between users (from a session's own badged sess cap; the
    // badge names the caller, never a word in the message). A share is
    // a view the owner derived from its home, offered under a name to
    // one user. It STANDS until unshared: the manager records path and
    // mode, and re-offers it every time the owner logs in (the view
    // itself dies with the owner's session; the next login derives it
    // again from the owner's root view).
    /// + view cap: offer it as `name` to `user`. `badge` is the view's
    /// badge on the owner's home filesystem (derive's answer), so the
    /// manager can revoke it through the owner's root view later, with
    /// bit 63 set when the share is read-write; `user_path` packs two
    /// buffer words in 16-bit fields — user_off | user_len<<16 |
    /// path_off<<32 | path_len<<48 — the path and mode being what the
    /// manager derives again at the owner's next login.
    share: struct { name: u64, user_path: u64, badge: u64 }, // name: off | len<<32
    /// Withdraw an offer: the holder's calls fail from now on.
    unshare: struct { name: u64 },
    /// List offers made to me and by me: an mshl table literal lands in
    /// my buffer; the reply is `data { len }`.
    shares: void,
    /// Take an offer made to me: the reply attaches the view cap.
    accept: struct { name: u64 },
    /// Change my passphrase (from a session's badged cap): the old one
    /// proves the identity, the seed is sealed again under the new one
    /// and the record rewritten — where the home lives (a session on a
    /// remote home is refused with sess_err 9: change it there). Words
    /// into my buffer, each at most 256 bytes; both wiped after.
    passwd: struct { old: u64, new: u64 },
    /// From another node's session manager (through the fabric): the
    /// user's record, 24 bytes per chunk — `chunk { a, b, c }` while
    /// bytes remain, `data { len }` once past the end, `denied` when
    /// there is no such user. The name travels in two words (16 bytes),
    /// since no buffer crosses the wire.
    record: struct { name_a: u64, name_b: u64, chunk: u64 },
    /// A remote home. The manager where the user is logging in asks the
    /// manager that holds the home for a LEASE: `home_challenge` names
    /// the user and answers a 24-byte nonce in `chunk` with a lease cap
    /// attached (a badged copy of the holder's channel); on that cap the
    /// asker attaches a buffer, puts the identity's signature over
    /// "moss-home-lease" ‖ nonce at buf[sig_off..+64], and sends
    /// `home_lease`; verified against the record's public key, the
    /// answer is `ok` with a rw view of the home's ciphertext directory
    /// attached, which the asker gives its own home service as backing.
    /// The key never leaves the asker; the holder ships only ciphertext.
    /// One lease or local session per home at a time (sess_err 6 =
    /// busy, 7 = bad proof); the lease ends when its cap dies.
    home_challenge: struct { name_a: u64, name_b: u64 },
    home_lease: struct { sig_off: u64 },
};

pub const SessResp = union(enum(u64)) {
    ok: void,
    session: struct { sid: u64 },
    exited: struct { code: u64 },
    /// Unknown user, wrong passphrase, or a record that will not parse:
    /// one answer, so the response never says which.
    denied: void,
    /// A data literal of `len` bytes waits in the caller's buffer.
    data: struct { len: u64 },
    /// 24 bytes of a record, little-endian words, zero-padded (or a
    /// lease challenge's nonce).
    chunk: struct { a: u64, b: u64, c: u64 },
    sess_err: struct { code: u64 },
};

/// What a remote home's lease signature covers, with the nonce.
pub const home_lease_label = "moss-home-lease";

// ------------------------------------------------------------ image store
//
// `img/` on the volume is content-addressed: a program lives at
// img/<digest>, digest = hex of SHA-256(image)[0..16] (32 chars), so an
// image can never change under its name and a loader verifies what it
// stages before it spawns. A manifest `img/<name>.msh` maps a name to its digest, one
// "name digest" line each — the only text in the store, at the admin
// boundary like conf/.
pub const img_digest_hex_len: usize = 32;
/// A program's manifest sits beside its image in a store: `img/<name>.msh`,
/// an mshl record `{ image: "<digest>", grant: [...], give: [...] }` —
/// the digest names the content, the rest says what the program is
/// handed when run.
pub const img_manifest_ext = ".msh";

// ----------------------------------------------------------- boot protocol
//
// How a program receives its world. Spawn grants only what fits in flags
// (log, spawner, bootfs, introspect) plus one channel; everything else —
// device caps, other services' channels, buffers, views, secrets,
// arguments — arrives as typed messages on that boot channel before
// `go`. The spawner (init, msh, a boot driver) is whoever holds the caps;
// the program need not know who. Tags name what a cap is FOR; the
// program maps tags to its own state. This is the one setup protocol:
// drivers, services, and run tools all start by taking it.

pub const CapTag = enum(u64) {
    console = 1, // a console channel
    console_buf = 2, // the console's byte buffer (shm)
    view = 3, // a filesystem view
    device = 4, // a device: its registers, interrupt line and DMA identity
    entropy = 6, // the right to seed the kernel pool
    buf = 7, // a shared buffer the program should map (service staging)
    disk = 8, // a block service channel
    net = 9, // a network view
    init = 10, // an init front channel (re-wiring, service control)
    fabric = 11, // the fabric service's channel
    spawner = 12, // spawn authority
    /// A result buffer (shm): a program run by msh writes its result
    /// there as an mshl data literal (NUL-terminated) and msh returns it
    /// as the command's value — structured output, no text to re-parse.
    out = 13,
    /// The platform's PCI config space window (bus 0), for the enumerator.
    ecam = 14,
    /// The platform's 32-bit MMIO window BARs are placed in.
    mmio = 15,
    /// The session manager's channel (usersvc: login, wait, logout).
    sess = 16,
    /// A settings view: the system layer of a program's configuration.
    conf = 17,
    /// The home tier (`home/`), for the session manager alone.
    home = 18,
    /// A program store: a read-only view whose root is an `img/`
    /// directory (the system's), so a shell can run programs it does
    /// not hold in its own store.
    store = 19,
    /// The standing shares (`conf/shares/`), for the session manager.
    shares = 20,
    // 21 (was `roots`): trust roots are read from the assets tier now
    // (a view), not handed as a file cap — see `assets_dir`.
    /// A TLS server's certificate chain (PEM), handed as a file under a
    /// tag (a mapped buffer: a u64 length, then the bytes); the matching
    /// private key comes as a `secret`.
    cert = 22,
    /// The display server's channel (gpusvc): a client drives the surface
    /// protocol (create_surface, commit) over it.
    display = 23,
    /// inputsvc's channel, for a console server that reads the keyboard.
    keys = 24,
    /// The system font service's channel (fontsvc): a client lays out and
    /// rasterizes text through it (shared glyph atlas), so type is
    /// consistent and scaled the same everywhere.
    font = 25,
    /// A pointer service's channel (inputsvc in pointer mode): the
    /// compositor reads the tablet's absolute position + buttons over it.
    ptr = 26,
    /// The locale service's channel (localesvc): a client formats numbers,
    /// dates and money through it and reads/sets the session's locale, so the
    /// whole session's formatting follows one shared choice — the way a
    /// display or font cap is a channel to its service. (Was a read-only view
    /// of assets/locale, when each process parsed the CLDR db itself.)
    locale = 27,
};

pub const cap_tag_count = 28;

/// What a device is, by virtio device id (the modern PCI device id minus
/// 0x1040). A device cap is handed over with its kind so the receiver
/// can file it without asking.
/// The virtio device types we drive, valued by their virtio device-type
/// number (modern PCI device id = 0x1040 + this) so pcisvc files a
/// function by `device_id - 0x1040`. The enum is SPARSE (gpu at 16,
/// input at 18), so a raw kind must be validated by enum membership
/// (`std.meta.intToEnum`), never `@enumFromInt` over a numeric range.
pub const DeviceKind = enum(u64) {
    none = 0,
    net = 1,
    blk = 2,
    console = 3,
    rng = 4,
    gpu = 16,
    input = 18,
};

/// One past the highest DeviceKind value: pcisvc's range pre-filter for
/// virtio functions. Membership is what actually gates (intToEnum).
pub const device_kind_count = 19;

pub const BootReq = union(enum(u64)) {
    /// + cap attachment: what it is for; `kind` (DeviceKind) files a
    /// device cap, 0 otherwise.
    cap: struct { tag: u64, kind: u64 },
    /// Secret material at buf[off..off+len] of the `buf` cap (the
    /// program copies it out and zeroizes the buffer).
    secret: struct { off: u64, len: u64 },
    /// Non-secret setup bytes at buf[off..off+len] (a certificate, a
    /// config record); copied out, the buffer left as is.
    data: struct { off: u64, len: u64 },
    /// Up to 24 bytes of argument text.
    arg: struct { a: u64, b: u64, c: u64 },
    go: void,
};

pub const BootResp = union(enum(u64)) {
    ok: void,
    refused: void,
};

/// The logging service protocol: 24 bytes of text packed into the words.
pub const LogMsg = union(enum(u64)) {
    text: struct { a: u64, b: u64, c: u64 },
};

/// One-time configuration a spawner sends a proxy before it starts serving:
/// the upstream channel cap rides as the attachment.
pub const ProxyCfg = union(enum(u64)) {
    upstream: void,
};

pub const ProxyCfgReply = union(enum(u64)) {
    ok: void,
};

/// The block service protocol. Data moves through a shared-memory buffer
/// the client grants once via setup; read/write name a sector run (count
/// 1..8, one virtio request) and an offset into that buffer. flush is a
/// durability barrier (virtio T_FLUSH); if the device did not offer the
/// flush feature it succeeds as a no-op and the driver logs the weakness.
pub const BlkReq = union(enum(u64)) {
    setup: void, // + shm cap attachment
    capacity: void,
    read: struct { sector: u64, off: u64, count: u64 },
    write: struct { sector: u64, off: u64, count: u64 },
    flush: void,
    /// Ring transport setup over the sync channel (one cap each):
    ring_setup: void, // + ring shm cap
    ring_sq_bell: void, // + notification the client rings after submitting
    ring_cq_bell: void, // + notification the server rings after completing
};

pub const blk_max_sectors: u64 = 64; // 32KB per request (one driver DMA slot)

pub const BlkResp = union(enum(u64)) {
    ok: void,
    capacity: struct { sectors: u64 },
    io_err: struct { code: u64 },
};

/// The display server's surface protocol (gpusvc). A client creates a
/// surface — a shared pixel buffer it draws XRGB into — and commits a
/// damage rect, at which the server copies that rectangle into the
/// scanout's framebuffer and flushes it to the host. Rects pack two u32
/// into a u64 (xy = x<<32 | y, wh = w<<32 | h) to fit the four-word ABI.
/// `create_surface` flag: cascade this window off any it would fully cover.
pub const gpu_place_cascade: u64 = 1;

pub const GpuReq = union(enum(u64)) {
    /// A surface at `xy` (x<<32 | y on the scanout) of size `wh`. The
    /// reply carries the surface id and its size, and a shm cap the client
    /// maps and draws. Later surfaces stack above earlier ones. A
    /// full-scanout surface at (0,0) is the single-window case. `flags`:
    /// `gpu_place_cascade` asks the compositor to nudge the window off any
    /// it would land squarely on top of, returning the final origin in the
    /// reply's `xy` (movable app windows set it; menus/exact placements
    /// leave it 0). Other bits reserved, pass 0.
    create_surface: struct { xy: u64, wh: u64, flags: u64 = 0 },
    /// A surface's damage rect changed (`xy`/`wh` in surface-local
    /// coordinates); the compositor recomposites the scanout and flushes.
    commit: struct { surface: u64, xy: u64, wh: u64 },
    /// Release a surface and its buffer.
    destroy_surface: struct { surface: u64 },
    /// Reposition a surface (its owner only): `xy` packs the new top-left
    /// as `packPair(x, y)`, clamped to the scanout. The compositor
    /// repaints the vacated and the newly-covered area. A window's own
    /// runtime sends this as the user drags its titlebar. -> ok.
    move_surface: struct { surface: u64, xy: u64 },
    /// Name a surface (its owner only): `a`/`b` carry up to 16 bytes of a
    /// title (`strToWords`). The compositor keeps it so a window can be
    /// found again by name — the dock restores a minimized window by its
    /// title (`restore_titled`). Sent once, right after `create_surface`.
    /// -> ok.
    set_title: struct { surface: u64, a: u64, b: u64 },
    /// Show or hide a surface (its owner only): `visible` 0 hides it (it
    /// stops compositing and drops focus to the topmost visible surface,
    /// its buffer retained), non-zero shows it again. A window minimizes
    /// itself by hiding (the amber traffic-light); the dock restores it.
    /// -> ok.
    set_visible: struct { surface: u64, visible: u64 },
    /// Restore (show, raise, and focus) the surface whose title matches the
    /// 16 bytes in `a`/`b` (`strToWords`) — the dock sends this when its
    /// pill for an already-running app is clicked, so a minimized window
    /// comes back instead of the app relaunching. The owner is woken with a
    /// `kind` 3 restore event so it repaints. -> ok when one matched, else
    /// `gpu_err` (nothing by that title) so the dock launches instead.
    restore_titled: struct { a: u64, b: u64 },
    /// Earn a uniquely-badged channel so several windows from different
    /// processes are told apart (their surfaces and input readers are keyed
    /// by badge). An ordinary GUI client registers once on start and drives
    /// the badged channel thereafter; the trusted login uses `attach_trusted`
    /// instead. -> registered + a badged channel cap.
    register: void,
    /// Block until the next input event, returned tagged with the surface
    /// that has focus — the compositor routes the keyboard to the
    /// focused window and handles focus-switch keys itself. (Needs the
    /// compositor to hold a keyboard; only the seat/focus profiles do.)
    /// A key is returned only to the client that owns the focused surface,
    /// so a keystroke meant for one window never leaks to another.
    next_input: void,
    /// Like `next_input`, but the reader also wants a periodic *tick*: if
    /// no real input arrives within `ms` (rounded to the 100ms timer), the
    /// compositor answers with a `kind` 2 event (arg 0) so a client can
    /// re-render on a clock — a live GUI without a busy-wait. The client
    /// re-issues it to keep ticking; `ms` 0 behaves as plain `next_input`.
    next_input_tick: struct { ms: u64 },
    /// Claim the trusted path by presenting the boot-provisioned trust
    /// token. On a match the reply is `trusted` + a badged channel the
    /// client drives instead of the shared display channel; surfaces made
    /// over it are the login surface (unspoofable focus indicator, keys
    /// isolated to it). A wrong or absent token is refused.
    attach_trusted: struct { token: u64 },
};
pub const GpuResp = union(enum(u64)) {
    ok: void,
    /// + a shm cap attachment: the surface's pixel buffer. `xy` is the
    /// origin the compositor actually placed it at (`packPair(x, y)`) —
    /// usually what the client asked for, but nudged when it would have
    /// landed on top of another window (see `cascadePlace`), so the client
    /// adopts it for hit-testing and later moves.
    created: struct { surface: u64, wh: u64, xy: u64 },
    /// An input event delivered to a surface (a message payload is only
    /// three words, so the event packs into `arg`). `kind` 0 is a keystroke
    /// to the focused surface: `arg` is the character. `kind` 1 is a
    /// pointer event to the surface under the cursor: `arg` packs the
    /// surface-local position and button bitmask as `ptrArg(x, y, btn)`
    /// (`x`/`y` fit 16 bits each on this scanout, `btn` bit0 = left).
    /// Pointer events arrive on a button change or while a button is held
    /// (a drag), never on a bare move — a hovering cursor never wakes the
    /// client. `kind` 2 is a timer *tick* (arg 0): no input happened, the
    /// deadline from `next_input_tick` elapsed — the client re-renders.
    /// `kind` 3 is a *restore* (arg 0): the compositor un-minimized this
    /// surface (a `restore_titled` from the dock) — the client clears its
    /// minimized state and repaints.
    input: struct { surface: u64, kind: u64 = 0, arg: u64 = 0 },
    /// The trust token matched: + a badged channel cap the client uses in
    /// place of the shared display channel for all further requests.
    trusted: void,
    /// A `register` succeeded: + a uniquely-badged channel cap.
    registered: void,
    gpu_err: struct { code: u64 },
};

/// The system font service (fontsvc). A client attaches a request/response
/// buffer and maps the shared glyph atlas once, then `layout`s each string:
/// fontsvc shapes it, rasterizes any new glyphs into the atlas, and writes
/// the glyph run back into the buffer. Rendering stays client-side — the
/// client blits coverage from the atlas into its own surface with its own
/// colour — so fontsvc never draws and never learns anyone's pixels; it is
/// the one place fonts are parsed, rasterized, cached, and scaled.
pub const FontReq = union(enum(u64)) {
    /// The client's request/response buffer (a shm cap): the UTF-8 string
    /// goes in at buf[0..len], the glyph run comes back. Attached once.
    attach_buf: void,
    /// Hand back the shared glyph atlas (an 8-bit coverage bitmap the
    /// client maps read-only). Reply `atlas` + the cap.
    atlas: void,
    /// Lay out and rasterize buf[0..len] in `role` at `px` device pixels
    /// (0 = the role's effective size, scale already applied). fontsvc
    /// ensures each glyph is in the atlas and writes `count` FontGlyph
    /// records back into the buffer.
    layout: struct { role: u64, px: u64, len: u64 },
    /// The effective metrics for a role (its size after scaling, and the
    /// line height) — so a client can lay a column out before drawing.
    metrics: struct { role: u64 },
    /// Re-scan the filesystem fonts directory: a font dropped there since
    /// startup is registered without restarting the service. Reply `ok`.
    rescan: void,
    /// Apply a per-user settings layer: buf[0..len] holds the user's
    /// `font.msh` (an mshl data literal), which fontsvc merges over the
    /// system layer (lib/settings) and re-applies — so a session can push
    /// the logged-in user's scale/sizes/families to the shared service.
    /// `len` 0 reverts to the system layer alone (logout). Reply `ok`.
    reconfigure: struct { len: u64 },
    /// The effective appearance (theme + accessibility) from the settings
    /// layer, so a GUI client can resolve its palette from the same
    /// system/user layers that carry the font scale. Reply `appearance`.
    appearance: void,
    /// Ask for a channel badged with a fresh client id, so several GUI
    /// clients (windows) that share this service are told apart and each
    /// gets its own request buffer — without it their `attach_buf`s would
    /// trample one global buffer. Reply `registered` + the badged cap. An
    /// unregistered client keeps badge 0 (one shared slot, the single-client
    /// legacy: the terminal, a drill).
    register: void,
};

/// The appearance settings a GUI resolves its colour palette from — three
/// independent axes, so they compose (e.g. dark + high-contrast +
/// colourblind-safe). Carried in the same settings layer as the font
/// scale (conf/font.msh), served by fontsvc, packed into one word.
pub const Theme = enum(u8) { dark = 0, light = 1 };
pub const Contrast = enum(u8) { normal = 0, high = 1 };
pub const ColorMode = enum(u8) { default = 0, cb_safe = 1 };
/// Pack the effective appearance for fontsvc's `appearance` reply: the
/// theme/contrast/colours in bytes 0/1/2, and which of those axes the
/// system layer LOCKS (a user cannot override) in byte 3 — bit 0 theme,
/// bit 1 contrast, bit 2 colours — so a settings UI can render a locked
/// control as non-editable.
pub fn packAppearance(t: Theme, c: Contrast, m: ColorMode, locked: u64) u64 {
    return @as(u64, @intFromEnum(t)) | (@as(u64, @intFromEnum(c)) << 8) | (@as(u64, @intFromEnum(m)) << 16) | ((locked & 0x7) << 24);
}
pub fn apTheme(flags: u64) Theme {
    return if (flags & 0xff == @intFromEnum(Theme.light)) .light else .dark;
}
pub fn apContrast(flags: u64) Contrast {
    return if ((flags >> 8) & 0xff == @intFromEnum(Contrast.high)) .high else .normal;
}
pub fn apColors(flags: u64) ColorMode {
    return if ((flags >> 16) & 0xff == @intFromEnum(ColorMode.cb_safe)) .cb_safe else .default;
}
/// The locked-axes mask (bit 0 theme, 1 contrast, 2 colours).
pub fn apLocked(flags: u64) u64 {
    return (flags >> 24) & 0x7;
}

pub const FontResp = union(enum(u64)) {
    ok: void,
    /// + the atlas shm cap; `wh` = width<<32 | height (pixels).
    atlas: struct { wh: u64 },
    /// The glyph run is `count` FontGlyph records at buf[0..]; `pen` packs
    /// the total advance width<<32 | line height (device px).
    laid: struct { count: u64, pen: u64 },
    /// Role metrics (device px): the effective size, the line height, and
    /// the ascent (baseline offset from the top of a line).
    metrics: struct { px: u64, line: u64, ascent: u64 },
    /// The effective appearance, packed by `packAppearance`.
    appearance: struct { flags: u64 },
    /// `register`'s answer: a channel badged with a fresh client id is
    /// attached (the client uses it for every later request).
    registered: void,
    font_err: struct { code: u64 },
};

/// The locale service (localesvc): a client formats numbers/dates/money and
/// reads/sets the session's locale through it, so one shared choice drives
/// every text a session shows. Like fontsvc, a client `register`s for a
/// badged channel and attaches its own request/response buffer (strings —
/// the locale tag, a currency code, the formatted result — cross through
/// it, keyed by badge so concurrent clients do not trample one buffer).
pub const LocaleReq = union(enum(u64)) {
    /// A badged channel so several clients each get their own buffer.
    register: void,
    /// The client's request/response buffer (a shm cap). Attached once.
    attach_buf: void,
    /// Format a value and write the result back into the buffer. `arg` is
    /// the value — f64 bits (number/money) or an i64 (int); ignored for
    /// date/time. `meta` packs the rest (a typed message holds only its tag
    /// plus three payload words, so the small fields share one):
    /// `kind` in bits 0..7 (0 number, 1 int, 2 money, 3 date, 4 time),
    /// `taglen` in bits 8..31 (the locale tag is `buf[0..taglen]`, empty =
    /// the session default), and `extra` in bits 32..63 — for money the
    /// currency-code length (it follows the tag in the buffer), for
    /// date/time the width (0 medium, 1 long). Reply `formatted` + the byte
    /// length, or `loc_err` (unknown locale / no clock).
    fmt: struct { arg: u64, meta: u64 },
    /// The known locales: the CLDR release then each tag, newline-joined,
    /// written into the buffer. Reply `formatted` + the length.
    locales: void,
    /// Set the session's default locale to `buf[0..taglen]` (empty reverts
    /// to the built-in default). Reply `ok` or `loc_err` for an unknown tag.
    set_default: struct { taglen: u64 },
    /// The current session default locale tag, into the buffer. Reply
    /// `formatted` + the length.
    get_default: void,
};
pub const LocaleResp = union(enum(u64)) {
    ok: void,
    /// A channel badged with a fresh client id is attached.
    registered: void,
    /// The result string is in the client buffer at [0..len].
    formatted: struct { len: u64 },
    loc_err: struct { code: u64 },
};

/// One laid-out glyph in the run fontsvc writes into the client buffer.
/// The client blits the `w`×`h` coverage rect at (`atlas_x`, `atlas_y`)
/// from the atlas to (origin_x + pen_x + left, baseline_y + top), blending
/// its own foreground by the coverage. `top` is the bitmap top edge as a
/// signed device-y offset from the baseline — negative for the usual case
/// of a glyph reaching above it. A 16-byte record (align 4).
pub const FontGlyph = extern struct {
    pen_x: i32, // cumulative advance before this glyph, device px
    atlas_x: u16,
    atlas_y: u16,
    w: u16,
    h: u16,
    left: i16, // bitmap left edge, from the pen
    top: i16, // bitmap top edge from the baseline (negative = above)
};

/// The text roles a client asks for; fontsvc maps each to a family and a
/// base size, then applies the accessibility scale.
pub const FontRole = enum(u64) { ui = 0, title = 1, mono = 2 };

/// Pack/unpack a rect's two u32 halves into the u64 fields above.
pub fn packPair(a: u32, b: u32) u64 {
    return (@as(u64, a) << 32) | b;
}
pub fn unpackHi(v: u64) u32 {
    return @truncate(v >> 32);
}
pub fn unpackLo(v: u64) u32 {
    return @truncate(v);
}

/// Pack a pointer event's surface-local position and button bitmask into
/// one word (GpuResp.input `arg` when kind is 1): x in bits 32..47, y in
/// bits 16..31, buttons in bits 0..15.
pub fn ptrArg(x: u64, y: u64, btn: u64) u64 {
    return ((x & 0xffff) << 32) | ((y & 0xffff) << 16) | (btn & 0xffff);
}
pub fn ptrX(arg: u64) u64 {
    return (arg >> 32) & 0xffff;
}
pub fn ptrY(arg: u64) u64 {
    return (arg >> 16) & 0xffff;
}
pub fn ptrBtn(arg: u64) u64 {
    return arg & 0xffff;
}

pub const blk_sector_size: u64 = 512;

// ---------------------------------------------------------------- console
//
// The console service protocol (virtio-console driver): a raw byte pipe
// for one client. Bytes move through a shared buffer granted via setup;
// read blocks until at least one byte is available. Echo and line
// discipline belong to the client (msh).

pub const ConsReq = union(enum(u64)) {
    setup: void, // + shm cap: the byte buffer
    read: struct { max: u64 }, // -> bytes at buf[0..n]
    write: struct { len: u64 }, // <- bytes from buf[0..len]
};

pub const ConsResp = union(enum(u64)) {
    ok: void,
    n: struct { n: u64 },
    cons_err: struct { code: u64 },
};

/// The pointer service — inputsvc in pointer mode, driving a virtio-input
/// tablet (absolute coordinates). A `read` blocks until the next pointer
/// frame and returns the absolute position (0..32767 on each axis, the
/// tablet's range) and the button bitmask (bit0 left, bit1 right, bit2
/// middle). The compositor scales the position to the scanout and
/// hit-tests; keeping the raw device range here leaves inputsvc unaware of
/// the display geometry.
pub const PtrReq = union(enum(u64)) {
    read: void,
};

pub const PtrResp = union(enum(u64)) {
    moved: struct { x: u64, y: u64, buttons: u64 },
    ptr_err: struct { code: u64 },
};

// ---------------------------------------------------------------- entropy
//
// The kernel entropy pool (kernel/rng.zig) is a ChaCha8 fast-key-erasure
// CSPRNG seeded only through rng_seed; the userspace virtio-rng driver
// (user/rng.zig, device id 4) harvests hardware entropy and holds the
// entropy cap. getrandom serves at most rng_max_request bytes per call
// (a bound on time under the kernel lock, not a throughput limit), and
// refuses with bad_state until the first seed has landed.

pub const rng_max_request: u64 = 256;
pub const rng_min_seed: u64 = 32;

// ------------------------------------------------------------- filesystem
//
// The FS protocol. A filesystem *view* is a badged channel_b cap minted by
// the FS service: the badge selects server-side state {subtree root,
// read-only}, so per-process namespaces are pure capability topology —
// there is no way to name anything outside your view. Paths and file data
// travel through a per-view shared buffer (attach_buf); path resolution is
// strictly descending ("." and ".." are rejected).

/// View buffers are up to 8 pages (the shm ceiling); one read/write op
/// moves up to fs_max_io bytes through them. Bigger ops amortize the IPC
/// round trip AND let full 4K blocks skip the read-modify-write path.
pub const fs_buf_pages: u64 = 8;
pub const fs_max_io: u64 = fs_buf_pages * 4096;

pub const FsReq = union(enum(u64)) {
    /// + shm cap: this view's path/data buffer. (Badge 0's buffer, the
    /// volume key, and the disk arrive over the boot channel: BootReq
    /// `buf`, `secret` (32 bytes), `disk`.)
    attach_buf: void,
    /// create: 0 = open existing, 1 = create file (or open existing),
    /// 2 = create directory (ok if it exists), 3 = create file, O_EXCL
    open: struct { path_off: u64, path_len: u64, create: u64 },
    read: struct { fd: u64, off: u64, len: u64 }, // data lands in buf[0..n]
    write: struct { fd: u64, off: u64, len: u64 }, // data taken from buf[0..n]
    list: struct { path_off: u64, path_len: u64 }, // names -> buf, '\n'-separated
    /// Derive a narrower view (readOnlyView and friends); the reply is
    /// `view { badge }` with a freshly minted badged channel cap attached.
    derive: struct { path_off: u64, path_len: u64, ro: u64 },
    /// Withdraw a view: from then on every call through it fails with
    /// bad_fd, whoever holds it. Allowed from the root view, or from the
    /// view that derived it. The slot is reused only once the holder's
    /// last cap dies (client_dead), so a stale cap can never alias a
    /// later view.
    revoke: struct { badge: u64 },
    /// Remove a file, symlink, or empty directory. Final symlinks are
    /// removed, never followed.
    delete: struct { path_off: u64, path_len: u64 },
    /// Atomic rename/move within one view; each word is off | len<<32.
    /// An existing target is replaced (directories only when empty).
    rename: struct { from: u64, to: u64 },
    truncate: struct { fd: u64, len: u64 },
    /// stat does not follow a final symlink.
    stat: struct { path_off: u64, path_len: u64 },
    /// Create a symlink; each word is off | len<<32. The target is stored
    /// verbatim and resolves relative to the link's containing directory.
    symlink: struct { path: u64, target: u64 },
    readlink: struct { path_off: u64, path_len: u64 }, // target -> buf
    /// Durability barrier: everything acknowledged is on disk on reply.
    sync: void,
    /// Volume stats (the `df` shape): free/total 4K blocks + encryption.
    statfs: void,
    close: struct { fd: u64 },
};

pub const FsResp = union(enum(u64)) {
    ok: void,
    /// derive's answer: the new view's badge (its name for `revoke`),
    /// with the view cap attached.
    view: struct { badge: u64 },
    num: struct { n: u64 },
    stat: struct { typ: u64, size: u64, mtime: u64 }, // typ: FsType
    // `flags`: bit 0 = the volume is encrypted, bit 1 = this view is
    // read-only. Packed into one word because a typed message carries only
    // its tag plus three payload words.
    statfs: struct { free_blocks: u64, total_blocks: u64, flags: u64 },
    fs_err: struct { code: u64 },
};

/// Object types as reported by stat (mirrors mossfs.ObjType).
pub const FsType = enum(u64) { file = 1, dir = 2, symlink = 3 };

pub const FsErr = enum(u64) {
    denied = 1, // read-only view
    not_found = 2,
    no_space = 3,
    bad_path = 4, // "..", absolute, malformed, or symlink loop
    bad_fd = 5,
    exists = 6,
    io = 7,
    not_empty = 8, // directory delete/replace target not empty
    bad_key = 9, // wrong or missing volume key
};

/// Boot filesystem archive ("MARC"): a flat sequence of
/// { path_len: u32 LE, data_len: u32 LE, path bytes, data bytes }.
pub const marc_magic = "MARC";

// ------------------------------------------------------------- networking
//
// The net service protocol. Like filesystems, network access is a badged
// view: the badge selects server-side filter state. An unrestricted view
// can derive filtered ones (allowlist of one destination, no listening) —
// allowlist-shaped network access as the sandbox idiom. Blocking ops are
// polled (would_block) so one serve loop handles every client; the async
// ring transport is the future home of real wakeups.
//
// Addressing is IPv6-native: every address is 128 bits, carried as two
// words (hi = bytes 0..8 big-endian, lo = bytes 8..16). IPv4 destinations
// are v4-mapped (::ffff:a.b.c.d) — the ABI has no IPv4-only path to
// depend on, and the stack speaks both families on the wire.

pub const NetReq = union(enum(u64)) {
    attach_buf: void, // + shm cap: payload buffer for this view
    tcp_listen: struct { port: u64 }, // family-agnostic
    tcp_connect: struct { ip_hi: u64, ip_lo: u64, port: u64 },
    tcp_status: struct { sock: u64 }, // -> num(TcpState)
    tcp_accept: struct { sock: u64 }, // -> num(new sock) | would_block
    tcp_send: struct { sock: u64, len: u64 }, // data from buf[0..len]
    tcp_recv: struct { sock: u64, len: u64 }, // data into buf[0..n]
    tcp_close: struct { sock: u64 },
    /// ICMP echo (v6 or v4 by address); poll ping_check for replies seen.
    ping: struct { ip_hi: u64, ip_lo: u64 },
    ping_check: void, // -> num(replies received so far)
    /// Unrestricted views only: mint a filtered view allowing exactly one
    /// outbound destination (and no listening). Reply attaches the cap.
    derive: struct { ip_hi: u64, ip_lo: u64, port: u64 },
    /// Hand a connected socket to a fresh net view: its ownership moves
    /// to a new badge, and the reply attaches a channel cap to that view.
    /// Whoever holds the cap owns exactly this socket (by the same
    /// number) and nothing else — a socket crossing to another domain,
    /// the cap being the authority. The caller's view can no longer use
    /// the socket. The new owner re-`watch`es it for its own doorbell.
    handoff: struct { sock: u64 },
    /// + notification cap: the socket's doorbell. Signaled (bit 1) when
    /// it has news — data, a state change, a connection to accept — so a
    /// client can block in recv with the notification bound instead of
    /// polling. One bell per socket; dropped with the socket. A UDP
    /// socket (its number is udp_sock_base + slot) takes one too.
    watch: struct { sock: u64 },
    /// Datagrams. `udp_bind` takes a port (0: an ephemeral one) and
    /// answers num(sock), numbered from udp_sock_base; a filtered view
    /// may bind ephemerally only, and hears only from its allowed
    /// destination. `udp_send` sends buf[udp_hdr..udp_hdr+len] to the
    /// address at buf[0..16] (the view's allowlist judges it) and the
    /// port; `udp_recv` puts the source address at buf[0..16], its port
    /// big-endian at buf[16..18], and the datagram at buf[udp_hdr..],
    /// answering num(len) or would_block. `tcp_close` closes either kind.
    udp_bind: struct { port: u64 },
    udp_send: struct { sock: u64, port: u64, len: u64 },
    udp_recv: struct { sock: u64, len: u64 },
    /// Name resolution. `resolve` takes the name at buf[0..len] and
    /// answers num(lookup), numbered from lookup_base — a `watch` on it
    /// rings when the answer is in; `resolve_check` then answers
    /// would_block, num(n) with the n addresses at buf[0..16n] (the TTL
    /// in seconds big-endian at buf[16n..16n+4]), or an error
    /// (nxdomain, timeout, no_resolver); either answer frees the lookup.
    /// Any view may resolve: a name is a question, the address it
    /// yields is what the allowlist judges.
    resolve: struct { len: u64 },
    resolve_check: struct { lookup: u64 },
};

/// The calendar: Unix time to dates and back, ISO and HTTP text.
pub const civil = @import("civil.zig");
/// The 8x16 console font (printable ASCII), shared by the kernel's
/// framebuffer console and the userspace terminal.
pub const font8x16 = @import("font8x16.zig");

/// Lookups are numbered from here.
pub const lookup_base: u64 = 2000;
/// The most addresses one lookup answers.
pub const resolve_max: u64 = 8;

/// Where a UDP datagram's bytes start in the view buffer, after the
/// address and port of its peer.
pub const udp_hdr: u64 = 32;
/// The largest datagram sent or delivered (an IPv6 MTU's worth).
pub const udp_max: u64 = 1452;
/// UDP sockets are numbered from here, so one `watch`/`close` serves both kinds.
pub const udp_sock_base: u64 = 1000;

/// v4-mapped IPv6 words for an IPv4 address given as 0xAABBCCDD.
pub fn v4Words(ip: u32) [2]u64 {
    return .{ 0, 0x0000_ffff_0000_0000 | @as(u64, ip) };
}

/// The most a tcp_send queues at once (it is all or would_block) and
/// the most a tcp_recv returns: a whole bulk-transport buffer, so a
/// remote home's read-ahead window crosses in one exchange. A view's
/// buffer is net_buf_pages (attach that many).
pub const net_buf_pages: u64 = 8;
pub const net_max_send: u64 = net_buf_pages * 4096;
pub const net_max_recv: u64 = net_buf_pages * 4096;

pub const NetResp = union(enum(u64)) {
    ok: void,
    num: struct { n: u64 },
    net_err: struct { code: u64 },
};

pub const NetErr = enum(u64) {
    would_block = 1,
    denied = 2,
    refused = 3,
    closed = 4,
    bad = 5,
    no_space = 6,
    /// Resolution: the name does not exist (or has no address), no
    /// resolver answered, no resolver is configured.
    nxdomain = 7,
    timeout = 8,
    no_resolver = 9,
};

pub const TcpState = enum(u64) {
    closed = 0,
    listen = 1,
    syn_sent = 2,
    syn_rcvd = 3,
    established = 4,
    close_wait = 5,
};

// -------------------------------------------------------- remote stages
//
// A script as a remote service: mshrun spawned by the fabric (arg 1)
// serves this on its channel. The client attaches a buffer (which the
// fabric proxies as a session buffer), writes the script text and the
// pipeline input as a data literal into it, and asks for `run`; the
// value comes back as a data literal in the same buffer.
pub const RunReq = union(enum(u64)) {
    attach_buf: void, // + shm cap
    /// buf[0..script_len] is the script; buf[script_len..+input_len] the
    /// input as a data literal (0 = no input, $in is nothing).
    run: struct { script_len: u64, input_len: u64 },
};

pub const RunResp = union(enum(u64)) {
    ok: void,
    /// The value as a data literal at buf[0..len] (0 = nothing).
    value: struct { len: u64 },
    /// The error message at buf[0..len].
    failed: struct { len: u64 },
    refused: void,
};

/// A worker (a `spawn`ed mshrun serving a typed channel): the buffer is
/// attached once, the handler's source set once, then each `call` sends
/// a request (a data literal in the buffer) and gets the handler's value
/// back the same way. Unlike the remote stage, the worker loops — it
/// answers many calls and lives until the channel closes.
pub const WorkReq = union(enum(u64)) {
    attach_buf: void, // + shm cap
    /// + a filesystem view cap: the handler's fs commands work on it. The
    /// caller derives a fresh view (the worker's own badge) from its own,
    /// so the worker is its agent without sharing a view buffer. Optional,
    /// set once, before the handler.
    attach_view: void,
    /// + a network view cap (a socket handed off to this worker): the
    /// worker's net commands work on it. Set before `serve`.
    attach_net: void,
    /// Run the handler with `$in` a `socket` for the handed-off socket
    /// `idx` on the attached net view (not a data literal): a worker
    /// serving a connection. The reply is the handler's value, as `call`.
    serve: struct { idx: u64 },
    /// + a notification cap: the doorbell the worker rings (with bit
    /// 1<<`bit`) each time a `dispatch` finishes, so the caller can wait
    /// on the first of many to complete (`race`). Optional, set once.
    attach_bell: struct { bit: u64 },
    /// The handler function's source at buf[0..len]; set once, first.
    handler: struct { len: u64 },
    /// The request (the handler's `$in`) as a data literal at buf[0..len]
    /// (0 = nothing). Synchronous: the reply carries the value.
    call: struct { len: u64 },
    /// Async dispatch: the request at buf[0..len]. The worker replies `.ok`
    /// AT ONCE (before running the handler), so the caller does not block
    /// on the work — the worker then computes and stashes the result for
    /// the next `collect`. Two workers dispatched before either is
    /// collected run in parallel. Refused if a result is already stashed.
    dispatch: struct { len: u64 },
    /// Join a started worker: reply the stashed result (`value`/`failed`,
    /// the data in the buffer), or `refused` if none is pending.
    collect: void,
};
pub const WorkResp = union(enum(u64)) {
    ok: void,
    /// The handler's value as a data literal at buf[0..len] (0 = nothing).
    value: struct { len: u64 },
    /// The handler's error message at buf[0..len].
    failed: struct { len: u64 },
    refused: void,
};

// ---------------------------------------------------------------- fabric
//
// The multi-node fabric: init at a larger radius. Each node runs a fabric
// service; peers speak a VERSIONED wire protocol over TCP (frames:
// [len u16][type u8][ver u8][payload], little-endian). A remote channel is
// a badged cap on the local fabric service — calls forward as call_req
// frames and come back as call_resp, so remote services look exactly like
// local ones to their callers. Cluster nodes use static addressing:
// node N is 10.77.0.N / fdcc::N.

pub const fabric_port: u64 = 7100;
pub const fabric_ver: u8 = 7; // v7: cross-node signals (fw_notify); v6: bulk transport (session buffers); v5: published services; v4: per-node identities

/// set_identity record: [identity seed 32][cluster key 32]; set_cert
/// then delivers the fab_cert_len certificate (lib/fabcert.zig layout).
pub const fab_identity_len: u64 = 32 + 32;
pub const fab_cert_len: u64 = 112;
pub const fab_rev_len: u64 = 72;
/// Certificate authorization flags (mirrored in lib/fabcert.zig).
pub const fab_flag_gossip: u64 = 1 << 0;
pub const fab_flag_spawn: u64 = 1 << 1;

pub fn nodeIp4(node: u64) u32 {
    return 0x0A4D_0000 | @as(u32, @intCast(node));
}

/// Local control protocol for the fabric service (badge 0). Badged calls
/// are not FabReq: their words forward verbatim to the remote peer.
/// Boot (BootReq): `buf` (staging buffer), `secret` = fab_identity_len
/// bytes {identity seed 32, cluster key 32}, and `net` (a network view).
/// Certification is then the service-level setup: identity_key hands
/// the PUBLIC key back for the root of trust to sign, set_cert installs
/// the certificate — it can only exist after the key does — and the
/// fabric opens the network at that point and not before (fail-closed).
pub const FabReq = union(enum(u64)) {
    /// Badge-0 only: leave this node's identity public key at buf[0..32]
    /// for the root of trust to certify. -> num{32}.
    identity_key: void,
    poll: void, // pump TCP + heartbeats (the driver's tick keeps it breathing)
    /// Join the fabric: dial this seed; membership gossip does the rest.
    connect_peer: struct { node: u64 },
    /// node 0 = placement: the least-loaded live member is chosen.
    remote_spawn: struct { node: u64, image: u64, arg: u64 },
    /// Reach a durable service UNIT on `node` through its init, by NAME
    /// (two words, up to 16 bytes): the peer starts and supervises it,
    /// and hands a channel back — `dial NODE NAME`, transparent
    /// clustering. -> found { node } + a remote-channel cap.
    remote_connect: struct { node: u64, a: u64, b: u64 },
    attach_buf: void, // + shm cap: buffer for members listings (clients)
    /// Badge-0 only, once: the fab_cert_len certificate the root issued
    /// for this node. Verified under the cluster key and checked to name
    /// this node and this identity key — refused here rather than at the
    /// first handshake. Accepting it opens the network.
    set_cert: struct { off: u64, len: u64 },
    /// Badge-0 only: a fab_rev_len revocation record signed by the root
    /// of trust, in the attached buffer. Verified, applied (matching live
    /// peers are dropped), and gossiped to every peer.
    revoke: struct { off: u64, len: u64 },
    /// Fill the attached buffer with fab_member_size-byte records
    /// {node u16, up u8, self u8, free_mb u16, pad u16}; reply num{n}.
    members: void,
    /// num{the most wire exchanges this node has had in flight at once}.
    stats: void,
    /// + channel_b cap: offer that channel to the pool under a NAME (two
    /// words, up to 16 bytes), so any member can `lookup` it here by that
    /// name. Local (unbadged) callers only.
    publish: struct { a: u64, b: u64 },
    /// A channel to the service `node` published under that NAME (two
    /// words): the reply is `found { node }` with a remote-channel cap
    /// (a local copy of the export when node is this node).
    lookup: struct { node: u64, a: u64, b: u64 },
    /// + a notification cap: publish it to the pool under a NAME (two
    /// words) as a *signal* export, so a peer can `signal` it by name and
    /// ring the notification this node waits on. Local (unbadged) only.
    publish_signal: struct { a: u64, b: u64 },
    /// Ring the signal a peer published under NAME (two words): send a
    /// one-way `fw_notify` to `node` carrying `bits`. `node_bits` packs the
    /// node (low 16) and the 48-bit bits (high 48). Reply `ok` once the
    /// frame is sent (the peer is a reachable member), else `fab_err`.
    signal: struct { a: u64, b: u64, node_bits: u64 },
    /// This node's live view of one member: reply `num{n}` with
    /// n = 0 unknown (never heard of), 1 down, 2 up. A race-free
    /// single-word query (no shared listing buffer) — dnsd resolves
    /// `nodeN.moss.test` from it, so cluster names track membership.
    member_state: struct { node: u64 },
};

/// Pack a node id (u16) and 48-bit signal bits into one word for
/// `FabReq.signal`; the fabric surface's `signal NODE NAME BITS` is
/// limited to 48-bit bits because they ride packed with the node.
pub fn packNodeBits(node: u64, bits: u64) u64 {
    return (node & 0xffff) | ((bits & 0xffff_ffff_ffff) << 16);
}
pub fn nbNode(nb: u64) u64 {
    return nb & 0xffff;
}
pub fn nbBits(nb: u64) u64 {
    return (nb >> 16) & 0xffff_ffff_ffff;
}

pub const FabResp = union(enum(u64)) {
    ok: void,
    spawned: struct { node: u64 }, // + remote-channel cap; node = where
    found: struct { node: u64 }, // + remote-channel cap to a published service
    num: struct { n: u64 },
    fab_err: struct { code: u64 },
};

pub const fab_member_size: usize = 8;

pub const FabErr = enum(u64) {
    no_peer = 1,
    timeout = 2,
    disconnected = 3,
    refused = 4,
    no_space = 5,
    no_identity = 6, // fail-closed: no identity/certificate was staged
    no_entropy = 7, // fail-closed: the kernel pool is unseeded (no rngd)
    denied = 8, // the peer's certificate does not authorize the request
};

/// The root of trust (fabric role 3, "fabroot"): the one holder of the
/// cluster's root signing key. Boot: `buf` + `secret` (the 32-byte root
/// seed). Orchestration then asks it for the cluster key, node
/// certificates, and revocations; fabsvc never sees the root key.
/// Replies are FabResp; byte artifacts land at buf[0].
pub const RootReq = union(enum(u64)) {
    cluster_key: void, // -> 32 bytes at buf[0]; num{32}
    /// Certificate for `node`, whose identity PUBLIC key sits at
    /// buf[0..32] (the root never sees a node's secret): flags_serial =
    /// flags | serial << 8, image_mask = images the holder may request.
    /// -> fab_cert_len bytes at buf[0].
    issue: struct { node: u64, flags_serial: u64, image_mask: u64 },
    /// Revocation record: certs of `node` below min_serial are refused.
    revoke: struct { node: u64, min_serial: u64 }, // -> fab_rev_len bytes
};

/// Badged-session error reply sentinel: word0 = this, word1 = FabErr code.
/// (No sane protocol tag collides with it.)
pub const fabric_err_sentinel: u64 = 0xffff_ffff_ffff_ffff;

// Wire frame types.
pub const fw_hello: u8 = 1;
pub const fw_hello_ack: u8 = 2;
pub const fw_spawn_req: u8 = 3;
pub const fw_spawn_ack: u8 = 4;
// Remote calls: [export u32][seq u32][4 x u64][export-of-attached-cap u32]
// and [seq u32][ok u8][4 x u64][export-of-reply-cap u32]. An EXPORT is a
// channel a node has made reachable by its peers under a small id (a
// remotely spawned child's channel, or any channel cap a caller attached
// to a call or a server attached to a reply); the other side binds a
// badged session to (node, export) and hands out the badge as an
// ordinary channel cap. That is cap transfer across the wire: a channel
// that crosses the network is a slower channel, in both directions. Many
// exchanges may be in flight per link; seq matches responses.
pub const fw_call_req: u8 = 5;
pub const fw_call_resp: u8 = 6;
// v2+: membership + liveness frames.
pub const fw_ping: u8 = 7; // [free_mb u16] heartbeat + load advertisement
pub const fw_pong: u8 = 8; // [free_mb u16]
pub const fw_member_up: u8 = 9; // [node u16]
pub const fw_member_down: u8 = 10; // [node u16]
// v4: per-node identities. Each node holds an Ed25519 identity key and a
// certificate signed by the cluster's root of trust (lib/fabcert.zig:
// node id, identity key, authorization flags + image mask, serial). The
// handshake is a signed ephemeral Diffie-Hellman — no shared secret
// exists anywhere:
//   dialer   -> fw_hello     [node u16][nonce 16][eph X25519 pk 32][cert 112]
//   acceptor -> fw_hello_ack [node u16][nonce 16][eph pk 32][cert 112]
//                            [sig64: identity key over the "ack" transcript]
//   dialer   -> fw_auth      [sig64: identity key over the "auth" transcript]
// Each side verifies the peer's certificate under the cluster key (node
// id must match the claim; serial must clear any revocation it knows),
// then the transcript signature under the certified identity key. The
// transcript covers the wire version, both node ids, nonces, ephemeral
// keys, and certificates, so downgrade or substitution breaks the
// signature. HKDF(X25519 shared secret, both nonces) derives per-
// direction AEGIS-128L session keys (forward secrecy: identity keys only
// sign) and EVERY subsequent frame travels as fw_sealed [ciphertext of a
// whole inner frame][tag 16] with counter nonces (TCP orders the stream).
// Membership gossip rides a sealed fw_members frame [free_mb u16][n u8]
// [{node u16, up u8} x n] and is believed only from peers whose cert
// carries the gossip flag; spawn requests need the spawn flag and the
// image bit. fw_revoke carries a root-signed revocation record (72
// bytes); it is verified, applied, and re-gossiped once.
pub const fw_auth: u8 = 11;
pub const fw_sealed: u8 = 12;
pub const fw_members: u8 = 13;
pub const fw_revoke: u8 = 14;
/// Published services: lookup_req [service u16][req u32] -> lookup_ack
/// [req u32][export u32][code u8] (1 = found, 0 = nothing published).
pub const fw_lookup_req: u8 = 15;
pub const fw_lookup_ack: u8 = 16;
// v6: bulk transport. A shared-memory cap attached to a badged call
// does not cross; instead it becomes the SESSION'S BUFFER: the fabric
// maps it, tells the peer how many pages (call_req gained [buf_pages
// u16]), and the peer creates a twin and attaches THAT to the exported
// channel. From then on every call ships what changed in the caller's
// buffer since the last exchange (fw_bulk, before the call_req) and
// every reply ships what the service changed in the twin (fw_bulk_resp,
// before the call_resp) — protocols that move bytes through an attached
// buffer (the filesystem view, a script's input and value) cross the
// wire unmodified.
pub const fw_bulk: u8 = 17; // [export u32][off u32][len u16][bytes]
pub const fw_bulk_resp: u8 = 18; // [seq u32][off u32][len u16][bytes]
/// The holder of a remote channel is gone: the export behind it (unless
/// published) is dropped — a remotely spawned child sees peer_dead.
pub const fw_release: u8 = 19; // [export u32]
pub const fw_connect_req: u8 = 20; // [service u16][req u32] -> start a service unit via the peer's init
pub const fw_connect_ack: u8 = 21; // [req u32][session u32][code u8]
// A cross-node signal: set `bits` on the notification a peer published
// under NAME (two words). One-way, no reply — the peer's fabsvc finds the
// signal export by name and rings the local notification; a name it does
// not host is dropped. `bits` is 48-bit (it rides the control call packed
// with the node id).
pub const fw_notify: u8 = 22; // [name a u64][name b u64][bits u64]
/// A session buffer is at most this many pages (32 KB: a view's buffer).
pub const fab_bulk_pages: u64 = 8;
/// One bulk frame carries at most this many bytes: a whole 32 KB
/// buffer's worth, so a diff that big is one frame (the seal's tag and
/// the headers fit beside it in one tcp_send).
pub const fab_bulk_chunk: usize = 32000;
/// Services a node may publish to the pool (slots in fabsvc's table).

// QEMU slirp constants (static config; DHCP/SLAAC are not Phase 10
// problems). v4 net 10.0.2.0/24, v6 prefix fec0::/64.
pub const net_own_ip4: u32 = 0x0A00_020F; // 10.0.2.15
pub const net_gw_ip4: u32 = 0x0A00_0202; // 10.0.2.2
pub const net_echo_ip4: u32 = 0x0A00_0264; // 10.0.2.100 (guestfwd echo)
pub const net_echo_port: u64 = 9000;
pub const net_own_ip6: [2]u64 = .{ 0xfec0_0000_0000_0000, 0x15 }; // fec0::15
pub const net_gw_ip6: [2]u64 = .{ 0xfec0_0000_0000_0000, 0x2 }; // fec0::2

/// Parse an address as the protocol carries it: dotted IPv4 (v4-mapped
/// on the way in) or IPv6 with one `::`. null for anything else.
/// An address as text: dotted for a v4-mapped one, else IPv6 with the
/// longest run of zero groups as `::` (RFC 5952). `out` needs 40 bytes.
pub fn formatAddr(out: []u8, words: [2]u64) []const u8 {
    if (words[0] == 0 and (words[1] >> 32) == 0x0000_ffff) {
        const ip: u32 = @truncate(words[1]);
        return std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}", .{ ip >> 24, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255 }) catch out[0..0];
    }
    var groups: [8]u16 = undefined;
    for (0..8) |i| {
        const w = if (i < 4) words[0] else words[1];
        groups[i] = @truncate(w >> @intCast((3 - (i % 4)) * 16));
    }
    // The longest run of zeros (two or more) becomes `::`.
    var best_at: usize = 8;
    var best_len: usize = 1;
    var i: usize = 0;
    while (i < 8) {
        if (groups[i] != 0) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < 8 and groups[j] == 0) j += 1;
        if (j - i > best_len) {
            best_at = i;
            best_len = j - i;
        }
        i = j;
    }
    var n: usize = 0;
    i = 0;
    while (i < 8) {
        if (i == best_at) {
            out[n] = ':';
            out[n + 1] = ':';
            n += 2;
            i += best_len;
            continue;
        }
        if (n > 0 and out[n - 1] != ':') {
            out[n] = ':';
            n += 1;
        }
        const t = std.fmt.bufPrint(out[n..], "{x}", .{groups[i]}) catch return out[0..n];
        n += t.len;
        i += 1;
    }
    return out[0..n];
}

pub fn parseAddr(text: []const u8) ?[2]u64 {
    if (std.mem.indexOfScalar(u8, text, ':') == null) {
        var v: u32 = 0;
        var octets: usize = 0;
        var cur: u32 = 0;
        var have = false;
        for (text) |c| {
            if (c == '.') {
                if (!have) return null;
                v = (v << 8) | cur;
                octets += 1;
                cur = 0;
                have = false;
            } else if (c >= '0' and c <= '9') {
                cur = cur * 10 + (c - '0');
                if (cur > 255) return null;
                have = true;
            } else return null;
        }
        if (!have or octets != 3) return null;
        return v4Words((v << 8) | cur);
    }
    // IPv6: up to eight 16-bit groups, one `::` standing for the zeros.
    var groups: [8]u16 = @splat(0);
    var head: usize = 0; // groups before ::
    var tail: [8]u16 = @splat(0);
    var ntail: usize = 0;
    var seen_gap = false;
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == ':' and text[i + 1] == ':') {
            if (seen_gap) return null;
            seen_gap = true;
            i += 2;
            continue;
        }
        if (text[i] == ':') {
            i += 1;
            continue;
        }
        var j = i;
        var g: u32 = 0;
        while (j < text.len and text[j] != ':') : (j += 1) {
            const d = std.fmt.charToDigit(text[j], 16) catch return null;
            g = (g << 4) | d;
            if (g > 0xffff) return null;
        }
        if (j == i) return null;
        if (seen_gap) {
            if (ntail == 8) return null;
            tail[ntail] = @intCast(g);
            ntail += 1;
        } else {
            if (head == 8) return null;
            groups[head] = @intCast(g);
            head += 1;
        }
        i = j;
    }
    if (!seen_gap and head != 8) return null;
    if (head + ntail > 8) return null;
    for (0..ntail) |k| groups[8 - ntail + k] = tail[k];
    var hi: u64 = 0;
    var lo: u64 = 0;
    for (0..4) |k| hi = (hi << 16) | groups[k];
    for (4..8) |k| lo = (lo << 16) | groups[k];
    return .{ hi, lo };
}

test "parseAddr reads dotted v4 (mapped) and v6 with a gap" {
    try std.testing.expectEqual(v4Words(net_echo_ip4), parseAddr("10.0.2.100").?);
    try std.testing.expectEqual(net_gw_ip6, parseAddr("fec0::2").?);
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("10.0.2.100", formatAddr(&buf, v4Words(net_echo_ip4)));
    try std.testing.expectEqualStrings("fec0::2", formatAddr(&buf, net_gw_ip6));
    try std.testing.expectEqualStrings("::1", formatAddr(&buf, .{ 0, 1 }));
    try std.testing.expectEqualStrings("::", formatAddr(&buf, .{ 0, 0 }));
    try std.testing.expectEqualStrings("fdcc::3", formatAddr(&buf, .{ 0xfdcc_0000_0000_0000, 3 }));
    try std.testing.expectEqualStrings("2001:db8:0:1:1::1", formatAddr(&buf, parseAddr("2001:db8:0:1:1::1").?)); // the longest run wins
    try std.testing.expectEqualStrings("2001:db8::1:0:0:1", formatAddr(&buf, parseAddr("2001:db8:0:0:1::1").?));
    for ([_][]const u8{ "1:2:3:4:5:6:7:8", "1::8", "1:0:0:2::" }) |t| {
        const round = formatAddr(&buf, parseAddr(t).?);
        try std.testing.expectEqualStrings(t, round);
    }
    try std.testing.expectEqual([2]u64{ 0, 1 }, parseAddr("::1").?);
    try std.testing.expectEqual([2]u64{ 0xfdcc_0000_0000_0000, 3 }, parseAddr("fdcc::3").?);
    try std.testing.expectEqual([2]u64{ 0x2001_0db8_0000_0000, 0x0000_0000_0000_0001 }, parseAddr("2001:db8:0:0:0:0:0:1").?);
    try std.testing.expect(parseAddr("10.0.2") == null);
    try std.testing.expect(parseAddr("10.0.2.300") == null);
    try std.testing.expect(parseAddr("fec0::2::3") == null);
    try std.testing.expect(parseAddr("host") == null);
    try std.testing.expect(parseAddr("1:2:3:4:5:6:7") == null);
}

// ---------------------------------------------------------------- rings
//
// The async transport: a submission ring and a completion ring in one
// shared page, single-producer/single-consumer each, with notification
// doorbells for wakeups. Entries carry the same typed message words as
// channels plus a correlation id — same semantics, different transport.
// The data plane needs no syscalls; only the doorbells do.

pub const ring_entries = 16;

pub const RingEntry = extern struct {
    id: u64,
    words: [4]u64,
};

pub const RingBuf = extern struct {
    sq_head: u32,
    sq_tail: u32,
    _pad0: [56]u8,
    cq_head: u32,
    cq_tail: u32,
    _pad1: [56]u8,
    sq: [ring_entries]RingEntry,
    cq: [ring_entries]RingEntry,

    pub fn init(self: *RingBuf) void {
        self.sq_head = 0;
        self.sq_tail = 0;
        self.cq_head = 0;
        self.cq_tail = 0;
    }

    pub fn sqPush(self: *RingBuf, e: RingEntry) bool {
        return push(&self.sq, &self.sq_head, &self.sq_tail, e);
    }

    pub fn sqPop(self: *RingBuf, out: *RingEntry) bool {
        return pop(&self.sq, &self.sq_head, &self.sq_tail, out);
    }

    pub fn cqPush(self: *RingBuf, e: RingEntry) bool {
        return push(&self.cq, &self.cq_head, &self.cq_tail, e);
    }

    pub fn cqPop(self: *RingBuf, out: *RingEntry) bool {
        return pop(&self.cq, &self.cq_head, &self.cq_tail, out);
    }

    fn push(ring: *[ring_entries]RingEntry, head: *u32, tail: *u32, e: RingEntry) bool {
        const t = @atomicLoad(u32, tail, .monotonic);
        const h = @atomicLoad(u32, head, .acquire);
        if (t -% h == ring_entries) return false; // full
        ring[t % ring_entries] = e;
        @atomicStore(u32, tail, t +% 1, .release);
        return true;
    }

    fn pop(ring: *[ring_entries]RingEntry, head: *u32, tail: *u32, out: *RingEntry) bool {
        const h = @atomicLoad(u32, head, .monotonic);
        const t = @atomicLoad(u32, tail, .acquire);
        if (h == t) return false; // empty
        out.* = ring[h % ring_entries];
        @atomicStore(u32, head, h +% 1, .release);
        return true;
    }
};

comptime {
    std.debug.assert(@sizeOf(RingBuf) <= 4096);
}

pub const LogReply = union(enum(u64)) {
    ok: void,
};

/// Pack a short string into three message words (nul-padded, max 24 bytes).
pub fn strToWords(s: []const u8) [3]u64 {
    var bytes: [24]u8 = @splat(0);
    const n = @min(s.len, 24);
    @memcpy(bytes[0..n], s[0..n]);
    return .{
        std.mem.readInt(u64, bytes[0..8], .little),
        std.mem.readInt(u64, bytes[8..16], .little),
        std.mem.readInt(u64, bytes[16..24], .little),
    };
}

/// Unpack; returns the slice up to the first nul within `buf`.
pub fn wordsToStr(buf: *[24]u8, w: [3]u64) []const u8 {
    std.mem.writeInt(u64, buf[0..8], w[0], .little);
    std.mem.writeInt(u64, buf[8..16], w[1], .little);
    std.mem.writeInt(u64, buf[16..24], w[2], .little);
    var n: usize = 0;
    while (n < 24 and buf[n] != 0) n += 1;
    return buf[0..n];
}

/// Header at the start of a flat user image ("MOSS" magic). Written by the
/// user program's entry assembly from linker-script symbols; read by the
/// kernel loader. All sizes are from the image base, 4K-aligned. The name
/// makes an image self-describing: it is the child's domain name and
/// must match the catalog entry it was staged from.
pub const UserImageHeader = extern struct {
    magic: u32,
    version: u32,
    text_size: u64,
    load_size: u64,
    mem_size: u64,
    name: [16]u8, // NUL-padded

    pub const expected_magic: u32 = 0x53534f4d; // "MOSS" little-endian

    pub fn nameSlice(h: *const UserImageHeader) []const u8 {
        var n: usize = 0;
        while (n < h.name.len and h.name[n] != 0) n += 1;
        return h.name[0..n];
    }
};

comptime {
    std.debug.assert(@sizeOf(UserImageHeader) == 48);
}

/// Where the catalog entry lives in the boot archive.
pub fn imagePath(id: ImageId) []const u8 {
    switch (id) {
        inline else => |t| return "img/" ++ @tagName(t),
    }
}

/// Look a path up in a MARC archive. Pure and allocation-free: usable by
/// the kernel's boot drivers, init, fssvc, and any spawner alike.
pub fn marcFind(blob: []const u8, path: []const u8) ?[]const u8 {
    if (blob.len < 4 or !std.mem.eql(u8, blob[0..4], marc_magic)) return null;
    var off: usize = 4;
    while (off + 8 <= blob.len) {
        const plen = std.mem.readInt(u32, blob[off..][0..4], .little);
        const dlen = std.mem.readInt(u32, blob[off + 4 ..][0..4], .little);
        off += 8;
        if (off + plen + dlen > blob.len) return null;
        const p = blob[off .. off + plen];
        const data = blob[off + plen .. off + plen + dlen];
        off += plen + dlen;
        if (std.mem.eql(u8, p, path)) return data;
    }
    return null;
}

/// Walk every entry of a MARC archive.
pub const MarcIter = struct {
    blob: []const u8,
    off: usize,

    pub const Entry = struct { path: []const u8, data: []const u8 };

    pub fn next(it: *MarcIter) ?Entry {
        if (it.off + 8 > it.blob.len) return null;
        const plen = std.mem.readInt(u32, it.blob[it.off..][0..4], .little);
        const dlen = std.mem.readInt(u32, it.blob[it.off + 4 ..][0..4], .little);
        const start = it.off + 8;
        if (start + plen + dlen > it.blob.len) return null;
        it.off = start + plen + dlen;
        return .{ .path = it.blob[start .. start + plen], .data = it.blob[start + plen .. start + plen + dlen] };
    }
};

pub fn marcIter(blob: []const u8) MarcIter {
    if (blob.len < 4 or !std.mem.eql(u8, blob[0..4], marc_magic)) return .{ .blob = blob, .off = blob.len };
    return .{ .blob = blob, .off = 4 };
}

/// Which units start eagerly at boot: a unit lists the profiles it is
/// eager under (`profiles: [system, blk]`). The kernel reads `profile=`
/// from the boot arguments and passes it to root, root to init, so one
/// archive serves the interactive system and every unit-file drill.
/// `login` boots the multi-user system: a login prompt on every
/// console; `session` is what a session's init starts (its units live in
/// the user's home, else the archive's conf/session/ template).
pub const BootProfile = enum(u64) { system = 0, blk = 1, fs = 2, net = 3, guest = 4, users = 5, login = 6, session = 7, flogin = 8, fjoin = 9, dot = 10, gpu = 11, term = 12, input = 13, seat = 14, gseat = 15, comp = 16, focus = 17, trust = 18, readers = 19, gui = 20, guilogin = 21, gtrust = 22, gsession = 23, lconsole = 24, gisession = 25, gboom = 26, fontrescan = 27, ptr = 28, pointer = 29, guiclick = 30, fontscale = 31, guishell = 32, fabgui = 33, fabsig = 34, fabsigtx = 35, locale = 36, localeupd = 37, desktop = 38, topbar = 39, dock = 40, listdemo = 41, explorer = 42, browse = 43, browsehost = 44, netbrowse = 45, cascade = 46, terminal = 47 };
/// A session's unit template in the boot archive.
pub const session_unit_dir = "conf/session/";
/// The graphical session template: what a GUI session (a mode-3 init with
/// a display cap) runs when the user's home has no `conf/units/` of its own.
pub const session_gui_unit_dir = "conf/sessiongui/";
/// The home skeleton: files a session's init copies into a fresh home's
/// `conf/` on first login (if absent), so a new user starts with config of
/// their own — currently the per-user font layer (`conf/skel/font.msh`).
pub const home_skel_dir = "conf/skel/";

/// Unit files: `conf/units/<name>.msh` in the boot archive (served at
/// boot/conf/units/ by fssvc) — mshl data literals init reads to spawn
/// and wire every program (see boot/conf/units/ and DESIGN).
pub const unit_dir = "conf/units/";
pub const unit_ext = ".msh";
/// The archive's library: modules a script reaches with `use NAME`,
/// installed into the store as content-addressed sources.
pub const lib_dir = "lib/";
/// Archive entries under this prefix are seeded into the `assets/` tier
/// of the filesystem at first boot: reference data (trust roots, and in
/// time timezone and locale databases) a running system reads and
/// updates in place, not baked into the read-only archive.
pub const assets_dir = "assets/";

test {
    _ = civil;
}

test "marcFind walks an archive and misses cleanly" {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    @memcpy(buf[0..4], marc_magic);
    n = 4;
    for ([_]struct { p: []const u8, d: []const u8 }{
        .{ .p = "etc/motd", .d = "hi\n" },
        .{ .p = "img/hello", .d = "MOSS" },
    }) |e| {
        std.mem.writeInt(u32, buf[n..][0..4], @intCast(e.p.len), .little);
        std.mem.writeInt(u32, buf[n + 4 ..][0..4], @intCast(e.d.len), .little);
        n += 8;
        @memcpy(buf[n .. n + e.p.len], e.p);
        n += e.p.len;
        @memcpy(buf[n .. n + e.d.len], e.d);
        n += e.d.len;
    }
    try std.testing.expectEqualStrings("MOSS", marcFind(buf[0..n], imagePath(.hello)).?);
    try std.testing.expectEqualStrings("hi\n", marcFind(buf[0..n], "etc/motd").?);
    try std.testing.expect(marcFind(buf[0..n], "img/nope") == null);
    try std.testing.expect(marcFind("junk", "etc/motd") == null);
}

/// Entry convention for user programs: x0 holds the debug-log capability
/// handle (as bits), or 0 when the manifest granted none.
pub const user_image_base: u64 = 0x40_0000;

test "typed messages round-trip through the four data words" {
    const req: CalcRequest = .{ .add = .{ .a = 17, .b = 25 } };
    const words = encodeMsg(CalcRequest, req);
    const back = decodeMsg(CalcRequest, words) orelse return error.DecodeFailed;
    try std.testing.expectEqual(req, back);

    const greet = encodeMsg(CalcRequest, .greet);
    try std.testing.expectEqual(CalcRequest.greet, decodeMsg(CalcRequest, greet).?);

    // A junk tag decodes to null, never to a wrong message.
    try std.testing.expectEqual(@as(?CalcRequest, null), decodeMsg(CalcRequest, .{ 99, 0, 0, 0 }));
}

test "strings round-trip through message words" {
    const w = strToWords("worker msg 7");
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("worker msg 7", wordsToStr(&buf, w));
    const empty = strToWords("");
    try std.testing.expectEqualStrings("", wordsToStr(&buf, empty));
}

test "rings push and pop with wraparound, full and empty detected" {
    var page: [4096]u8 align(64) = @splat(0);
    const rb: *RingBuf = @ptrCast(@alignCast(&page));
    rb.init();

    var out: RingEntry = undefined;
    try std.testing.expect(!rb.sqPop(&out)); // empty

    // Fill completely, then overflow must be refused.
    for (0..ring_entries) |i| {
        try std.testing.expect(rb.sqPush(.{ .id = i, .words = .{ i, 0, 0, 0 } }));
    }
    try std.testing.expect(!rb.sqPush(.{ .id = 99, .words = @splat(0) }));

    // Drain in order.
    for (0..ring_entries) |i| {
        try std.testing.expect(rb.sqPop(&out));
        try std.testing.expectEqual(@as(u64, i), out.id);
    }
    try std.testing.expect(!rb.sqPop(&out));

    // Wraparound: interleave 3 full cycles.
    for (0..3 * ring_entries) |i| {
        try std.testing.expect(rb.cqPush(.{ .id = i, .words = @splat(i) }));
        try std.testing.expect(rb.cqPop(&out));
        try std.testing.expectEqual(@as(u64, i), out.id);
    }
}

test "handle round-trips through its integer representation" {
    const h: Handle = .{ .slot = 7, .generation = 42 };
    const bits: u64 = @bitCast(h);
    const back: Handle = @bitCast(bits);
    try std.testing.expect(h.eql(back));
    try std.testing.expect(!h.eql(Handle.invalid));
}
