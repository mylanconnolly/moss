//! The filesystem, by x2:
//!   1 "fssvc" — the FS service. Serves a union namespace: "boot/" is a
//!               read-only MARC archive granted at spawn (the boot image
//!               filesystem), "disk/" is mossfs, a deliberately tiny
//!               writable FS living on the virtio-blk driver (client over
//!               the sync channel). A *view* is a badged channel cap this
//!               service mints: the badge picks {subtree root, read-only}
//!               server-side, so a process's namespace is exactly the view
//!               caps it holds — nothing outside a view can even be named,
//!               and ".." does not exist.
//!   2 "alice" — root view (rw): reads the boot image, writes disk files,
//!               makes disk/pub for bob.
//!   3 "bob"   — a derived view of disk/pub, read-only: sees note.txt and
//!               nothing else; every escape and write attempt must fail.
//!
//! mossfs on-disk format (512B sectors): sector 0 superblock ("MOSF");
//! sectors 1-8 inode table (64 inodes x 64B: type u16, size u32,
//! 12 direct block pointers u32 -> max file 6KB); sector 9 data bitmap;
//! data from sector 10. Directories are files of 32B entries
//! {ino u16, used u8, namelen u8, name[28]}. No delete in v1.

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

export fn umain(log_h: u64, chan_h: u64, role: u64, blob_va: u64, blob_len: u64) callconv(.c) noreturn {
    switch (role) {
        1 => fssvc(log_h, chan_h, blob_va, blob_len),
        2 => alice(log_h, chan_h),
        3 => bob(log_h, chan_h),
        else => usys.exit(250),
    }
}

// ------------------------------------------------------------ the service

const sector = 512;
const max_views = 16;
const max_boot = 16;
const max_fds = 8;
const ino_root: u32 = 0;

const Fd = struct {
    used: bool = false,
    boot: bool = false,
    idx: u32 = 0, // boot entry index
    ino: u32 = 0, // disk inode
};

const ViewKind = enum { uroot, boot, disk };

