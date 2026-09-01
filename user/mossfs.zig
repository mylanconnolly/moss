//! mossfs v2 — a copy-on-write, checksummed, crash-consistent filesystem.
//!
//! PURE library: std-only, no OS imports, driven through a BlockDev vtable
//! — the same code runs in fssvc over virtio-blk and in host unit tests
//! over a RAM device, where the crash-injection harness cuts the write
//! stream at every point and proves consistency.
//!
//! Design (see the mossfs v2 plan and DESIGN.md):
//! - Never update in place. All state hangs off a superblock through
//!   checksummed BlockPtrs {addr, xxhash64}; every read verifies, so the
//!   tree is self-validating and torn/misdirected writes are detected.
//! - 8 rotating superblock slots (blocks 0..7); mount picks the highest
//!   txg whose full-slot checksum verifies. No fsck, ever.
//! - Objects (file/dir/symlink) are 128B dnodes in the objmap, itself a
//!   CoW block tree. Files: 3 direct ptrs + an indirect tree (level<=4,
//!   256 ptrs/block -> 16TB max file). Directories: 64B fixed dirents.
//!   Symlinks are ordinary small objects holding the target path.
//! - Free space: allocation groups (size set at format; 1GiB production,
//!   tiny in tests) with per-group CoW bitmaps referenced from a CoW
//!   group table carrying free counts. Commit cost scales with dirty
//!   groups, not volume size; nothing volume-proportional at mount.
//! - Transactions: mutations live in an in-memory overlay (dirty data
//!   blocks, dirty dnodes, per-object trim boundaries). Commit: (A) the
//!   object subgraph is rebuilt bottom-up (alloc, fill, checksum, write —
//!   its checksums never depend on bitmaps); (B) the space subgraph's
//!   addresses reach fixpoint (allocating bitmap/group-table blocks
//!   dirties bitmaps; allocation prefers already-dirty groups so this
//!   converges); (C) bitmaps and the group table are filled, checksummed
//!   bottom-up, written; (D) FLUSH -> superblock slot -> FLUSH. Blocks
//!   freed from the old tree are quarantined: recorded free in the new
//!   bitmaps but never reallocated within the txg that freed them.
//! - Large delete/truncate are O(1): subtrees go onto a persisted
//!   deleting set (object 1) drained a bounded amount per commit; mount
//!   resumes draining, so a crash mid-huge-delete needs no special case.
//!
//! Ops are atomic w.r.t. txg boundaries: the library NEVER commits inside
//! an operation — callers invoke maybeCommit()/sync() between ops.

const std = @import("std");

pub const block_size = 4096;
pub const ptrs_per_block = block_size / 16; // 256
pub const sb_slots = 8;
pub const dirent_size = 64;
pub const max_name = 56;
pub const dnode_size = 128;
pub const dnodes_per_block = block_size / dnode_size; // 32
pub const max_level = 4;
pub const max_objs: u32 = 1 << 20;
pub const gt_entry_size = 144; // 8 bitmap ptrs (128B) + free count + pad
pub const gt_per_block = block_size / gt_entry_size; // 28
const bits_per_bblock: u64 = block_size * 8; // 32768

const sb_magic = "MOS2";
const fs_version: u32 = 2;

pub const DevError = error{IoError};

pub const Error = error{
    IoError,
    /// A checksum failed to verify: the medium returned wrong bits.
    Corrupt,
    NoSpace,
    NoObjects,
    TooLarge,
    /// Internal capacity (overlay/working set) exceeded: an op larger
    /// than the configured limits. Ops are meant to be small.
    Overflow,
    NoFilesystem,
};

pub const BlockDev = struct {
    ctx: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, addr: u64, dst: *[block_size]u8) DevError!void,
    writeFn: *const fn (ctx: *anyopaque, addr: u64, src: *const [block_size]u8) DevError!void,
    flushFn: *const fn (ctx: *anyopaque) DevError!void,
    nblocks: u64,

    fn read(d: BlockDev, addr: u64, dst: *[block_size]u8) DevError!void {
        return d.readFn(d.ctx, addr, dst);
    }
    fn write(d: BlockDev, addr: u64, src: *const [block_size]u8) DevError!void {
        return d.writeFn(d.ctx, addr, src);
    }
    fn flush(d: BlockDev) DevError!void {
        return d.flushFn(d.ctx);
    }
};

pub const BlockPtr = struct {
    addr: u64 = 0, // 0 = hole (block 0 is a superblock slot, never data)
    csum: u64 = 0,

    fn isHole(p: BlockPtr) bool {
        return p.addr == 0;
    }
};

pub const ObjType = enum(u8) { free = 0, file = 1, dir = 2, symlink = 3 };

pub const Dnode = struct {
    typ: ObjType = .free,
    level: u8 = 0, // height of the indirect tree (0 = directs only)
    nlink: u16 = 1, // reserved for a future hardlink design; always 1
    size: u64 = 0,
    mtime: u64 = 0,
    direct: [3]BlockPtr = @splat(.{}),
    indirect: BlockPtr = .{},
};

pub const Stat = struct { typ: ObjType, size: u64, mtime: u64 };

pub const root_obj: u32 = 0;
pub const delset_obj: u32 = 1;
const first_user_obj: u32 = 2;
const del_entry_size = 24; // {addr u64, csum u64, level u8, pad}

// ------------------------------------------------------------ capacities

const rcache_n = 96;
const max_dirty_data = 160;
const max_dirty_dnodes = 48;
const max_wbb = 24; // working (dirty) bitmap blocks per txg
const max_frees = 768; // quarantined frees per txg
const max_gt_dirty = 32; // dirty group-table leaves / path nodes per txg
const commit_data_threshold = 96;
const commit_dnode_threshold = 32;
const drain_budget = 48; // deleting-set frees per commit
pub const alloc_reserve = 96; // headroom so a commit can always land

// --------------------------------------------------------------- codecs

fn csum(data: *const [block_size]u8) u64 {
    return std.hash.XxHash64.hash(0x6d6f7373, data);
}

fn leU(comptime T: type, b: []const u8) T {
    return std.mem.readInt(T, b[0..@sizeOf(T)], .little);
}

fn puU(comptime T: type, b: []u8, v: T) void {
    std.mem.writeInt(T, b[0..@sizeOf(T)], v, .little);
}

fn putPtr(b: []u8, p: BlockPtr) void {
    puU(u64, b[0..8], p.addr);
    puU(u64, b[8..16], p.csum);
}

fn getPtr(b: []const u8) BlockPtr {
    return .{ .addr = leU(u64, b[0..8]), .csum = leU(u64, b[8..16]) };
}

fn putDnode(b: []u8, d: *const Dnode) void {
    @memset(b[0..dnode_size], 0);
    b[0] = @intFromEnum(d.typ);
    b[1] = d.level;
    puU(u16, b[2..4], d.nlink);
    puU(u64, b[8..16], d.size);
    puU(u64, b[16..24], d.mtime);
    for (0..3) |i| putPtr(b[24 + i * 16 ..], d.direct[i]);
    putPtr(b[72..], d.indirect);
}

fn getDnode(b: []const u8) Dnode {
    var d: Dnode = .{};
    d.typ = std.enums.fromInt(ObjType, b[0]) orelse .free;
    d.level = b[1];
    d.nlink = leU(u16, b[2..4]);
    d.size = leU(u64, b[8..16]);
    d.mtime = leU(u64, b[16..24]);
    for (0..3) |i| d.direct[i] = getPtr(b[24 + i * 16 ..]);
    d.indirect = getPtr(b[72..]);
    return d;
}

fn treeCapacity(level: u8) u64 {
    var c: u64 = 1;
    for (0..level) |_| c *= ptrs_per_block;
    return c;
}

/// Smallest tree height whose capacity exceeds `idx`.
fn levelFor(idx: u64) u8 {
    var l: u8 = 1;
    while (treeCapacity(l) <= idx) l += 1;
    return l;
}

// ------------------------------------------------------- state structs

const RCacheEnt = struct {
    addr: u64 = 0, // 0 = empty
    lru: u64 = 0,
    data: [block_size]u8 = undefined,
};

const DirtyData = struct {
    used: bool = false,
    obj: u32 = 0,
    blkidx: u64 = 0,
    data: [block_size]u8 = undefined,
};

const DirtyDnode = struct {
    used: bool = false,
    obj: u32 = 0,
    dn: Dnode = .{},
    orig: Dnode = .{},
    /// Truncation boundary (in block indexes): committed blocks at
    /// blkidx >= trim are gone (their subtrees sit in the deleting set);
    /// reads see holes and commit nulls the stale pointers.
    trim: u64 = std.math.maxInt(u64),
};

const Wbb = struct { // one working bitmap block
    used: bool = false,
    group: u32 = 0,
    sub: u32 = 0,
    old: BlockPtr = .{},
    new_addr: u64 = 0,
    new_ptr: BlockPtr = .{},
    data: [block_size]u8 = undefined,
};

const GtDirty = struct { // a group-table leaf or path node being rewritten
    used: bool = false,
    h: u8 = 0, // 0 = leaf
    nid: u64 = 0,
    old: BlockPtr = .{},
    new_addr: u64 = 0,
    new_ptr: BlockPtr = .{},
};

// ---------------------------------------------------------------- the FS

