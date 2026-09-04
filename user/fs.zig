//! The filesystem, by x2:
//!   1 "fssvc" — the FS service. Serves a union namespace: "boot/" is a
//!               read-only MARC archive granted at spawn (the boot image
//!               filesystem), everything else is mossfs v3 — a CoW,
//!               checksummed, crash-consistent, compressed and (when a
//!               key is granted) encrypted filesystem (user/mossfs.zig)
//!               living on the virtio-blk driver over the ring transport.
//!               A *view* is a badged channel cap this service mints: the
//!               badge picks {subtree root, read-only} server-side, so a
//!               process's namespace is exactly the view caps it holds —
//!               nothing outside a view can even be named, and ".." does
//!               not exist.
//!   2 "alice" — root view (rw): reads the boot image, writes disk files,
//!               makes data/pub for bob.
//!   3 "bob"   — a derived view of data/pub, read-only: sees note.txt and
//!               nothing else; every escape and write attempt must fail.
//!   4 "homefs" — a user's HOME VOLUME: the same service over a mossfs
//!               volume kept in a file on the system volume, keyed from
//!               the user's identity; spawned per session by the session
//!               manager and destroyed with it (see "home volumes").
//!   5 "churn"  — the reclamation drill: views and buffers come and go
//!               by the hundred, then two dozen are held to the grave.
//!   6 "churn2" — after churn's death, holds two dozen more at once:
//!               only possible if the dead client's were reclaimed.
//!
//! A client is a badge. When the last cap carrying a view's badge dies
//! (cap_drop, or the holder's teardown) the kernel reports it to the
//! serve loop as client_dead, and the view's buffer is unmapped and its
//! slot freed — a service keeps nothing for a client that is gone.
//!
//! Durability model: ops are acknowledged when applied in memory; a
//! transaction group commits them in batches (and between ops only), and
//! FsReq.sync forces everything down before replying. A crash never
//! damages the tree — it only loses unsynced acknowledgments.
//!
//! Symlinks resolve relative to their containing directory with the same
//! component rules as any path (no "..", no absolute targets), so a link
//! can never name anything outside the view it is read through. At most
//! 8 followed links per resolution; stat/delete/readlink do not follow a
//! final symlink.

const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");
const mossfs = @import("mossfs.zig");
const fsc = @import("fsclient.zig");

comptime {
    asm (usys.imageHeader("fs"));
}

pub const panic = @import("std").debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

export fn umain(log_h: u64, chan_h: u64, role: u64, blob_va: u64, blob_len: u64) callconv(.c) noreturn {
    switch (role) {
        1 => fssvc(log_h, chan_h, blob_va, blob_len),
        2 => alice(log_h, boot.take(chan_h).cap(.view)),
        3 => bob(log_h, boot.take(chan_h).cap(.view)),
        4 => homefs(log_h, chan_h),
        5 => churn(log_h, boot.take(chan_h).cap(.view), false),
        6 => churn(log_h, boot.take(chan_h).cap(.view), true),
        else => usys.exit(250),
    }
}

// ------------------------------------------------------------ the service

const max_views = 32;
const max_boot = 40; // etc/, conf/, and every img/ entry
const max_fds = 8;
const max_path = 256;
const max_target = 200; // symlink target length cap
const max_follow = 8;

const Fd = struct {
    used: bool = false,
    boot: bool = false,
    idx: u32 = 0, // boot entry index
    obj: u32 = 0, // disk object
};

const ViewKind = enum { uroot, boot, disk };

const View = struct {
    used: bool = false,
    /// Withdrawn: every call fails until the holder's last cap dies and
    /// client_dead frees the slot (never reused before, so a stale cap
    /// cannot alias the next view minted here).
    revoked: bool = false,
    /// The badge that derived this view (0: the root).
    parent: u64 = 0,
    ro: bool = false,
    kind: ViewKind = .uroot,
    boot_prefix: [48]u8 = undefined,
    boot_prefix_len: usize = 0,
    obj: u32 = 0, // disk subtree root
    buf: u64 = 0,
    buf_pages: u64 = 0,
    fds: [max_fds]Fd = @splat(.{}),
};

const BootEntry = struct {
    path: []const u8,
    data: []const u8,
};

var views: [max_views]View = @splat(.{});
var boot_entries: [max_boot]BootEntry = undefined;
var boot_count: usize = 0;
var serve_a: u64 = 0;
var glog: u64 = 0;

var mfs: mossfs.Fs = undefined;
var disk_ok = false;

fn fssvc(log_h: u64, chan_h: u64, blob_va: u64, blob_len: u64) noreturn {
    glog = log_h;
    serve_a = chan_h;
    parseBoot(blob_va, blob_len);
    views[0] = .{ .used = true, .ro = false, .kind = .uroot }; // badge 0: root of trust

    // Boot: the root view's buffer, the volume key (32 bytes, secret),
    // and the disk — from whoever spawned us. Without a disk we serve
    // the boot archive alone.
    var setup = boot.take(chan_h);
    views[0].buf = setup.buf_va;
    views[0].buf_pages = setup.buf_pages;
    if (setup.secret().len == 32) {
        pending_key = setup.secret()[0..32].*;
        setup.wipeSecret();
    }
    if (setup.has(.disk)) {
        _ = setupDisk(setup.cap(.disk));
    } else {
        _ = usys.log(glog, "fssvc: no disk handed over; serving bootfs only");
    }
    serve();
}

/// The view protocol, for every client badge, forever.
fn serve() noreturn {
    while (true) {
        const r = usys.recvMsg(serve_a);
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err == .client_dead) {
            releaseView(r.badge);
            continue;
        }
        if (r.err != .ok) usys.exit(200);
        const req = shared.decodeMsg(shared.FsReq, r.data) orelse {
            _ = usys.replyTyped(shared.FsResp, serve_a, ferr(.bad_path), 0);
            continue;
        };
        const v = viewOf(r.badge) orelse {
            _ = usys.replyTyped(shared.FsResp, serve_a, ferr(.bad_fd), 0);
            continue;
        };
        switch (req) {
            .attach_buf => {
                if (r.cap != 0) {
                    const m = usys.shmMap(r.cap);
                    if (m.err == .ok) {
                        if (v.buf != 0) _ = usys.shmUnmap(v.buf); // re-attached: the old one goes
                        v.buf = m.data[0];
                        v.buf_pages = m.data[1];
                    }
                    _ = usys.capDrop(r.cap); // the mapping keeps its own ref
                }
                _ = usys.replyTyped(shared.FsResp, serve_a, .ok, 0);
            },
            .open => |o| reply(doOpen(v, o.path_off, o.path_len, o.create)),
            .read => |io| reply(doRead(v, io.fd, io.off, io.len)),
            .write => |io| reply(doWrite(v, io.fd, io.off, io.len)),
            .list => |l| reply(doList(v, l.path_off, l.path_len)),
            .derive => |dv| doDerive(v, r.badge, dv.path_off, dv.path_len, dv.ro != 0),
            .revoke => |rv| reply(doRevoke(r.badge, rv.badge)),
            .delete => |d| reply(doDelete(v, d.path_off, d.path_len)),
            .rename => |rn| reply(doRename(v, rn.from, rn.to)),
            .truncate => |t| reply(doTruncate(v, t.fd, t.len)),
            .stat => |st| reply(doStat(v, st.path_off, st.path_len)),
            .symlink => |sl| reply(doSymlink(v, sl.path, sl.target)),
            .readlink => |rl| reply(doReadlink(v, rl.path_off, rl.path_len)),
            .sync => reply(doSync()),
            .statfs => reply(doStatfs()),
            .close => |c| reply(doClose(v, c.fd)),
        }
        // Batched durability: commit between ops when enough is dirty.
        if (disk_ok) mfs.maybeCommit(nowSec()) catch {};
    }
}

fn reply(resp: shared.FsResp) void {
    _ = usys.replyTyped(shared.FsResp, serve_a, resp, 0);
}

fn ferr(code: shared.FsErr) shared.FsResp {
    return .{ .fs_err = .{ .code = @intFromEnum(code) } };
}

fn viewOf(badge: u64) ?*View {
    if (badge >= max_views) return null;
    if (!views[badge].used or views[badge].revoked) return null;
    return &views[badge];
}

/// Withdraw a view: the root may revoke any, a view only those it
/// derived. Its buffer goes now; the slot waits for client_dead.
fn doRevoke(caller: u64, badge: u64) shared.FsResp {
    if (badge == 0 or badge >= max_views or !views[badge].used) return ferr(.bad_fd);
    const v = &views[badge];
    if (caller != 0 and v.parent != caller) return ferr(.denied);
    if (v.buf != 0) _ = usys.shmUnmap(v.buf);
    v.buf = 0;
    v.buf_pages = 0;
    v.revoked = true;
    for (&v.fds) |*fd| fd.used = false;
    return .ok;
}