const View = struct {
    used: bool = false,
    ro: bool = false,
    kind: ViewKind = .uroot,
    boot_prefix: [48]u8 = undefined,
    boot_prefix_len: usize = 0,
    ino: u32 = 0,
    buf: u64 = 0,
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
var blk_chan: u64 = 0;
var blk_buf: u64 = 0;
var glog: u64 = 0;

fn fssvc(log_h: u64, chan_h: u64, blob_va: u64, blob_len: u64) noreturn {
    glog = log_h;
    serve_a = chan_h;
    parseBoot(blob_va, blob_len);
    views[0] = .{ .used = true, .ro = false, .kind = .uroot }; // badge 0: root of trust

    while (true) {
        const r = usys.recvMsg(serve_a);
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err != .ok) usys.exit(200);
        const req = shared.decodeMsg(shared.FsReq, r.data) orelse {
            _ = usys.replyTyped(shared.FsResp, serve_a, ferr(.bad_path), 0);
            continue;
        };
        // The disk arrives once, from the spawner, as an attach on open —
        // recognized by an attach_buf carrying a channel cap before any
        // disk exists.
        if (blk_chan == 0 and r.cap != 0 and req == .attach_buf) {
            blk_chan = r.cap;
            setupDisk();
            _ = usys.replyTyped(shared.FsResp, serve_a, .ok, 0);
            continue;
        }
        const v = viewOf(r.badge) orelse {
            _ = usys.replyTyped(shared.FsResp, serve_a, ferr(.bad_fd), 0);
            continue;
        };
        switch (req) {
            .attach_buf => {
                if (r.cap != 0) {
                    const m = usys.shmMap(r.cap);
                    if (m.err == .ok) v.buf = m.data[0];
                }
                _ = usys.replyTyped(shared.FsResp, serve_a, .ok, 0);
            },
            .open => |o| reply(doOpen(v, o.path_off, o.path_len, o.create)),
            .read => |io| reply(doRead(v, io.fd, io.off, io.len)),
            .write => |io| reply(doWrite(v, io.fd, io.off, io.len)),
            .list => |l| reply(doList(v, l.path_off, l.path_len)),
            .derive => |dv| doDerive(v, dv.path_off, dv.path_len, dv.ro != 0),
        }
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
    if (!views[badge].used) return null;
    return &views[badge];
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

// ----------------------------------------------------------- disk backend

fn setupDisk() void {
    const s = usys.shmCreate(1);
    if (s.err != .ok) usys.exit(201);
    const m = usys.shmMap(s.data[0]);
    if (m.err != .ok) usys.exit(202);
    blk_buf = m.data[0];
    switch (usys.callTyped(shared.BlkReq, shared.BlkResp, blk_chan, .setup, s.data[0])) {
        .ok => {},
        .err => usys.exit(203),
    }
    // Format on first boot (no superblock magic).
    var sb: [sector]u8 = undefined;
    diskRead(0, &sb);
    if (!eq(sb[0..4], "MOSF")) {
        var zero: [sector]u8 = @splat(0);
        for (1..10) |sec| diskWrite(@intCast(sec), &zero);
        @memset(sb[0..], 0);
        sb[0] = 'M';
        sb[1] = 'O';
        sb[2] = 'S';
        sb[3] = 'F';
        diskWrite(0, &sb);
        var root: Inode = .{ .typ = 2 };
        writeInode(ino_root, &root);
        // The standard hierarchy exists from the first format.
        for ([_][]const u8{ "conf", "state", "data", "volatile" }) |name| {
            const ino = allocInode() orelse usys.exit(208);
            var node: Inode = .{ .typ = 2 };
            writeInode(ino, &node);
            var rootnode = readInode(ino_root);
            if (!dirAdd(ino_root, &rootnode, name, ino)) usys.exit(209);
        }
        _ = usys.log(glog, "fssvc: formatted fresh mossfs (std hierarchy)");
    } else {
        _ = usys.log(glog, "fssvc: existing mossfs found");
    }
}

fn diskRead(sec: u32, dst: *[sector]u8) void {
    switch (usys.callTyped(shared.BlkReq, shared.BlkResp, blk_chan, .{
        .read = .{ .sector = sec, .off = 0 },
    }, 0)) {
        .ok => |rep| if (rep != .ok) usys.exit(204),
        .err => usys.exit(205),
    }
    const src: [*]const volatile u8 = @ptrFromInt(blk_buf);
    for (0..sector) |i| dst[i] = src[i];
}

fn diskWrite(sec: u32, src: *const [sector]u8) void {
    const dst: [*]volatile u8 = @ptrFromInt(blk_buf);
    for (0..sector) |i| dst[i] = src[i];
    switch (usys.callTyped(shared.BlkReq, shared.BlkResp, blk_chan, .{
        .write = .{ .sector = sec, .off = 0 },
    }, 0)) {
        .ok => |rep| if (rep != .ok) usys.exit(206),
        .err => usys.exit(207),
    }
}

const Inode = struct {
    typ: u16 = 0, // 0 free, 1 file, 2 dir
    size: u32 = 0,
    blocks: [12]u32 = @splat(0),
};

fn inodeSector(ino: u32) u32 {
    return 1 + ino / 8;
}

fn readInode(ino: u32) Inode {
    var sec: [sector]u8 = undefined;
    diskRead(inodeSector(ino), &sec);
    const base = (ino % 8) * 64;
    var n: Inode = .{
        .typ = leu16(sec[base..]),
        .size = leu32(sec[base + 4 ..]),
    };
    for (0..12) |i| n.blocks[i] = leu32(sec[base + 8 + i * 4 ..]);
    return n;
}

fn writeInode(ino: u32, n: *const Inode) void {
    var sec: [sector]u8 = undefined;
    diskRead(inodeSector(ino), &sec);
    const base = (ino % 8) * 64;
    puleu16(sec[base..], n.typ);
    puleu32(sec[base + 4 ..], n.size);
    for (0..12) |i| puleu32(sec[base + 8 + i * 4 ..], n.blocks[i]);
    diskWrite(inodeSector(ino), &sec);
}

fn allocInode() ?u32 {
    for (0..64) |ino| {
        if (readInode(@intCast(ino)).typ == 0) return @intCast(ino);
    }
    return null;
}

fn allocBlock() ?u32 {
    var bm: [sector]u8 = undefined;
    diskRead(9, &bm);
    for (0..sector) |byte| {
        if (bm[byte] != 0xff) {
            var bit: u3 = 0;
            while (true) : (bit += 1) {
                if (bm[byte] & (@as(u8, 1) << bit) == 0) break;
            }
            bm[byte] |= @as(u8, 1) << bit;
            diskWrite(9, &bm);
            return @intCast(10 + byte * 8 + bit);
        }
    }
    return null;
}

/// Copy file bytes [off, off+len) into dst; returns bytes copied.
fn fileRead(node: *const Inode, off: u64, len: u64, dst: []u8) u64 {
    if (off >= node.size) return 0;
    const n = @min(len, node.size - off);
    var done: u64 = 0;
    var sec: [sector]u8 = undefined;
    while (done < n) {
        const pos = off + done;
        const bi = pos / sector;
        if (bi >= 12 or node.blocks[bi] == 0) break;
        diskRead(node.blocks[bi], &sec);
        const so = pos % sector;
        const chunk = @min(n - done, sector - so);
        @memcpy(dst[done .. done + chunk], sec[so .. so + chunk]);
        done += chunk;
    }
    return done;
}

/// Write bytes at off, growing the file (direct blocks only).
fn fileWrite(ino: u32, node: *Inode, off: u64, src: []const u8) ?u64 {
    var done: u64 = 0;
    var sec: [sector]u8 = undefined;
    while (done < src.len) {
        const pos = off + done;
        const bi = pos / sector;
        if (bi >= 12) break;
        if (node.blocks[bi] == 0) {
            node.blocks[bi] = allocBlock() orelse return null;
            const zero: [sector]u8 = @splat(0);
            diskWrite(node.blocks[bi], &zero);
        }
        diskRead(node.blocks[bi], &sec);
        const so = pos % sector;
        const chunk = @min(src.len - done, sector - so);
        @memcpy(sec[so .. so + chunk], src[done .. done + chunk]);
        diskWrite(node.blocks[bi], &sec);
        done += chunk;
    }
    if (off + done > node.size) node.size = @intCast(off + done);
    writeInode(ino, node);
    return done;
}

const dirent_size = 32;

fn dirFind(dir: *const Inode, name: []const u8) ?u32 {
    var e: [dirent_size]u8 = undefined;
    var off: u64 = 0;
    while (off < dir.size) : (off += dirent_size) {
        if (fileRead(dir, off, dirent_size, &e) != dirent_size) break;
        if (e[2] != 0 and e[3] == name.len and eq(e[4 .. 4 + name.len], name)) {
            return leu16(e[0..]);
        }
    }
    return null;
}

fn dirAdd(dirino: u32, dir: *Inode, name: []const u8, child: u32) bool {
    if (name.len == 0 or name.len > 28) return false;
    var e: [dirent_size]u8 = @splat(0);
    puleu16(e[0..], @intCast(child));
    e[2] = 1;
    e[3] = @intCast(name.len);
    @memcpy(e[4 .. 4 + name.len], name);
    return fileWrite(dirino, dir, dir.size, &e) == dirent_size;
}

// ------------------------------------------------------- paths and views

const Resolved = union(enum) {
    boot_file: usize,
    boot_dir: struct { prefix: []const u8 },
    disk: struct { ino: u32, is_dir: bool },
    uroot: void,
    missing: void,
    bad: void,
};

/// Iterate path components; sets bad on "." / ".." / leading '/'.
fn resolve(v: *View, path: []const u8, scratch: *[64]u8) Resolved {
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
            return resolveDisk(ino_root, path);
        },
        .boot => {
            const prefix = v.boot_prefix[0..v.boot_prefix_len];
            return resolveBoot(prefix, path, scratch);
        },
        .disk => return resolveDisk(v.ino, path),
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

fn resolveDisk(root: u32, path: []const u8) Resolved {
    var ino = root;
    var node = readInode(ino);
    var it = path;
    while (it.len > 0) {
        const c = firstComp(it);
        if (badComp(c)) return .bad;
        it = if (c.len == it.len) "" else it[c.len + 1 ..];
        if (node.typ != 2) return .missing;
        ino = dirFind(&node, c) orelse return .missing;
        node = readInode(ino);
    }
    return .{ .disk = .{ .ino = ino, .is_dir = node.typ == 2 } };
}

fn viewPath(v: *View, off: u64, len: u64) ?[]const u8 {
    if (v.buf == 0 or len > 256 or off + len > 4096) return null;
    return @as([*]const u8, @ptrFromInt(v.buf + off))[0..len];
}

// ---------------------------------------------------------- operations

fn doOpen(v: *View, path_off: u64, path_len: u64, create: u64) shared.FsResp {
    const path = viewPath(v, path_off, path_len) orelse return ferr(.bad_path);
    var scratch: [64]u8 = undefined;
    const res = resolve(v, path, &scratch);
    switch (res) {
        .bad => return ferr(.bad_path),
        .boot_file => |idx| {
            if (create != 0) return ferr(.denied);
            return fdInsert(v, .{ .used = true, .boot = true, .idx = @intCast(idx) });
        },
        .boot_dir, .uroot => return ferr(.denied),
        .disk => |dk| {
            // Create is open-if-exists (no O_EXCL yet): mkdir of an
            // existing dir succeeds, create of an existing file opens it.
            if (create == 2) return if (dk.is_dir) .ok else ferr(.exists);
            if (dk.is_dir) return ferr(.denied);
            if (create != 0 and v.ro) return ferr(.denied);
            return fdInsert(v, .{ .used = true, .ino = dk.ino });
        },
        .missing => {
            if (create == 0) return ferr(.not_found);
            if (v.ro) return ferr(.denied);
            return doCreate(v, path, create == 2);
        },
    }
}

fn doCreate(v: *View, path: []const u8, is_dir: bool) shared.FsResp {
    // Boot subtree never accepts creation.
    var scratch: [64]u8 = undefined;
    const parent_path = dirName(path);
    const name = baseName(path);
    const parent = resolve(v, parent_path, &scratch);
    const parent_ino = switch (parent) {
        .disk => |dk| if (dk.is_dir) dk.ino else return ferr(.bad_path),
        .uroot, .boot_dir, .boot_file => return ferr(.denied),
        else => return ferr(.not_found),
    };
    const ino = allocInode() orelse return ferr(.no_space);
    var node: Inode = .{ .typ = if (is_dir) 2 else 1 };
    writeInode(ino, &node);
    var pnode = readInode(parent_ino);
    if (!dirAdd(parent_ino, &pnode, name, ino)) return ferr(.no_space);
    if (is_dir) return .ok;
    return fdInsert(v, .{ .used = true, .ino = ino });
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
    if (v.buf == 0 or len > 2048) return ferr(.bad_path);
    const dst = @as([*]u8, @ptrFromInt(v.buf))[0..len];
    const fd = &v.fds[fdn];
    if (fd.boot) {
        const data = boot_entries[fd.idx].data;
        if (off >= data.len) return .{ .num = .{ .n = 0 } };
        const n = @min(len, data.len - off);
        @memcpy(dst[0..n], data[off .. off + n]);
        return .{ .num = .{ .n = n } };
    }
    var node = readInode(fd.ino);
    const n = fileRead(&node, off, len, dst);
    return .{ .num = .{ .n = n } };
}

fn doWrite(v: *View, fdn: u64, off: u64, len: u64) shared.FsResp {
    if (v.ro) return ferr(.denied);
    if (fdn >= max_fds or !v.fds[fdn].used) return ferr(.bad_fd);
    if (v.fds[fdn].boot) return ferr(.denied);
    if (v.buf == 0 or len > 2048) return ferr(.bad_path);
    const src = @as([*]const u8, @ptrFromInt(v.buf))[0..len];
    const fd = &v.fds[fdn];
    var node = readInode(fd.ino);
    const n = fileWrite(fd.ino, &node, off, src) orelse return ferr(.no_space);
    return .{ .num = .{ .n = n } };
}

fn doList(v: *View, path_off: u64, path_len: u64) shared.FsResp {
    const path = viewPath(v, path_off, path_len) orelse return ferr(.bad_path);
    if (v.buf == 0) return ferr(.bad_path);
    var scratch: [64]u8 = undefined;
    const out = @as([*]u8, @ptrFromInt(v.buf))[0..2048];
    var n: usize = 0;
    switch (resolve(v, path, &scratch)) {
        .bad => return ferr(.bad_path),
        .missing, .boot_file => return ferr(.not_found),
        .uroot => {
            n = putLine(out, n, "boot");
            n = listDiskDir(ino_root, out, n);
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
            if (!dk.is_dir) return ferr(.not_found);
            n = listDiskDir(dk.ino, out, n);
        },
    }
    return .{ .num = .{ .n = n } };
}

fn listDiskDir(ino: u32, out: []u8, start: usize) usize {
    var n = start;
    const dir = readInode(ino);
    var e: [dirent_size]u8 = undefined;
    var off: u64 = 0;
    while (off < dir.size) : (off += dirent_size) {
        if (fileRead(&dir, off, dirent_size, &e) != dirent_size) break;
        if (e[2] != 0) n = putLine(out, n, e[4 .. 4 + e[3]]);
    }
    return n;
}

fn doDerive(v: *View, path_off: u64, path_len: u64, want_ro: bool) void {
    const fail = struct {
        fn f(code: shared.FsErr) void {
            _ = usys.replyTyped(shared.FsResp, serve_a, .{
                .fs_err = .{ .code = @intFromEnum(code) },
            }, 0);
        }
    }.f;
    const path = viewPath(v, path_off, path_len) orelse return fail(.bad_path);
    var scratch: [64]u8 = undefined;
    const res = resolve(v, path, &scratch);

    // Find a free view slot (badge = index).
    var slot: usize = 0;
    while (slot < max_views and views[slot].used) slot += 1;
    if (slot == max_views) return fail(.no_space);
    var nv = &views[slot];

    switch (res) {
        .bad => return fail(.bad_path),
        .missing, .boot_file => return fail(.not_found),
        .uroot => nv.* = .{ .used = true, .kind = .uroot, .ro = v.ro or want_ro },
        .boot_dir => |bd| {
            nv.* = .{ .used = true, .kind = .boot, .ro = true }; // boot is always ro
            @memcpy(nv.boot_prefix[0..bd.prefix.len], bd.prefix);
            nv.boot_prefix_len = bd.prefix.len;
        },
        .disk => |dk| {
            if (!dk.is_dir) return fail(.not_found);
            nv.* = .{ .used = true, .kind = .disk, .ino = dk.ino, .ro = v.ro or want_ro };
        },
    }
    const minted = usys.chanMint(serve_a, slot);
    if (minted.err != .ok) {
        nv.used = false;
        return fail(.no_space);
    }
    _ = usys.replyTyped(shared.FsResp, serve_a, .ok, minted.data[1]);
    _ = usys.capDrop(minted.data[1]); // the transferred copy carries the ref
}

// -------------------------------------------------------------- clients

fn fsOpen(chan: u64, buf: [*]u8, path: []const u8, create: u64) union(enum) { fd: u64, err: shared.FsErr } {
    @memcpy(buf[1024 .. 1024 + path.len], path);
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .{
        .open = .{ .path_off = 1024, .path_len = path.len, .create = create },
    }, 0)) {
        .ok => |rep| switch (rep) {
            .num => |x| return .{ .fd = x.n },
            .fs_err => |e| return .{ .err = @enumFromInt(e.code) },
            else => return .{ .err = .io },
        },
        .err => return .{ .err = .io },
    }
}