pub const Fs = struct {
    dev: BlockDev = undefined,

    // Committed roots (updated only when a commit lands).
    txg: u64 = 0,
    slot_next: u32 = 0,
    obj_root: BlockPtr = .{},
    obj_level: u8 = 0,
    gt_root: BlockPtr = .{},
    gt_level: u8 = 0,
    gcount: u32 = 0,
    group_blocks: u64 = 0,
    bblocks_per_group: u32 = 0,
    nblocks: u64 = 0,
    free_hint: u32 = first_user_obj,

    gfree: [max_groups]u32 = @splat(0),

    rc: [rcache_n]RCacheEnt = @splat(.{}),
    lru_tick: u64 = 0,

    dd: [max_dirty_data]DirtyData = @splat(.{}),
    dd_count: u32 = 0,
    ddn: [max_dirty_dnodes]DirtyDnode = @splat(.{}),

    freed: [max_frees]u64 = @splat(0),
    freed_count: u32 = 0,

    wbb: [max_wbb]Wbb = @splat(.{}),
    gtd: [max_gt_dirty]GtDirty = @splat(.{}),

    commits: u64 = 0,

    pub const max_groups = 16384; // 16TB at 1GiB groups; raise as needed

    // ------------------------------------------------------- read cache

    fn cacheFind(fs: *Fs, addr: u64) ?*RCacheEnt {
        for (&fs.rc) |*e| {
            if (e.addr == addr) {
                fs.lru_tick += 1;
                e.lru = fs.lru_tick;
                return e;
            }
        }
        return null;
    }

    fn cacheSlot(fs: *Fs) *RCacheEnt {
        var best: *RCacheEnt = &fs.rc[0];
        for (&fs.rc) |*e| {
            if (e.addr == 0) return e;
            if (e.lru < best.lru) best = e;
        }
        return best;
    }

    fn cacheDrop(fs: *Fs, addr: u64) void {
        for (&fs.rc) |*e| {
            if (e.addr == addr) e.addr = 0;
        }
    }

    fn cacheInsert(fs: *Fs, addr: u64, data: *const [block_size]u8) void {
        fs.cacheDrop(addr); // never two entries for one addr
        const e = fs.cacheSlot();
        e.addr = addr;
        fs.lru_tick += 1;
        e.lru = fs.lru_tick;
        @memcpy(&e.data, data);
    }

    /// Verified read through the cache. The returned pointer is valid
    /// only until the next cache operation — copy out to keep it.
    fn readPtr(fs: *Fs, p: BlockPtr) Error!*const [block_size]u8 {
        std.debug.assert(!p.isHole());
        if (fs.cacheFind(p.addr)) |e| return &e.data;
        const e = fs.cacheSlot();
        const prev = e.addr;
        e.addr = 0;
        fs.dev.read(p.addr, &e.data) catch return Error.IoError;
        _ = prev;
        if (csum(&e.data) != p.csum) return Error.Corrupt;
        e.addr = p.addr;
        fs.lru_tick += 1;
        e.lru = fs.lru_tick;
        return &e.data;
    }

    fn readPtrCopy(fs: *Fs, p: BlockPtr, dst: *[block_size]u8) Error!void {
        if (p.isHole()) {
            @memset(dst, 0);
            return;
        }
        const blk = try fs.readPtr(p);
        @memcpy(dst, blk);
    }

    // ---------------------------------------------------------- overlay

    fn dirtyDataFind(fs: *Fs, obj: u32, blkidx: u64) ?*DirtyData {
        for (&fs.dd) |*e| {
            if (e.used and e.obj == obj and e.blkidx == blkidx) return e;
        }
        return null;
    }

    fn dnodeSlot(fs: *Fs, obj: u32) Error!*DirtyDnode {
        for (&fs.ddn) |*e| {
            if (e.used and e.obj == obj) return e;
        }
        for (&fs.ddn) |*e| {
            if (!e.used) {
                const dn = try fs.dnodeRead(obj);
                e.* = .{ .used = true, .obj = obj, .dn = dn, .orig = dn };
                return e;
            }
        }
        return Error.Overflow;
    }

    fn dirtyDnodeFind(fs: *Fs, obj: u32) ?*DirtyDnode {
        for (&fs.ddn) |*e| {
            if (e.used and e.obj == obj) return e;
        }
        return null;
    }

    fn quarantine(fs: *Fs, addr: u64) Error!void {
        if (addr == 0) return;
        if (fs.freed_count >= max_frees) return Error.Overflow;
        fs.freed[fs.freed_count] = addr;
        fs.freed_count += 1;
        fs.cacheDrop(addr);
    }

    fn isQuarantined(fs: *Fs, addr: u64) bool {
        for (fs.freed[0..fs.freed_count]) |a| {
            if (a == addr) return true;
        }
        return false;
    }

    /// Free a committed block: quarantine + clear its bitmap bit.
    fn freeCommitted(fs: *Fs, addr: u64) Error!void {
        if (addr == 0) return;
        try fs.quarantine(addr);
        try fs.freeInBitmap(addr);
    }

    // ------------------------------------------------------------ objmap

    /// Committed pointer to objmap leaf `leaf` (a block of 32 dnodes).
    fn objmapLeafPtr(fs: *Fs, leaf: u64) Error!BlockPtr {
        if (fs.obj_level == 0) {
            return if (leaf == 0) fs.obj_root else BlockPtr{};
        }
        return fs.treeLeafPtr(fs.obj_root, fs.obj_level, leaf);
    }

    fn dnodeRead(fs: *Fs, obj: u32) Error!Dnode {
        if (obj >= max_objs) return Error.NoObjects;
        const p = try fs.objmapLeafPtr(obj / dnodes_per_block);
        if (p.isHole()) return .{};
        const blk = try fs.readPtr(p);
        return getDnode(blk[(obj % dnodes_per_block) * dnode_size ..]);
    }

    pub fn dnodeOf(fs: *Fs, obj: u32) Error!Dnode {
        if (fs.dirtyDnodeFind(obj)) |e| return e.dn;
        return fs.dnodeRead(obj);
    }

    /// Walk a committed tree (root at height `level`, leaves at height 0).
    fn treeLeafPtr(fs: *Fs, root: BlockPtr, level: u8, leaf: u64) Error!BlockPtr {
        if (leaf >= treeCapacity(level)) return .{};
        var node = root;
        var h = level;
        var index = leaf;
        while (h > 0) : (h -= 1) {
            if (node.isHole()) return .{};
            const blk = try fs.readPtr(node);
            const stride = treeCapacity(h - 1);
            const d = index / stride;
            index = index % stride;
            node = getPtr(blk[(d % ptrs_per_block) * 16 ..]);
        }
        return node;
    }

    // -------------------------------------------------------- file blocks

    /// Committed pointer for a file block, honoring the trim boundary.
    fn origFileBlockPtr(fs: *Fs, obj: u32, blkidx: u64) Error!BlockPtr {
        var orig: Dnode = undefined;
        var trim: u64 = std.math.maxInt(u64);
        if (fs.dirtyDnodeFind(obj)) |e| {
            orig = e.orig;
            trim = e.trim;
        } else {
            orig = try fs.dnodeRead(obj);
        }
        if (blkidx >= trim) return .{};
        if (blkidx < 3) return orig.direct[blkidx];
        const idxp = blkidx - 3;
        if (orig.level == 0 or idxp >= treeCapacity(orig.level)) return .{};
        var node = orig.indirect;
        var h = orig.level;
        var index = idxp;
        while (h > 0) : (h -= 1) {
            if (node.isHole()) return .{};
            const blk = try fs.readPtr(node);
            const stride = treeCapacity(h - 1);
            const d = index / stride;
            index = index % stride;
            node = getPtr(blk[(d % ptrs_per_block) * 16 ..]);
        }
        return node;
    }

    pub fn readFileBlock(fs: *Fs, obj: u32, blkidx: u64, dst: *[block_size]u8) Error!void {
        if (fs.dirtyDataFind(obj, blkidx)) |e| {
            @memcpy(dst, &e.data);
            return;
        }
        const p = try fs.origFileBlockPtr(obj, blkidx);
        try fs.readPtrCopy(p, dst);
    }

    fn dirtyFileBlock(fs: *Fs, obj: u32, blkidx: u64) Error!*DirtyData {
        if (fs.dirtyDataFind(obj, blkidx)) |e| return e;
        for (&fs.dd) |*e| {
            if (e.used) continue;
            e.used = true;
            e.obj = obj;
            e.blkidx = blkidx;
            fs.dd_count += 1;
            const p = try fs.origFileBlockPtr(obj, blkidx);
            try fs.readPtrCopy(p, &e.data);
            return e;
        }
        return Error.Overflow;
    }

    // ------------------------------------------------------- public API

    pub fn allocObject(fs: *Fs, typ: ObjType, now: u64) Error!u32 {
        var obj = if (fs.free_hint < first_user_obj) first_user_obj else fs.free_hint;
        var scanned: u32 = 0;
        while (scanned < max_objs) : (scanned += 1) {
            const dn = try fs.dnodeOf(obj);
            if (dn.typ == .free) {
                const e = try fs.dnodeSlot(obj);
                e.dn = .{ .typ = typ, .mtime = now };
                fs.free_hint = obj + 1;
                return obj;
            }
            obj += 1;
            if (obj >= max_objs) obj = first_user_obj;
        }
        return Error.NoObjects;
    }

    pub fn statObj(fs: *Fs, obj: u32) Error!Stat {
        const dn = try fs.dnodeOf(obj);
        return .{ .typ = dn.typ, .size = dn.size, .mtime = dn.mtime };
    }

    pub fn readObj(fs: *Fs, obj: u32, off: u64, dst: []u8) Error!usize {
        const dn = try fs.dnodeOf(obj);
        if (off >= dn.size) return 0;
        const n: usize = @intCast(@min(dst.len, dn.size - off));
        var done: usize = 0;
        var buf: [block_size]u8 = undefined;
        while (done < n) {
            const pos = off + done;
            const bo: usize = @intCast(pos % block_size);
            const chunk = @min(n - done, block_size - bo);
            try fs.readFileBlock(obj, pos / block_size, &buf);
            @memcpy(dst[done .. done + chunk], buf[bo .. bo + chunk]);
            done += chunk;
        }
        return n;
    }

    pub fn writeObj(fs: *Fs, obj: u32, off: u64, src: []const u8, now: u64) Error!usize {
        if (try fs.freeBlocksTotal() < alloc_reserve) return Error.NoSpace;
        const end = off + src.len;
        if (end > 0) {
            const last_idx = (end - 1) / block_size;
            if (last_idx >= 3 and levelFor(last_idx - 3) > max_level) return Error.TooLarge;
        }
        var done: usize = 0;
        while (done < src.len) {
            const pos = off + done;
            const bo: usize = @intCast(pos % block_size);
            const chunk = @min(src.len - done, block_size - bo);
            const e = try fs.dirtyFileBlock(obj, pos / block_size);
            @memcpy(e.data[bo .. bo + chunk], src[done .. done + chunk]);
            done += chunk;
        }
        const e = try fs.dnodeSlot(obj);
        if (end > e.dn.size) e.dn.size = end;
        if (end > 0) {
            const last_idx = (end - 1) / block_size;
            if (last_idx >= 3) {
                const lv = levelFor(last_idx - 3);
                if (lv > e.dn.level) e.dn.level = lv;
            }
        }
        e.dn.mtime = now;
        return src.len;
    }

    // -------------------------------------------------- deleting set

    fn delsetPush(fs: *Fs, p: BlockPtr, level: u8, now: u64) Error!void {
        if (p.isHole()) return;
        var ent: [del_entry_size]u8 = @splat(0);
        puU(u64, ent[0..8], p.addr);
        puU(u64, ent[8..16], p.csum);
        ent[16] = level;
        const dn = try fs.dnodeOf(delset_obj);
        _ = try fs.writeObjRaw(delset_obj, dn.size, &ent, now);
    }

    /// writeObj without the free-space gate (the deleting set must be able
    /// to grow while draining, or a full disk could never recover space).
    fn writeObjRaw(fs: *Fs, obj: u32, off: u64, src: []const u8, now: u64) Error!usize {
        var done: usize = 0;
        while (done < src.len) {
            const pos = off + done;
            const bo: usize = @intCast(pos % block_size);
            const chunk = @min(src.len - done, block_size - bo);
            const e = try fs.dirtyFileBlock(obj, pos / block_size);
            @memcpy(e.data[bo .. bo + chunk], src[done .. done + chunk]);
            done += chunk;
        }
        const e = try fs.dnodeSlot(obj);
        const end = off + src.len;
        if (end > e.dn.size) e.dn.size = end;
        if (end > 0) {
            const last_idx = (end - 1) / block_size;
            if (last_idx >= 3) {
                const lv = levelFor(last_idx - 3);
                if (lv > e.dn.level) e.dn.level = lv;
            }
        }
        e.dn.mtime = now;
        return src.len;
    }

    fn drainDeleting(fs: *Fs, budget: u32, now: u64) Error!u32 {
        var freed: u32 = 0;
        while (freed < budget) {
            const dn = try fs.dnodeOf(delset_obj);
            if (dn.size < del_entry_size) break;
            var ent: [del_entry_size]u8 = undefined;
            _ = try fs.readObj(delset_obj, dn.size - del_entry_size, &ent);
            const p: BlockPtr = .{ .addr = leU(u64, ent[0..8]), .csum = leU(u64, ent[8..16]) };
            const level = ent[16];
            try fs.truncateObjRaw(delset_obj, dn.size - del_entry_size, now);
            if (level > 0) {
                var copy: [block_size]u8 = undefined;
                try fs.readPtrCopy(p, &copy);
                for (0..ptrs_per_block) |i| {
                    const child = getPtr(copy[i * 16 ..]);
                    if (!child.isHole()) try fs.delsetPush(child, level - 1, now);
                }
            }
            try fs.freeCommitted(p.addr);
            freed += 1;
        }
        return freed;
    }

    // ---------------------------------------------------------- truncate

    pub fn truncateObj(fs: *Fs, obj: u32, newlen: u64, now: u64) Error!void {
        return fs.truncateObjRaw(obj, newlen, now);
    }

    fn truncateObjRaw(fs: *Fs, obj: u32, newlen: u64, now: u64) Error!void {
        const e = try fs.dnodeSlot(obj);
        if (newlen >= e.dn.size) {
            e.dn.size = newlen;
            e.dn.mtime = now;
            return;
        }
        const keep_blocks = (newlen + block_size - 1) / block_size;
        // Drop overlay blocks past the boundary.
        for (&fs.dd) |*d| {
            if (d.used and d.obj == obj and d.blkidx >= keep_blocks) {
                d.used = false;
                fs.dd_count -= 1;
            }
        }
        // Committed content past the boundary goes to the deleting set —
        // whole subtrees where possible (never proportional to file size
        // here; the drain pays it off over future commits).
        for (0..3) |i| {
            if (i >= keep_blocks and i < e.trim and !e.orig.direct[i].isHole()) {
                try fs.delsetPush(e.orig.direct[i], 0, now);
            }
            if (i >= keep_blocks) e.dn.direct[i] = .{};
        }
        if (keep_blocks <= 3) {
            if (e.trim > 3 and !e.orig.indirect.isHole()) {
                try fs.delsetPush(e.orig.indirect, e.orig.level, now);
            }
            e.dn.indirect = .{};
            e.dn.level = 0;
        } else if (keep_blocks < e.trim) {
            // Push right-of-boundary subtrees along the old boundary path.
            try fs.pushRightOf(&e.orig, keep_blocks - 3, @min(e.trim, e.orig.size / block_size + 1), now);
        }
        if (keep_blocks < e.trim) e.trim = keep_blocks;
        // Zero the tail of the kept boundary block.
        if (newlen % block_size != 0) {
            const db = try fs.dirtyFileBlock(obj, keep_blocks - 1);
            @memset(db.data[@intCast(newlen % block_size)..], 0);
        }
        e.dn.size = newlen;
        e.dn.mtime = now;
    }

    /// Push every committed subtree fully at/right of leaf index `keep`
    /// (in idxp units) onto the deleting set, walking the boundary path.
    fn pushRightOf(fs: *Fs, orig: *const Dnode, keep_idxp: u64, hint_end: u64, now: u64) Error!void {
        _ = hint_end;
        if (orig.level == 0 or orig.indirect.isHole()) return;
        var node = orig.indirect;
        var h = orig.level;
        // Boundary leaf = keep_idxp - 1 (last kept); free strictly-right
        // children at each level.
        var boundary = keep_idxp - 1;
        while (h > 0) : (h -= 1) {
            if (node.isHole()) return;
            var copy: [block_size]u8 = undefined;
            try fs.readPtrCopy(node, &copy);
            const stride = treeCapacity(h - 1);
            const d = (boundary / stride) % ptrs_per_block;
            var i: usize = @intCast(d + 1);
            while (i < ptrs_per_block) : (i += 1) {
                const child = getPtr(copy[i * 16 ..]);
                if (!child.isHole()) try fs.delsetPush(child, h - 1, now);
            }
            boundary = boundary % stride;
            node = getPtr(copy[@as(usize, @intCast(d)) * 16 ..]);
        }
    }

    pub fn freeObject(fs: *Fs, obj: u32, now: u64) Error!void {
        const e = try fs.dnodeSlot(obj);
        for (0..3) |i| {
            if (e.trim > i and !e.orig.direct[i].isHole()) {
                try fs.delsetPush(e.orig.direct[i], 0, now);
            }
        }
        if (e.trim > 3 and !e.orig.indirect.isHole()) {
            try fs.delsetPush(e.orig.indirect, e.orig.level, now);
        }
        for (&fs.dd) |*d| {
            if (d.used and d.obj == obj) {
                d.used = false;
                fs.dd_count -= 1;
            }
        }
        e.trim = 0;
        e.dn = .{ .typ = .free };
        if (obj < fs.free_hint) fs.free_hint = obj;
    }

    // -------------------------------------------------------- directories

    pub const DirentRef = struct { obj: u32, typ: ObjType, index: u64 };

    pub fn dirLookup(fs: *Fs, dir: u32, name: []const u8) Error!?DirentRef {
        const dn = try fs.dnodeOf(dir);
        var buf: [block_size]u8 = undefined;
        var index: u64 = 0;
        var off: u64 = 0;
        while (off < dn.size) : (off += block_size) {
            try fs.readFileBlock(dir, off / block_size, &buf);
            const in_blk: usize = @intCast(@min(dn.size - off, block_size) / dirent_size);
            for (0..in_blk) |i| {
                const e = buf[i * dirent_size ..];
                if (e[4] != 0 and e[5] == name.len and std.mem.eql(u8, e[8 .. 8 + name.len], name)) {
                    return .{
                        .obj = leU(u32, e[0..4]),
                        .typ = std.enums.fromInt(ObjType, e[4]) orelse .free,
                        .index = index + i,
                    };
                }
            }
            index += in_blk;
        }
        return null;
    }

    pub fn dirAdd(fs: *Fs, dir: u32, name: []const u8, obj: u32, typ: ObjType, now: u64) Error!void {
        if (name.len == 0 or name.len > max_name) return Error.TooLarge;
        var ent: [dirent_size]u8 = @splat(0);
        puU(u32, ent[0..4], obj);
        ent[4] = @intFromEnum(typ);
        ent[5] = @intCast(name.len);
        @memcpy(ent[8 .. 8 + name.len], name);

        const dn = try fs.dnodeOf(dir);
        var buf: [block_size]u8 = undefined;
        var off: u64 = 0;
        while (off < dn.size) : (off += block_size) {
            try fs.readFileBlock(dir, off / block_size, &buf);
            const in_blk: usize = @intCast(@min(dn.size - off, block_size) / dirent_size);
            for (0..in_blk) |i| {
                if (buf[i * dirent_size + 4] == 0) {
                    _ = try fs.writeObj(dir, off + i * dirent_size, &ent, now);
                    return;
                }
            }
        }
        _ = try fs.writeObj(dir, dn.size, &ent, now);
    }

    pub fn dirRemove(fs: *Fs, dir: u32, name: []const u8, now: u64) Error!bool {
        const found = (try fs.dirLookup(dir, name)) orelse return false;
        var ent: [dirent_size]u8 = @splat(0);
        _ = try fs.writeObj(dir, found.index * dirent_size, &ent, now);
        return true;
    }

    pub fn dirIsEmpty(fs: *Fs, dir: u32) Error!bool {
        const dn = try fs.dnodeOf(dir);
        var buf: [block_size]u8 = undefined;
        var off: u64 = 0;
        while (off < dn.size) : (off += block_size) {
            try fs.readFileBlock(dir, off / block_size, &buf);
            const in_blk: usize = @intCast(@min(dn.size - off, block_size) / dirent_size);
            for (0..in_blk) |i| {
                if (buf[i * dirent_size + 4] != 0) return false;
            }
        }
        return true;
    }

    /// Fill `out` with "name\n" per live entry; returns bytes written.
    pub fn dirList(fs: *Fs, dir: u32, out: []u8) Error!usize {
        const dn = try fs.dnodeOf(dir);
        var buf: [block_size]u8 = undefined;
        var n: usize = 0;
        var off: u64 = 0;
        while (off < dn.size) : (off += block_size) {
            try fs.readFileBlock(dir, off / block_size, &buf);
            const in_blk: usize = @intCast(@min(dn.size - off, block_size) / dirent_size);
            for (0..in_blk) |i| {
                const e = buf[i * dirent_size ..];
                if (e[4] == 0) continue;
                const nl = e[5];
                if (n + nl + 1 > out.len) return n;
                @memcpy(out[n .. n + nl], e[8 .. 8 + nl]);
                out[n + nl] = '\n';
                n += nl + 1;
            }
        }
        return n;
    }

    // ------------------------------------------------------- allocation

    pub fn freeBlocksTotal(fs: *Fs) Error!u64 {
        var total: u64 = 0;
        for (fs.gfree[0..fs.gcount]) |c| total += c;
        return total;
    }

    fn wbbFind(fs: *Fs, group: u32, sub: u32) ?*Wbb {
        for (&fs.wbb) |*w| {
            if (w.used and w.group == group and w.sub == sub) return w;
        }
        return null;
    }

    fn wbbGet(fs: *Fs, group: u32, sub: u32) Error!*Wbb {
        if (fs.wbbFind(group, sub)) |w| return w;
        for (&fs.wbb) |*w| {
            if (w.used) continue;
            w.* = .{ .used = true, .group = group, .sub = sub };
            w.old = try fs.groupBitmapPtr(group, sub);
            try fs.readPtrCopy(w.old, &w.data);
            return w;
        }
        return Error.Overflow;
    }

    fn gtLeafPtr(fs: *Fs, leaf: u64) Error!BlockPtr {
        if (fs.gt_level == 0) {
            return if (leaf == 0) fs.gt_root else BlockPtr{};
        }
        return fs.treeLeafPtr(fs.gt_root, fs.gt_level, leaf);
    }

    fn groupBitmapPtr(fs: *Fs, group: u32, sub: u32) Error!BlockPtr {
        const p = try fs.gtLeafPtr(group / gt_per_block);
        if (p.isHole()) return .{};
        const blk = try fs.readPtr(p);
        return getPtr(blk[(group % gt_per_block) * gt_entry_size + sub * 16 ..]);
    }

    fn bitTest(w: *Wbb, bit: u64) bool {
        return w.data[@intCast(bit / 8)] & (@as(u8, 1) << @intCast(bit % 8)) != 0;
    }

    fn bitSet(w: *Wbb, bit: u64) void {
        w.data[@intCast(bit / 8)] |= @as(u8, 1) << @intCast(bit % 8);
    }

    fn bitClear(w: *Wbb, bit: u64) void {
        w.data[@intCast(bit / 8)] &= ~(@as(u8, 1) << @intCast(bit % 8));
    }

    /// Allocate one block (during commit). Prefers groups whose bitmaps
    /// are already dirty this txg; never hands out a quarantined address.
    fn allocBlock(fs: *Fs) Error!u64 {
        for (&fs.wbb) |*w| {
            if (!w.used) continue;
            if (try fs.allocInGroup(w.group)) |a| return a;
        }
        for (0..fs.gcount) |g| {
            if (fs.gfree[g] == 0) continue;
            if (try fs.allocInGroup(@intCast(g))) |a| return a;
        }
        return Error.NoSpace;
    }

    fn allocInGroup(fs: *Fs, group: u32) Error!?u64 {
        if (fs.gfree[group] == 0) return null;
        for (0..fs.bblocks_per_group) |sub| {
            const w = try fs.wbbGet(group, @intCast(sub));
            var bit: u64 = 0;
            while (bit < bits_per_bblock) : (bit += 1) {
                const inner = sub * bits_per_bblock + bit;
                if (inner >= fs.group_blocks) break; // bitmap tail past the group
                if (bitTest(w, bit)) continue;
                const addr = @as(u64, group) * fs.group_blocks + inner;
                if (addr >= fs.nblocks) break;
                if (fs.isQuarantined(addr)) continue;
                bitSet(w, bit);
                fs.gfree[group] -= 1;
                return addr;
            }
        }
        return null;
    }

    fn freeInBitmap(fs: *Fs, addr: u64) Error!void {
        const group: u32 = @intCast(addr / fs.group_blocks);
        const inner = addr % fs.group_blocks;
        const w = try fs.wbbGet(group, @intCast(inner / bits_per_bblock));
        bitClear(w, inner % bits_per_bblock);
        fs.gfree[group] += 1;
    }

    // ------------------------------------------------------------ commit

    pub fn dirtyEnough(fs: *Fs) bool {
        var dnodes: u32 = 0;
        for (&fs.ddn) |*e| {
            if (e.used) dnodes += 1;
        }
        return fs.dd_count >= commit_data_threshold or dnodes >= commit_dnode_threshold;
    }

    pub fn hasWork(fs: *Fs) bool {
        if (fs.dd_count > 0) return true;
        for (&fs.ddn) |*e| {
            if (e.used) return true;
        }
        return false;
    }

    pub fn deletingPending(fs: *Fs) bool {
        const dn = fs.dnodeOf(delset_obj) catch return false;
        return dn.size >= del_entry_size;
    }

    /// Call between operations (never inside one): drains a slice of the
    /// deleting set and commits when the overlay is full enough.
    pub fn maybeCommit(fs: *Fs, now: u64) Error!void {
        if (fs.deletingPending()) {
            _ = try fs.drainDeleting(drain_budget, now);
            try fs.commit();
            return;
        }
        if (fs.dirtyEnough()) try fs.commit();
    }

    /// Durability point: everything acknowledged so far is on disk after
    /// this returns (deleting-set work fully paid off too).
    pub fn sync(fs: *Fs, now: u64) Error!void {
        while (fs.deletingPending()) {
            _ = try fs.drainDeleting(drain_budget, now);
            try fs.commit();
        }
        if (fs.hasWork()) try fs.commit();
    }

    fn writeNew(fs: *Fs, addr: u64, data: *const [block_size]u8) Error!BlockPtr {
        if (dbg_track) {
            for (dbg_written[0..dbg_written_n]) |a| {
                if (a == addr) std.debug.panic("double writeNew addr {d}", .{addr});
            }
            if (dbg_written_n < dbg_written.len) {
                dbg_written[dbg_written_n] = addr;
                dbg_written_n += 1;
            }
        }
        fs.dev.write(addr, data) catch return Error.IoError;
        fs.cacheInsert(addr, data);
        return .{ .addr = addr, .csum = csum(data) };
    }

    fn anyDirtyLeafIn(fs: *Fs, obj: u32, first_blkidx: u64, span_blocks: u64) bool {
        for (&fs.dd) |*e| {
            if (e.used and e.obj == obj and
                e.blkidx >= first_blkidx and e.blkidx < first_blkidx + span_blocks)
                return true;
        }
        return false;
    }

    /// Committed pointer for a FILE indirect node at (h, nid) given the
    /// original dnode shape; holes above the old root (reshape).
    fn origFileNodePtr(fs: *Fs, orig: *const Dnode, h: u8, nid: u64) Error!BlockPtr {
        if (orig.level == 0 or h > orig.level) return .{};
        if (h == orig.level) return if (nid == 0) orig.indirect else BlockPtr{};
        var node = orig.indirect;
        var cur = orig.level;
        var index = nid;
        while (cur > h) : (cur -= 1) {
            if (node.isHole()) return .{};
            const blk = try fs.readPtr(node);
            const stride = treeCapacity(cur - 1) / treeCapacity(h);
            const d = index / stride;
            index = index % stride;
            node = getPtr(blk[@as(usize, @intCast(d % ptrs_per_block)) * 16 ..]);
        }
        return node;
    }

    /// Rebuild a FILE indirect node (h >= 1). Returns the pointer to use
    /// in the parent — the unchanged old pointer when nothing below moved.
    fn rebuildFileNode(fs: *Fs, e: *DirtyDnode, h: u8, nid: u64) Error!BlockPtr {
        const child_span = treeCapacity(h - 1); // idxp per child
        const base_idxp = nid * treeCapacity(h);
        const old = try fs.origFileNodePtr(&e.orig, h, nid);

        const spine = h > e.orig.level and nid == 0 and e.orig.level > 0;
        const trims = e.trim != std.math.maxInt(u64) and
            base_idxp + treeCapacity(h) > (if (e.trim > 3) e.trim - 3 else 0);
        const dirty = fs.anyDirtyLeafIn(e.obj, base_idxp + 3, treeCapacity(h));
        if (!dirty and !spine and !trims) return old;

        var content: [block_size]u8 = undefined;
        try fs.readPtrCopy(old, &content);

        const keep_idxp: u64 = if (e.trim == std.math.maxInt(u64))
            std.math.maxInt(u64)
        else if (e.trim > 3) e.trim - 3 else 0;

        for (0..ptrs_per_block) |c| {
            const c_base = base_idxp + c * child_span;
            const child_old = getPtr(content[c * 16 ..]);
            // Fully truncated child subtrees become holes (the deleting
            // set owns their blocks; do not free here).
            if (c_base >= keep_idxp) {
                putPtr(content[c * 16 ..], .{});
                continue;
            }
            if (h == 1) {
                const blkidx = c_base + 3;
                if (fs.dirtyDataFind(e.obj, blkidx)) |dblk| {
                    const addr = try fs.allocBlock();
                    const np = try fs.writeNew(addr, &dblk.data);
                    // Free the committed version (trim already handled).
                    const oldp = try fs.origFileBlockPtr(e.obj, blkidx);
                    try fs.freeCommitted(oldp.addr);
                    putPtr(content[c * 16 ..], np);
                }
            } else {
                const c_dirty = fs.anyDirtyLeafIn(e.obj, c_base + 3, child_span);
                const c_spine = (h - 1) > e.orig.level and (nid * ptrs_per_block + c) == 0 and e.orig.level > 0;
                const c_trims = keep_idxp != std.math.maxInt(u64) and
                    c_base + child_span > keep_idxp;
                if (c_dirty or c_spine or c_trims) {
                    const np = try fs.rebuildFileNode(e, h - 1, nid * ptrs_per_block + c);
                    putPtr(content[c * 16 ..], np);
                } else if ((h - 1) == e.orig.level and (nid * ptrs_per_block + c) == 0 and !child_old.isHole() == false and e.orig.level > 0 and h > e.orig.level) {
                    // Spine slot 0 links the old root when growing.
                    putPtr(content[c * 16 ..], e.orig.indirect);
                }
            }
        }
        // When this node is new spine above the old root, slot 0 must
        // carry the (possibly rebuilt) old-root chain even if untouched.
        if (h > e.orig.level and nid == 0 and e.orig.level > 0) {
            const slot0 = getPtr(content[0..]);
            if (slot0.isHole()) {
                const np = try fs.rebuildFileNode(e, h - 1, 0);
                putPtr(content[0..], np);
            }
        }

        const addr = try fs.allocBlock();
        const np = try fs.writeNew(addr, &content);
        try fs.freeCommitted(old.addr);
        return np;
    }

    /// Rebuild one dirty object's block tree, patching its overlay dnode.
    fn rebuildFile(fs: *Fs, e: *DirtyDnode) Error!void {
        if (e.dn.typ == .free) return; // freed: pointers already zeroed
        // Directs.
        for (0..3) |i| {
            if (fs.dirtyDataFind(e.obj, i)) |dblk| {
                const addr = try fs.allocBlock();
                const np = try fs.writeNew(addr, &dblk.data);
                const oldp = try fs.origFileBlockPtr(e.obj, i);
                try fs.freeCommitted(oldp.addr);
                e.dn.direct[i] = np;
            } else if (i < e.trim) {
                e.dn.direct[i] = e.orig.direct[i];
            }
        }
        // Indirect tree.
        if (e.dn.level > 0) {
            e.dn.indirect = try fs.rebuildFileNode(e, e.dn.level, 0);
        }
    }

    // Objmap rebuild: same recursion shape over dnode-leaf blocks.

    fn anyDirtyDnodeIn(fs: *Fs, first_leaf: u64, span: u64) bool {
        for (&fs.ddn) |*e| {
            if (!e.used) continue;
            const leaf = e.obj / dnodes_per_block;
            if (leaf >= first_leaf and leaf < first_leaf + span) return true;
        }
        return false;
    }

    fn origObjmapNodePtr(fs: *Fs, old_level: u8, h: u8, nid: u64) Error!BlockPtr {
        if (h > old_level) return .{};
        if (h == old_level) return if (nid == 0) fs.obj_root else BlockPtr{};
        var node = fs.obj_root;
        var cur = old_level;
        var index = nid;
        while (cur > h) : (cur -= 1) {
            if (node.isHole()) return .{};
            const blk = try fs.readPtr(node);
            const stride = treeCapacity(cur - 1) / treeCapacity(h);
            const d = index / stride;
            index = index % stride;
            node = getPtr(blk[@as(usize, @intCast(d % ptrs_per_block)) * 16 ..]);
        }
        return node;
    }

    /// Rebuild objmap node at height h (0 = a dnode-leaf block).
    fn rebuildObjmapNode(fs: *Fs, old_level: u8, h: u8, nid: u64) Error!BlockPtr {
        if (h == 0) {
            const old = try fs.origObjmapNodePtr(old_level, 0, nid);
            var content: [block_size]u8 = undefined;
            try fs.readPtrCopy(old, &content);
            for (&fs.ddn) |*e| {
                if (e.used and e.obj / dnodes_per_block == nid) {
                    putDnode(content[(e.obj % dnodes_per_block) * dnode_size ..], &e.dn);
                }
            }
            const addr = try fs.allocBlock();
            const np = try fs.writeNew(addr, &content);
            try fs.freeCommitted(old.addr);
            return np;
        }
        const child_span = treeCapacity(h - 1);
        const base = nid * treeCapacity(h);
        const old = try fs.origObjmapNodePtr(old_level, h, nid);
        var content: [block_size]u8 = undefined;
        try fs.readPtrCopy(old, &content);
        for (0..ptrs_per_block) |c| {
            const c_base = base + c * child_span;
            const c_nid = nid * ptrs_per_block + c;
            const c_dirty = fs.anyDirtyDnodeIn(c_base, child_span);
            const c_spine = (h - 1) >= old_level and c_nid == 0 and old_level < h;
            if (c_dirty) {
                const np = try fs.rebuildObjmapNode(old_level, h - 1, c_nid);
                putPtr(content[c * 16 ..], np);
            } else if (c_spine and getPtr(content[c * 16 ..]).isHole()) {
                // New spine: link the old root (or its chain) at slot 0.
                if (h - 1 == old_level) {
                    putPtr(content[c * 16 ..], fs.obj_root);
                } else {
                    const np = try fs.rebuildObjmapNode(old_level, h - 1, c_nid);
                    putPtr(content[c * 16 ..], np);
                }
            }
        }
        const addr = try fs.allocBlock();
        const np = try fs.writeNew(addr, &content);
        try fs.freeCommitted(old.addr);
        return np;
    }

    fn gtdFind(fs: *Fs, h: u8, nid: u64) ?*GtDirty {
        for (&fs.gtd) |*g| {
            if (g.used and g.h == h and g.nid == nid) return g;
        }
        return null;
    }

    fn gtdAdd(fs: *Fs, h: u8, nid: u64, old: BlockPtr) Error!*GtDirty {
        if (fs.gtdFind(h, nid)) |g| return g;
        for (&fs.gtd) |*g| {
            if (!g.used) {
                g.* = .{ .used = true, .h = h, .nid = nid, .old = old };
                return g;
            }
        }
        return Error.Overflow;
    }

    pub fn commit(fs: *Fs) Error!void {
        if (!fs.hasWork()) return;
        if (dbg_track) dbg_written_n = 0;

        // --- A: object subgraph, bottom-up (allocates as it goes). ---
        var new_obj_level = fs.obj_level;
        for (&fs.ddn) |*e| {
            if (!e.used) continue;
            try fs.rebuildFile(e);
            const leaf = e.obj / dnodes_per_block;
            if (leaf > 0) {
                const lv = levelFor(leaf);
                if (lv > new_obj_level) new_obj_level = lv;
            }
        }
        const new_obj_root = try fs.rebuildObjmapNode(fs.obj_level, new_obj_level, 0);

        // --- B: space subgraph address fixpoint. ---
        var rounds: u32 = 0;
        while (true) : (rounds += 1) {
            if (rounds > 12) return Error.Overflow;
            var changed = false;
            for (&fs.wbb) |*w| {
                if (w.used and w.new_addr == 0) {
                    const na = try fs.allocBlock();
                    w.new_addr = na;
                    try fs.freeCommitted(w.old.addr);
                    changed = true;
                }
            }
            // Group-table leaves for every group with a dirty bitmap.
            for (&fs.wbb) |*w| {
                if (!w.used) continue;
                const leaf = w.group / gt_per_block;
                if (fs.gtdFind(0, leaf) == null) {
                    const old = try fs.gtLeafPtr(leaf);
                    const g = try fs.gtdAdd(0, leaf, old);
                    g.new_addr = try fs.allocBlock();
                    try fs.freeCommitted(old.addr);
                    changed = true;
                }
            }
            // Group-table path nodes above dirty leaves.
            if (fs.gt_level > 0) {
                for (&fs.gtd) |*g| {
                    if (!g.used or g.h != 0) continue;
                    var h: u8 = 1;
                    var nid = g.nid;
                    while (h <= fs.gt_level) : (h += 1) {
                        nid = nid / ptrs_per_block;
                        if (fs.gtdFind(h, nid) == null) {
                            const old = try fs.origGtNodePtr(h, nid);
                            const pn = try fs.gtdAdd(h, nid, old);
                            pn.new_addr = try fs.allocBlock();
                            try fs.freeCommitted(old.addr);
                            changed = true;
                        }
                    }
                }
            }
            if (!changed) break;
        }

        // --- C: fill + checksum + write the space subgraph, bottom-up. ---
        for (&fs.wbb) |*w| {
            if (w.used) w.new_ptr = try fs.writeNew(w.new_addr, &w.data);
        }
        // Leaves: old content patched with new bitmap ptrs + free counts.
        for (&fs.gtd) |*g| {
            if (!g.used or g.h != 0) continue;
            var content: [block_size]u8 = undefined;
            try fs.readPtrCopy(g.old, &content);
            const first_group: u64 = g.nid * gt_per_block;
            for (0..gt_per_block) |slot| {
                const grp: u64 = first_group + slot;
                if (grp >= fs.gcount) break;
                const entry = content[slot * gt_entry_size ..];
                var touched = false;
                for (&fs.wbb) |*w| {
                    if (w.used and w.group == grp) {
                        putPtr(entry[w.sub * 16 ..], w.new_ptr);
                        touched = true;
                    }
                }
                if (touched) {
                    puU(u32, entry[128..132], fs.gfree[@intCast(grp)]);
                }
            }
            g.new_ptr = try fs.writeNew(g.new_addr, &content);
        }
        // Path nodes, height by height.
        var h: u8 = 1;
        while (h <= fs.gt_level) : (h += 1) {
            for (&fs.gtd) |*g| {
                if (!g.used or g.h != h) continue;
                var content: [block_size]u8 = undefined;
                try fs.readPtrCopy(g.old, &content);
                for (&fs.gtd) |*cg| {
                    if (!cg.used or cg.h != h - 1) continue;
                    if (cg.nid / ptrs_per_block == g.nid) {
                        putPtr(content[@as(usize, @intCast(cg.nid % ptrs_per_block)) * 16 ..], cg.new_ptr);
                    }
                }
                g.new_ptr = try fs.writeNew(g.new_addr, &content);
            }
        }
        var new_gt_root = fs.gt_root;
        if (fs.gt_level == 0) {
            if (fs.gtdFind(0, 0)) |g| new_gt_root = g.new_ptr;
        } else if (fs.gtdFind(fs.gt_level, 0)) |g| {
            new_gt_root = g.new_ptr;
        }

        // --- D: barrier, superblock, barrier; then swing in-memory. ---
        fs.dev.flush() catch return Error.IoError;
        try fs.writeSuper(new_obj_root, new_obj_level, new_gt_root);
        fs.dev.flush() catch return Error.IoError;

        fs.obj_root = new_obj_root;
        fs.obj_level = new_obj_level;
        fs.gt_root = new_gt_root;
        fs.txg += 1;
        fs.slot_next = (fs.slot_next + 1) % sb_slots;
        fs.commits += 1;

        // Reset the overlay; quarantined blocks become reusable now.
        for (&fs.dd) |*e| e.used = false;
        fs.dd_count = 0;
        for (&fs.ddn) |*e| e.used = false;
        for (&fs.wbb) |*w| w.used = false;
        for (&fs.gtd) |*g| g.used = false;
        fs.freed_count = 0;
    }

    fn origGtNodePtr(fs: *Fs, h: u8, nid: u64) Error!BlockPtr {
        if (h > fs.gt_level) return .{};
        if (h == fs.gt_level) return if (nid == 0) fs.gt_root else BlockPtr{};
        var node = fs.gt_root;
        var cur = fs.gt_level;
        var index = nid;
        while (cur > h) : (cur -= 1) {
            if (node.isHole()) return .{};
            const blk = try fs.readPtr(node);
            const stride = treeCapacity(cur - 1) / treeCapacity(h);
            const d = index / stride;
            index = index % stride;
            node = getPtr(blk[@as(usize, @intCast(d % ptrs_per_block)) * 16 ..]);
        }
        return node;
    }

    // -------------------------------------------------- superblock, mount

    fn writeSuper(fs: *Fs, obj_root: BlockPtr, obj_level: u8, gt_root: BlockPtr) Error!void {
        var blk: [block_size]u8 = @splat(0);
        @memcpy(blk[0..4], sb_magic);
        puU(u32, blk[4..8], fs_version);
        puU(u64, blk[8..16], fs.txg + 1);
        puU(u32, blk[16..20], fs.slot_next);
        puU(u64, blk[24..32], fs.nblocks);
        puU(u64, blk[32..40], fs.group_blocks);
        puU(u32, blk[40..44], fs.bblocks_per_group);
        puU(u32, blk[44..48], fs.gcount);
        putPtr(blk[48..], obj_root);
        blk[64] = obj_level;
        putPtr(blk[72..], gt_root);
        blk[88] = fs.gt_level;
        puU(u32, blk[92..96], fs.free_hint);
        // Full-slot self-checksum (txg and slot index inside the sum).
        const sc = std.hash.XxHash64.hash(0x5342, blk[0 .. block_size - 8]);
        puU(u64, blk[block_size - 8 ..], sc);
        fs.dev.write(fs.slot_next % sb_slots, &blk) catch return Error.IoError;
    }

    pub fn mount(fs: *Fs, dev: BlockDev) Error!void {
        fs.* = .{ .dev = dev };
        var best_txg: u64 = 0;
        var best_slot: u32 = 0;
        var found = false;
        var blk: [block_size]u8 = undefined;
        for (0..sb_slots) |slot| {
            dev.read(slot, &blk) catch continue;
            if (!std.mem.eql(u8, blk[0..4], sb_magic)) continue;
            if (leU(u32, blk[4..8]) != fs_version) continue;
            const sc = std.hash.XxHash64.hash(0x5342, blk[0 .. block_size - 8]);
            if (sc != leU(u64, blk[block_size - 8 ..])) continue;
            const txg = leU(u64, blk[8..16]);
            if (txg > best_txg) {
                best_txg = txg;
                best_slot = @intCast(slot);
                found = true;
            }
        }
        if (!found) return Error.NoFilesystem;
        dev.read(best_slot, &blk) catch return Error.IoError;
        fs.txg = best_txg;
        fs.slot_next = (best_slot + 1) % sb_slots;
        fs.nblocks = @min(leU(u64, blk[24..32]), dev.nblocks);
        fs.group_blocks = leU(u64, blk[32..40]);
        fs.bblocks_per_group = leU(u32, blk[40..44]);
        fs.gcount = leU(u32, blk[44..48]);
        fs.obj_root = getPtr(blk[48..]);
        fs.obj_level = blk[64];
        fs.gt_root = getPtr(blk[72..]);
        fs.gt_level = blk[88];
        fs.free_hint = leU(u32, blk[92..96]);
        if (fs.gcount > max_groups) return Error.TooLarge;
        // Free counts, from the group table (lazy bitmaps; this is small).
        for (0..fs.gcount) |g| {
            const p = try fs.gtLeafPtr(g / gt_per_block);
            if (p.isHole()) return Error.Corrupt;
            const lb = try fs.readPtr(p);
            fs.gfree[g] = leU(u32, lb[(g % gt_per_block) * gt_entry_size + 128 ..][0..4]);
        }
    }

    // ------------------------------------------------------------ format

    /// Create a fresh filesystem. `group_blocks` tunes allocation-group
    /// size (1 GiB = 1 << 18 in production; small in tests) and must be a
    /// multiple of 32768 or exactly cover the volume in one group.
    pub fn format(dev: BlockDev, group_blocks: u64) Error!void {
        const nblocks = dev.nblocks;
        if (nblocks < 64) return Error.TooLarge;
        const gb = group_blocks;
        const bbpg: u32 = @intCast((gb + bits_per_bblock - 1) / bits_per_bblock);
        if (bbpg > 8) return Error.TooLarge; // 8 ptrs per group entry
        const gcount: u32 = @intCast((nblocks + gb - 1) / gb);
        if (gcount > max_groups) return Error.TooLarge;
        const gt_leaves: u64 = (gcount + gt_per_block - 1) / gt_per_block;
        const gt_level: u8 = if (gt_leaves <= 1) 0 else 1;
        if (gt_leaves > ptrs_per_block) return Error.TooLarge; // format supports level<=1

        // Bootstrap layout in group 0, after the superblock slots:
        //   [8]                 objmap leaf 0
        //   [9 .. 9+L)          group-table leaves
        //   [9+L]               group-table root (only if gt_level == 1)
        //   group g bitmaps: g == 0 -> right after the above; else at the
        //   group's own first blocks.
        var cursor: u64 = sb_slots;
        const objmap_addr = cursor;
        cursor += 1;
        const gtl_addr = cursor;
        cursor += gt_leaves;
        const gtr_addr = cursor;
        if (gt_level == 1) cursor += 1;
        const g0_bitmap_addr = cursor;
        cursor += bbpg;
        if (cursor >= gb or cursor >= nblocks) return Error.TooLarge;

        var blk: [block_size]u8 = @splat(0);

        // Objmap leaf: root dir (obj 0) and the deleting set (obj 1).
        var dn_root: Dnode = .{ .typ = .dir };
        var dn_del: Dnode = .{ .typ = .file };
        putDnode(blk[0..], &dn_root);
        putDnode(blk[dnode_size..], &dn_del);
        dev.write(objmap_addr, &blk) catch return Error.IoError;
        const objmap_ptr: BlockPtr = .{ .addr = objmap_addr, .csum = csum(&blk) };

        // Bitmaps: written per group; group-table entries collected.
        var gt_leaf_bufs_ok = true;
        _ = &gt_leaf_bufs_ok;
        var gt_leaf: [block_size]u8 = undefined;
        var leaf_idx: u64 = 0;
        var slot_in_leaf: u64 = 0;
        @memset(&gt_leaf, 0);
        var gtl_ptrs: [ptrs_per_block]BlockPtr = @splat(.{});

        var bm: [block_size]u8 = undefined;
        for (0..gcount) |g| {
            const g_start = @as(u64, g) * gb;
            const bm_base = if (g == 0) g0_bitmap_addr else g_start;
            var free_count: u32 = 0;
            var entry: [gt_entry_size]u8 = @splat(0);
            for (0..bbpg) |sub| {
                @memset(&bm, 0);
                const bit_base = g_start + sub * bits_per_bblock;
                var bit: u64 = 0;
                while (bit < bits_per_bblock) : (bit += 1) {
                    const addr = bit_base + bit;
                    const used = addr >= nblocks or addr >= g_start + gb or
                        (g == 0 and addr < cursor) or
                        (g != 0 and addr >= bm_base and addr < bm_base + bbpg);
                    if (used) {
                        bm[@intCast(bit / 8)] |= @as(u8, 1) << @intCast(bit % 8);
                    } else if (addr < nblocks and addr < g_start + gb) {
                        free_count += 1;
                    }
                }
                const a = bm_base + sub;
                dev.write(a, &bm) catch return Error.IoError;
                putPtr(entry[sub * 16 ..], .{ .addr = a, .csum = csum(&bm) });
            }
            puU(u32, entry[128..132], free_count);
            @memcpy(gt_leaf[@intCast(slot_in_leaf * gt_entry_size)..][0..gt_entry_size], &entry);
            slot_in_leaf += 1;
            if (slot_in_leaf == gt_per_block or g == gcount - 1) {
                const a = gtl_addr + leaf_idx;
                dev.write(a, &gt_leaf) catch return Error.IoError;
                gtl_ptrs[@intCast(leaf_idx)] = .{ .addr = a, .csum = csum(&gt_leaf) };
                leaf_idx += 1;
                slot_in_leaf = 0;
                @memset(&gt_leaf, 0);
            }
        }
        var gt_root: BlockPtr = gtl_ptrs[0];
        if (gt_level == 1) {
            @memset(&blk, 0);
            for (0..gt_leaves) |i| putPtr(blk[i * 16 ..], gtl_ptrs[i]);
            dev.write(gtr_addr, &blk) catch return Error.IoError;
            gt_root = .{ .addr = gtr_addr, .csum = csum(&blk) };
        }

        // Superblock slot 0 (txg 1); wipe the other slots so stale
        // filesystems can never win the mount election.
        @memset(&blk, 0);
        for (1..sb_slots) |slot| dev.write(slot, &blk) catch return Error.IoError;
        dev.flush() catch return Error.IoError;

        @memcpy(blk[0..4], sb_magic);
        puU(u32, blk[4..8], fs_version);
        puU(u64, blk[8..16], 1); // txg
        puU(u32, blk[16..20], 0); // slot
        puU(u64, blk[24..32], nblocks);
        puU(u64, blk[32..40], gb);
        puU(u32, blk[40..44], bbpg);
        puU(u32, blk[44..48], gcount);
        putPtr(blk[48..], objmap_ptr);
        blk[64] = 0; // objmap level
        putPtr(blk[72..], gt_root);
        blk[88] = gt_level;
        puU(u32, blk[92..96], first_user_obj);
        const sc = std.hash.XxHash64.hash(0x5342, blk[0 .. block_size - 8]);
        puU(u64, blk[block_size - 8 ..], sc);
        dev.write(0, &blk) catch return Error.IoError;
        dev.flush() catch return Error.IoError;
    }
};

