//! The fabric: init at a larger radius. By x2 (low byte = role, byte 1 =
//! node id):
//!   1 "fabsvc"      — the per-node fabric service. Speaks the versioned
//!                     wire protocol over TCP (via a netsvc view), accepts
//!                     peers on :7100, and makes remote services look
//!                     local: a remote channel is a badged cap on THIS
//!                     service — badged calls forward verbatim as call_req
//!                     frames and return the peer's reply words. Remote
//!                     spawn ships {image, arg, grants} to the peer, which
//!                     spawns locally (its own init-style manifest path)
//!                     and proxies the child's channel back. Addressing is
//!                     static (node N = 10.77.0.N); membership is dynamic
//!                     (dial any seed, gossip, heartbeats). The serve
//!                     thread alone touches peers and the wire; inbound
//!                     remote calls run on a small worker pool, and a
//!                     timer notification plus socket doorbells wake the
//!                     serve loop — nothing polls.
//!   2 "remote-echo" — the remotely-spawned service: an ordinary
//!                     CalcRequest server on its granted channel; it
//!                     neither knows nor cares that its clients are on
//!                     another machine. Handed a channel cap with a
//!                     greet, it calls back through it — proving a cap
//!                     that crossed the wire works in the other direction.
//!   3 "fabroot"     — the root of trust: the one holder of the cluster's
//!                     root signing key. Mints node certificates and
//!                     revocations for boot orchestration (RootReq);
//!                     fabsvc never sees the root key.
//!
//! Security (v4): every node has an Ed25519 identity and a root-issued
//! certificate (lib/fabcert.zig) naming its node id, key, and what it
//! may do to peers. Joining is a signed ephemeral-DH handshake; there is
//! no shared secret anywhere, so a compromised node is a revocable
//! identity (a root-signed revocation gossips through the mesh), not a
//! cluster rekey.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");

const loader = @import("loader.zig");
const boot = @import("boot.zig");
const fsc = @import("fsclient.zig");
const fabcert = @import("mosslib").fabcert;
const Aead = std.crypto.aead.aegis.Aegis128L;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const Ed25519 = fabcert.Ed25519;
const X25519 = std.crypto.dh.X25519;

comptime {
    asm (
        \\.section .text.uhdr, "ax"
        \\.global __uhdr
        \\__uhdr:
        \\        .ascii  "MOSS"
        \\        .word   0
        \\        .quad   __utext_size
        \\        .quad   __uload_size
        \\        .quad   __umem_size
        \\        .ascii  "fabric"
        \\        .space  10
        \\.global _ustart
        \\_ustart:
        \\        b       umain
    );
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

const spawner: u64 = @bitCast(shared.Handle{ .slot = 2, .generation = 1 });

export fn umain(log_h: u64, chan_h: u64, arg: u64, blob_va: u64, blob_len: u64) callconv(.c) noreturn {
    switch (arg & 0xff) {
        1 => {
            boot_va = blob_va;
            boot_len = blob_len;
            fabsvc(log_h, chan_h, (arg >> 8) & 0xff);
        },
        2 => remoteEcho(log_h, chan_h),
        3 => fabroot(log_h, chan_h),
        else => usys.exit(250),
    }
}

// ------------------------------------------------------------ remote echo

fn remoteEcho(log_h: u64, chan_h: u64) noreturn {
    _ = usys.log(log_h, "remote-echo: serving (spawned by the fabric)");
    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err != .ok) usys.exit(150);
        const req = shared.decodeMsg(shared.CalcRequest, r.data) orelse {
            _ = usys.replyTyped(shared.CalcReply, chan_h, .hi, 0);
            continue;
        };
        switch (req) {
            .add => |a| _ = usys.replyTyped(shared.CalcReply, chan_h, .{
                .sum = .{ .value = a.a + a.b },
            }, 0),
            .greet => {
                if (r.cap != 0) {
                    // A channel arrived with the greeting: use it. From
                    // here it is an ordinary cap; the fabric on this node
                    // carries the call back to wherever it came from.
                    var rep: shared.CalcReply = .hi;
                    switch (usys.callTyped(shared.CalcRequest, shared.CalcReply, r.cap, .{ .add = .{ .a = 1, .b = 2 } }, 0)) {
                        .ok => |cr| rep = cr,
                        .err => {},
                    }
                    _ = usys.capDrop(r.cap);
                    _ = usys.replyTyped(shared.CalcReply, chan_h, rep, 0);
                } else {
                    _ = usys.replyTyped(shared.CalcReply, chan_h, .hi, 0);
                }
            },
        }
    }
}

// --------------------------------------------------------------- fabroot

var root_kp: Ed25519.KeyPair = undefined;
var have_root = false;
var root_buf: u64 = 0;

/// The root of trust: a capability service holding the cluster's root
/// signing key (per the code-sharing decision: where custody matters, a
/// service holds the secret). It mints certificates over identity
/// PUBLIC keys handed to it and signs revocations; it never sees a
/// node's identity seed, and fabsvc never sees the root key.
fn fabroot(log_h: u64, chan_h: u64) noreturn {
    glog = log_h;
    // Boot: the staging buffer and the root seed (secret, 32 bytes).
    var setup = boot.take(chan_h);
    root_buf = setup.buf_va;
    if (setup.secret().len == 32 and root_buf != 0) {
        root_kp = Ed25519.KeyPair.generateDeterministic(setup.secret()[0..32].*) catch usys.exit(161);
        have_root = true;
        _ = usys.log(glog, "fabroot: root of trust loaded");
    }
    setup.wipeSecret();
    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err != .ok) usys.exit(160);
        const req = shared.decodeMsg(shared.RootReq, r.data) orelse {
            rreply(chan_h, ferr(.refused));
            continue;
        };
        switch (req) {
            .cluster_key => {
                if (!have_root or root_buf == 0) {
                    rreply(chan_h, ferr(.no_identity));
                    continue;
                }
                const out: [*]volatile u8 = @ptrFromInt(root_buf);
                const pk = root_kp.public_key.toBytes();
                for (0..32) |i| out[i] = pk[i];
                rreply(chan_h, .{ .num = .{ .n = 32 } });
            },
            .issue => |q| {
                if (!have_root or root_buf == 0) {
                    rreply(chan_h, ferr(.no_identity));
                    continue;
                }
                const buf: [*]volatile u8 = @ptrFromInt(root_buf);
                var node_pk: [32]u8 = undefined;
                for (0..32) |i| node_pk[i] = buf[i];
                var cert: [fabcert.cert_len]u8 = undefined;
                fabcert.issue(root_kp, .{
                    .node = @intCast(q.node & 0xffff),
                    .flags = @intCast(q.flags_serial & 0xff),
                    .image_mask = q.image_mask,
                    .serial = @intCast((q.flags_serial >> 8) & 0xffff_ffff),
                    .node_pk = node_pk,
                }, &cert) catch {
                    rreply(chan_h, ferr(.refused));
                    continue;
                };
                for (0..fabcert.cert_len) |i| buf[i] = cert[i];
                rreply(chan_h, .{ .num = .{ .n = fabcert.cert_len } });
            },
            .revoke => |q| {
                if (!have_root or root_buf == 0) {
                    rreply(chan_h, ferr(.no_identity));
                    continue;
                }
                var rec: [fabcert.rev_len]u8 = undefined;
                fabcert.issueRevocation(root_kp, .{
                    .node = @intCast(q.node & 0xffff),
                    .min_serial = @intCast(q.min_serial & 0xffff_ffff),
                }, &rec) catch {
                    rreply(chan_h, ferr(.refused));
                    continue;
                };
                const buf: [*]volatile u8 = @ptrFromInt(root_buf);
                for (0..fabcert.rev_len) |i| buf[i] = rec[i];
                _ = usys.log(glog, "fabroot: revocation signed");
                rreply(chan_h, .{ .num = .{ .n = fabcert.rev_len } });
            },
        }
    }
}

fn rreply(chan_h: u64, resp: shared.FabResp) void {
    _ = usys.replyTyped(shared.FabResp, chan_h, resp, 0);
}

// ---------------------------------------------------------------- fabsvc

