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
//!                     and proxies the child's channel back. Membership is
//!                     a static table (node N = 10.77.0.N). The fabric has
//!                     no thread of its own beyond the serve loop: the
//!                     node driver's poll tick keeps TCP breathing.
//!   2 "remote-echo" — the remotely-spawned service: an ordinary
//!                     CalcRequest server on its granted channel; it
//!                     neither knows nor cares that its clients are on
//!                     another machine.

const shared = @import("shared");
const usys = @import("usys.zig");

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
        \\.global _ustart
        \\_ustart:
        \\        b       umain
    );
}

pub const panic = @import("std").debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

const spawner: u64 = @bitCast(shared.Handle{ .slot = 2, .generation = 1 });

export fn umain(log_h: u64, chan_h: u64, arg: u64) callconv(.c) noreturn {
    switch (arg & 0xff) {
        1 => fabsvc(log_h, chan_h, (arg >> 8) & 0xff),
        2 => remoteEcho(log_h, chan_h),
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
            .greet => _ = usys.replyTyped(shared.CalcReply, chan_h, .hi, 0),
        }
    }
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
    greeted: bool = false,
    dead: bool = false,
    born: u64 = 0, // tick when accepted/dialed (reaps silent strangers)
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

/// A-side: badge -> the remote service's home. Keyed by NODE (not peer
/// slot) so a peer slot recycled by rejoin can never misroute a stale
/// session; calls to a rebooted node fail cleanly instead.
const Session = struct {
    used: bool = false,
    node: u64 = 0,
    remote_id: u32 = 0,
};

/// B-side: remote session id -> local channel to the spawned child.
const RSession = struct {
    used: bool = false,
    chan_b: u64 = 0,
};

var peers: [max_peers]Peer = @splat(.{});
var members: [max_members]Member = @splat(.{});
var sessions: [max_sessions]Session = @splat(.{});
var rsessions: [max_sessions]RSession = @splat(.{});
var serve_a: u64 = 0;
var net_chan: u64 = 0;
var net_buf: u64 = 0;
var fab_buf: u64 = 0; // client shm for members listings
const no_sock: u64 = 0xffff_ffff_ffff_ffff;
var lsock: u64 = no_sock; // sockets are small indices; 0 is valid!
var my_node: u64 = 0;
var glog: u64 = 0;
var tick: u64 = 0; // the local poll clock
var last_ping: u64 = 0;
var mesh_logged = false;

// One outstanding wire exchange at a time (v0 serializes).
var got_spawn_ack = false;
var spawn_ack_session: u32 = 0;
var spawn_ack_ok = false;
var got_call_resp = false;
var call_resp_ok = false;
var call_resp_words: [4]u64 = @splat(0);