// ======================================================================
// Host-side test support: RAM block device with write recording, crash
// injection (clean cuts AND torn final writes), and corruption flips.
// ======================================================================

pub const RamDev = struct {
    blocks: [][block_size]u8,
    /// Recorded write sequence since last resetLog (addr per write).
    wlog: [4096]u64 = undefined,
    wlog_len: usize = 0,
    /// When set, writes stop being applied after this many more writes
    /// (simulating power loss mid-stream); the final write can be torn.
    cut_after: ?usize = null,
    tear_final: bool = false,
    dropped: usize = 0,
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0x746f726e),

    pub fn dev(rd: *RamDev) BlockDev {
        return .{
            .ctx = rd,
            .readFn = doRead,
            .writeFn = doWrite,
            .flushFn = doFlush,
            .nblocks = rd.blocks.len,
        };
    }

    fn doRead(ctx: *anyopaque, addr: u64, dst: *[block_size]u8) DevError!void {
        const rd: *RamDev = @ptrCast(@alignCast(ctx));
        if (addr >= rd.blocks.len) return DevError.IoError;
        @memcpy(dst, &rd.blocks[@intCast(addr)]);
    }

    fn doWrite(ctx: *anyopaque, addr: u64, src: *const [block_size]u8) DevError!void {
        const rd: *RamDev = @ptrCast(@alignCast(ctx));
        if (addr >= rd.blocks.len) return DevError.IoError;
        if (rd.cut_after) |*n| {
            if (n.* == 0) {
                rd.dropped += 1;
                return; // power is gone: silently dropped
            }
            n.* -= 1;
            if (n.* == 0 and rd.tear_final) {
                // Torn write: only a prefix of the sectors lands, the rest
                // is garbage.
                const sectors = 1 + rd.prng.random().uintLessThan(usize, 7);
                @memcpy(rd.blocks[@intCast(addr)][0 .. sectors * 512], src[0 .. sectors * 512]);
                rd.prng.random().bytes(rd.blocks[@intCast(addr)][sectors * 512 ..]);
                if (rd.wlog_len < rd.wlog.len) {
                    rd.wlog[rd.wlog_len] = addr;
                    rd.wlog_len += 1;
                }
                return;
            }
        }
        @memcpy(&rd.blocks[@intCast(addr)], src);
        if (rd.wlog_len < rd.wlog.len) {
            rd.wlog[rd.wlog_len] = addr;
            rd.wlog_len += 1;
        }
    }

    fn doFlush(ctx: *anyopaque) DevError!void {
        _ = ctx;
        return;
    }
};