const max_peers = 6;
const max_sessions = 8;
const max_members = 8;
const rxbuf_cap = 512;
const ping_every = 5; // polls between heartbeats
const dead_after = 40; // silent polls before a peer is declared dead

const Peer = struct {
    used: bool = false,
    node: u64 = 0, // 0 until hello
    sock: u64 = 0,
    greeted: bool = false, // fully authenticated + session keys live
    dead: bool = false,
    born: u64 = 0, // tick when accepted/dialed (reaps silent strangers)
    dialer: bool = false, // we initiated this connection
    nonce_mine: [16]u8 = @splat(0),
    nonce_theirs: [16]u8 = @splat(0),
    // Ephemeral X25519 for this connection (secret wiped once derived).
    eph_sk: [32]u8 = @splat(0),
    eph_pk: [32]u8 = @splat(0),
    eph_theirs: [32]u8 = @splat(0),
    // The peer's certified identity and authorizations.
    cert_theirs: [fabcert.cert_len]u8 = @splat(0),
    pk_theirs: [32]u8 = @splat(0),
    flags_theirs: u8 = 0,
    mask_theirs: u64 = 0,
    serial_theirs: u32 = 0,
    tx_key: [16]u8 = @splat(0),
    rx_key: [16]u8 = @splat(0),
    tx_ctr: u64 = 0,
    rx_ctr: u64 = 0,
    rx: [rxbuf_cap]u8 = undefined,
    rxlen: usize = 0,
};

/// The membership view: what this node believes about the fabric. All
/// liveness is counted on OUR poll tick — no shared clock anywhere.
const Member = struct {
    used: bool = false,
    node: u64 = 0,
    up: bool = false,
    free_mb: u64 = 0,
    last_heard: u64 = 0,
};

/// A-side: badge -> a channel on another node (its export id there).
/// Keyed by NODE (not peer slot) so a peer slot recycled by rejoin can
/// never misroute a stale session; calls to a rebooted node fail cleanly.
const Session = struct {
    used: bool = false,
    node: u64 = 0,
    remote_id: u32 = 0,
};

/// B-side: a local channel made reachable by peers under an id — a
/// remotely spawned child's channel, or any channel cap that crossed the
/// wire in a call or a reply.
const Export = struct {
    used: bool = false,
    chan_b: u64 = 0,
};

/// A local call forwarded to a peer and awaiting its response: the
/// caller stays parked in the kernel under its reply token while the
/// serve loop carries on — many exchanges in flight per link.
const InFlight = struct {
    used: bool = false,
    token: u64 = 0,
    seq: u32 = 0,
    node: u64 = 0,
    deadline: u64 = 0,
};

const max_inflight = 8; // the kernel's pending-reply slots per channel
const call_timeout = 30; // ticks

/// An inbound remote call being served by a worker thread: the local
/// callee may itself call out through this fabric (a cap that crossed
/// the wire), so the serve loop must never block on it. Workers own
/// only their job record; every peer and wire touch stays on the serve
/// thread, which the worker rings when the result is in.
const Job = struct {
    state: std.atomic.Value(u32) = .init(0), // 0 free, 1 running, 2 done
    node: u64 = 0,
    seq: u32 = 0,
    chan_b: u64 = 0,
    cap: u64 = 0, // minted session cap to hand the callee (dropped after)
    words: [4]u64 = @splat(0),
    ok: bool = false,
    reply: [4]u64 = @splat(0),
    reply_cap: u64 = 0,
    bell: u64 = 0, // the worker's own notification
};

const n_workers = 4;
const worker_stack = 16 << 10;

var peers: [max_peers]Peer = @splat(.{});
var members: [max_members]Member = @splat(.{});
var sessions: [max_sessions]Session = @splat(.{});
var exports: [max_sessions]Export = @splat(.{});
var inflight: [max_inflight]InFlight = @splat(.{});
var next_seq: u32 = 1;
var max_inflight_seen: u64 = 0;
// The event source: socket doorbells (bit_net) and the heartbeat clock
// (bit_tick) on one bound notification.
var notif: u64 = 0;
const bit_net: u64 = 1;
const bit_tick: u64 = 2;
const bit_work: u64 = 4;
var jobs: [n_workers]Job = @splat(.{});
var worker_stacks: [n_workers][worker_stack]u8 = undefined;
var serve_a: u64 = 0;
var net_chan: u64 = 0;
var net_buf: u64 = 0;
var fab_buf: u64 = 0; // client shm for members listings
const no_sock: u64 = 0xffff_ffff_ffff_ffff;
var lsock: u64 = no_sock; // sockets are small indices; 0 is valid!
var my_node: u64 = 0;
var glog: u64 = 0;
var tick: u64 = 0; // the local clock: one timer signal per kernel tick
var last_ping: u64 = 0;
// This node's identity: its signing keypair, the cluster key (the root
// of trust's public key), and the certificate the root issued for it.
var identity: Ed25519.KeyPair = undefined;
var cluster_pk: [32]u8 = @splat(0);
var my_cert: [fabcert.cert_len]u8 = @splat(0);
var have_identity = false; // seed + cluster key staged
var have_cert = false; // certificate verified; the fabric may open
// Remote spawns load their images from the boot archive we were granted.
var boot_va: u64 = 0;
var boot_len: u64 = 0;
var stage: ?loader.Stage = null;

/// Our state (a view of state/fabric, when the unit gives one): the
/// revocations we hold survive a reboot there.
var state_view: u64 = 0;
var state_buf: [*]u8 = undefined;
const revocations_file = "revocations";

/// Revocations we hold: certs of `node` below min_serial are refused.
const Revoked = struct {
    used: bool = false,
    node: u64 = 0,
    min_serial: u32 = 0,
    rec: [fabcert.rev_len]u8 = @splat(0), // the signed record, for re-gossip at join
};
var revoked: [max_members]Revoked = @splat(.{});
var mesh_logged = false;

// One outstanding wire exchange at a time (v0 serializes).
var got_spawn_ack = false;
var spawn_ack_session: u32 = 0;
var spawn_ack_code: u8 = 0; // 1 = spawned, 2 = unauthorized, 0 = failed

/// hello / hello_ack body prefix: [node u16][nonce 16][eph pk 32][cert].
const hello_len = 2 + 16 + 32 + fabcert.cert_len;