fn fabsvc(log_h: u64, chan_h: u64, node: u64) noreturn {
    glog = log_h;
    serve_a = chan_h;
    my_node = node;
    _ = memberUpsert(my_node, true);

    while (true) {
        const r = usys.recvMsg(serve_a);
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err != .ok) usys.exit(151);
        if (r.badge != 0) {
            forwardCall(r.badge, r.data);
            continue;
        }
        const req = shared.decodeMsg(shared.FabReq, r.data) orelse {
            freply(ferr(.refused));
            continue;
        };
        switch (req) {
            .attach_net => {
                if (r.cap != 0) {
                    net_chan = r.cap;
                    netAttach();
                }
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
            .poll => {
                tick += 1;
                pumpAll();
                heartbeat();
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
    _ = usys.log(glog, "fabsvc: listening on the fabric port");
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

/// Send one wire frame on a peer's socket, retrying past stop-and-wait.
/// Failure (hard error or retries exhausted) is a PEER FAILURE: membership
/// learns immediately, not on the next silent timeout.
fn sendFrame(p: *Peer, frame: []const u8) bool {
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
    const buf: [*]u8 = @ptrFromInt(net_buf);
    @memcpy(buf[0..frame.len], frame);
    const resp = ncall(.{ .tcp_send = .{ .sock = p.sock, .len = frame.len } });
    if (nnum(resp) != null) return;
    if (!wouldBlock(resp)) peerFailed(p);
}

/// One place a peer dies: close, membership down, broadcast. Setting
/// p.dead FIRST keeps the broadcast from recursing into this peer.
fn peerFailed(p: *Peer) void {
    if (p.dead) return;
    p.dead = true;
    _ = ncall(.{ .tcp_close = .{ .sock = p.sock } });
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
            p.dead = true;
            break;
        }
        @memcpy(p.rx[p.rxlen .. p.rxlen + n], buf[0..n]);
        p.rxlen += n;
    }
    // Process complete frames: [len u16][type u8][ver u8][payload].
    while (p.rxlen >= 4) {
        const flen = leu16(p.rx[0..2]);
        if (flen < 4 or flen > rxbuf_cap) {
            p.dead = true;
            return;
        }
        if (p.rxlen < flen) return;
        if (p.rx[3] != shared.fabric_ver) {
            p.dead = true; // version mismatch: drop the peer, loudly simple
            return;
        }
        handleFrame(p, p.rx[2], p.rx[4..flen]);
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
            if (body.len < 2) return;
            const node = leu16(body[0..2]);
            // Rejoin / duplicate: a fresh connection for a node we already
            // track replaces the old one (the old socket is stale).
            for (&peers) |*old| {
                if (old.used and old != p and old.node == node) {
                    _ = ncall(.{ .tcp_close = .{ .sock = old.sock } });
                    old.dead = true;
                }
            }
            p.node = node;
            p.greeted = true;
            _ = memberUpsert(node, true);
            if (memberByNode(node)) |m| m.last_heard = tick;
            sendHelloAck(p);
            broadcastMember(shared.fw_member_up, node);
            _ = usys.log(glog, "fabsvc: peer joined (hello); acked with member view");
        },
        shared.fw_hello_ack => {
            if (body.len < 5) return;
            p.node = leu16(body[0..2]);
            p.greeted = true;
            _ = memberUpsert(p.node, true);
            if (memberByNode(p.node)) |m| {
                m.last_heard = tick;
                m.free_mb = leu16(body[2..4]);
            }
            // The gossip payload: the acker's member view.
            const n = body[4];
            var off: usize = 5;
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
            if (body.len < 2) return;
            const node = leu16(body[0..2]);
            if (node != my_node) _ = memberUpsert(node, true);
        },
        shared.fw_member_down => {
            if (body.len < 2) return;
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
            var sid: u32 = 0;
            var ok = false;
            for (&rsessions, 0..) |*rs, i| {
                if (rs.used) continue;
                const ch = usys.chanCreate();
                if (ch.err != .ok) break;
                const sp = usys.spawn(
                    spawner,
                    @enumFromInt(image),
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
            ack[12] = if (ok) 1 else 0;
            _ = sendFrame(p, &ack);
        },
        shared.fw_spawn_ack => {
            if (body.len < 9) return;
            spawn_ack_session = leu32(body[4..8]);
            spawn_ack_ok = body[8] != 0;
            got_spawn_ack = true;
        },
        shared.fw_call_req => {
            // [session u32][seq u32][4 x u64] -> call the local child.
            if (body.len < 40) return;
            const sid = leu32(body[0..4]);
            const seq = leu32(body[4..8]);
            var w: [4]u64 = undefined;
            for (0..4) |i| w[i] = leu64(body[8 + i * 8 .. 16 + i * 8]);
            var ok = false;
            var rw: [4]u64 = @splat(0);
            if (sid < max_sessions and rsessions[sid].used) {
                const res = usys.callRaw(rsessions[sid].chan_b, w, 0);
                if (res.err == .ok) {
                    ok = true;
                    rw = res.data;
                }
            }
            var resp: [41]u8 = undefined;
            frameHdr(resp[0..4], 41, shared.fw_call_resp);
            puleu32(resp[4..8], seq);
            resp[8] = if (ok) 1 else 0;
            for (0..4) |i| puleu64(resp[9 + i * 8 .. 17 + i * 8], rw[i]);
            _ = sendFrame(p, &resp);
        },
        shared.fw_call_resp => {
            if (body.len < 37) return;
            call_resp_ok = body[4] != 0;
            for (0..4) |i| call_resp_words[i] = leu64(body[5 + i * 8 .. 13 + i * 8]);
            got_call_resp = true;
        },
        else => {},
    }
}

/// hello_ack: [node u16][free_mb u16][n u8][{node u16, up u8} x n].
fn sendHelloAck(p: *Peer) void {
    var ack: [9 + max_members * 3]u8 = undefined;
    puleu16(ack[4..6], @intCast(my_node));
    puleu16(ack[6..8], @intCast(@min(selfFreeMb(), 0xffff)));
    var n: u8 = 0;
    var off: usize = 9;
    for (&members) |*m| {
        if (!m.used or m.node == p.node) continue;
        puleu16(ack[off .. off + 2][0..2], @intCast(m.node));
        ack[off + 2] = @intFromBool(m.up);
        off += 3;
        n += 1;
    }
    ack[8] = n;
    frameHdr(ack[0..4], @intCast(off), shared.fw_hello_ack);
    _ = sendFrame(p, ack[0..off]);
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
    }
    const words = shared.v4Words(shared.nodeIp4(node));
    const sock = nnum(ncall(.{ .tcp_connect = .{
        .ip_hi = words[0],
        .ip_lo = words[1],
        .port = shared.fabric_port,
    } })) orelse return ferr(.refused);

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

    var hello: [6]u8 = undefined;
    frameHdr(hello[0..4], 6, shared.fw_hello);
    puleu16(hello[4..6], @intCast(my_node));
    if (!sendFrame(p, &hello)) return ferr(.disconnected);
    for (0..50) |_| {
        pumpAll();
        if (p.greeted) return .ok;
        if (p.dead) return ferr(.disconnected);
        usys.sleep(1);
    }
    return ferr(.timeout);
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
    const p = peerByNode(node) orelse {
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
    if (!got_spawn_ack or !spawn_ack_ok) {
        freply(ferr(.timeout));
        return;
    }
    // Bind a local badge to the remote session and hand out the cap: the
    // caller receives an ordinary-looking channel to a remote service.
    var badge: u64 = 0;
    var found = false;
    for (&sessions, 0..) |*se, i| {
        if (!se.used) {
            se.* = .{ .used = true, .node = node, .remote_id = spawn_ack_session };
            badge = i + 1;
            found = true;
            break;
        }
    }
    if (!found) {
        freply(ferr(.no_space));
        return;
    }
    const minted = usys.chanMint(serve_a, badge);
    if (minted.err != .ok) {
        sessions[badge - 1].used = false;
        freply(ferr(.no_space));
        return;
    }
    _ = usys.replyTyped(shared.FabResp, serve_a, .{ .spawned = .{ .node = node } }, minted.data[1]);
    _ = usys.capDrop(minted.data[1]);
}

/// A badged call: forward the words to the remote peer, reply with the
/// remote's words — or the error sentinel if the peer is gone. This is the
/// remote channel's entire implementation.
fn forwardCall(badge: u64, words: [4]u64) void {
    const fail = struct {
        fn f(code: shared.FabErr) void {
            _ = usys.replyRaw(serve_a, .{
                shared.fabric_err_sentinel, @intFromEnum(code), 0, 0,
            }, 0);
        }
    }.f;
    if (badge - 1 >= max_sessions or !sessions[badge - 1].used) return fail(.no_peer);
    const sess = &sessions[badge - 1];
    const p = peerByNode(sess.node) orelse return fail(.disconnected);

    got_call_resp = false;
    var req: [44]u8 = undefined;
    frameHdr(req[0..4], 44, shared.fw_call_req);
    puleu32(req[4..8], sess.remote_id);
    puleu32(req[8..12], 1);
    for (0..4) |i| puleu64(req[12 + i * 8 .. 20 + i * 8], words[i]);
    if (!sendFrame(p, &req)) return fail(.disconnected);
    for (0..30) |_| {
        pumpAll();
        if (got_call_resp) {
            if (!call_resp_ok) return fail(.refused);
            _ = usys.replyRaw(serve_a, call_resp_words, 0);
            return;
        }
        if (p.dead) return fail(.disconnected);
        usys.sleep(1);
    }
    // The node-kill drill lands here: a peer that vanishes mid-RPC.
    peerFailed(p);
    return fail(.timeout);
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