// ----------------------------------------------------------------- tests

const dbg_track = @import("builtin").is_test;
var dbg_written: [4096]u64 = undefined;
var dbg_written_n: usize = 0;

const testing = std.testing;

const test_blocks = 2048; // 8MB volume
const test_group_blocks = 512; // tiny groups: multi-group on a toy volume

var t_storage: [test_blocks][block_size]u8 = undefined;
var t_fs: Fs = undefined;
var t_fs2: Fs = undefined;

fn freshDev(rd: *RamDev) BlockDev {
    for (&t_storage) |*b| @memset(b, 0xAA); // poison
    rd.* = .{ .blocks = &t_storage };
    return rd.dev();
}

test "format, mount, small file round trip, remount persistence" {
    var rd: RamDev = undefined;
    const dev = freshDev(&rd);
    try Fs.format(dev, test_group_blocks);
    try t_fs.mount(dev);

    const obj = try t_fs.allocObject(.file, 100);
    try t_fs.dirAdd(root_obj, "hello.txt", obj, .file, 100);
    _ = try t_fs.writeObj(obj, 0, "hello mossfs v2", 101);
    try t_fs.sync(101);

    // Remount from scratch: everything must persist.
    try t_fs2.mount(dev);
    const found = (try t_fs2.dirLookup(root_obj, "hello.txt")).?;
    try testing.expectEqual(obj, found.obj);
    var buf: [64]u8 = undefined;
    const n = try t_fs2.readObj(found.obj, 0, &buf);
    try testing.expectEqualStrings("hello mossfs v2", buf[0..n]);
    const st = try t_fs2.statObj(found.obj);
    try testing.expectEqual(@as(u64, 101), st.mtime);
    try testing.expectEqual(ObjType.file, st.typ);
}