/// A client identity died — the last cap carrying this view's badge is
/// gone, so nobody can ever call through it again: its buffer is
/// unmapped (the last ref on a buffer the client created goes with it),
/// its open files are forgotten, and the badge is free to mint again.
fn releaseView(badge: u64) void {
    if (badge == 0) return; // the root view's holders are the side itself
    const v = viewOf(badge) orelse return;
    if (v.buf != 0) _ = usys.shmUnmap(v.buf);
    v.* = .{};
}

fn parseBoot(blob_va: u64, blob_len: u64) void {
    if (blob_len < 4) return;
    const blob = @as([*]const u8, @ptrFromInt(blob_va))[0..blob_len];
    if (!eq(blob[0..4], shared.marc_magic)) return;
    var off: usize = 4;
    while (off + 8 <= blob.len and boot_count < max_boot) {
        const plen = leu32(blob[off..]);
        const dlen = leu32(blob[off + 4 ..]);
        off += 8;
        if (off + plen + dlen > blob.len) break;
        boot_entries[boot_count] = .{
            .path = blob[off .. off + plen],
            .data = blob[off + plen .. off + plen + dlen],
        };
        boot_count += 1;
        off += plen + dlen;
    }
}

var cycle_hz: u64 = 0;

fn nowSec() u64 {
    if (cycle_hz == 0) cycle_hz = usys.cycleHz();
    return usys.cycles() / cycle_hz;
}

// ----------------------------------------------------------- disk backend
//
// mossfs speaks sector runs (<= 8 sectors) against a BlockDev vtable; this
// one rides the blk driver's ring transport (SQ/CQ in shared memory,
// notification doorbells) over a 256K data window of 8 x 32K slots:
//
// - WRITES COALESCE AND PIPELINE: adjacent runs (the byte-aligned
//   allocator emits mostly-sequential addresses) accumulate into an open
//   32K staging slot and ship as one 64-sector request; up to 7 such
//   requests are in flight at once. This is sound because mossfs orders
//   writes only at dev.flush() and never reads back a sector written
//   since the last flush except through its cache.
// - READS drain outstanding writes (belt and braces), then fetch 32K of
//   READAHEAD into slot 0 — sequential file reads hit the next 7 blocks
//   for free. A write overlapping the readahead range invalidates it.
// - flush drains, then goes over the sync channel; the reply doubles as
//   the barrier ack.

const blk_slots = 8; // 32K window slots; slot 0 = read/readahead, 1..7 = writes
const slot_bytes: u64 = 32768;
const slot_secs: u64 = slot_bytes / 512; // 64: one protocol request

var blk_chan: u64 = 0;
var blk_buf: u64 = 0; // 8-slot shm data window; slot i at i*slot_bytes
var blk_ring: *shared.RingBuf = undefined;
var sq_bell: u64 = 0;
var cq_bell: u64 = 0;
var dev_ctx_dummy: u8 = 0;
var pending_key: ?[32]u8 = null;
var slot_busy: [blk_slots]bool = @splat(false); // [0] unused (read slot)
var wr_error = false; // sticky until the next barrier reports it

// Open write-staging run (in its reserved slot, not yet submitted).
var stage_slot: u32 = 0; // 0 = none open
var stage_sector: u64 = 0;
var stage_secs: u64 = 0;

// Readahead: slot 0 holds ra_secs sectors starting at ra_sector.
var ra_sector: u64 = 0;
var ra_secs: u64 = 0;
var dev_nsecs: u64 = 0; // set at attach; mfs may not be mounted yet

/// Reap one completion (blocking); frees its slot. IO errors latch into
/// wr_error so the barrier that needs them can fail the whole txg.
fn reapOne() void {
    var e: shared.RingEntry = undefined;
    while (!blk_ring.cqPop(&e)) _ = usys.notifyWait(cq_bell);
    if (e.id < blk_slots) slot_busy[@intCast(e.id)] = false;
    const resp = shared.decodeMsg(shared.BlkResp, e.words) orelse {
        wr_error = true;
        return;
    };
    if (resp != .ok) wr_error = true;
}

fn submitStage() void {
    if (stage_slot == 0) return;
    const req: shared.BlkReq = .{ .write = .{
        .sector = stage_sector,
        .off = @as(u64, stage_slot) * slot_bytes,
        .count = stage_secs,
    } };
    if (blk_ring.sqPush(.{ .id = stage_slot, .words = shared.encodeMsg(shared.BlkReq, req) })) {
        slot_busy[stage_slot] = true;
        _ = usys.notifySignal(sq_bell, 1);
    } else {
        wr_error = true; // SQ full cannot happen at <=7 in flight; fail safe
    }
    stage_slot = 0;
}

fn drainWrites() void {
    submitStage();
    var outstanding: u32 = 0;
    for (slot_busy) |b| {
        if (b) outstanding += 1;
    }
    while (outstanding > 0) : (outstanding -= 1) reapOne();
}

fn takeWriteSlot() u32 {
    while (true) {
        for (slot_busy[1..], 1..) |b, i| {
            if (!b) return @intCast(i);
        }
        reapOne();
    }
}

fn devRead(_: *anyopaque, sector: u64, count: u64, dst: []u8) mossfs.DevError!void {
    if (count == 0 or count > mossfs.spb) return error.IoError;
    if (sector >= ra_sector and sector + count <= ra_sector + ra_secs) {
        const src: [*]const volatile u8 = @ptrFromInt(blk_buf + (sector - ra_sector) * 512);
        for (0..dst.len) |i| dst[i] = src[i];
        return;
    }
    drainWrites();
    if (wr_error) return error.IoError;
    ra_secs = 0;
    const want = @min(slot_secs, dev_nsecs -| sector);
    if (want < count) return error.IoError;
    const req: shared.BlkReq = .{ .read = .{ .sector = sector, .off = 0, .count = want } };
    if (!blk_ring.sqPush(.{ .id = blk_slots, .words = shared.encodeMsg(shared.BlkReq, req) }))
        return error.IoError;
    _ = usys.notifySignal(sq_bell, 1);
    var e: shared.RingEntry = undefined;
    while (!blk_ring.cqPop(&e)) _ = usys.notifyWait(cq_bell);
    const resp = shared.decodeMsg(shared.BlkResp, e.words) orelse return error.IoError;
    if (resp != .ok) return error.IoError;
    ra_sector = sector;
    ra_secs = want;
    const src: [*]const volatile u8 = @ptrFromInt(blk_buf);
    for (0..dst.len) |i| dst[i] = src[i];
}

fn devWrite(_: *anyopaque, sector: u64, count: u64, src: []const u8) mossfs.DevError!void {
    if (count == 0 or count > mossfs.spb) return error.IoError;
    // Stale-readahead guard: this range's content is changing.
    if (sector < ra_sector + ra_secs and ra_sector < sector + count) ra_secs = 0;
    if (stage_slot != 0) {
        if (sector == stage_sector + stage_secs and stage_secs + count <= slot_secs) {
            const dst: [*]volatile u8 = @ptrFromInt(blk_buf + @as(u64, stage_slot) * slot_bytes + stage_secs * 512);
            for (0..src.len) |i| dst[i] = src[i];
            stage_secs += count;
            return;
        }
        submitStage();
    }
    const slot = takeWriteSlot();
    stage_slot = slot;
    stage_sector = sector;
    stage_secs = count;
    const dst: [*]volatile u8 = @ptrFromInt(blk_buf + @as(u64, slot) * slot_bytes);
    for (0..src.len) |i| dst[i] = src[i];
}

fn devFlush(_: *anyopaque) mossfs.DevError!void {
    drainWrites();
    if (wr_error) {
        wr_error = false; // reported; the failed txg will not superblock
        return error.IoError;
    }
    switch (usys.callTyped(shared.BlkReq, shared.BlkResp, blk_chan, .flush, 0)) {
        .ok => |rep| if (rep != .ok) return error.IoError,
        .err => return error.IoError,
    }
}

