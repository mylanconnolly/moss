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

/// Syscall numbers, passed in x8; arguments in x0..x5, result in x0.
/// IPC calls additionally return message words in x1..x4 and a received cap
/// handle (or 0) in x5.
pub const Syscall = enum(u64) {
    log = 1,
    yield = 2,
    sleep = 3,
    exit = 4,
    /// call(channel, w0..w3, cap) -> reply w0..w3, cap
    call = 5,
    /// recv(channel) -> msg w0..w3, cap
    recv = 6,
    /// reply(channel, w0..w3, cap)
    reply = 7,
    notify_create = 8,
    notify_signal = 9,
    /// notify_wait(notification) -> x1 = accumulated bits (cleared)
    notify_wait = 10,
    /// shm_create(pages) -> x1 = handle
    shm_create = 11,
    /// shm_map(handle) -> x1 = va
    shm_map = 12,
    /// spawn(spawner, image_shm, arg, chan, flags, limits) -> x1 =
    /// domain_ctl handle. The image is a MOSS image staged in an shm
    /// buffer the caller holds; the kernel copies it into the child (no
    /// kernel image table, no path lookup). The child's name comes from
    /// the image header.
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
    /// mmio_map(handle) -> x1 = va, x2 = bytes (device-attribute mapping)
    mmio_map = 19,
    /// irq_bind(irq_handle, notif_handle, offset): SPI (cap base + offset)
    /// signals the notification; the line is masked until irq_ack
    irq_bind = 20,
    /// irq_ack(irq_handle, offset): re-enable the line after handling
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
    _,
};

pub const SpawnFlags = struct {
    pub const grant_log: u64 = 1 << 0;
    pub const grant_spawner: u64 = 1 << 1;
    /// Grant the A (serving) side of the channel in x3 instead of B.
    pub const chan_side_a: u64 = 1 << 2;
    /// Grant the system boot blob (bootfs archive); va/len arrive in x3/x4.
    pub const grant_bootfs: u64 = 1 << 3;
};

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

    pub const size = 48;

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
};

/// Services init knows how to activate. Discovery is by protocol id over
/// init's channel — never by global name.
pub const ServiceId = enum(u64) {
    logsvc = 0,
    greeter = 1,
};

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
    /// Connect to (lazily starting, or restarting a stopped) service.
    connect: struct { service: u64 },
    /// Service-level status: up/down, restart usage.
    status: struct { service: u64 },
    /// Deliberate stop: the instance is destroyed and supervision will
    /// not restart it (connect starts it again).
    stop: struct { service: u64 },
};

pub const InitReply = union(enum(u64)) {
    connected: void,
    failed: struct { err: u64 },
    svc_status: struct { up: u64, restarts: u64, max_restarts: u64 },
    stopped: void,
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
    attach_buf: void, // + shm cap: this view's path/data buffer
    /// Root handshake: hand the FS its disk (+ blk channel cap). On an
    /// encrypted volume, set_key must have arrived first.
    attach_disk: void,
    /// Badge-0 only, before attach_disk: 32 bytes of master key material
    /// in the view buffer (zeroized by the service after reading).
    set_key: struct { off: u64, len: u64 },
    /// create: 0 = open existing, 1 = create file (or open existing),
    /// 2 = create directory (ok if it exists), 3 = create file, O_EXCL
    open: struct { path_off: u64, path_len: u64, create: u64 },
    read: struct { fd: u64, off: u64, len: u64 }, // data lands in buf[0..n]
    write: struct { fd: u64, off: u64, len: u64 }, // data taken from buf[0..n]
    list: struct { path_off: u64, path_len: u64 }, // names -> buf, '\n'-separated
    /// Derive a narrower view (readOnlyView and friends); the reply
    /// attaches a freshly minted badged channel cap.
    derive: struct { path_off: u64, path_len: u64, ro: u64 },
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
    num: struct { n: u64 },
    stat: struct { typ: u64, size: u64, mtime: u64 }, // typ: FsType
    statfs: struct { free_blocks: u64, total_blocks: u64, encrypted: u64 },
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
};

/// v4-mapped IPv6 words for an IPv4 address given as 0xAABBCCDD.
pub fn v4Words(ip: u32) [2]u64 {
    return .{ 0, 0x0000_ffff_0000_0000 | @as(u64, ip) };
}

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
};

pub const TcpState = enum(u64) {
    closed = 0,
    listen = 1,
    syn_sent = 2,
    syn_rcvd = 3,
    established = 4,
    close_wait = 5,
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
pub const fabric_ver: u8 = 4; // v4: per-node identities (certs + signed DH)

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
pub const FabReq = union(enum(u64)) {
    attach_net: void, // + net view cap; also starts the listener
    poll: void, // pump TCP + heartbeats (the driver's tick keeps it breathing)
    /// Join the fabric: dial this seed; membership gossip does the rest.
    connect_peer: struct { node: u64 },
    /// node 0 = placement: the least-loaded live member is chosen.
    remote_spawn: struct { node: u64, image: u64, arg: u64 },
    attach_buf: void, // + shm cap: buffer for members listings + identity staging
    /// Badge-0 only, BEFORE attach_net: this node's identity — a
    /// fab_identity_len record {identity seed, cluster key} in the
    /// attached buffer (the seed is zeroized after reading). The reply
    /// leaves the identity PUBLIC key at buf[0..32] (num{32}) for the
    /// root of trust to certify.
    set_identity: struct { off: u64, len: u64 },
    /// Badge-0 only, BEFORE attach_net: the fab_cert_len certificate the
    /// root issued for this node. Verified under the cluster key and
    /// checked to name this node and this identity key — refused here
    /// rather than at the first handshake. The fabric is fail-closed:
    /// without identity + certificate it refuses to listen or dial.
    set_cert: struct { off: u64, len: u64 },
    /// Badge-0 only: a fab_rev_len revocation record signed by the root
    /// of trust, in the attached buffer. Verified, applied (matching live
    /// peers are dropped), and gossiped to every peer.
    revoke: struct { off: u64, len: u64 },
    /// Fill the attached buffer with fab_member_size-byte records
    /// {node u16, up u8, pad u8, free_mb u16, pad u16}; reply num{n}.
    members: void,
};

pub const FabResp = union(enum(u64)) {
    ok: void,
    spawned: struct { node: u64 }, // + remote-channel cap; node = where
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
/// cluster's root signing key. Boot orchestration asks it for the cluster
/// key, node certificates, and revocations; fabsvc never sees the root
/// key. Replies are FabResp; byte artifacts land at buf[0].
pub const RootReq = union(enum(u64)) {
    attach_buf: void, // + shm cap
    /// 32 bytes of root seed in the buffer (zeroized after reading).
    set_root: struct { off: u64, len: u64 },
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

// QEMU slirp constants (static config; DHCP/SLAAC are not Phase 10
// problems). v4 net 10.0.2.0/24, v6 prefix fec0::/64.
pub const net_own_ip4: u32 = 0x0A00_020F; // 10.0.2.15
pub const net_gw_ip4: u32 = 0x0A00_0202; // 10.0.2.2
pub const net_echo_ip4: u32 = 0x0A00_0264; // 10.0.2.100 (guestfwd echo)
pub const net_echo_port: u64 = 9000;
pub const net_own_ip6: [2]u64 = .{ 0xfec0_0000_0000_0000, 0x15 }; // fec0::15
pub const net_gw_ip6: [2]u64 = .{ 0xfec0_0000_0000_0000, 0x2 }; // fec0::2

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