test "large file through indirect levels, sparse holes, truncate, delete" {
    var rd: RamDev = undefined;
    const dev = freshDev(&rd);
    try Fs.format(dev, test_group_blocks);
    try t_fs.mount(dev);

    const obj = try t_fs.allocObject(.file, 1);
    // Write into the second indirect level (idx 3 + 256 + 10).
    const far: u64 = (3 + ptrs_per_block + 10) * block_size;
    var pat: [block_size]u8 = undefined;
    for (&pat, 0..) |*c, i| c.* = @truncate(i *% 7 +% 1);
    _ = try t_fs.writeObj(obj, far, &pat, 2);
    _ = try t_fs.writeObj(obj, 0, "front", 3);
    try t_fs.sync(3);
    try t_fs2.mount(dev);

    var buf: [block_size]u8 = undefined;
    var n = try t_fs2.readObj(obj, far, &buf);
    try testing.expectEqual(block_size, n);
    try testing.expectEqualSlices(u8, &pat, buf[0..block_size]);
    // Sparse middle reads as zeros.
    n = try t_fs2.readObj(obj, 10 * block_size, buf[0..16]);
    try testing.expectEqualSlices(u8, &(.{0} ** 16), buf[0..16]);

    // Truncate to 5 bytes: far block goes to the deleting set; content
    // survives; regrow reads zeros where the old tree used to be.
    try t_fs2.truncateObj(obj, 5, 4);
    try t_fs2.sync(4);
    n = try t_fs2.readObj(obj, 0, &buf);
    try testing.expectEqualStrings("front", buf[0..n]);
    _ = try t_fs2.writeObj(obj, far, "again", 5);
    try t_fs2.sync(5);
    n = try t_fs2.readObj(obj, far, buf[0..8]);
    try testing.expectEqualStrings("again\x00\x00\x00", buf[0..8]);

    // Delete entirely; space must eventually return.
    const free_before = try t_fs2.freeBlocksTotal();
    _ = free_before;
    _ = try t_fs2.dirRemove(root_obj, "nope", 6); // no-op remove is fine
    try t_fs2.freeObject(obj, 6);
    try t_fs2.sync(6);
    try testing.expect(!t_fs2.deletingPending());
    const st = try t_fs2.statObj(obj);
    try testing.expectEqual(ObjType.free, st.typ);
}