fn setupDisk(chan: u64) shared.FsResp {
    blk_chan = chan;

    // Data window: 8 x 32K slots (readahead + coalesced write pipeline).
    const s = usys.shmCreate(blk_slots * slot_bytes / 4096);
    if (s.err != .ok) usys.exit(201);
    const m = usys.shmMap(s.data[0]);
    if (m.err != .ok) usys.exit(202);
    blk_buf = m.data[0];
    switch (usys.callTyped(shared.BlkReq, shared.BlkResp, blk_chan, .setup, s.data[0])) {
        .ok => {},
        .err => usys.exit(203),
    }

    // Ring transport: ring page + two doorbells.
    const rs = usys.shmCreate(1);
    if (rs.err != .ok) usys.exit(204);
    const rm = usys.shmMap(rs.data[0]);
    if (rm.err != .ok) usys.exit(205);
    blk_ring = @ptrFromInt(rm.data[0]);
    blk_ring.init();
    const sqb = usys.notifyCreate();
    const cqb = usys.notifyCreate();
    if (sqb.err != .ok or cqb.err != .ok) usys.exit(206);
    sq_bell = sqb.data[0];
    cq_bell = cqb.data[0];
    ringSetup(.ring_setup, rs.data[0]);
    ringSetup(.ring_sq_bell, sq_bell);
    ringSetup(.ring_cq_bell, cq_bell);

    // Geometry.
    const sectors = switch (usys.callTyped(shared.BlkReq, shared.BlkResp, blk_chan, .capacity, 0)) {
        .ok => |rep| switch (rep) {
            .capacity => |c| c.sectors,
            else => usys.exit(207),
        },
        .err => usys.exit(208),
    };
    dev_nsecs = sectors;
    const dev: mossfs.BlockDev = .{
        .ctx = @ptrCast(&dev_ctx_dummy),
        .readFn = devRead,
        .writeFn = devWrite,
        .flushFn = devFlush,
        .nsecs = sectors,
    };
    return attachVolume(dev, sectors);
}

/// Mount (or format) the volume behind `dev`, check its key, and shape
/// its root: shared by the disk-backed service and the file-backed one.
fn attachVolume(dev: mossfs.BlockDev, sectors: u64) shared.FsResp {
    // Mount; format only a genuinely blank disk (all-zero superblock
    // region) — a garbage or wrong-format disk is NEVER auto-wiped: the
    // service stays up serving bootfs so an operator can intervene.
    var fresh = false;
    mfs.mount(dev) catch |err| switch (err) {
        error.NoFilesystem => {
            if (!sbRegionZero(dev)) {
                _ = usys.log(glog, "fssvc: DISK IS NOT MOSSFS AND NOT BLANK — refusing to format; bootfs only");
                return ferr(.io);
            }
            // Groups: 128MB (262144 sectors) when the volume is big
            // enough for several, else 16MB toy groups.
            const gs: u64 = if (sectors >= 4 * 262144) 262144 else 32768;
            const keyp: ?*const [32]u8 = if (pending_key) |*k| k else null;
            mossfs.Fs.format(dev, gs, keyp) catch usys.exit(209);
            mfs.mount(dev) catch usys.exit(210);
            fresh = true;
        },
        else => usys.exit(211),
    };

    // Key gating: nothing touches object trees until the key checks out.
    if (mfs.keyRequired()) {
        const kp = pending_key orelse {
            _ = usys.log(glog, "fssvc: ENCRYPTED VOLUME, NO KEY — serving bootfs only");
            return ferr(.bad_key);
        };
        mfs.setKey(&kp) catch {
            _ = usys.log(glog, "fssvc: WRONG KEY for encrypted volume — serving bootfs only");
            return ferr(.bad_key);
        };
    }
    if (pending_key) |*k| @memset(k, 0);
    pending_key = null;
    disk_ok = true;

    const now = nowSec();
    if (fresh) {
        // The standard hierarchy exists from the first format.
        for (hierarchy) |name| {
            const o = mfs.allocObject(.dir, now) catch usys.exit(212);
            mfs.dirAdd(mossfs.root_obj, name, o, .dir, now) catch usys.exit(213);
        }
        if (is_home) {
            _ = usys.log(glog, "homefs: formatted a fresh home volume (encrypted)");
        } else if (mfs.enc) {
            _ = usys.log(glog, "fssvc: formatted fresh mossfs (std hierarchy, encrypted)");
        } else {
            _ = usys.log(glog, "fssvc: formatted fresh mossfs (std hierarchy)");
        }
    } else {
        if (is_home) {
            _ = usys.log(glog, "homefs: home volume opened (key verified)");
        } else if (mfs.enc) {
            _ = usys.log(glog, "fssvc: existing mossfs found (encrypted, key verified)");
        } else {
            _ = usys.log(glog, "fssvc: existing mossfs found");
        }
        // Top-level names are the hierarchy, never created through the
        // protocol — so a volume formatted before a tier existed gets it
        // here, from the one place allowed to shape the root.
        for (hierarchy) |name| {
            if ((mfs.dirLookup(mossfs.root_obj, name) catch null) != null) continue;
            const o = mfs.allocObject(.dir, now) catch usys.exit(212);
            mfs.dirAdd(mossfs.root_obj, name, o, .dir, now) catch usys.exit(213);
            _ = usys.log(glog, "fssvc: hierarchy upgraded: added a missing top-level tier");
        }
    }

    // volatile/ starts every boot empty — that is its contract.
    clearVolatile(now);
    mfs.sync(now) catch usys.exit(214);
    return .ok;
}

/// The root's fixed children (boot/ is the archive overlay, not on disk).
const std_hierarchy = [_][]const u8{ "conf", "img", "state", "data", "volatile", "home" };
/// A home volume: the same lifecycle tiers at the user's radius (its
/// conf/ is the user settings layer, its img/ a program store).
const home_hierarchy = [_][]const u8{ "conf", "img", "state", "data", "volatile" };
var hierarchy: []const []const u8 = &std_hierarchy;
var is_home = false;

// ------------------------------------------------------------ home volumes
//
// A home volume is a mossfs volume in a FILE on the system volume
// (`home/<name>/vol`), reached through a view of that directory: the
// block device is the file, one read/write per sector run. Encrypted
// with the key derived from the user's identity, so the system volume
// holds ciphertext and this service, spawned per session and destroyed
// with it, is the only holder of the plaintext.

/// Capacity a home volume reports (the file grows as blocks are written).
const home_capacity_secs: u64 = 16384; // 8 MB
var file_view: u64 = 0;
var file_buf: [*]u8 = undefined;
var file_fd: u64 = 0;

fn homefs(log_h: u64, chan_h: u64) noreturn {
    glog = log_h;
    serve_a = chan_h;
    hierarchy = &home_hierarchy;
    is_home = true;
    views[0] = .{ .used = true, .ro = false, .kind = .uroot };
    var setup = boot.take(chan_h);
    views[0].buf = setup.buf_va;
    views[0].buf_pages = setup.buf_pages;
    if (setup.secret().len == 32) {
        pending_key = setup.secret()[0..32].*;
        setup.wipeSecret();
    }
    const backing = setup.cap(.view);
    if (backing == 0 or pending_key == null) usys.exit(230);
    _ = setupFile(backing);
    serve();
}

fn setupFile(view: u64) shared.FsResp {
    file_view = view;
    file_buf = @ptrFromInt(fsc.attachBuf(view).va);
    file_fd = switch (fsc.fsOpen(view, file_buf, "vol", 1)) {
        .fd => |fd| fd,
        .err => usys.exit(231),
    };
    const dev: mossfs.BlockDev = .{
        .ctx = @ptrCast(&dev_ctx_dummy),
        .readFn = fileRead,
        .writeFn = fileWrite,
        .flushFn = fileFlush,
        .nsecs = home_capacity_secs,
    };
    return attachVolume(dev, home_capacity_secs);
}

/// The read-ahead window: a volume behind a view — a remote home's,
/// above all, where every read is an exchange across the fabric — is
/// read a whole window (fs_max_io, 32 KB) at a time, and the blocks
/// that follow a miss are served from it. This service is the volume's
/// only writer (a remote home is leased to exactly one), so the window
/// stays true as long as writes go through it.
var ra_buf: [shared.fs_max_io]u8 = undefined;
var ra_off: u64 = 0;
var ra_len: usize = 0; // 0: no window

fn raInvalidate() void {
    ra_len = 0;
}

/// Past the file's end reads as zeros: a fresh volume file is blank.
fn fileRead(_: *anyopaque, sector: u64, count: u64, dst: []u8) mossfs.DevError!void {
    const off = sector * mossfs.sector_size;
    const len = count * mossfs.sector_size;
    if (len > dst.len) return error.IoError;
    if (ra_len != 0 and off >= ra_off and off + len <= ra_off + ra_len) {
        @memcpy(dst[0..len], ra_buf[off - ra_off .. off - ra_off + len]);
        return;
    }
    if (len > shared.fs_max_io) {
        const n = fsc.fsReadAt(file_view, file_fd, off, len) orelse return error.IoError;
        const k = @min(n, len);
        @memcpy(dst[0..k], file_buf[0..k]);
        @memset(dst[k..len], 0);
        return;
    }
    // A window aligned to its own size, holding the request.
    const win = off - off % shared.fs_max_io;
    const n = fsc.fsReadAt(file_view, file_fd, win, shared.fs_max_io) orelse return error.IoError;
    @memcpy(ra_buf[0..n], file_buf[0..n]);
    @memset(ra_buf[n..], 0); // past the end: zeros
    ra_off = win;
    ra_len = shared.fs_max_io;
    @memcpy(dst[0..len], ra_buf[off - win .. off - win + len]);
}