fn fabsvc(log_h: u64, chan_h: u64, node: u64) noreturn {
    glog = log_h;
    serve_a = chan_h;
    my_node = node;
    _ = memberUpsert(my_node, true);

    // Boot: the staging buffer, our identity (secret: seed 32 + cluster
    // key 32 — the public key goes back into the buffer for the root of
    // trust to certify), and a network view. The network stays closed
    // until the certificate arrives (set_cert).
    var setup = boot.take(chan_h);
    fab_buf = setup.buf_va;
    if (setup.secret().len == shared.fab_identity_len and fab_buf != 0) {
        const sec = setup.secret();
        @memcpy(&cluster_pk, sec[32..64]);
        identity = Ed25519.KeyPair.generateDeterministic(sec[0..32].*) catch usys.exit(162);
        have_identity = true;
    }
    setup.wipeSecret();
    net_chan = setup.cap(.net);
    if (setup.has(.view)) {
        state_view = setup.cap(.view);
        state_buf = @ptrFromInt(fsc.attachBuf(state_view).va);
        loadRevocations();
    }

    // Nobody pumps us: socket doorbells and a timer interrupt our recv.
    const n = usys.notifyCreate();
    if (n.err != .ok) usys.exit(163);
    notif = n.data[0];
    if (usys.notifyBind(notif) != .ok) usys.exit(164);
    if (usys.timerArm(notif, 1, bit_tick) != .ok) usys.exit(165);
    // Workers for inbound calls: each waits on its own bell.
    for (&jobs, 0..) |*j, i| {
        const b = usys.notifyCreate();
        if (b.err != .ok) usys.exit(166);
        j.bell = b.data[0];
        if (usys.threadCreate(worker, i, &worker_stacks[i]) != .ok) usys.exit(167);
    }

    while (true) {
        const r = usys.recvMsg(serve_a);
        if (r.err == .interrupted) {
            const w = usys.notifyWait(notif); // drain the latched bits
            if (w.err == .ok and w.data[0] & bit_tick != 0) {
                tick += 1;
                heartbeat();
                expireInflight();
            }
            if (w.err == .ok and w.data[0] & bit_work != 0) finishJobs();
            pumpAll();
            continue;
        }
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err == .client_dead) {
            // The local holder of a remote channel is gone: its session
            // slot is free again (the peer's export stays that node's
            // business; nothing crosses the wire for this).
            if (r.badge != 0 and r.badge - 1 < max_sessions) sessions[r.badge - 1] = .{};
            continue;
        }
        if (r.err != .ok) usys.exit(151);
        if (r.badge != 0) {
            forwardCall(r.badge, r.data, r.cap, r.token);
            continue;
        }
        const req = shared.decodeMsg(shared.FabReq, r.data) orelse {
            freply(ferr(.refused));
            continue;
        };
        switch (req) {
            .identity_key => {
                if (!have_identity or fab_buf == 0) {
                    freply(ferr(.no_identity));
                    continue;
                }
                const out: [*]volatile u8 = @ptrFromInt(fab_buf);
                const pk = identity.public_key.toBytes();
                for (0..32) |i| out[i] = pk[i];
                freply(.{ .num = .{ .n = 32 } });
            },
            .set_cert => |sc| {
                if (!have_identity or have_cert or fab_buf == 0 or sc.len != fabcert.cert_len or sc.off + sc.len > 4096) {
                    freply(ferr(.refused));
                    continue;
                }
                const src: [*]volatile u8 = @ptrFromInt(fab_buf + sc.off);
                for (0..fabcert.cert_len) |i| my_cert[i] = src[i];
                const c = fabcert.verify(&my_cert, cluster_pk) catch {
                    _ = usys.log(glog, "fabsvc: our certificate does not verify under the cluster key; refused");
                    freply(ferr(.refused));
                    continue;
                };
                if (c.node != my_node or !std.mem.eql(u8, &c.node_pk, &identity.public_key.toBytes())) {
                    _ = usys.log(glog, "fabsvc: certificate names another node or key; refused");
                    freply(ferr(.refused));
                    continue;
                }
                have_cert = true;
                _ = usys.log(glog, "fabsvc: identity certified by the trust root");
                // Certified: the network may open — given a view and entropy.
                if (net_chan == 0) {
                    _ = usys.log(glog, "fabsvc: NO NETWORK VIEW — certified but isolated");
                    freply(ferr(.no_peer));
                    continue;
                }
                var probe: [16]u8 = undefined;
                if (usys.getrandom(&probe) != .ok) {
                    _ = usys.log(glog, "fabsvc: NO ENTROPY — kernel pool unseeded; refusing the network (fail closed)");
                    freply(ferr(.no_entropy));
                    continue;
                }
                netAttach();
                freply(.ok);
            },
            .revoke => |rv| {
                if (fab_buf == 0 or rv.len != fabcert.rev_len or rv.off + rv.len > 4096) {
                    freply(ferr(.refused));
                    continue;
                }
                const src: [*]volatile u8 = @ptrFromInt(fab_buf + rv.off);
                var rec: [fabcert.rev_len]u8 = undefined;
                for (0..fabcert.rev_len) |i| rec[i] = src[i];
                if (!applyRevocation(&rec)) {
                    freply(ferr(.refused));
                    continue;
                }
                gossipRevocation(&rec, null);
                freply(.ok);
            },
            .attach_buf => {
                if (r.cap != 0) {
                    const m = usys.shmMap(r.cap);
                    if (m.err == .ok) fab_buf = m.data[0];
                }
                freply(.ok);
            },
            .members => freply(doMembers()),
            .stats => freply(.{ .num = .{ .n = max_inflight_seen } }),
            .poll => {
                // Kept for callers that still tick us; the clock is ours.
                pumpAll();
                freply(.ok);
            },
            .connect_peer => |q| freply(doConnectPeer(q.node)),
            .remote_spawn => |q| doRemoteSpawn(q.node, q.image, q.arg),
        }
    }
}

fn freply(resp: shared.FabResp) void {
    _ = usys.replyTyped(shared.FabResp, serve_a, resp, 0);
}

fn ferr(code: shared.FabErr) shared.FabResp {
    return .{ .fab_err = .{ .code = @intFromEnum(code) } };
}

// ----------------------------------------------------------- membership

fn memberByNode(node: u64) ?*Member {
    for (&members) |*m| {
        if (m.used and m.node == node) return m;
    }
    return null;
}

fn memberUpsert(node: u64, up: bool) ?*Member {
    if (memberByNode(node)) |m| {
        if (up and !m.up) {
            m.up = true;
            m.last_heard = tick;
            if (node != my_node) _ = usys.log(glog, "fabsvc: member back up");
            logMesh();
        }
        return m;
    }
    for (&members) |*m| {
        if (m.used) continue;
        m.* = .{ .used = true, .node = node, .up = up, .last_heard = tick };
        if (node != my_node and up) logMesh();
        return m;
    }
    return null;
}

fn memberDown(node: u64) void {
    if (node == my_node) return;
    if (memberByNode(node)) |m| {
        if (m.up) {
            m.up = false;
            _ = usys.log(glog, "fabsvc: member down");
        }
    }
}

fn upCount() u64 {
    var n: u64 = 0;
    for (&members) |*m| {
        if (m.used and m.up) n += 1;
    }
    return n;
}

/// The gossip proof marker: this node's own view reached a full mesh.
fn logMesh() void {
    if (!mesh_logged and upCount() >= 3) {
        mesh_logged = true;
        _ = usys.log(glog, "fabsvc: full mesh (3+ members up)");
    }
}

fn selfFreeMb() u64 {
    const r = usys.sysInfo(spawner);
    if (r.err != .ok) return 0;
    return r.data[0] >> 20;
}

/// Heartbeats, death detection, and dialing learned members — all on the
/// local poll clock.
fn heartbeat() void {
    if (tick - last_ping >= ping_every) {
        last_ping = tick;
        if (memberByNode(my_node)) |m| m.free_mb = selfFreeMb();
        var ping: [6]u8 = undefined;
        frameHdr(ping[0..4], 6, shared.fw_ping);
        puleu16(ping[4..6], @intCast(@min(selfFreeMb(), 0xffff)));
        for (&peers) |*p| {
            if (p.used and !p.dead and p.greeted) tryPing(p, &ping);
        }
    }
    // Death detection: a greeted peer silent too long, or a stranger that
    // never said hello.
    for (&peers) |*p| {
        if (!p.used or p.dead) continue;
        if (p.greeted) {
            const m = memberByNode(p.node) orelse continue;
            if (tick - m.last_heard > dead_after) peerFailed(p);
        } else if (tick - p.born > dead_after) {
            p.dead = true;
        }
    }
    dialMissing();
    reapDeadPeers();
}

/// The mesh rule: the LOWER node id dials a learned member it has no
/// connection to (the joiner's dial to its seed is the bootstrap
/// exception). One attempt per poll keeps the serve loop responsive.
fn dialMissing() void {
    for (&members) |*m| {
        if (!m.used or !m.up or m.node == my_node) continue;
        if (my_node > m.node) continue;
        if (peerByNode(m.node) != null) continue;
        _ = doConnectPeer(m.node);
        return;
    }
}

fn reapDeadPeers() void {
    for (&peers) |*p| {
        if (p.used and p.dead) p.* = .{};
    }
}

fn broadcastMember(ftype: u8, node: u64) void {
    var f: [6]u8 = undefined;
    frameHdr(f[0..4], 6, ftype);
    puleu16(f[4..6], @intCast(node));
    for (&peers) |*p| {
        if (p.used and !p.dead and p.greeted and p.node != node) _ = sendFrame(p, &f);
    }
}

fn doMembers() shared.FabResp {
    if (fab_buf == 0) return ferr(.refused);
    const out: [*]u8 = @ptrFromInt(fab_buf);
    var n: u64 = 0;
    for (&members) |*m| {
        if (!m.used) continue;
        const rec = out[n * shared.fab_member_size ..];
        puleu16(rec[0..2], @intCast(m.node));
        rec[2] = @intFromBool(m.up);
        rec[3] = 0;
        puleu16(rec[4..6], @intCast(@min(m.free_mb, 0xffff)));
        rec[6] = 0;
        rec[7] = 0;
        n += 1;
    }
    return .{ .num = .{ .n = n } };
}