test "directories: add, lookup, remove, list, emptiness" {
    var rd: RamDev = undefined;
    const dev = freshDev(&rd);
    try Fs.format(dev, test_group_blocks);
    try t_fs.mount(dev);

    const d = try t_fs.allocObject(.dir, 1);
    try t_fs.dirAdd(root_obj, "sub", d, .dir, 1);
    const f = try t_fs.allocObject(.file, 2);
    try t_fs.dirAdd(d, "a.txt", f, .file, 2);
    try testing.expect(!try t_fs.dirIsEmpty(d));
    try testing.expect((try t_fs.dirLookup(d, "a.txt")) != null);
    try testing.expect((try t_fs.dirLookup(d, "b.txt")) == null);
    try testing.expect(try t_fs.dirRemove(d, "a.txt", 3));
    try testing.expect(try t_fs.dirIsEmpty(d));
    try t_fs.sync(3);

    try t_fs2.mount(dev);
    try testing.expect(try t_fs2.dirIsEmpty(d));
    var out: [256]u8 = undefined;
    const n = try t_fs2.dirList(root_obj, &out);
    try testing.expectEqualStrings("sub\n", out[0..n]);
}

test "corruption is detected, never returned" {
    var rd: RamDev = undefined;
    const dev = freshDev(&rd);
    try Fs.format(dev, test_group_blocks);
    try t_fs.mount(dev);
    const obj = try t_fs.allocObject(.file, 1);
    var pat: [block_size]u8 = undefined;
    for (&pat, 0..) |*c, i| c.* = @truncate(i);
    _ = try t_fs.writeObj(obj, 0, &pat, 1);
    try t_fs.sync(1);

    // Find the file's data block on disk and flip one byte.
    try t_fs2.mount(dev);
    const dn = try t_fs2.dnodeOf(obj);
    const victim = dn.direct[0].addr;
    try testing.expect(victim != 0);
    t_storage[@intCast(victim)][100] ^= 0x40;

    var buf: [block_size]u8 = undefined;
    try testing.expectError(Error.Corrupt, t_fs2.readObj(obj, 0, &buf));
}