fn fileWrite(_: *anyopaque, sector: u64, _: u64, src: []const u8) mossfs.DevError!void {
    const off = sector * mossfs.sector_size;
    if (!fsc.fsWriteAt(file_view, file_buf, file_fd, off, src)) return error.IoError;
    // Keep the window true: patch what it covers, drop it otherwise.
    if (ra_len != 0) {
        if (off >= ra_off and off + src.len <= ra_off + ra_len) {
            @memcpy(ra_buf[off - ra_off .. off - ra_off + src.len], src);
        } else if (off < ra_off + ra_len and off + src.len > ra_off) {
            raInvalidate();
        }
    }
}

fn fileFlush(_: *anyopaque) mossfs.DevError!void {
    if (!fsc.fsSync(file_view)) return error.IoError;
}

/// True when superblock sectors 0..63 are entirely zero (blank disk).
fn sbRegionZero(dev: mossfs.BlockDev) bool {
    var buf: [mossfs.block_size]u8 = undefined;
    for (0..mossfs.sb_slots) |slot| {
        dev.readFn(dev.ctx, slot * 8, 8, &buf) catch return false;
        for (buf) |b| {
            if (b != 0) return false;
        }
    }
    return true;
}

fn ringSetup(comptime which: shared.BlkReq, cap: u64) void {
    switch (usys.callTyped(shared.BlkReq, shared.BlkResp, blk_chan, which, cap)) {
        .ok => {},
        .err => usys.exit(215),
    }
}

/// Empty volatile/ (one service-dir level deep, then their contents).
fn clearVolatile(now: u64) void {
    const vol = (mfs.dirLookup(mossfs.root_obj, "volatile") catch return) orelse return;
    if (vol.typ != .dir) return;
    deleteChildren(vol.obj, now, 4);
}

fn deleteChildren(dir: u32, now: u64, depth: u32) void {
    if (depth == 0) return;
    var names: [128]u8 = undefined; // only the first entry's name is used
    while (true) {
        const n = mfs.dirList(dir, &names) catch return;
        if (n == 0) return;
        // First line = first entry.
        var end: usize = 0;
        while (end < n and names[end] != '\n') end += 1;
        const name = names[0..end];
        const ent = (mfs.dirLookup(dir, name) catch return) orelse return;
        if (ent.typ == .dir) deleteChildren(ent.obj, now, depth - 1);
        _ = mfs.dirRemove(dir, name, now) catch return;
        mfs.freeObject(ent.obj, now) catch return;
        mfs.maybeCommit(now) catch return;
    }
}

fn mapErr(err: mossfs.Error) shared.FsResp {
    return ferr(switch (err) {
        error.NoSpace, error.NoObjects, error.TooLarge => .no_space,
        error.NoKey, error.BadKey => .bad_key,
        else => .io,
    });
}

// ------------------------------------------------------- paths and views

const Resolved = union(enum) {
    boot_file: usize,
    boot_dir: struct { prefix: []const u8 },
    disk: struct { obj: u32, typ: mossfs.ObjType },
    uroot: void,
    missing: void,
    bad: void,
    failed: shared.FsErr,
};

/// Resolve a path within a view. follow_last says whether a final
/// symlink is followed (opens do; stat/delete/readlink do not).
fn resolve(v: *View, path: []const u8, scratch: *[64]u8, follow_last: bool) Resolved {
    if (path.len > 0 and path[0] == '/') return .bad;

    switch (v.kind) {
        .uroot => {
            // The system namespace: boot/ overlays the archive; everything
            // else (conf, state, data, volatile, ...) is the disk root.
            if (path.len == 0) return .uroot;
            const head = firstComp(path);
            if (badComp(head)) return .bad;
            const rest = if (head.len == path.len) "" else path[head.len + 1 ..];
            if (eq(head, "boot")) return resolveBoot("", rest, scratch);
            return resolveDisk(mossfs.root_obj, path, follow_last);
        },
        .boot => {
            const prefix = v.boot_prefix[0..v.boot_prefix_len];
            return resolveBoot(prefix, path, scratch);
        },
        .disk => return resolveDisk(v.obj, path, follow_last),
    }
}

fn resolveBoot(prefix: []const u8, path: []const u8, scratch: *[64]u8) Resolved {
    // Validate components, then join prefix + path.
    var it = path;
    while (it.len > 0) {
        const c = firstComp(it);
        if (badComp(c)) return .bad;
        it = if (c.len == it.len) "" else it[c.len + 1 ..];
    }
    const full = join(scratch, prefix, path);
    if (full.len > 0) {
        for (boot_entries[0..boot_count]) |e| {
            if (eq(e.path, full)) return .{ .boot_file = idxOf(e) };
        }
    }
    // A directory if any entry lives under it.
    for (boot_entries[0..boot_count]) |e| {
        if (full.len == 0 or (e.path.len > full.len + 1 and
            eq(e.path[0..full.len], full) and e.path[full.len] == '/'))
        {
            return .{ .boot_dir = .{ .prefix = full } };
        }
    }
    return .missing;
}

/// Walk the disk tree. Symlinks splice their target in place of the link
/// component, relative to the containing directory, subject to the same
/// component rules — an escape is unrepresentable.
fn resolveDisk(root: u32, path0: []const u8, follow_last: bool) Resolved {
    if (!disk_ok) return .{ .failed = .io };
    if (path0.len > max_path) return .bad;
    var bufs: [2][max_path + max_target + 1]u8 = undefined;
    var cur: usize = 0;
    @memcpy(bufs[0][0..path0.len], path0);
    var rest: []const u8 = bufs[0][0..path0.len];
    var dir = root;
    var hops: u32 = 0;

    while (rest.len > 0) {
        const c = firstComp(rest);
        if (badComp(c)) return .bad;
        const is_last = c.len == rest.len;
        const after: []const u8 = if (is_last) "" else rest[c.len + 1 ..];

        const found = (mfs.dirLookup(dir, c) catch |err| return .{ .failed = errCode(err) }) orelse
            return .missing;

        if (found.typ == .symlink and (!is_last or follow_last)) {
            hops += 1;
            if (hops > max_follow) return .bad;
            var tgt: [max_target]u8 = undefined;
            const tn = mfs.readObj(found.obj, 0, &tgt) catch |err| return .{ .failed = errCode(err) };
            if (tn == 0 or tgt[0] == '/') return .bad;
            // Splice target + "/" + after into the other buffer.
            const other = 1 - cur;
            if (tn + 1 + after.len > bufs[other].len) return .bad;
            @memcpy(bufs[other][0..tn], tgt[0..tn]);
            var total = tn;
            if (after.len > 0) {
                bufs[other][total] = '/';
                total += 1;
                @memcpy(bufs[other][total .. total + after.len], after);
                total += after.len;
            }
            cur = other;
            rest = bufs[cur][0..total];
            continue; // dir unchanged: target is relative to it
        }

        if (is_last) return .{ .disk = .{ .obj = found.obj, .typ = found.typ } };
        if (found.typ != .dir) return .missing;
        dir = found.obj;
        rest = after;
    }
    return .{ .disk = .{ .obj = dir, .typ = .dir } };
}

fn errCode(err: mossfs.Error) shared.FsErr {
    return switch (err) {
        error.NoSpace, error.NoObjects, error.TooLarge => .no_space,
        error.NoKey, error.BadKey => .bad_key,
        else => .io,
    };
}

/// The disk directory that must hold `baseName(path)` — for create,
/// delete, rename, symlink. Follows symlinks on the way down.
fn resolveParent(v: *View, path: []const u8, scratch: *[64]u8) union(enum) { dir: u32, resp: shared.FsResp } {
    const parent_path = dirName(path);
    const name = baseName(path);
    if (name.len == 0 or name.len > mossfs.max_name) return .{ .resp = ferr(.bad_path) };
    switch (resolve(v, parent_path, scratch, true)) {
        .disk => |dk| return if (dk.typ == .dir) .{ .dir = dk.obj } else .{ .resp = ferr(.bad_path) },
        // Top-level names in the system namespace are the standard
        // hierarchy — never created or removed through the protocol. A
        // home volume's root is its user's (the tiers return on mount).
        .uroot => return if (is_home and disk_ok) .{ .dir = mossfs.root_obj } else .{ .resp = ferr(.denied) },
        .boot_dir, .boot_file => return .{ .resp = ferr(.denied) },
        .bad => return .{ .resp = ferr(.bad_path) },
        .missing => return .{ .resp = ferr(.not_found) },
        .failed => |code| return .{ .resp = ferr(code) },
    }
}

fn viewPath(v: *View, off: u64, len: u64) ?[]const u8 {
    if (v.buf == 0 or len > max_path or off + len > v.buf_pages * 4096) return null;
    return @as([*]const u8, @ptrFromInt(v.buf + off))[0..len];
}

// ---------------------------------------------------------- operations