// ----------------------------------------------------------- handshake
//
// Signed ephemeral Diffie-Hellman under root-issued certificates: each
// side presents its certificate and proves its identity key over a
// transcript of the whole exchange; session keys come from X25519 over
// per-connection ephemeral keys (identity keys only ever sign — forward
// secrecy). No shared secret exists anywhere. The wire version sits in
// the transcript, so a downgrade breaks the signature.

/// Handshake nonce: 16 bytes from the kernel CSPRNG (getrandom, seeded
/// by the virtio-rng driver). attach_net already proved the pool is
/// live; a refusal here means it went away, and the fabric stays closed.
fn mkNonce() [16]u8 {
    var n: [16]u8 = undefined;
    if (usys.getrandom(&n) != .ok) {
        _ = usys.log(glog, "fabsvc: getrandom refused mid-life; no handshake without entropy");
        usys.exit(158);
    }
    return n;
}

/// A fresh ephemeral X25519 keypair for one connection.
fn mkEphemeral(p: *Peer) void {
    var seed: [32]u8 = undefined;
    if (usys.getrandom(&seed) != .ok) {
        _ = usys.log(glog, "fabsvc: getrandom refused mid-life; no handshake without entropy");
        usys.exit(158);
    }
    const kp = X25519.KeyPair.generateDeterministic(seed) catch usys.exit(159);
    @memset(&seed, 0);
    p.eph_sk = kp.secret_key;
    p.eph_pk = kp.public_key;
}

const hs_max = 1 + 4 + 32 + 64 + 2 * fabcert.cert_len;
const hs_ack = "moss-fabric-hs-ack";
const hs_auth = "moss-fabric-hs-auth";

/// The signed transcript: ver || dialer node || acceptor node || dialer
/// nonce || acceptor nonce || dialer eph || acceptor eph || dialer cert
/// || acceptor cert — dialer-first whichever side we are, so both sides
/// sign and verify identical bytes. (The label is prepended by the
/// signing primitive; it separates ack from auth from certificates.)
fn transcript(p: *Peer, out: *[hs_max]u8) []const u8 {
    var n: usize = 0;
    n = put(out, n, &.{shared.fabric_ver});
    var ids: [4]u8 = undefined;
    puleu16(ids[0..2], @intCast(if (p.dialer) my_node else p.node));
    puleu16(ids[2..4], @intCast(if (p.dialer) p.node else my_node));
    n = put(out, n, &ids);
    n = put(out, n, if (p.dialer) &p.nonce_mine else &p.nonce_theirs);
    n = put(out, n, if (p.dialer) &p.nonce_theirs else &p.nonce_mine);
    n = put(out, n, if (p.dialer) &p.eph_pk else &p.eph_theirs);
    n = put(out, n, if (p.dialer) &p.eph_theirs else &p.eph_pk);
    n = put(out, n, if (p.dialer) &my_cert else &p.cert_theirs);
    n = put(out, n, if (p.dialer) &p.cert_theirs else &my_cert);
    return out[0..n];
}

fn put(out: []u8, at: usize, bytes: []const u8) usize {
    @memcpy(out[at .. at + bytes.len], bytes);
    return at + bytes.len;
}

fn signTranscript(label: []const u8, p: *Peer) [64]u8 {
    var buf: [hs_max]u8 = undefined;
    return fabcert.signLabeled(identity, label, transcript(p, &buf)) catch usys.exit(157);
}

fn verifyTranscript(label: []const u8, p: *Peer, sig: []const u8) bool {
    var buf: [hs_max]u8 = undefined;
    fabcert.verifyLabeled(p.pk_theirs, label, transcript(p, &buf), sig) catch return false;
    return true;
}

/// Admit a peer's certificate: signed by our root, naming the node it
/// claims to be, clearing every revocation we hold. On success the
/// peer's identity key and authorizations are recorded on the slot.
fn acceptCert(p: *Peer, node: u64, bytes: []const u8) bool {
    if (bytes.len < fabcert.cert_len) return false;
    @memcpy(&p.cert_theirs, bytes[0..fabcert.cert_len]);
    const c = fabcert.verify(&p.cert_theirs, cluster_pk) catch {
        _ = usys.log(glog, "fabsvc: certificate not signed by our trust root; refused");
        return false;
    };
    if (c.node != node) {
        _ = usys.log(glog, "fabsvc: certificate names another node; refused");
        return false;
    }
    if (isRevoked(node, c.serial)) {
        _ = usys.log(glog, "fabsvc: revoked identity refused");
        return false;
    }
    p.pk_theirs = c.node_pk;
    p.flags_theirs = c.flags;
    p.mask_theirs = c.image_mask;
    p.serial_theirs = c.serial;
    return true;
}

/// Directional session keys: HKDF(X25519 shared secret, salt = both
/// nonces). The ephemeral secret is wiped here; nothing can re-derive.
fn deriveSession(p: *Peer) bool {
    const secret = X25519.scalarmult(p.eph_sk, p.eph_theirs) catch return false;
    @memset(&p.eph_sk, 0);
    var salt: [32]u8 = undefined;
    const dn = if (p.dialer) &p.nonce_mine else &p.nonce_theirs;
    const an = if (p.dialer) &p.nonce_theirs else &p.nonce_mine;
    @memcpy(salt[0..16], dn);
    @memcpy(salt[16..32], an);
    const prk = Hkdf.extract(&salt, &secret);
    var d2a: [16]u8 = undefined;
    var a2d: [16]u8 = undefined;
    Hkdf.expand(&d2a, "moss-fabric-d2a", prk);
    Hkdf.expand(&a2d, "moss-fabric-a2d", prk);
    p.tx_key = if (p.dialer) d2a else a2d;
    p.rx_key = if (p.dialer) a2d else d2a;
    p.tx_ctr = 0;
    p.rx_ctr = 0;
    return true;
}

// ---------------------------------------------------------- revocation

fn isRevoked(node: u64, serial: u32) bool {
    for (&revoked) |*r| {
        if (r.used and r.node == node and serial < r.min_serial) return true;
    }
    return false;
}

/// Verify and apply a revocation record. Returns true when it was NEWS
/// (raised the bar for that node): the caller gossips it on. A record we
/// already hold is not re-broadcast, which bounds the flood.
fn applyRevocation(rec: *const [fabcert.rev_len]u8) bool {
    const r = fabcert.verifyRevocation(rec, cluster_pk) catch {
        _ = usys.log(glog, "fabsvc: revocation not signed by our trust root; ignored");
        return false;
    };
    var slot: ?*Revoked = null;
    for (&revoked) |*e| {
        if (e.used and e.node == r.node) slot = e;
    }
    if (slot == null) {
        for (&revoked) |*e| {
            if (!e.used) {
                e.* = .{ .used = true, .node = r.node, .min_serial = 0 };
                slot = e;
                break;
            }
        }
    }
    const e = slot orelse return false;
    if (r.min_serial <= e.min_serial) return false;
    e.min_serial = r.min_serial;
    e.rec = rec.*;
    _ = usys.log(glog, "fabsvc: revocation accepted from trust root");
    saveRevocations();
    for (&peers) |*p| {
        if (p.used and !p.dead and p.greeted and p.node == r.node and p.serial_theirs < r.min_serial) {
            _ = usys.log(glog, "fabsvc: identity revoked by trust root; peer dropped");
            peerFailed(p);
        }
    }
    return true;
}

/// At join, both sides hand the newcomer every revocation they hold, so
/// a node that was down while one circulated learns it before it can be
/// fooled by a revoked peer. Already-held records are not news there.
fn sendRevocations(p: *Peer) void {
    for (&revoked) |*e| {
        if (!e.used or e.min_serial == 0) continue;
        var f: [4 + fabcert.rev_len]u8 = undefined;
        frameHdr(f[0..4], f.len, shared.fw_revoke);
        @memcpy(f[4..], &e.rec);
        _ = sendFrame(p, &f);
    }
}