fn fsWrite(chan: u64, buf: [*]u8, fd: u64, data: []const u8) bool {
    @memcpy(buf[0..data.len], data);
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .{
        .write = .{ .fd = fd, .off = 0, .len = data.len },
    }, 0)) {
        .ok => |rep| return rep == .num,
        .err => return false,
    }
}

fn fsRead(chan: u64, fd: u64, len: u64) ?u64 {
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .{
        .read = .{ .fd = fd, .off = 0, .len = len },
    }, 0)) {
        .ok => |rep| switch (rep) {
            .num => |x| return x.n,
            else => return null,
        },
        .err => return null,
    }
}

fn fsList(chan: u64, buf: [*]u8, path: []const u8) ?u64 {
    @memcpy(buf[1024 .. 1024 + path.len], path);
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .{
        .list = .{ .path_off = 1024, .path_len = path.len },
    }, 0)) {
        .ok => |rep| switch (rep) {
            .num => |x| return x.n,
            else => return null,
        },
        .err => return null,
    }
}

fn attachBuf(chan: u64) struct { va: u64, cap: u64 } {
    const s = usys.shmCreate(1);
    if (s.err != .ok) usys.exit(210);
    const m = usys.shmMap(s.data[0]);
    if (m.err != .ok) usys.exit(211);
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .attach_buf, s.data[0])) {
        .ok => {},
        .err => usys.exit(212),
    }
    return .{ .va = m.data[0], .cap = s.data[0] };
}