fn doOpen(v: *View, path_off: u64, path_len: u64, create: u64) shared.FsResp {
    const path = viewPath(v, path_off, path_len) orelse return ferr(.bad_path);
    var scratch: [64]u8 = undefined;
    const res = resolve(v, path, &scratch, true);
    switch (res) {
        .bad => return ferr(.bad_path),
        .failed => |code| return ferr(code),
        .boot_file => |idx| {
            if (create != 0) return ferr(.denied);
            return fdInsert(v, .{ .used = true, .boot = true, .idx = @intCast(idx) });
        },
        .boot_dir, .uroot => return ferr(.denied),
        .disk => |dk| {
            if (create == 3) return ferr(.exists); // O_EXCL
            if (dk.typ == .dir) return if (create == 2) .ok else ferr(.denied);
            if (create != 0 and v.ro) return ferr(.denied);
            if (dk.typ != .file) return ferr(.bad_path);
            return fdInsert(v, .{ .used = true, .obj = dk.obj });
        },
        .missing => {
            if (create == 0) return ferr(.not_found);
            if (v.ro) return ferr(.denied);
            return doCreate(v, path, create == 2);
        },
    }
}

fn doCreate(v: *View, path: []const u8, is_dir: bool) shared.FsResp {
    var scratch: [64]u8 = undefined;
    const parent = switch (resolveParent(v, path, &scratch)) {
        .dir => |d| d,
        .resp => |r| return r,
    };
    const name = baseName(path);
    // The full path resolved missing, but the *entry* may still exist —
    // e.g. a dangling symlink. Refuse rather than shadow it.
    if ((mfs.dirLookup(parent, name) catch |err| return mapErr(err)) != null) return ferr(.exists);
    const now = nowSec();
    const typ: mossfs.ObjType = if (is_dir) .dir else .file;
    const o = mfs.allocObject(typ, now) catch |err| return mapErr(err);
    mfs.dirAdd(parent, name, o, typ, now) catch |err| {
        mfs.freeObject(o, now) catch {};
        return mapErr(err);
    };
    if (is_dir) return .ok;
    return fdInsert(v, .{ .used = true, .obj = o });
}

fn fdInsert(v: *View, fd: Fd) shared.FsResp {
    for (&v.fds, 0..) |*slot, i| {
        if (!slot.used) {
            slot.* = fd;
            return .{ .num = .{ .n = i } };
        }
    }
    return ferr(.no_space);
}

fn doRead(v: *View, fdn: u64, off: u64, len: u64) shared.FsResp {
    if (fdn >= max_fds or !v.fds[fdn].used) return ferr(.bad_fd);
    if (v.buf == 0 or len > v.buf_pages * 4096 or len > shared.fs_max_io) return ferr(.bad_path);
    const dst = @as([*]u8, @ptrFromInt(v.buf))[0..len];
    const fd = &v.fds[fdn];
    if (fd.boot) {
        const data = boot_entries[fd.idx].data;
        if (off >= data.len) return .{ .num = .{ .n = 0 } };
        const n = @min(len, data.len - off);
        @memcpy(dst[0..n], data[off .. off + n]);
        return .{ .num = .{ .n = n } };
    }
    const n = mfs.readObj(fd.obj, off, dst) catch |err| return mapErr(err);
    return .{ .num = .{ .n = n } };
}

fn doWrite(v: *View, fdn: u64, off: u64, len: u64) shared.FsResp {
    if (v.ro) return ferr(.denied);
    if (fdn >= max_fds or !v.fds[fdn].used) return ferr(.bad_fd);
    if (v.fds[fdn].boot) return ferr(.denied);
    if (v.buf == 0 or len > v.buf_pages * 4096 or len > shared.fs_max_io) return ferr(.bad_path);
    const src = @as([*]const u8, @ptrFromInt(v.buf))[0..len];
    const fd = &v.fds[fdn];
    // The object may have been deleted out from under the fd.
    const dn = mfs.dnodeOf(fd.obj) catch |err| return mapErr(err);
    if (dn.typ != .file) return ferr(.bad_fd);
    const n = mfs.writeObj(fd.obj, off, src, nowSec()) catch |err| return mapErr(err);
    return .{ .num = .{ .n = n } };
}

fn doTruncate(v: *View, fdn: u64, len: u64) shared.FsResp {
    if (v.ro) return ferr(.denied);
    if (fdn >= max_fds or !v.fds[fdn].used) return ferr(.bad_fd);
    if (v.fds[fdn].boot) return ferr(.denied);
    const fd = &v.fds[fdn];
    const dn = mfs.dnodeOf(fd.obj) catch |err| return mapErr(err);
    if (dn.typ != .file) return ferr(.bad_fd);
    mfs.truncateObj(fd.obj, len, nowSec()) catch |err| return mapErr(err);
    return .ok;
}

fn doDelete(v: *View, path_off: u64, path_len: u64) shared.FsResp {
    if (v.ro) return ferr(.denied);
    const path = viewPath(v, path_off, path_len) orelse return ferr(.bad_path);
    var scratch: [64]u8 = undefined;
    const parent = switch (resolveParent(v, path, &scratch)) {
        .dir => |d| d,
        .resp => |r| return r,
    };
    const name = baseName(path);
    const ent = (mfs.dirLookup(parent, name) catch |err| return mapErr(err)) orelse
        return ferr(.not_found);
    if (ent.typ == .dir) {
        const empty = mfs.dirIsEmpty(ent.obj) catch |err| return mapErr(err);
        if (!empty) return ferr(.not_empty);
    }
    const now = nowSec();
    _ = mfs.dirRemove(parent, name, now) catch |err| return mapErr(err);
    mfs.freeObject(ent.obj, now) catch |err| return mapErr(err);
    dropObjRefs(ent.obj);
    return .ok;
}

/// A deleted object invalidates any fd or derived view rooted at it.
fn dropObjRefs(obj: u32) void {
    for (&views, 0..) |*view, i| {
        if (!view.used) continue;
        if (i != 0 and view.kind == .disk and view.obj == obj) view.used = false;
        for (&view.fds) |*fd| {
            if (fd.used and !fd.boot and fd.obj == obj) fd.used = false;
        }
    }
}

fn doRename(v: *View, from_w: u64, to_w: u64) shared.FsResp {
    if (v.ro) return ferr(.denied);
    const from = viewPath(v, from_w & 0xffffffff, from_w >> 32) orelse return ferr(.bad_path);
    const to = viewPath(v, to_w & 0xffffffff, to_w >> 32) orelse return ferr(.bad_path);
    var scratch: [64]u8 = undefined;
    const fparent = switch (resolveParent(v, from, &scratch)) {
        .dir => |d| d,
        .resp => |r| return r,
    };
    const tparent = switch (resolveParent(v, to, &scratch)) {
        .dir => |d| d,
        .resp => |r| return r,
    };
    const fname = baseName(from);
    const tname = baseName(to);
    const ent = (mfs.dirLookup(fparent, fname) catch |err| return mapErr(err)) orelse
        return ferr(.not_found);
    // A directory must not move into its own subtree; without ".." the
    // only cheap, sound rule is: same parent, or a non-dir. Directory
    // moves across parents walk tparent's ancestry — skipped in v2
    // (no parent pointers); refuse instead of risking a cycle.
    if (ent.typ == .dir and fparent != tparent) return ferr(.denied);
    const now = nowSec();
    if (mfs.dirLookup(tparent, tname) catch |err| return mapErr(err)) |target| {
        if (target.obj == ent.obj) return .ok; // rename onto itself
        if (target.typ == .dir) {
            const empty = mfs.dirIsEmpty(target.obj) catch |err| return mapErr(err);
            if (!empty) return ferr(.not_empty);
        }
        _ = mfs.dirRemove(tparent, tname, now) catch |err| return mapErr(err);
        mfs.freeObject(target.obj, now) catch |err| return mapErr(err);
        dropObjRefs(target.obj);
    }
    _ = mfs.dirRemove(fparent, fname, now) catch |err| return mapErr(err);
    mfs.dirAdd(tparent, tname, ent.obj, ent.typ, now) catch |err| return mapErr(err);
    return .ok;
}

fn doStat(v: *View, path_off: u64, path_len: u64) shared.FsResp {
    const path = viewPath(v, path_off, path_len) orelse return ferr(.bad_path);
    var scratch: [64]u8 = undefined;
    switch (resolve(v, path, &scratch, false)) {
        .bad => return ferr(.bad_path),
        .missing => return ferr(.not_found),
        .failed => |code| return ferr(code),
        .boot_file => |idx| return .{ .stat = .{
            .typ = @intFromEnum(shared.FsType.file),
            .size = boot_entries[idx].data.len,
            .mtime = 0,
        } },
        .boot_dir, .uroot => return .{ .stat = .{
            .typ = @intFromEnum(shared.FsType.dir),
            .size = 0,
            .mtime = 0,
        } },
        .disk => |dk| {
            const st = mfs.statObj(dk.obj) catch |err| return mapErr(err);
            return .{ .stat = .{
                .typ = @intFromEnum(st.typ),
                .size = st.size,
                .mtime = st.mtime,
            } };
        },
    }
}