/// Restore held revocations from state (a file of rev_len records).
fn loadRevocations() void {
    const fd = switch (fsc.fsOpen(state_view, state_buf, revocations_file, 0)) {
        .fd => |fd| fd,
        .err => return,
    };
    defer fsc.fsClose(state_view, fd);
    const n = fsc.fsRead(state_view, fd, max_members * fabcert.rev_len) orelse return;
    var restored: usize = 0;
    var off: usize = 0;
    while (off + fabcert.rev_len <= n) : (off += fabcert.rev_len) {
        var rec: [fabcert.rev_len]u8 = undefined;
        @memcpy(&rec, state_buf[off .. off + fabcert.rev_len]);
        if (applyRevocation(&rec)) restored += 1;
    }
    if (restored > 0) _ = usys.log(glog, "fabsvc: revocations restored from state");
}

/// Keep every held revocation in state (rewritten whole; a handful of
/// 72-byte records).
fn saveRevocations() void {
    if (state_view == 0) return;
    const fd = switch (fsc.fsOpen(state_view, state_buf, revocations_file, 1)) {
        .fd => |fd| fd,
        .err => return,
    };
    defer fsc.fsClose(state_view, fd);
    var off: usize = 0;
    for (&revoked) |*e| {
        if (!e.used or e.min_serial == 0) continue;
        if (!fsc.fsWriteAt(state_view, state_buf, fd, off, &e.rec)) return;
        off += fabcert.rev_len;
    }
    _ = fsc.fsTruncate(state_view, fd, off);
    _ = fsc.fsSync(state_view);
}

fn gossipRevocation(rec: *const [fabcert.rev_len]u8, except: ?*Peer) void {
    var f: [4 + fabcert.rev_len]u8 = undefined;
    frameHdr(f[0..4], f.len, shared.fw_revoke);
    @memcpy(f[4..], rec);
    for (&peers) |*p| {
        if (p.used and !p.dead and p.greeted and p != except) _ = sendFrame(p, &f);
    }
}

fn ctrNonce(ctr: u64) [16]u8 {
    var n: [16]u8 = @splat(0);
    puleu64(n[0..8], ctr);
    return n;
}

/// Wrap an inner frame as fw_sealed: [outer hdr][ciphertext][tag16].
fn sealFrame(p: *Peer, inner: []const u8, out: []u8) usize {
    const olen = 4 + inner.len + 16;
    frameHdr(out[0..4], @intCast(olen), shared.fw_sealed);
    var tag: [16]u8 = undefined;
    Aead.encrypt(out[4 .. 4 + inner.len], &tag, inner, "", ctrNonce(p.tx_ctr), p.tx_key);
    @memcpy(out[4 + inner.len .. olen], &tag);
    p.tx_ctr += 1;
    return olen;
}

// ------------------------------------------------------- net plumbing

fn netAttach() void {
    const s = usys.shmCreate(1);
    if (s.err != .ok) usys.exit(152);
    const m = usys.shmMap(s.data[0]);
    if (m.err != .ok) usys.exit(153);
    net_buf = m.data[0];
    switch (usys.callTyped(shared.NetReq, shared.NetResp, net_chan, .attach_buf, s.data[0])) {
        .ok => {},
        .err => usys.exit(154),
    }
    lsock = nnum(ncall(.{ .tcp_listen = .{ .port = shared.fabric_port } })) orelse usys.exit(155);
    watchSock(lsock);
    _ = usys.log(glog, "fabsvc: listening on the fabric port");
}

/// Ring our notification whenever this socket has news.
fn watchSock(sock: u64) void {
    _ = usys.callTyped(shared.NetReq, shared.NetResp, net_chan, .{ .watch = .{ .sock = sock } }, notif);
}

fn ncall(req: shared.NetReq) shared.NetResp {
    switch (usys.callTyped(shared.NetReq, shared.NetResp, net_chan, req, 0)) {
        .ok => |rep| return rep,
        .err => usys.exit(156),
    }
}

fn nnum(resp: shared.NetResp) ?u64 {
    return switch (resp) {
        .num => |x| x.n,
        else => null,
    };
}

fn wouldBlock(resp: shared.NetResp) bool {
    return switch (resp) {
        .net_err => |e| e.code == @intFromEnum(shared.NetErr.would_block),
        else => false,
    };
}

/// Send one wire frame on a peer's socket, retrying past stop-and-wait;
/// authenticated peers get it sealed (AEGIS + counter nonce). Failure
/// (hard error or retries exhausted) is a PEER FAILURE: membership
/// learns immediately, not on the next silent timeout.
fn sendFrame(p: *Peer, frame: []const u8) bool {
    if (p.greeted) {
        var sealed: [rxbuf_cap]u8 = undefined;
        const n = sealFrame(p, frame, &sealed);
        return sendFrameN(p, sealed[0..n], 30);
    }
    return sendFrameN(p, frame, 30);
}

fn sendFrameN(p: *Peer, frame: []const u8, retries: u64) bool {
    const buf: [*]u8 = @ptrFromInt(net_buf);
    @memcpy(buf[0..frame.len], frame);
    for (0..retries) |_| {
        const resp = ncall(.{ .tcp_send = .{ .sock = p.sock, .len = frame.len } });
        if (nnum(resp) != null) return true;
        if (!wouldBlock(resp)) {
            peerFailed(p);
            return false;
        }
        if (retries > 1) usys.sleep(1);
    }
    peerFailed(p);
    return false;
}

/// Best-effort ping: skip while stop-and-wait has a segment in flight
/// (a healthy peer mid-exchange must not be failed for it); hard errors
/// fail the peer. Silent death is the last_heard timeout's job.
fn tryPing(p: *Peer, frame: []const u8) void {
    var sealed: [rxbuf_cap]u8 = undefined;
    const n = sealFrame(p, frame, &sealed); // pings only go to authed peers
    const buf: [*]u8 = @ptrFromInt(net_buf);
    @memcpy(buf[0..n], sealed[0..n]);
    const resp = ncall(.{ .tcp_send = .{ .sock = p.sock, .len = n } });
    if (nnum(resp) != null) return;
    // Counter burned but unheard is fine: the receiver only steps rx_ctr
    // on frames it actually decrypts... it is NOT fine — a skipped
    // counter desyncs the stream. Roll it back: nothing was sent.
    if (wouldBlock(resp)) {
        p.tx_ctr -= 1;
        return;
    }
    peerFailed(p);
}

/// One place a peer dies: close, membership down, broadcast. Setting
/// p.dead FIRST keeps the broadcast from recursing into this peer.
fn peerFailed(p: *Peer) void {
    if (p.dead) return;
    p.dead = true;
    _ = ncall(.{ .tcp_close = .{ .sock = p.sock } });
    // Every exchange in flight to it completes with a clean error.
    for (&inflight) |*f| {
        if (f.used and f.node == p.node) {
            failReply(f.token, .disconnected);
            f.* = .{};
        }
    }
    if (p.greeted) {
        _ = usys.log(glog, "fabsvc: peer lost; membership updated");
        memberDown(p.node);
        broadcastMember(shared.fw_member_down, p.node);
    }
}

/// Pump every peer: accept newcomers, read frames, dispatch.
fn pumpAll() void {
    // Accept a pending inbound peer.
    if (lsock != no_sock) {
        const resp = ncall(.{ .tcp_accept = .{ .sock = lsock } });
        if (nnum(resp)) |sock| {
            watchSock(sock);
            for (&peers) |*p| {
                if (!p.used) {
                    p.* = .{ .used = true, .sock = sock, .born = tick };
                    break;
                }
            }
        }
    }
    for (&peers) |*p| {
        if (!p.used or p.dead) continue;
        pumpPeer(p);
    }
}