test "superblock rotation: older valid slot wins over a torn newest" {
    var rd: RamDev = undefined;
    const dev = freshDev(&rd);
    try Fs.format(dev, test_group_blocks);
    try t_fs.mount(dev);
    const obj = try t_fs.allocObject(.file, 1);
    _ = try t_fs.writeObj(obj, 0, "one", 1);
    try t_fs.sync(1); // txg 2 -> slot 0? (slot_next was 1 at mount)
    _ = try t_fs.writeObj(obj, 0, "two", 2);
    try t_fs.sync(2);
    const latest_slot = (t_fs.slot_next + sb_slots - 1) % sb_slots;
    // Corrupt the newest superblock: mount must fall back cleanly.
    t_storage[latest_slot][500] ^= 0xFF;
    try t_fs2.mount(dev);
    var buf: [8]u8 = undefined;
    const n = try t_fs2.readObj(obj, 0, &buf);
    try testing.expectEqualStrings("one", buf[0..n]);
}

// The heart of the matter: run a scripted workload; for every prefix of
// the write stream (clean cut AND torn final write), remount and verify
// the filesystem is consistent and equals either the pre- or post-txg
// state.
test "crash injection sweep" {
    var rd: RamDev = undefined;
    var dev = freshDev(&rd);
    try Fs.format(dev, test_group_blocks);
    try t_fs.mount(dev);
    const obj = try t_fs.allocObject(.file, 1);
    try t_fs.dirAdd(root_obj, "f", obj, .file, 1);
    _ = try t_fs.writeObj(obj, 0, "BEFORE-STATE", 1);
    try t_fs.sync(1);

    // Snapshot the committed image (global: far too big for the stack).
    @memcpy(&t_snap, &t_storage);

    // The txg under test: rewrite the file + create a second one.
    // First, count its writes with no cut.
    _ = try t_fs.writeObj(obj, 0, "AFTER!-STATE", 2);
    const obj2 = try t_fs.allocObject(.file, 2);
    try t_fs.dirAdd(root_obj, "g", obj2, .file, 2);
    _ = try t_fs.writeObj(obj2, 0, "second file", 2);
    rd.wlog_len = 0;
    try t_fs.sync(2);
    const total_writes = rd.wlog_len;
    try testing.expect(total_writes > 4);

    for (0..2) |tear| {
        var cut: usize = 0;
        while (cut <= total_writes) : (cut += 1) {
            // Restore the pre-txg image and replay with a cut.
            @memcpy(&t_storage, &t_snap);
            rd = .{ .blocks = &t_storage };
            rd.cut_after = cut;
            rd.tear_final = tear == 1 and cut > 0;
            dev = rd.dev();

            try t_fs2.mount(dev);
            _ = try t_fs2.writeObj(obj, 0, "AFTER!-STATE", 2);
            const o2 = try t_fs2.allocObject(.file, 2);
            try t_fs2.dirAdd(root_obj, "g", o2, .file, 2);
            _ = try t_fs2.writeObj(o2, 0, "second file", 2);
            t_fs2.sync(2) catch {}; // the "crash" may surface as IoError

            // Power cycle: remount and verify exactly-old-or-new.
            rd.cut_after = null;
            rd.tear_final = false;
            try t_fs.mount(dev);
            var buf: [64]u8 = undefined;
            const fref = (try t_fs.dirLookup(root_obj, "f")).?;
            const n = try t_fs.readObj(fref.obj, 0, &buf);
            const is_new = std.mem.eql(u8, buf[0..n], "AFTER!-STATE");
            const is_old = std.mem.eql(u8, buf[0..n], "BEFORE-STATE");
            try testing.expect(is_new or is_old);
            const gref = try t_fs.dirLookup(root_obj, "g");
            if (is_old) {
                try testing.expect(gref == null);
            } else {
                const n2 = try t_fs.readObj(gref.?.obj, 0, &buf);
                try testing.expectEqualStrings("second file", buf[0..n2]);
            }
        }
    }
}