fn doSymlink(v: *View, path_w: u64, target_w: u64) shared.FsResp {
    if (v.ro) return ferr(.denied);
    const path = viewPath(v, path_w & 0xffffffff, path_w >> 32) orelse return ferr(.bad_path);
    const target = viewPath(v, target_w & 0xffffffff, target_w >> 32) orelse return ferr(.bad_path);
    if (target.len == 0 or target.len > max_target or target[0] == '/') return ferr(.bad_path);
    var scratch: [64]u8 = undefined;
    const parent = switch (resolveParent(v, path, &scratch)) {
        .dir => |d| d,
        .resp => |r| return r,
    };
    const name = baseName(path);
    if ((mfs.dirLookup(parent, name) catch |err| return mapErr(err)) != null) return ferr(.exists);
    const now = nowSec();
    const o = mfs.allocObject(.symlink, now) catch |err| return mapErr(err);
    _ = mfs.writeObj(o, 0, target, now) catch |err| {
        mfs.freeObject(o, now) catch {};
        return mapErr(err);
    };
    mfs.dirAdd(parent, name, o, .symlink, now) catch |err| {
        mfs.freeObject(o, now) catch {};
        return mapErr(err);
    };
    return .ok;
}

fn doReadlink(v: *View, path_off: u64, path_len: u64) shared.FsResp {
    const path = viewPath(v, path_off, path_len) orelse return ferr(.bad_path);
    if (v.buf == 0) return ferr(.bad_path);
    var scratch: [64]u8 = undefined;
    switch (resolve(v, path, &scratch, false)) {
        .disk => |dk| {
            if (dk.typ != .symlink) return ferr(.bad_path);
            const out = @as([*]u8, @ptrFromInt(v.buf))[0..max_target];
            const n = mfs.readObj(dk.obj, 0, out) catch |err| return mapErr(err);
            return .{ .num = .{ .n = n } };
        },
        .missing => return ferr(.not_found),
        .failed => |code| return ferr(code),
        else => return ferr(.bad_path),
    }
}

fn doClose(v: *View, fdn: u64) shared.FsResp {
    if (fdn >= max_fds or !v.fds[fdn].used) return ferr(.bad_fd);
    v.fds[fdn].used = false;
    return .ok;
}

fn doStatfs() shared.FsResp {
    if (!disk_ok) return ferr(.io);
    const free = mfs.freeBlocksTotal() catch |err| return mapErr(err);
    return .{ .statfs = .{
        .free_blocks = free,
        .total_blocks = mfs.nsecs / mossfs.spb,
        .encrypted = @intFromBool(mfs.enc),
    } };
}

fn doSync() shared.FsResp {
    if (!disk_ok) return ferr(.io);
    mfs.sync(nowSec()) catch |err| return mapErr(err);
    return .ok;
}

fn doList(v: *View, path_off: u64, path_len: u64) shared.FsResp {
    const path = viewPath(v, path_off, path_len) orelse return ferr(.bad_path);
    if (v.buf == 0) return ferr(.bad_path);
    var scratch: [64]u8 = undefined;
    const out = @as([*]u8, @ptrFromInt(v.buf))[0..2048];
    var n: usize = 0;
    switch (resolve(v, path, &scratch, true)) {
        .bad => return ferr(.bad_path),
        .missing, .boot_file => return ferr(.not_found),
        .failed => |code| return ferr(code),
        .uroot => {
            n = putLine(out, n, "boot");
            n += mfs.dirList(mossfs.root_obj, out[n..]) catch |err| return mapErr(err);
        },
        .boot_dir => |bd| {
            // Unique next components under the prefix.
            var seen: [max_boot][]const u8 = undefined;
            var nseen: usize = 0;
            for (boot_entries[0..boot_count]) |e| {
                var rel: []const u8 = undefined;
                if (bd.prefix.len == 0) {
                    rel = e.path;
                } else if (e.path.len > bd.prefix.len + 1 and
                    eq(e.path[0..bd.prefix.len], bd.prefix) and e.path[bd.prefix.len] == '/')
                {
                    rel = e.path[bd.prefix.len + 1 ..];
                } else continue;
                const c = firstComp(rel);
                var dup = false;
                for (seen[0..nseen]) |s| {
                    if (eq(s, c)) dup = true;
                }
                if (!dup and nseen < max_boot) {
                    seen[nseen] = c;
                    nseen += 1;
                    n = putLine(out, n, c);
                }
            }
        },
        .disk => |dk| {
            if (dk.typ != .dir) return ferr(.not_found);
            n += mfs.dirList(dk.obj, out[n..]) catch |err| return mapErr(err);
        },
    }
    return .{ .num = .{ .n = n } };
}

fn doDerive(v: *View, caller: u64, path_off: u64, path_len: u64, want_ro: bool) void {
    const fail = struct {
        fn f(code: shared.FsErr) void {
            _ = usys.replyTyped(shared.FsResp, serve_a, .{
                .fs_err = .{ .code = @intFromEnum(code) },
            }, 0);
        }
    }.f;
    const path = viewPath(v, path_off, path_len) orelse return fail(.bad_path);
    var scratch: [64]u8 = undefined;
    const res = resolve(v, path, &scratch, true);

    // Find a free view slot (badge = index).
    var slot: usize = 0;
    while (slot < max_views and views[slot].used) slot += 1;
    if (slot == max_views) return fail(.no_space);
    var nv = &views[slot];

    switch (res) {
        .bad => return fail(.bad_path),
        .missing, .boot_file => return fail(.not_found),
        .failed => |code| return fail(code),
        .uroot => nv.* = .{ .used = true, .kind = .uroot, .ro = v.ro or want_ro },
        .boot_dir => |bd| {
            nv.* = .{ .used = true, .kind = .boot, .ro = true }; // boot is always ro
            @memcpy(nv.boot_prefix[0..bd.prefix.len], bd.prefix);
            nv.boot_prefix_len = bd.prefix.len;
        },
        .disk => |dk| {
            if (dk.typ != .dir) return fail(.not_found);
            nv.* = .{ .used = true, .kind = .disk, .obj = dk.obj, .ro = v.ro or want_ro };
        },
    }
    nv.parent = caller;
    const minted = usys.chanMint(serve_a, slot);
    if (minted.err != .ok) {
        nv.used = false;
        return fail(.no_space);
    }
    _ = usys.replyTyped(shared.FsResp, serve_a, .{ .view = .{ .badge = slot } }, minted.data[1]);
    _ = usys.capDrop(minted.data[1]); // the transferred copy carries the ref
}

/// One client's whole life: a view derived, a fresh buffer attached to
/// it, a read through it. What it holds is what release lets go of.
const Client = struct { view: u64, shm: u64, va: u64 };

fn clientOpen(fs_chan: u64, buf: [*]u8) Client {
    const v = fsc.fsDerive(fs_chan, buf, "data/pub", true) orelse usys.exit(180);
    const s = usys.shmCreate(shared.fs_buf_pages);
    if (s.err != .ok) usys.exit(181);
    const m = usys.shmMap(s.data[0]);
    if (m.err != .ok) usys.exit(182);
    switch (usys.callTyped(shared.FsReq, shared.FsResp, v, .attach_buf, s.data[0])) {
        .ok => {},
        .err => usys.exit(183),
    }
    const vb: [*]u8 = @ptrFromInt(m.data[0]);
    switch (fsc.fsOpen(v, vb, "note.txt", 0)) {
        .fd => |fd| {
            const n = fsc.fsRead(v, fd, 64) orelse usys.exit(184);
            if (!eq(vb[0..n], "hello from alice")) usys.exit(185);
            fsc.fsClose(v, fd);
        },
        .err => usys.exit(186),
    }
    return .{ .view = v, .shm = s.data[0], .va = m.data[0] };
}

/// The buffer unmapped and both caps dropped: the service hears of the
/// view's death and lets its side go; the buffer's frames return.
fn clientRelease(log_h: u64, c: Client) void {
    if (usys.shmUnmap(c.va) != .ok) usys.exit(187);
    // Gone means gone: the kernel refuses to copy through the hole
    // (a fault, not a panic), and a second unmap names nothing.
    const hole: [*]const u8 = @ptrFromInt(c.va);
    if (usys.log(log_h, hole[0..8]) != .fault) usys.exit(188);
    if (usys.shmUnmap(c.va) != .bad_arg) usys.exit(189);
    _ = usys.capDrop(c.shm);
    _ = usys.capDrop(c.view);
}