fn pumpPeer(p: *Peer) void {
    const buf: [*]const u8 = @ptrFromInt(net_buf);
    while (true) {
        const resp = ncall(.{ .tcp_recv = .{ .sock = p.sock, .len = 256 } });
        const n = nnum(resp) orelse {
            if (!wouldBlock(resp)) {
                // TCP-level death is instant membership news.
                peerFailed(p);
            }
            break;
        };
        if (p.rxlen + n > rxbuf_cap) {
            _ = usys.log(glog, "fabsvc: peer overran the frame buffer; dropped");
            peerFailed(p);
            break;
        }
        @memcpy(p.rx[p.rxlen .. p.rxlen + n], buf[0..n]);
        p.rxlen += n;
    }
    // Process complete frames: [len u16][type u8][ver u8][payload].
    while (p.rxlen >= 4) {
        const flen = leu16(p.rx[0..2]);
        if (flen < 4 or flen > rxbuf_cap) {
            _ = usys.log(glog, "fabsvc: malformed frame length; peer dropped");
            peerFailed(p);
            return;
        }
        if (p.rxlen < flen) return;
        if (p.rx[3] != shared.fabric_ver) {
            _ = usys.log(glog, "fabsvc: wire version mismatch; peer dropped");
            peerFailed(p);
            return;
        }
        const ftype = p.rx[2];
        if (ftype == shared.fw_sealed) {
            if (!p.greeted or flen < 4 + 16) {
                peerFailed(p);
                return;
            }
            const clen = flen - 4 - 16;
            var inner: [rxbuf_cap]u8 = undefined;
            var tag: [16]u8 = undefined;
            @memcpy(&tag, p.rx[4 + clen .. flen]);
            Aead.decrypt(inner[0..clen], p.rx[4 .. 4 + clen], tag, "", ctrNonce(p.rx_ctr), p.rx_key) catch {
                _ = usys.log(glog, "fabsvc: sealed frame failed authentication; dropping peer");
                peerFailed(p);
                return;
            };
            p.rx_ctr += 1;
            // The plaintext is itself a complete frame.
            if (clen < 4 or leu16(inner[0..2]) != clen or inner[3] != shared.fabric_ver) {
                peerFailed(p);
                return;
            }
            handleFrame(p, inner[2], inner[4..clen]);
        } else if (!p.greeted and (ftype == shared.fw_hello or ftype == shared.fw_hello_ack or ftype == shared.fw_auth)) {
            handleFrame(p, ftype, p.rx[4..flen]);
        } else {
            // Plaintext outside the handshake (or handshake replays after
            // auth) are protocol violations.
            peerFailed(p);
            return;
        }
        const rest = p.rxlen - flen;
        for (0..rest) |i| p.rx[i] = p.rx[flen + i];
        p.rxlen = rest;
        if (p.dead) return;
    }
}

/// Every frame from a known peer refreshes its liveness.
fn heard(p: *Peer) void {
    if (!p.greeted) return;
    if (memberByNode(p.node)) |m| m.last_heard = tick;
}

fn handleFrame(p: *Peer, ftype: u8, body: []const u8) void {
    heard(p);
    switch (ftype) {
        shared.fw_hello => {
            // [node u16][nonce 16][eph pk 32][cert 112]
            if (body.len < hello_len) return;
            const node = leu16(body[0..2]);
            // The certificate is checked BEFORE anything else changes: a
            // stranger claiming a live peer's id must not evict it.
            if (!acceptCert(p, node, body[50..hello_len])) {
                peerFailed(p);
                return;
            }
            // Rejoin / duplicate: a fresh authentic connection for a node
            // we already track replaces the old one (the old socket is
            // stale).
            for (&peers) |*old| {
                if (old.used and old != p and old.node == node) {
                    _ = ncall(.{ .tcp_close = .{ .sock = old.sock } });
                    old.dead = true;
                }
            }
            p.node = node;
            p.dialer = false;
            @memcpy(&p.nonce_theirs, body[2..18]);
            @memcpy(&p.eph_theirs, body[18..50]);
            p.nonce_mine = mkNonce();
            mkEphemeral(p);
            // Our identity + proof over the transcript; they prove with auth.
            var ack: [4 + hello_len + 64]u8 = undefined;
            frameHdr(ack[0..4], ack.len, shared.fw_hello_ack);
            puleu16(ack[4..6], @intCast(my_node));
            @memcpy(ack[6..22], &p.nonce_mine);
            @memcpy(ack[22..54], &p.eph_pk);
            @memcpy(ack[54 .. 54 + fabcert.cert_len], &my_cert);
            const sig = signTranscript(hs_ack, p);
            @memcpy(ack[4 + hello_len ..], &sig);
            _ = sendFrame(p, &ack);
        },
        shared.fw_hello_ack => {
            // Dialer side: verify the acceptor's certificate and proof,
            // send ours, go live.
            if (body.len < hello_len + 64 or !p.dialer) return;
            if (leu16(body[0..2]) != p.node) {
                _ = usys.log(glog, "fabsvc: acceptor claims a different node id; dropped");
                peerFailed(p);
                return;
            }
            @memcpy(&p.nonce_theirs, body[2..18]);
            @memcpy(&p.eph_theirs, body[18..50]);
            if (!acceptCert(p, p.node, body[50..hello_len]) or
                !verifyTranscript(hs_ack, p, body[hello_len .. hello_len + 64]))
            {
                _ = usys.log(glog, "fabsvc: peer failed authentication; dropped");
                peerFailed(p);
                return;
            }
            var auth: [4 + 64]u8 = undefined;
            frameHdr(auth[0..4], auth.len, shared.fw_auth);
            const sig = signTranscript(hs_auth, p);
            @memcpy(auth[4..], &sig);
            _ = sendFrame(p, &auth); // still plaintext: they derive on receipt
            if (!deriveSession(p)) {
                peerFailed(p);
                return;
            }
            p.greeted = true;
            _ = memberUpsert(p.node, true);
            if (memberByNode(p.node)) |m| m.last_heard = tick;
            sendRevocations(p);
        },
        shared.fw_auth => {
            // Acceptor side: the dialer's proof completes the join.
            if (body.len < 64 or p.dialer) return;
            if (!verifyTranscript(hs_auth, p, body[0..64])) {
                _ = usys.log(glog, "fabsvc: peer failed authentication; dropped");
                peerFailed(p);
                return;
            }
            if (!deriveSession(p)) {
                peerFailed(p);
                return;
            }
            p.greeted = true;
            _ = memberUpsert(p.node, true);
            if (memberByNode(p.node)) |m| m.last_heard = tick;
            broadcastMember(shared.fw_member_up, p.node);
            sendMembersFrame(p);
            sendRevocations(p);
            _ = usys.log(glog, "fabsvc: peer joined (authenticated); sent member view");
        },
        shared.fw_members => {
            // The acceptor's member view, sealed: gossip at join. Believed
            // only from a peer certified to gossip (its own liveness and
            // load are always taken — those it speaks for itself).
            if (body.len < 3) return;
            if (memberByNode(p.node)) |m| m.free_mb = leu16(body[0..2]);
            if (p.flags_theirs & fabcert.flag_gossip == 0) return;
            const n = body[2];
            var off: usize = 3;
            for (0..n) |_| {
                if (off + 3 > body.len) break;
                const node = leu16(body[off .. off + 2][0..2]);
                const up = body[off + 2] != 0;
                if (node != my_node) _ = memberUpsert(node, up);
                off += 3;
            }
        },
        shared.fw_ping => {
            if (body.len >= 2) {
                if (memberByNode(p.node)) |m| m.free_mb = leu16(body[0..2]);
            }
            var pong: [6]u8 = undefined;
            frameHdr(pong[0..4], 6, shared.fw_pong);
            puleu16(pong[4..6], @intCast(@min(selfFreeMb(), 0xffff)));
            _ = sendFrame(p, &pong);
        },
        shared.fw_pong => {
            if (body.len >= 2) {
                if (memberByNode(p.node)) |m| m.free_mb = leu16(body[0..2]);
            }
        },
        shared.fw_member_up => {
            if (body.len < 2 or p.flags_theirs & fabcert.flag_gossip == 0) return;
            const node = leu16(body[0..2]);
            if (node != my_node) _ = memberUpsert(node, true);
        },
        shared.fw_member_down => {
            if (body.len < 2 or p.flags_theirs & fabcert.flag_gossip == 0) return;
            const node = leu16(body[0..2]);
            // Trust it only when we cannot see the node ourselves — our own
            // heartbeat is the authority for peers we are connected to.
            if (node != my_node and peerByNode(node) == null) memberDown(node);
        },
        shared.fw_spawn_req => {
            // [image u16][arg u64][req u32] -> spawn locally, proxy child.
            if (body.len < 14) return;
            const image = leu16(body[0..2]);
            const arg = leu64(body[2..10]);
            const req_id = leu32(body[10..14]);
            // Authorization is the peer's certificate: the spawn flag and
            // the image bit, both signed by the root of trust.
            const allowed = p.flags_theirs & fabcert.flag_spawn != 0 and
                image < 64 and (p.mask_theirs >> @intCast(image)) & 1 != 0;
            if (!allowed) _ = usys.log(glog, "fabsvc: refused spawn: peer's certificate does not authorize that image");
            var sid: u32 = 0;
            var ok = false;
            for (&exports, 0..) |*rs, i| {
                if (!allowed) break;
                if (rs.used) continue;
                if (stage == null) stage = loader.Stage.init(loader.Stage.default_pages);
                const st = &(stage orelse break);
                const id = std.enums.fromInt(shared.ImageId, image) orelse break;
                if (!st.load(boot_va, boot_len, id)) {
                    _ = usys.log(glog, "fabsvc: requested image missing from the boot archive");
                    break;
                }
                const ch = usys.chanCreate();
                if (ch.err != .ok) break;
                const sp = usys.spawn(
                    spawner,
                    st.handle,
                    arg,
                    ch.data[0],
                    shared.SpawnFlags.grant_log | shared.SpawnFlags.chan_side_a,
                    usys.kbLimits(1 << 10, 4 << 10),
                );
                if (sp.err != .ok) break;
                _ = usys.capDrop(ch.data[0]); // child owns its serving side
                rs.* = .{ .used = true, .chan_b = ch.data[1] };
                sid = @intCast(i);
                ok = true;
                _ = usys.log(glog, "fabsvc: remote spawn request served; child running here");
                break;
            }
            var ack: [13]u8 = undefined;
            frameHdr(ack[0..4], 13, shared.fw_spawn_ack);
            puleu32(ack[4..8], req_id);
            puleu32(ack[8..12], sid);
            ack[12] = if (ok) 1 else if (!allowed) 2 else 0;
            _ = sendFrame(p, &ack);
        },
        shared.fw_spawn_ack => {
            if (body.len < 9) return;
            spawn_ack_session = leu32(body[4..8]);
            spawn_ack_code = body[8];
            got_spawn_ack = true;
        },
        shared.fw_revoke => {
            // A root-signed revocation, forwarded by a peer: verify, apply,
            // and pass it on once if it was news.
            if (body.len < fabcert.rev_len) return;
            if (applyRevocation(body[0..fabcert.rev_len])) gossipRevocation(body[0..fabcert.rev_len], p);
        },
        shared.fw_call_req => {
            // [export u32][seq u32][4 x u64][cap export u32] -> a worker
            // calls the local channel; a cap that crossed with the call
            // becomes a badged session back to the caller's node. No
            // free worker = refused, never a stall.
            if (body.len < 44) return;
            const eid = leu32(body[0..4]);
            const seq = leu32(body[4..8]);
            var w: [4]u64 = undefined;
            for (0..4) |i| w[i] = leu64(body[8 + i * 8 .. 16 + i * 8]);
            const cap_export = leu32(body[40..44]);
            var job: ?*Job = null;
            for (&jobs) |*j| {
                if (j.state.load(.acquire) == 0) {
                    job = j;
                    break;
                }
            }
            if (eid >= max_sessions or !exports[eid].used or job == null) {
                sendCallResp(p, seq, false, @splat(0), 0);
                return;
            }
            const j = job.?;
            j.node = p.node;
            j.seq = seq;
            j.chan_b = exports[eid].chan_b;
            j.cap = if (cap_export != 0) sessionCap(p.node, cap_export - 1) else 0;
            j.words = w;
            j.state.store(1, .release);
            _ = usys.notifySignal(j.bell, 1);
        },
        shared.fw_call_resp => {
            // [seq u32][ok u8][4 x u64][cap export u32] -> answer the
            // parked caller by its token.
            if (body.len < 41) return;
            const seq = leu32(body[0..4]);
            const ok = body[4] != 0;
            var rw: [4]u64 = undefined;
            for (0..4) |i| rw[i] = leu64(body[5 + i * 8 .. 13 + i * 8]);
            const cap_export = leu32(body[37..41]);
            for (&inflight) |*f| {
                if (!f.used or f.seq != seq or f.node != p.node) continue;
                if (!ok) {
                    failReply(f.token, .refused);
                } else {
                    var minted: u64 = 0;
                    if (cap_export != 0) minted = sessionCap(p.node, cap_export - 1);
                    _ = usys.replyRawTo(serve_a, rw, minted, f.token);
                    if (minted != 0) _ = usys.capDrop(minted);
                }
                f.* = .{};
                break;
            }
        },
        else => {},
    }
}