fn fsMkdir(chan: u64, buf: [*]u8, path: []const u8) bool {
    @memcpy(buf[1024 .. 1024 + path.len], path);
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .{
        .open = .{ .path_off = 1024, .path_len = path.len, .create = 2 },
    }, 0)) {
        .ok => |rep| return rep == .ok,
        .err => return false,
    }
}

fn alice(log_h: u64, fs_chan: u64) noreturn {
    var line: [96]u8 = undefined;
    const b = attachBuf(fs_chan);
    const buf: [*]u8 = @ptrFromInt(b.va);

    // Boot image is readable...
    switch (fsOpen(fs_chan, buf, "boot/etc/motd", 0)) {
        .fd => |fd| {
            const n = fsRead(fs_chan, fd, 64) orelse usys.exit(101);
            _ = usys.log(log_h, cat(&line, "alice: boot/etc/motd says: ", buf[0..n]));
        },
        .err => usys.exit(102),
    }
    // ...but never writable, even for a rw root view.
    switch (fsOpen(fs_chan, buf, "boot/hack", 1)) {
        .fd => usys.exit(103),
        .err => |e| if (e != .denied) usys.exit(104),
    }

    // Real storage, standard hierarchy: private state in state/alice,
    // shared payload in data/pub for bob.
    if (!fsMkdir(fs_chan, buf, "state/alice")) usys.exit(105);
    switch (fsOpen(fs_chan, buf, "state/alice/secret.txt", 1)) {
        .fd => |fd| if (!fsWrite(fs_chan, buf, fd, "top secret stuff")) usys.exit(106),
        .err => usys.exit(107),
    }
    if (!fsMkdir(fs_chan, buf, "data/pub")) usys.exit(108);
    switch (fsOpen(fs_chan, buf, "data/pub/note.txt", 1)) {
        .fd => |fd| if (!fsWrite(fs_chan, buf, fd, "hello from alice")) usys.exit(109),
        .err => usys.exit(110),
    }

    const n = fsList(fs_chan, buf, "") orelse usys.exit(111);
    _ = usys.log(log_h, cat(&line, "alice: / holds: ", collapse(buf[0..n])));
    usys.exit(0);
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
    const b = attachBuf(fs_chan);
    const buf: [*]u8 = @ptrFromInt(b.va);

    // The whole world is note.txt.
    const n = fsList(fs_chan, buf, "") orelse usys.exit(120);
    if (!eq(buf[0..n], "note.txt\n")) {
        _ = usys.log(log_h, cat(&line, "bob: unexpected view: ", buf[0..n]));
        usys.exit(121);
    }
    _ = usys.log(log_h, "bob: my entire world is note.txt — as granted");

    switch (fsOpen(fs_chan, buf, "note.txt", 0)) {
        .fd => |fd| {
            const rn = fsRead(fs_chan, fd, 64) orelse usys.exit(122);
            if (!eq(buf[0..rn], "hello from alice")) usys.exit(123);
            _ = usys.log(log_h, cat(&line, "bob: read note.txt: ", buf[0..rn]));
            // Writing through a read-only view must fail.
            if (fsWrite(fs_chan, buf, fd, "vandalism")) usys.exit(124);
        },
        .err => usys.exit(125),
    }

    // Creation refused, escape unpronounceable, privilege un-upgradeable.
    switch (fsOpen(fs_chan, buf, "graffiti.txt", 1)) {
        .fd => usys.exit(126),
        .err => |e| if (e != .denied) usys.exit(127),
    }
    switch (fsOpen(fs_chan, buf, "../../state/alice/secret.txt", 0)) {
        .fd => usys.exit(128),
        .err => |e| if (e != .bad_path) usys.exit(129),
    }
    // derive(rw) from an ro view yields another ro view.
    switch (usys.callTypedCap(shared.FsReq, shared.FsResp, fs_chan, .{
        .derive = .{ .path_off = 1024, .path_len = 0, .ro = 0 },
    }, 0)) {
        .ok => |ok| {
            if (ok.cap == 0) usys.exit(130);
            switch (fsOpen(fs_chan, buf, "sneaky.txt", 1)) { // still on old cap: ro
                .fd => usys.exit(131),
                .err => {},
            }
            // The derived cap needs its own buffer; reuse ours.
            switch (usys.callTyped(shared.FsReq, shared.FsResp, ok.cap, .attach_buf, b.cap)) {
                .ok => {},
                .err => usys.exit(132),
            }
            switch (fsOpen(ok.cap, buf, "sneaky.txt", 1)) {
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

fn leu16(b: []const u8) u16 {
    return @as(u16, b[0]) | (@as(u16, b[1]) << 8);
}

fn leu32(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}

fn puleu16(b: []u8, v: u16) void {
    b[0] = @truncate(v);
    b[1] = @truncate(v >> 8);
}

fn puleu32(b: []u8, v: u32) void {
    b[0] = @truncate(v);
    b[1] = @truncate(v >> 8);
    b[2] = @truncate(v >> 16);
    b[3] = @truncate(v >> 24);
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