/// Roles 5 and 6: reclamation on client death. A hundred clients come
/// and go through one domain — more than the kernel's shared-buffer
/// pool (64), this domain's window table (64) or the service's view
/// table (32) hold — so every one must be released as it dies. Then
/// role 5 opens two dozen and exits holding them: its teardown is the
/// release. Role 6, started after that death, opens two dozen at once,
/// which the view table can only fit if the dead client's are gone.
fn churn(log_h: u64, fs_chan: u64, second: bool) noreturn {
    const b = fsc.attachBuf(fs_chan);
    const buf: [*]u8 = @ptrFromInt(b.va);
    const cycles = 100;
    for (0..cycles) |_| clientRelease(log_h, clientOpen(fs_chan, buf));
    if (!second) _ = usys.log(log_h, "churn: 100 clients came and went through one domain — every buffer unmapped, every view dropped");
    const held = 24;
    var kept: [held]Client = undefined;
    for (&kept) |*k| k.* = clientOpen(fs_chan, buf);
    if (second) {
        _ = usys.log(log_h, "churn2: 24 views at once after the churner died holding 24 — the dead client's were reclaimed");
    } else {
        _ = usys.log(log_h, "churn: exiting with 24 views and buffers held — teardown is the release");
    }
    usys.exit(0);
}

fn alice(log_h: u64, fs_chan: u64) noreturn {
    var line: [96]u8 = undefined;
    const b = fsc.attachBuf(fs_chan);
    const buf: [*]u8 = @ptrFromInt(b.va);

    // Boot image is readable...
    switch (fsc.fsOpen(fs_chan, buf, "boot/etc/motd", 0)) {
        .fd => |fd| {
            const n = fsc.fsRead(fs_chan, fd, 64) orelse usys.exit(101);
            _ = usys.log(log_h, cat(&line, "alice: boot/etc/motd says: ", buf[0..n]));
        },
        .err => usys.exit(102),
    }
    // ...but never writable, even for a rw root view.
    switch (fsc.fsOpen(fs_chan, buf, "boot/hack", 1)) {
        .fd => usys.exit(103),
        .err => |e| if (e != .denied) usys.exit(104),
    }

    // Real storage, standard hierarchy: private state in state/alice,
    // shared payload in data/pub for bob.
    if (!fsc.fsMkdir(fs_chan, buf, "state/alice")) usys.exit(105);
    switch (fsc.fsOpen(fs_chan, buf, "state/alice/secret.txt", 1)) {
        .fd => |fd| if (!fsc.fsWrite(fs_chan, buf, fd, "top secret stuff")) usys.exit(106),
        .err => usys.exit(107),
    }
    if (!fsc.fsMkdir(fs_chan, buf, "data/pub")) usys.exit(108);
    switch (fsc.fsOpen(fs_chan, buf, "data/pub/note.txt", 1)) {
        .fd => |fd| if (!fsc.fsWrite(fs_chan, buf, fd, "hello from alice")) usys.exit(109),
        .err => usys.exit(110),
    }

    const n = fsc.fsList(fs_chan, buf, "") orelse usys.exit(111);
    _ = usys.log(log_h, cat(&line, "alice: / holds: ", collapse(buf[0..n])));

    // volatile/ starts every boot empty — run 2 proves the clearing.
    if (fsc.fsStat(fs_chan, buf, "volatile/scratch") != null) usys.exit(140);
    if (!fsc.fsMkdir(fs_chan, buf, "volatile/scratch")) usys.exit(141);
    switch (fsc.fsOpen(fs_chan, buf, "volatile/scratch/tmp.txt", 1)) {
        .fd => |fd| if (!fsc.fsWrite(fs_chan, buf, fd, "gone at reboot")) usys.exit(142),
        .err => usys.exit(143),
    }
    _ = usys.log(log_h, "alice: volatile/ empty at boot — cleared as promised");

    // O_EXCL, truncate, stat.
    _ = fsc.fsDelete(fs_chan, buf, "state/alice/x.tmp"); // idempotent across runs
    const xfd = switch (fsc.fsOpen(fs_chan, buf, "state/alice/x.tmp", 3)) {
        .fd => |fd| fd,
        .err => usys.exit(144),
    };
    if (!fsc.fsWrite(fs_chan, buf, xfd, "0123456789abcdef")) usys.exit(145);
    switch (fsc.fsOpen(fs_chan, buf, "state/alice/x.tmp", 3)) {
        .fd => usys.exit(146), // O_EXCL on an existing file must refuse
        .err => |e| if (e != .exists) usys.exit(147),
    }
    if (!fsc.fsTruncate(fs_chan, xfd, 4)) usys.exit(148);
    const xst = fsc.fsStat(fs_chan, buf, "state/alice/x.tmp") orelse usys.exit(149);
    if (xst.typ != @intFromEnum(shared.FsType.file) or xst.size != 4) usys.exit(150);

    // Rename (same dir and across dirs), delete.
    _ = fsc.fsDelete(fs_chan, buf, "data/y.tmp");
    if (!fsc.fsRename(fs_chan, buf, "state/alice/x.tmp", "data/y.tmp")) usys.exit(151);
    if (fsc.fsStat(fs_chan, buf, "state/alice/x.tmp") != null) usys.exit(152);
    const yst = fsc.fsStat(fs_chan, buf, "data/y.tmp") orelse usys.exit(153);
    if (yst.size != 4) usys.exit(154);
    switch (fsc.fsDelete(fs_chan, buf, "data/y.tmp")) {
        .ok => {},
        .err => usys.exit(155),
    }

    // Directory delete honors emptiness.
    _ = fsc.fsDelete(fs_chan, buf, "data/tmpd/f.txt");
    _ = fsc.fsDelete(fs_chan, buf, "data/tmpd");
    if (!fsc.fsMkdir(fs_chan, buf, "data/tmpd")) usys.exit(156);
    switch (fsc.fsOpen(fs_chan, buf, "data/tmpd/f.txt", 1)) {
        .fd => {},
        .err => usys.exit(157),
    }
    switch (fsc.fsDelete(fs_chan, buf, "data/tmpd")) {
        .ok => usys.exit(158), // must refuse: not empty
        .err => |e| if (e != .not_empty) usys.exit(159),
    }
    switch (fsc.fsDelete(fs_chan, buf, "data/tmpd/f.txt")) {
        .ok => {},
        .err => usys.exit(160),
    }
    switch (fsc.fsDelete(fs_chan, buf, "data/tmpd")) {
        .ok => {},
        .err => usys.exit(161),
    }

    // Symlinks: in-view resolution works; stored verbatim, so an escape
    // target only fails at resolution (for everyone).
    _ = fsc.fsDelete(fs_chan, buf, "data/pub/ln");
    _ = fsc.fsDelete(fs_chan, buf, "data/pub/esc");
    if (!fsc.fsSymlink(fs_chan, buf, "data/pub/ln", "note.txt")) usys.exit(162);
    switch (fsc.fsOpen(fs_chan, buf, "data/pub/ln", 0)) {
        .fd => |fd| {
            const ln = fsc.fsRead(fs_chan, fd, 64) orelse usys.exit(163);
            if (!eq(buf[0..ln], "hello from alice")) usys.exit(164);
        },
        .err => usys.exit(165),
    }
    const rln = fsc.fsReadlink(fs_chan, buf, "data/pub/ln") orelse usys.exit(166);
    if (!eq(buf[0..rln], "note.txt")) usys.exit(167);
    const lst = fsc.fsStat(fs_chan, buf, "data/pub/ln") orelse usys.exit(168);
    if (lst.typ != @intFromEnum(shared.FsType.symlink)) usys.exit(169);
    if (!fsc.fsSymlink(fs_chan, buf, "data/pub/esc", "../../state/alice/secret.txt")) usys.exit(170);
    switch (fsc.fsOpen(fs_chan, buf, "data/pub/esc", 0)) {
        .fd => usys.exit(171),
        .err => |e| if (e != .bad_path) usys.exit(172),
    }

    if (!fsc.fsSync(fs_chan)) usys.exit(173);
    _ = usys.log(log_h, "alice: v2 ops verified — delete, rename, truncate, stat, symlink, excl, sync");

    // Throughput baseline through the whole stack (IPC + fssvc + mossfs
    // + ring + blkdrv + virtio) on this encrypted volume: 512KB in 32KB
    // chunks, compressible then incompressible, write+sync and read.
    benchOne(log_h, fs_chan, buf, "alice: bench comp KB/s: ", true);
    benchOne(log_h, fs_chan, buf, "alice: bench raw  KB/s: ", false);
    usys.exit(0);
}

const bench_chunk = 32768;
const bench_chunks = 16; // 512KB