/// Sealed member-view gossip: [free_mb u16][n u8][{node u16, up u8} x n].
fn sendMembersFrame(p: *Peer) void {
    var f: [7 + max_members * 3]u8 = undefined;
    puleu16(f[4..6], @intCast(@min(selfFreeMb(), 0xffff)));
    var n: u8 = 0;
    var off: usize = 7;
    for (&members) |*m| {
        if (!m.used or m.node == p.node) continue;
        puleu16(f[off .. off + 2][0..2], @intCast(m.node));
        f[off + 2] = @intFromBool(m.up);
        off += 3;
        n += 1;
    }
    f[6] = n;
    frameHdr(f[0..4], @intCast(off), shared.fw_members);
    _ = sendFrame(p, f[0..off]);
}

// ------------------------------------------------------------ operations

fn peerByNode(node: u64) ?*Peer {
    for (&peers) |*p| {
        if (p.used and !p.dead and p.node == node) return p;
    }
    return null;
}

fn doConnectPeer(node: u64) shared.FabResp {
    if (peerByNode(node)) |p| {
        if (p.greeted) return .ok;
        // A half-open attempt from an earlier dial must not linger beside
        // a fresh one: the stale socket would be a dead letterbox that
        // peerByNode could still hand to a caller. Close it first.
        _ = ncall(.{ .tcp_close = .{ .sock = p.sock } });
        p.dead = true;
    }
    const words = shared.v4Words(shared.nodeIp4(node));
    const sock = nnum(ncall(.{ .tcp_connect = .{
        .ip_hi = words[0],
        .ip_lo = words[1],
        .port = shared.fabric_port,
    } })) orelse return ferr(.refused);
    watchSock(sock);

    // Wait for the handshake, pumping our own stack.
    var established = false;
    for (0..30) |_| {
        const st = nnum(ncall(.{ .tcp_status = .{ .sock = sock } })) orelse break;
        if (st == @intFromEnum(shared.TcpState.established)) {
            established = true;
            break;
        }
        if (st == @intFromEnum(shared.TcpState.closed)) break;
        usys.sleep(1);
    }
    if (!established) {
        _ = ncall(.{ .tcp_close = .{ .sock = sock } });
        return ferr(.timeout);
    }
    var p: *Peer = undefined;
    var found = false;
    for (&peers) |*slot| {
        if (!slot.used) {
            slot.* = .{ .used = true, .sock = sock, .node = node, .born = tick };
            p = slot;
            found = true;
            break;
        }
    }
    if (!found) return ferr(.no_space);

    p.dialer = true;
    p.nonce_mine = mkNonce();
    mkEphemeral(p);
    var hello: [4 + hello_len]u8 = undefined;
    frameHdr(hello[0..4], hello.len, shared.fw_hello);
    puleu16(hello[4..6], @intCast(my_node));
    @memcpy(hello[6..22], &p.nonce_mine);
    @memcpy(hello[22..54], &p.eph_pk);
    @memcpy(hello[54..], &my_cert);
    if (!sendFrame(p, &hello)) return ferr(.disconnected);
    for (0..50) |_| {
        pumpAll();
        if (p.greeted) return .ok;
        if (p.dead) return ferr(.disconnected);
        usys.sleep(1);
    }
    return ferr(.timeout);
}

/// An authenticated peer for `node` — the only kind RPC may travel on.
fn greetedPeer(node: u64) ?*Peer {
    const p = peerByNode(node) orelse return null;
    return if (p.greeted) p else null;
}