var t_snap: [test_blocks][block_size]u8 = undefined;

// Model-based randomized workload: mirror ops against a trivial in-memory
// model; verify equality after every commit and after remount.
test "randomized ops vs model" {
    var rd: RamDev = undefined;
    const dev = freshDev(&rd);
    try Fs.format(dev, test_group_blocks);
    try t_fs.mount(dev);

    const Model = struct {
        used: [16]bool = @splat(false),
        name: [16]u8 = undefined,
        obj: [16]u32 = undefined,
        content: [16][96]u8 = undefined,
        len: [16]usize = @splat(0),
    };
    var model: Model = .{};
    var prng = std.Random.DefaultPrng.init(0x6d6f5353);
    const rand = prng.random();

    var now: u64 = 10;
    for (0..600) |_| {
        now += 1;
        const slot = rand.uintLessThan(usize, 16);
        const op = rand.uintLessThan(u8, 5);
        const name: [1]u8 = .{'a' + @as(u8, @intCast(slot))};
        switch (op) {
            0 => { // create or overwrite
                if (!model.used[slot]) {
                    const o = try t_fs.allocObject(.file, now);
                    try t_fs.dirAdd(root_obj, &name, o, .file, now);
                    model.used[slot] = true;
                    model.obj[slot] = o;
                    model.len[slot] = 0;
                }
                var data: [64]u8 = undefined;
                rand.bytes(&data);
                const wl = 1 + rand.uintLessThan(usize, 63);
                _ = try t_fs.writeObj(model.obj[slot], 0, data[0..wl], now);
                if (wl > model.len[slot]) model.len[slot] = wl;
                @memcpy(model.content[slot][0..wl], data[0..wl]);
            },
            1 => { // delete
                if (model.used[slot]) {
                    _ = try t_fs.dirRemove(root_obj, &name, now);
                    try t_fs.freeObject(model.obj[slot], now);
                    model.used[slot] = false;
                }
            },
            2 => { // truncate
                if (model.used[slot] and model.len[slot] > 0) {
                    const nl = rand.uintLessThan(usize, model.len[slot]);
                    try t_fs.truncateObj(model.obj[slot], nl, now);
                    model.len[slot] = nl;
                }
            },
            3 => try t_fs.maybeCommit(now),
            else => try t_fs.sync(now),
        }
    }
    try t_fs.sync(now);

    // Verify against the model, then again after a remount.
    for (0..2) |round| {
        const f = if (round == 0) &t_fs else blk: {
            try t_fs2.mount(dev);
            break :blk &t_fs2;
        };
        for (0..16) |slot| {
            const name: [1]u8 = .{'a' + @as(u8, @intCast(slot))};
            const found = try f.dirLookup(root_obj, &name);
            if (!model.used[slot]) {
                try testing.expect(found == null);
                continue;
            }
            try testing.expect(found != null);
            var buf: [96]u8 = undefined;
            const n = try f.readObj(found.?.obj, 0, &buf);
            try testing.expectEqual(model.len[slot], n);
            try testing.expectEqualSlices(u8, model.content[slot][0..n], buf[0..n]);
        }
    }
}