fn benchOne(log_h: u64, fs_chan: u64, buf: [*]u8, label: []const u8, compressible: bool) void {
    _ = fsc.fsDelete(fs_chan, buf, "state/alice/bench.bin");
    const fd = switch (fsc.fsOpen(fs_chan, buf, "state/alice/bench.bin", 1)) {
        .fd => |f| f,
        .err => usys.exit(174),
    };
    var seed: u64 = 0x9e3779b97f4a7c15;
    const hz = usys.cycleHz();

    const t0 = usys.cycles();
    for (0..bench_chunks) |i| {
        fillChunk(buf, compressible, &seed);
        switch (usys.callTyped(shared.FsReq, shared.FsResp, fs_chan, .{
            .write = .{ .fd = fd, .off = i * bench_chunk, .len = bench_chunk },
        }, 0)) {
            .ok => |rep| if (rep != .num) usys.exit(175),
            .err => usys.exit(176),
        }
    }
    if (!fsc.fsSync(fs_chan)) usys.exit(177);
    const w_us = (usys.cycles() - t0) * 1_000_000 / hz;

    const t1 = usys.cycles();
    for (0..bench_chunks) |i| {
        switch (usys.callTyped(shared.FsReq, shared.FsResp, fs_chan, .{
            .read = .{ .fd = fd, .off = i * bench_chunk, .len = bench_chunk },
        }, 0)) {
            .ok => |rep| if (rep != .num) usys.exit(178),
            .err => usys.exit(179),
        }
    }
    const r_us = (usys.cycles() - t1) * 1_000_000 / hz;

    const total_kb: u64 = bench_chunks * bench_chunk / 1024;
    var msg: [96]u8 = undefined;
    var n: usize = 0;
    for (label) |c| {
        msg[n] = c;
        n += 1;
    }
    n = putNum(&msg, n, "w=", total_kb * 1_000_000 / @max(w_us, 1));
    n = putNum(&msg, n, " r=", total_kb * 1_000_000 / @max(r_us, 1));
    _ = usys.log(log_h, msg[0..n]);
    switch (fsc.fsDelete(fs_chan, buf, "state/alice/bench.bin")) {
        .ok => {},
        .err => usys.exit(180),
    }
    if (!fsc.fsSync(fs_chan)) usys.exit(181);
}

fn fillChunk(buf: [*]u8, compressible: bool, seed: *u64) void {
    if (compressible) {
        for (0..bench_chunk) |i| buf[i] = @truncate(i / 32);
    } else {
        for (0..bench_chunk / 8) |i| {
            seed.* = seed.* *% 6364136223846793005 +% 1442695040888963407;
            const v = seed.*;
            inline for (0..8) |j| buf[i * 8 + j] = @truncate(v >> (j * 8));
        }
    }
}

fn putNum(msg: []u8, n0: usize, prefix: []const u8, v: u64) usize {
    var n = n0;
    for (prefix) |c| {
        msg[n] = c;
        n += 1;
    }
    var digits: [20]u8 = undefined;
    var d: usize = 0;
    var x = v;
    while (true) {
        digits[d] = '0' + @as(u8, @intCast(x % 10));
        d += 1;
        x /= 10;
        if (x == 0) break;
    }
    while (d > 0) {
        d -= 1;
        msg[n] = digits[d];
        n += 1;
    }
    return n;
}

/// Newlines to spaces, for one-line logging.
fn collapse(s: []u8) []const u8 {
    for (s) |*c| {
        if (c.* == '\n') c.* = ' ';
    }
    return s;
}

fn bob(log_h: u64, fs_chan: u64) noreturn {
    var line: [96]u8 = undefined;
    const b = fsc.attachBuf(fs_chan);
    const buf: [*]u8 = @ptrFromInt(b.va);

    // The whole world is note.txt and alice's two symlinks.
    const n = fsc.fsList(fs_chan, buf, "") orelse usys.exit(120);
    if (!eq(buf[0..n], "note.txt\nln\nesc\n")) {
        _ = usys.log(log_h, cat(&line, "bob: unexpected view: ", buf[0..n]));
        usys.exit(121);
    }
    _ = usys.log(log_h, "bob: my entire world is data/pub — as granted");

    // A symlink inside the view resolves; one that points outward cannot
    // even be pronounced (its ".." fails like any other path).
    switch (fsc.fsOpen(fs_chan, buf, "ln", 0)) {
        .fd => |fd| {
            const ln = fsc.fsRead(fs_chan, fd, 64) orelse usys.exit(136);
            if (!eq(buf[0..ln], "hello from alice")) usys.exit(137);
        },
        .err => usys.exit(138),
    }
    switch (fsc.fsOpen(fs_chan, buf, "esc", 0)) {
        .fd => usys.exit(139),
        .err => |e| if (e != .bad_path) usys.exit(140),
    }
    if (fsc.fsSymlink(fs_chan, buf, "own.lnk", "note.txt")) usys.exit(141); // ro view
    switch (fsc.fsDelete(fs_chan, buf, "note.txt")) {
        .ok => usys.exit(142), // ro view
        .err => |e| if (e != .denied) usys.exit(143),
    }
    _ = usys.log(log_h, "bob: symlinks resolve in-view, escape and ro-violations refused");

    switch (fsc.fsOpen(fs_chan, buf, "note.txt", 0)) {
        .fd => |fd| {
            const rn = fsc.fsRead(fs_chan, fd, 64) orelse usys.exit(122);
            if (!eq(buf[0..rn], "hello from alice")) usys.exit(123);
            _ = usys.log(log_h, cat(&line, "bob: read note.txt: ", buf[0..rn]));
            // Writing through a read-only view must fail.
            if (fsc.fsWrite(fs_chan, buf, fd, "vandalism")) usys.exit(124);
        },
        .err => usys.exit(125),
    }

    // Creation refused, escape unpronounceable, privilege un-upgradeable.
    switch (fsc.fsOpen(fs_chan, buf, "graffiti.txt", 1)) {
        .fd => usys.exit(126),
        .err => |e| if (e != .denied) usys.exit(127),
    }
    switch (fsc.fsOpen(fs_chan, buf, "../../state/alice/secret.txt", 0)) {
        .fd => usys.exit(128),
        .err => |e| if (e != .bad_path) usys.exit(129),
    }
    // derive(rw) from an ro view yields another ro view.
    switch (usys.callTypedCap(shared.FsReq, shared.FsResp, fs_chan, .{
        .derive = .{ .path_off = 1024, .path_len = 0, .ro = 0 },
    }, 0)) {
        .ok => |ok| {
            if (ok.cap == 0) usys.exit(130);
            switch (fsc.fsOpen(fs_chan, buf, "sneaky.txt", 1)) { // still on old cap: ro
                .fd => usys.exit(131),
                .err => {},
            }
            // The derived cap needs its own buffer; reuse ours.
            switch (usys.callTyped(shared.FsReq, shared.FsResp, ok.cap, .attach_buf, b.cap)) {
                .ok => {},
                .err => usys.exit(132),
            }
            switch (fsc.fsOpen(ok.cap, buf, "sneaky.txt", 1)) {
                .fd => usys.exit(133), // upgrade would be a hole
                .err => |e| if (e != .denied) usys.exit(134),
            }
        },
        .err => usys.exit(135),
    }
    _ = usys.log(log_h, "bob: write, create, escape, and privilege upgrade all refused");
    usys.exit(0);
}

// ------------------------------------------------------------- utilities

fn firstComp(path: []const u8) []const u8 {
    var i: usize = 0;
    while (i < path.len and path[i] != '/') i += 1;
    return path[0..i];
}

fn badComp(c: []const u8) bool {
    if (c.len == 0) return true;
    if (eq(c, ".") or eq(c, "..")) return true;
    return false;
}

fn dirName(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/') return path[0 .. i - 1];
    }
    return "";
}

fn baseName(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/') return path[i..];
    }
    return path;
}

fn join(scratch: *[64]u8, prefix: []const u8, path: []const u8) []const u8 {
    if (prefix.len == 0) return path;
    if (path.len == 0) return prefix;
    var n: usize = 0;
    @memcpy(scratch[0..prefix.len], prefix);
    n = prefix.len;
    scratch[n] = '/';
    n += 1;
    @memcpy(scratch[n .. n + path.len], path);
    return scratch[0 .. n + path.len];
}

fn idxOf(e: BootEntry) usize {
    for (boot_entries[0..boot_count], 0..) |be, i| {
        if (be.path.ptr == e.path.ptr) return i;
    }
    return 0;
}

fn putLine(out: []u8, n: usize, s: []const u8) usize {
    if (n + s.len + 1 > out.len) return n;
    @memcpy(out[n .. n + s.len], s);
    out[n + s.len] = '\n';
    return n + s.len + 1;
}

fn leu32(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}

fn eq(a: []const u8, bs: []const u8) bool {
    if (a.len != bs.len) return false;
    for (a, bs) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn cat(buf: []u8, prefix: []const u8, s: []const u8) []const u8 {
    var i: usize = 0;
    for (prefix) |c| {
        buf[i] = c;
        i += 1;
    }
    for (s) |c| {
        if (i == buf.len) break;
        buf[i] = c;
        i += 1;
    }
    return buf[0..i];
}