/// Pick the least-loaded live member for a placement spawn (never self).
fn placeNode() ?u64 {
    var best: ?u64 = null;
    var best_free: u64 = 0;
    for (&members) |*m| {
        if (!m.used or !m.up or m.node == my_node) continue;
        if (peerByNode(m.node) == null) continue;
        if (best == null or m.free_mb > best_free) {
            best = m.node;
            best_free = m.free_mb;
        }
    }
    return best;
}

fn doRemoteSpawn(node_arg: u64, image: u64, arg: u64) void {
    const node = if (node_arg == 0)
        placeNode() orelse {
            freply(ferr(.no_peer));
            return;
        }
    else
        node_arg;
    const p = greetedPeer(node) orelse {
        freply(ferr(.no_peer));
        return;
    };
    got_spawn_ack = false;
    var req: [18]u8 = undefined;
    frameHdr(req[0..4], 18, shared.fw_spawn_req);
    puleu16(req[4..6], @intCast(image));
    puleu64(req[6..14], arg);
    puleu32(req[14..18], 1);
    if (!sendFrame(p, &req)) {
        freply(ferr(.disconnected));
        return;
    }
    for (0..50) |_| {
        pumpAll();
        if (got_spawn_ack) break;
        if (p.dead) {
            freply(ferr(.disconnected));
            return;
        }
        usys.sleep(1);
    }
    if (!got_spawn_ack) {
        freply(ferr(.timeout));
        return;
    }
    if (spawn_ack_code == 2) {
        freply(ferr(.denied));
        return;
    }
    if (spawn_ack_code != 1) {
        freply(ferr(.refused));
        return;
    }
    // Bind a local badge to the remote export and hand out the cap: the
    // caller receives an ordinary-looking channel to a remote service.
    const minted = sessionCap(node, spawn_ack_session);
    if (minted == 0) {
        freply(ferr(.no_space));
        return;
    }
    _ = usys.replyTyped(shared.FabResp, serve_a, .{ .spawned = .{ .node = node } }, minted);
    _ = usys.capDrop(minted);
}

/// A worker thread: wait for a job, make the (blocking) local call, hand
/// the result back to the serve thread.
fn worker(idx: u64) callconv(.c) void {
    const j = &jobs[idx];
    while (true) {
        _ = usys.notifyWait(j.bell);
        if (j.state.load(.acquire) != 1) continue;
        const res = usys.callRaw(j.chan_b, j.words, j.cap);
        if (j.cap != 0) _ = usys.capDrop(j.cap);
        j.ok = res.err == .ok;
        j.reply = res.data;
        j.reply_cap = if (res.err == .ok) res.cap else 0;
        j.state.store(2, .release);
        _ = usys.notifySignal(notif, bit_work);
    }
}

/// Serve thread: send every finished job's response.
fn finishJobs() void {
    for (&jobs) |*j| {
        if (j.state.load(.acquire) != 2) continue;
        var export_id: u32 = 0;
        if (j.reply_cap != 0) {
            if (exportNew(j.reply_cap)) |x| export_id = x + 1 else _ = usys.capDrop(j.reply_cap);
        }
        if (peerByNode(j.node)) |p| {
            if (p.greeted) sendCallResp(p, j.seq, j.ok, j.reply, export_id);
        }
        j.* = .{ .bell = j.bell };
    }
}

fn sendCallResp(p: *Peer, seq: u32, ok: bool, rw: [4]u64, export_id: u32) void {
    var resp: [45]u8 = undefined;
    frameHdr(resp[0..4], 45, shared.fw_call_resp);
    puleu32(resp[4..8], seq);
    resp[8] = if (ok) 1 else 0;
    for (0..4) |i| puleu64(resp[9 + i * 8 .. 17 + i * 8], rw[i]);
    puleu32(resp[41..45], export_id);
    _ = sendFrame(p, &resp);
}

/// A badged cap on this service bound to (node, export id there): the
/// local face of a remote channel. 0 when the tables are full.
fn sessionCap(node: u64, remote_id: u32) u64 {
    for (&sessions, 0..) |*se, i| {
        if (se.used) continue;
        se.* = .{ .used = true, .node = node, .remote_id = remote_id };
        const minted = usys.chanMint(serve_a, i + 1);
        if (minted.err != .ok) {
            se.* = .{};
            return 0;
        }
        return minted.data[1];
    }
    return 0;
}

/// Make a local channel cap reachable by peers under an export id.
fn exportNew(chan_b: u64) ?u32 {
    for (&exports, 0..) |*e, i| {
        if (e.used) continue;
        e.* = .{ .used = true, .chan_b = chan_b };
        return @intCast(i);
    }
    return null;
}

/// A badged call: forward the words (and any attached channel cap, as
/// an export) to the remote peer and park the caller under its reply
/// token; the response — or the peer's death, or a timeout — answers it
/// later from the serve loop. This is the remote channel's entire
/// implementation, and nothing here waits.
fn forwardCall(badge: u64, words: [4]u64, cap: u64, token: u64) void {
    if (badge - 1 >= max_sessions or !sessions[badge - 1].used) return failReply(token, .no_peer);
    const sess = &sessions[badge - 1];
    const p = greetedPeer(sess.node) orelse return failReply(token, .disconnected);
    var slot: ?*InFlight = null;
    for (&inflight) |*f| {
        if (!f.used) {
            slot = f;
            break;
        }
    }
    const f = slot orelse return failReply(token, .no_space);
    var cap_export: u32 = 0;
    if (cap != 0) {
        const x = exportNew(cap) orelse return failReply(token, .no_space);
        cap_export = x + 1;
    }
    const seq = next_seq;
    next_seq +%= 1;
    if (next_seq == 0) next_seq = 1;
    f.* = .{ .used = true, .token = token, .seq = seq, .node = sess.node, .deadline = tick + call_timeout };
    var req: [48]u8 = undefined;
    frameHdr(req[0..4], 48, shared.fw_call_req);
    puleu32(req[4..8], sess.remote_id);
    puleu32(req[8..12], seq);
    for (0..4) |i| puleu64(req[12 + i * 8 .. 20 + i * 8], words[i]);
    puleu32(req[44..48], cap_export);
    if (!sendFrame(p, &req)) {
        f.* = .{};
        return failReply(token, .disconnected);
    }
    var live: u64 = 0;
    for (&inflight) |*g| {
        if (g.used) live += 1;
    }
    if (live > max_inflight_seen) max_inflight_seen = live;
}

fn failReply(token: u64, code: shared.FabErr) void {
    _ = usys.replyRawTo(serve_a, .{ shared.fabric_err_sentinel, @intFromEnum(code), 0, 0 }, 0, token);
}

/// The clock's job: an exchange past its deadline fails its caller and
/// its peer — the node-kill drill lands here when a peer vanishes
/// mid-RPC before the heartbeats notice.
fn expireInflight() void {
    for (&inflight) |*f| {
        if (!f.used or tick < f.deadline) continue;
        const node = f.node;
        failReply(f.token, .timeout);
        f.* = .{};
        if (peerByNode(node)) |p| peerFailed(p);
    }
}

// ------------------------------------------------------------- utilities

fn frameHdr(b: *[4]u8, len: u16, ftype: u8) void {
    puleu16(b[0..2], len);
    b[2] = ftype;
    b[3] = shared.fabric_ver;
}

fn leu16(b: []const u8) u16 {
    return @as(u16, b[0]) | (@as(u16, b[1]) << 8);
}

fn leu32(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}

fn leu64(b: []const u8) u64 {
    var v: u64 = 0;
    for (0..8) |i| v |= @as(u64, b[i]) << @intCast(i * 8);
    return v;
}

fn puleu16(b: []u8, v: u16) void {
    b[0] = @truncate(v);
    b[1] = @truncate(v >> 8);
}

fn puleu32(b: []u8, v: u32) void {
    for (0..4) |i| b[i] = @truncate(v >> @intCast(i * 8));
}

fn puleu64(b: []u8, v: u64) void {
    for (0..8) |i| b[i] = @truncate(v >> @intCast(i * 8));
}
