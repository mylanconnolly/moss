//! mossfs v3 — a copy-on-write, checksummed, crash-consistent filesystem
//! with per-block compression (LZ4) and FS-native encryption (AES-256-XTS).
//!
//! PURE library: std-only plus the moss static lib modules (lz4, xts),
//! driven through a sector-run BlockDev vtable — the same code runs in
//! fssvc over virtio-blk and in host unit tests over a RAM device, where
//! the crash-injection harness cuts the write stream at every point and
//! proves consistency.
//!
//! Design (see DESIGN.md):
//! - Never update in place. All state hangs off a superblock through
//!   checksummed BlockPtrs; every read verifies before anything else runs,
//!   so the tree is self-validating and torn/misdirected writes are
//!   detected. 8 rotating superblock slots (sectors 0..63); mount picks
//!   the highest txg whose full-slot checksum verifies. No fsck, ever.
//! - The logical unit is a 4K block; the physical unit is a 512B sector.
//!   A BlockPtr packs [flags u8 | psize u8 | sector u48] + an 8-byte
//!   csum/MAC. Data blocks are LZ4-compressed when that saves at least a
//!   sector (psize < 8); metadata is always a full 8-sector run. The
//!   stored form is what the csum covers, so verification precedes the
//!   (bounds-checked, output-driven) decoder.
//! - Encryption is per-block: object data, indirect blocks, and the objmap
//!   are AES-256-XTS-encrypted (tweak = absolute sector); superblocks,
//!   group table, and bitmaps stay plaintext so mount and allocation work
//!   keyless. Encrypted blocks use a keyed SipHash-2-4 MAC as their csum;
//!   the SB additionally carries a keyed MAC verified at setKey — wrong
//!   keys fail there, cleanly. Compress, then encrypt.
//! - Free space: allocation groups with per-group CoW sector bitmaps
//!   referenced from a CoW group table. Allocation is byte-aligned in the
//!   bitmap: metadata/raw runs take one full free byte (8 aligned
//!   sectors); compressed runs pack inside a single byte and never cross
//!   byte boundaries. The free counter counts free BYTES — an exact lower
//!   bound on metadata capacity, which keeps the ENOSPC reserve honest
//!   under fragmentation.
//! - Transactions: overlay -> commit (A) object subgraph bottom-up,
//!   (B) space-subgraph address fixpoint, (C) bitmaps/group table filled
//!   and written, (D) FLUSH -> superblock -> FLUSH. Freed runs are
//!   quarantined (range-overlap checked) until the superblock lands.
//! - Large delete/truncate are O(1): subtrees go onto a persisted
//!   deleting set (object 1) drained a bounded amount per commit; mount
//!   resumes draining, so a crash mid-huge-delete needs no special case.
//!
//! Ops are atomic w.r.t. txg boundaries: the library NEVER commits inside
//! an operation — callers invoke maybeCommit()/sync() between ops.

const std = @import("std");
const mosslib = @import("mosslib");
const lz4 = mosslib.lz4;
const xts = mosslib.xts;

pub const block_size = 4096;
pub const sector_size = 512;
pub const spb = block_size / sector_size; // sectors per logical block
pub const ptrs_per_block = block_size / 16; // 256
pub const sb_slots = 8;
pub const dirent_size = 64;
pub const max_name = 56;
pub const dnode_size = 128;
pub const dnodes_per_block = block_size / dnode_size; // 32
pub const max_level = 4;
pub const max_objs: u32 = 1 << 20;
pub const gt_entry_size = 144; // 8 bitmap ptrs (128B) + free counts + pad
pub const gt_per_block = block_size / gt_entry_size; // 28
const bits_per_bblock: u64 = block_size * 8; // sectors covered per bitmap block

const sb_magic = "MOS3";
/// v4 adds hashed directories (a dnode flag + the HDIR layout). A v3
/// volume mounts unchanged (all its directories are linear) and is
/// written as v4 from then on; only directories that outgrow one block
/// take the new layout.
const fs_version: u32 = 4;
const fs_version_min: u32 = 3;

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
    /// The volume is encrypted and the operation needs the key.
    NoKey,
    /// setKey: the key does not authenticate this volume's superblock.
    BadKey,
};

/// Sector-run block device: read/write `count` 512-byte sectors starting
/// at absolute sector `sector`; buffers are count*512 bytes.
pub const BlockDev = struct {
    ctx: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, sector: u64, count: u64, dst: []u8) DevError!void,
    writeFn: *const fn (ctx: *anyopaque, sector: u64, count: u64, src: []const u8) DevError!void,
    flushFn: *const fn (ctx: *anyopaque) DevError!void,
    nsecs: u64,

    fn read(d: BlockDev, sector: u64, count: u64, dst: []u8) DevError!void {
        return d.readFn(d.ctx, sector, count, dst);
    }
    fn write(d: BlockDev, sector: u64, count: u64, src: []const u8) DevError!void {
        return d.writeFn(d.ctx, sector, count, src);
    }
    fn flush(d: BlockDev) DevError!void {
        return d.flushFn(d.ctx);
    }
};

pub const flag_comp: u8 = 1; // stored form is LZ4-compressed
pub const flag_enc: u8 = 2; // stored form is XTS-encrypted

/// Packed pointer to a stored block: w = [flags u8 | psize u8 | sector u48]
/// + 8-byte csum (xxhash64 of the stored plaintext form, or keyed SipHash
/// when encrypted). Whole-word 0 = hole (sector 0 is a superblock sector,
/// never allocatable, so 0 stays a safe sentinel).
pub const BlockPtr = struct {
    w: u64 = 0,
    csum: u64 = 0,

    fn isHole(p: BlockPtr) bool {
        return p.w == 0;
    }
    /// First absolute sector of the stored run.
    fn sec(p: BlockPtr) u64 {
        return p.w & 0xffff_ffff_ffff;
    }
    /// Stored length in sectors (1..8).
    fn psize(p: BlockPtr) u64 {
        return (p.w >> 48) & 0xff;
    }
    fn flags(p: BlockPtr) u8 {
        return @intCast(p.w >> 56);
    }
    fn pack(sector: u64, ps: u64, fl: u8) u64 {
        std.debug.assert(sector < (1 << 48) and ps >= 1 and ps <= spb);
        return sector | (ps << 48) | (@as(u64, fl) << 56);
    }
};

pub const ObjType = enum(u8) { free = 0, file = 1, dir = 2, symlink = 3 };

/// Dnode flags (byte 4).
pub const dn_flag_hashed: u8 = 1; // directory data is the HDIR layout

pub const Dnode = struct {
    typ: ObjType = .free,
    level: u8 = 0, // height of the indirect tree (0 = directs only)
    nlink: u16 = 1, // reserved for a future hardlink design; always 1
    flags: u8 = 0,
    size: u64 = 0,
    mtime: u64 = 0,
    direct: [3]BlockPtr = @splat(.{}),
    indirect: BlockPtr = .{},
};

pub const Stat = struct { typ: ObjType, size: u64, mtime: u64 };

pub const root_obj: u32 = 0;
pub const delset_obj: u32 = 1;
const first_user_obj: u32 = 2;
const del_entry_size = 24; // {ptr word u64, csum u64, level u8, pad}

// ------------------------------------------------------------ capacities

const rcache_n = 96;
const max_dirty_data = 160;
const max_dirty_dnodes = 48;
const max_wbb = 24; // working (dirty) bitmap blocks per txg
const max_frees = 768; // quarantined frees per txg
const max_gt_dirty = 32; // dirty group-table leaves / path nodes per txg
const commit_data_threshold = 144; // fits a 512K stream in one txg (dd cap 160)
const commit_dnode_threshold = 32;
const drain_budget = 48; // deleting-set frees per commit
pub const alloc_reserve = 96; // headroom so a commit can always land

// --------------------------------------------------------------- codecs

fn xxsum(data: []const u8) u64 {
    return std.hash.XxHash64.hash(0x6d6f7373, data);
}

const SipMac = std.crypto.auth.siphash.SipHash64(2, 4);

/// Derived key material: master -> HKDF-SHA256 -> XTS pair + block MAC
/// key + superblock MAC key.
pub const KeySchedule = struct {
    xts_ctx: xts.Xts256,
    mac_key: [16]u8,
    sb_mac_key: [16]u8,
};

fn deriveSchedule(master: *const [32]u8) KeySchedule {
    const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
    const prk = Hkdf.extract("mossfs v3", master);
    var xk: [xts.key_len]u8 = undefined;
    Hkdf.expand(&xk, "xts", prk);
    var ks: KeySchedule = undefined;
    Hkdf.expand(&ks.mac_key, "mac", prk);
    Hkdf.expand(&ks.sb_mac_key, "sb-mac", prk);
    ks.xts_ctx = xts.Xts256.init(xk);
    std.crypto.secureZero(u8, &xk);
    return ks;
}

fn leU(comptime T: type, b: []const u8) T {
    return std.mem.readInt(T, b[0..@sizeOf(T)], .little);
}

fn puU(comptime T: type, b: []u8, v: T) void {
    std.mem.writeInt(T, b[0..@sizeOf(T)], v, .little);
}

fn putPtr(b: []u8, p: BlockPtr) void {
    puU(u64, b[0..8], p.w);
    puU(u64, b[8..16], p.csum);
}

fn getPtr(b: []const u8) BlockPtr {
    return .{ .w = leU(u64, b[0..8]), .csum = leU(u64, b[8..16]) };
}

fn putDnode(b: []u8, d: *const Dnode) void {
    @memset(b[0..dnode_size], 0);
    b[0] = @intFromEnum(d.typ);
    b[1] = d.level;
    puU(u16, b[2..4], d.nlink);
    b[4] = d.flags;
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
    d.flags = b[4];
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
    /// Masked first sector of the stored run; 0 = empty. Holds the LOGICAL
    /// 4K plaintext (post-decrypt, post-decompress), inserted only after
    /// verification — that is why cache hits may skip verification.
    addr: u64 = 0,
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
    group_secs: u64 = 0,
    bblocks_per_group: u32 = 0,
    nsecs: u64 = 0,
    free_hint: u32 = first_user_obj,

    /// Free bitmap BYTES per group (8 aligned free sectors each): the
    /// exact metadata/raw-block capacity, and the ENOSPC currency.
    gfree: [max_groups]u32 = @splat(0),

    // Encryption state (volume key; per-subtree keys are a reserved hook).
    enc: bool = false,
    key_ok: bool = false,
    xts_ctx: xts.Xts256 = undefined,
    mac_key: [16]u8 = undefined,
    sb_mac_key: [16]u8 = undefined,

    lz_tbl: lz4.EncTable = undefined,

    rc: [rcache_n]RCacheEnt = @splat(.{}),
    lru_tick: u64 = 0,

    dd: [max_dirty_data]DirtyData = @splat(.{}),
    dd_count: u32 = 0,
    ddn: [max_dirty_dnodes]DirtyDnode = @splat(.{}),

    /// Quarantined freed runs, packed sector | len<<48 (range-checked).
    freed: [max_frees]u64 = @splat(0),
    freed_count: u32 = 0,

    wbb: [max_wbb]Wbb = @splat(.{}),
    gtd: [max_gt_dirty]GtDirty = @splat(.{}),

    commits: u64 = 0,

    pub const max_groups = 8192; // 1TB at 128MB groups; growth path: wider gt entries

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

    /// csum/MAC over a stored plaintext form.
    fn storedCsum(fs: *Fs, stored: []const u8, enc: bool) u64 {
        if (enc) return SipMac.toInt(stored, &fs.mac_key);
        return xxsum(stored);
    }

    /// Verified read through the cache: fetch the stored run, decrypt,
    /// verify the csum/MAC over the stored plaintext form, THEN decompress
    /// into the cache as the logical 4K block. The returned pointer is
    /// valid only until the next cache operation — copy out to keep it.
    fn readPtr(fs: *Fs, p: BlockPtr) Error!*const [block_size]u8 {
        std.debug.assert(!p.isHole());
        if (fs.cacheFind(p.sec())) |e| return &e.data;

        const ps = p.psize();
        if (ps < 1 or ps > spb) return Error.Corrupt;
        const enc = p.flags() & flag_enc != 0;
        if (enc and !fs.key_ok) return Error.NoKey;
        var stored: [block_size]u8 = undefined;
        const sbytes = stored[0 .. ps * sector_size];
        fs.dev.read(p.sec(), ps, sbytes) catch return Error.IoError;
        if (enc) {
            var i: u64 = 0;
            while (i < ps) : (i += 1) {
                fs.xts_ctx.decryptSector(stored[i * sector_size ..][0..sector_size], p.sec() + i);
            }
        }
        if (fs.storedCsum(sbytes, enc) != p.csum) return Error.Corrupt;

        const e = fs.cacheSlot();
        e.addr = 0;
        if (p.flags() & flag_comp != 0) {
            const n = lz4.decompress(sbytes, &e.data) catch return Error.Corrupt;
            if (n != block_size) return Error.Corrupt;
        } else {
            if (ps != spb) return Error.Corrupt;
            @memcpy(&e.data, &stored);
        }
        e.addr = p.sec();
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

    fn quarantine(fs: *Fs, sector: u64, len: u64) Error!void {
        if (fs.freed_count >= max_frees) return Error.Overflow;
        fs.freed[fs.freed_count] = sector | (len << 48);
        fs.freed_count += 1;
        fs.cacheDrop(sector);
    }

    /// Range-overlap check: may [sector, sector+len) be handed out?
    fn quarantineOverlaps(fs: *Fs, sector: u64, len: u64) bool {
        for (fs.freed[0..fs.freed_count]) |q| {
            const qs = q & 0xffff_ffff_ffff;
            const ql = q >> 48;
            if (sector < qs + ql and qs < sector + len) return true;
        }
        return false;
    }

    /// Free a committed stored run: quarantine + clear its bitmap bits.
    fn freeCommitted(fs: *Fs, p: BlockPtr) Error!void {
        if (p.isHole()) return;
        try fs.quarantine(p.sec(), p.psize());
        try fs.freeInBitmap(p.sec(), p.psize());
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

    /// Claim (or find) the overlay slot for a file block. `full` promises
    /// the caller overwrites all 4096 bytes, so the committed content is
    /// never fetched — sequential block-aligned writes skip the
    /// read-modify-write (and its decrypt/decompress) entirely.
    fn dirtyFileBlock(fs: *Fs, obj: u32, blkidx: u64, full: bool) Error!*DirtyData {
        if (fs.dirtyDataFind(obj, blkidx)) |e| return e;
        for (&fs.dd) |*e| {
            if (e.used) continue;
            e.used = true;
            e.obj = obj;
            e.blkidx = blkidx;
            fs.dd_count += 1;
            if (full) {
                // Content is entirely caller-supplied; nothing to read.
            } else {
                const p = try fs.origFileBlockPtr(obj, blkidx);
                try fs.readPtrCopy(p, &e.data);
            }
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
            const e = try fs.dirtyFileBlock(obj, pos / block_size, bo == 0 and chunk == block_size);
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
        puU(u64, ent[0..8], p.w);
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
            const e = try fs.dirtyFileBlock(obj, pos / block_size, bo == 0 and chunk == block_size);
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
            const p: BlockPtr = .{ .w = leU(u64, ent[0..8]), .csum = leU(u64, ent[8..16]) };
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
            try fs.freeCommitted(p);
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
            const db = try fs.dirtyFileBlock(obj, keep_blocks - 1, false);
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
    //
    // A directory that fits one block is a flat array of 64-byte entries
    // scanned in order (insertion order, and what every small directory
    // is). The first entry that would not fit converts it to a HASHED
    // directory — extendible hashing over the name's xxhash64: block 0 is
    // a header {magic, depth, bucket count, a table of 2^depth bucket
    // block numbers indexed by the hash's top `depth` bits}; every other
    // block is a bucket {local depth, 63 entries}. Lookup is one hash,
    // one table read, one bucket scan; a full bucket splits on its next
    // hash bit (doubling the table when its local depth equals the
    // global one). Buckets are ordinary blocks of the directory object,
    // so CoW, checksums, and txg commits cover them as they cover data.
    // Entry `index` = byte offset / 64 in both layouts, so removal is one
    // zeroed entry either way. Listing order is bucket order for hashed
    // directories (nothing may rely on insertion order past one block).

    pub const DirentRef = struct { obj: u32, typ: ObjType, index: u64 };

    const linear_max = block_size / dirent_size; // 64
    const hdir_magic = "HDIR";
    const hdir_max_depth = 9; // 512 buckets: ~32K entries per directory
    const bucket_hdr = 64;
    const bucket_entries = (block_size - bucket_hdr) / dirent_size; // 63
    const hdir_table_off = 16;

    fn nameHash(name: []const u8) u64 {
        return std.hash.XxHash64.hash(0x64697268, name);
    }

    fn slotOf(h: u64, depth: u8) usize {
        if (depth == 0) return 0;
        const shift: u6 = @intCast(64 - @as(u32, depth));
        return @intCast(h >> shift);
    }

    /// The hash bit a bucket at local depth `ld` splits on (MSB = bit 63).
    fn splitBit(h: u64, ld: u8) u1 {
        const shift: u6 = @intCast(63 - @as(u32, ld));
        return @intCast((h >> shift) & 1);
    }

    const HdirHeader = struct {
        depth: u8,
        nbuckets: u32,
        table: [1 << hdir_max_depth]u32,

        fn slots(h: *const HdirHeader) usize {
            return @as(usize, 1) << @intCast(h.depth);
        }

        fn write(h: *const HdirHeader, blk: *[block_size]u8) void {
            @memset(blk, 0);
            @memcpy(blk[0..4], hdir_magic);
            blk[4] = h.depth;
            puU(u32, blk[8..12], h.nbuckets);
            for (0..h.slots()) |i| puU(u32, blk[hdir_table_off + i * 4 ..], h.table[i]);
        }
    };

    fn hdirReadHeader(fs: *Fs, dir: u32) Error!HdirHeader {
        var blk: [block_size]u8 = undefined;
        try fs.readFileBlock(dir, 0, &blk);
        if (!std.mem.eql(u8, blk[0..4], hdir_magic) or blk[4] > hdir_max_depth) return Error.Corrupt;
        var h: HdirHeader = .{ .depth = blk[4], .nbuckets = leU(u32, blk[8..12]), .table = undefined };
        for (0..h.slots()) |i| h.table[i] = leU(u32, blk[hdir_table_off + i * 4 ..]);
        return h;
    }

    fn isHashed(dn: *const Dnode) bool {
        return dn.flags & dn_flag_hashed != 0;
    }

    pub fn dirLookup(fs: *Fs, dir: u32, name: []const u8) Error!?DirentRef {
        const dn = try fs.dnodeOf(dir);
        if (isHashed(&dn)) return fs.hdirLookup(dir, name);
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

    fn hdirLookup(fs: *Fs, dir: u32, name: []const u8) Error!?DirentRef {
        const hdr = try fs.hdirReadHeader(dir);
        const h = nameHash(name);
        const b = hdr.table[slotOf(h, hdr.depth)];
        var buf: [block_size]u8 = undefined;
        try fs.readFileBlock(dir, b, &buf);
        for (0..bucket_entries) |i| {
            const e = buf[bucket_hdr + i * dirent_size ..];
            if (e[4] != 0 and e[5] == name.len and std.mem.eql(u8, e[8 .. 8 + name.len], name)) {
                return .{
                    .obj = leU(u32, e[0..4]),
                    .typ = std.enums.fromInt(ObjType, e[4]) orelse .free,
                    .index = (@as(u64, b) * block_size + bucket_hdr) / dirent_size + i,
                };
            }
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
        if (isHashed(&dn)) return fs.hdirAdd(dir, &ent, nameHash(name), now);
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
        if (dn.size == linear_max * dirent_size) {
            // One full block: the directory becomes hashed from here on.
            try fs.hdirConvert(dir, &buf, now);
            return fs.hdirAdd(dir, &ent, nameHash(name), now);
        }
        _ = try fs.writeObj(dir, dn.size, &ent, now);
    }

    /// Turn a full one-block linear directory (its block in `linear`) into
    /// a hashed one: header at block 0, two buckets at blocks 1 and 2
    /// split on the hash's top bit.
    fn hdirConvert(fs: *Fs, dir: u32, linear: *[block_size]u8, now: u64) Error!void {
        var buckets: [2][block_size]u8 = undefined;
        @memset(&buckets[0], 0);
        @memset(&buckets[1], 0);
        buckets[0][0] = 1;
        buckets[1][0] = 1;
        var fill: [2]usize = .{ 0, 0 };
        for (0..linear_max) |i| {
            const e = linear[i * dirent_size ..][0..dirent_size];
            if (e[4] == 0) continue;
            const which: usize = splitBit(nameHash(e[8 .. 8 + e[5]]), 0);
            @memcpy(buckets[which][bucket_hdr + fill[which] * dirent_size ..][0..dirent_size], e);
            fill[which] += 1;
        }
        var hdr: HdirHeader = .{ .depth = 1, .nbuckets = 2, .table = undefined };
        hdr.table[0] = 1;
        hdr.table[1] = 2;
        var blk: [block_size]u8 = undefined;
        hdr.write(&blk);
        _ = try fs.writeObj(dir, 0, &blk, now);
        _ = try fs.writeObj(dir, block_size, &buckets[0], now);
        _ = try fs.writeObj(dir, 2 * block_size, &buckets[1], now);
        const e = try fs.dnodeSlot(dir);
        e.dn.flags |= dn_flag_hashed;
    }

    fn hdirAdd(fs: *Fs, dir: u32, ent: *const [dirent_size]u8, h: u64, now: u64) Error!void {
        var guard: usize = 0;
        while (guard < hdir_max_depth + 2) : (guard += 1) {
            var hdr = try fs.hdirReadHeader(dir);
            const b = hdr.table[slotOf(h, hdr.depth)];
            var buf: [block_size]u8 = undefined;
            try fs.readFileBlock(dir, b, &buf);
            for (0..bucket_entries) |i| {
                if (buf[bucket_hdr + i * dirent_size + 4] == 0) {
                    _ = try fs.writeObj(dir, @as(u64, b) * block_size + bucket_hdr + i * dirent_size, ent, now);
                    return;
                }
            }
            try fs.hdirSplit(dir, &hdr, b, &buf, now);
        }
        return Error.TooLarge;
    }

    /// Split bucket `b` (its block in `buf`) on its next hash bit; the
    /// table doubles first when the bucket is already at global depth.
    fn hdirSplit(fs: *Fs, dir: u32, hdr: *HdirHeader, b: u32, buf: *[block_size]u8, now: u64) Error!void {
        const ld = buf[0];
        if (ld == hdr.depth) {
            if (hdr.depth == hdir_max_depth) return Error.TooLarge;
            var i = hdr.slots();
            while (i > 0) {
                i -= 1;
                hdr.table[2 * i] = hdr.table[i];
                hdr.table[2 * i + 1] = hdr.table[i];
            }
            hdr.depth += 1;
        }
        const nb: u32 = hdr.nbuckets + 1;
        hdr.nbuckets = nb;
        var newb: [block_size]u8 = undefined;
        @memset(&newb, 0);
        newb[0] = ld + 1;
        buf[0] = ld + 1;
        var fill: usize = 0;
        for (0..bucket_entries) |i| {
            const e = buf[bucket_hdr + i * dirent_size ..][0..dirent_size];
            if (e[4] == 0) continue;
            if (splitBit(nameHash(e[8 .. 8 + e[5]]), ld) == 1) {
                @memcpy(newb[bucket_hdr + fill * dirent_size ..][0..dirent_size], e);
                fill += 1;
                @memset(e, 0);
            }
        }
        // Table slots that pointed at b and carry the split bit now point
        // at the new bucket.
        const shift: u6 = @intCast(hdr.depth - ld - 1);
        for (0..hdr.slots()) |i| {
            if (hdr.table[i] == b and (i >> shift) & 1 == 1) hdr.table[i] = nb;
        }
        var blk: [block_size]u8 = undefined;
        hdr.write(&blk);
        _ = try fs.writeObj(dir, 0, &blk, now);
        _ = try fs.writeObj(dir, @as(u64, b) * block_size, buf, now);
        _ = try fs.writeObj(dir, @as(u64, nb) * block_size, &newb, now);
    }

    pub fn dirRemove(fs: *Fs, dir: u32, name: []const u8, now: u64) Error!bool {
        const found = (try fs.dirLookup(dir, name)) orelse return false;
        var ent: [dirent_size]u8 = @splat(0);
        _ = try fs.writeObj(dir, found.index * dirent_size, &ent, now);
        return true;
    }

    /// Visit every live entry in the directory (either layout).
    fn dirEach(fs: *Fs, dir: u32, ctx: anytype, comptime visit: fn (@TypeOf(ctx), []const u8) bool) Error!void {
        const dn = try fs.dnodeOf(dir);
        var buf: [block_size]u8 = undefined;
        if (isHashed(&dn)) {
            const hdr = try fs.hdirReadHeader(dir);
            var b: u32 = 1;
            while (b <= hdr.nbuckets) : (b += 1) {
                try fs.readFileBlock(dir, b, &buf);
                for (0..bucket_entries) |i| {
                    const e = buf[bucket_hdr + i * dirent_size ..][0..dirent_size];
                    if (e[4] != 0 and !visit(ctx, e)) return;
                }
            }
            return;
        }
        var off: u64 = 0;
        while (off < dn.size) : (off += block_size) {
            try fs.readFileBlock(dir, off / block_size, &buf);
            const in_blk: usize = @intCast(@min(dn.size - off, block_size) / dirent_size);
            for (0..in_blk) |i| {
                const e = buf[i * dirent_size ..][0..dirent_size];
                if (e[4] != 0 and !visit(ctx, e)) return;
            }
        }
    }

    pub fn dirIsEmpty(fs: *Fs, dir: u32) Error!bool {
        var any = false;
        try fs.dirEach(dir, &any, struct {
            fn v(flag: *bool, _: []const u8) bool {
                flag.* = true;
                return false;
            }
        }.v);
        return !any;
    }

    /// Fill `out` with "name\n" per live entry; returns bytes written.
    pub fn dirList(fs: *Fs, dir: u32, out: []u8) Error!usize {
        const Ctx = struct { out: []u8, n: usize = 0 };
        var ctx: Ctx = .{ .out = out };
        try fs.dirEach(dir, &ctx, struct {
            fn v(c: *Ctx, e: []const u8) bool {
                const nl = e[5];
                if (c.n + nl + 1 > c.out.len) return false;
                @memcpy(c.out[c.n .. c.n + nl], e[8 .. 8 + nl]);
                c.out[c.n + nl] = '\n';
                c.n += nl + 1;
                return true;
            }
        }.v);
        return ctx.n;
    }

    // ------------------------------------------------------- allocation
    //
    // Bitmap bit = one sector. Allocation is byte-aligned: metadata and
    // raw data take a whole free byte (8 aligned sectors); compressed runs
    // (psize <= 7) pack inside a single byte and never cross byte
    // boundaries. The per-group free counter counts free BYTES, so it is
    // an exact lower bound on full-block capacity — fragmentation from
    // compressed runs can never starve a commit invisibly.

    /// Free bitmap bytes = allocatable full 4K blocks. The ENOSPC gate.
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

    /// Allocate a full byte-aligned 8-sector run (metadata / raw blocks).
    /// Prefers groups whose bitmaps are already dirty this txg; never
    /// hands out anything overlapping a quarantined range.
    fn allocMeta(fs: *Fs) Error!u64 {
        for (&fs.wbb) |*w| {
            if (!w.used) continue;
            if (try fs.allocRunInGroup(w.group, spb)) |a| return a;
        }
        for (0..fs.gcount) |g| {
            if (fs.gfree[g] == 0) continue;
            if (try fs.allocRunInGroup(@intCast(g), spb)) |a| return a;
        }
        return Error.NoSpace;
    }

    /// Allocate `n` (1..7) contiguous sectors inside a single bitmap byte
    /// (compressed data). Prefers partially-used bytes so free bytes — the
    /// full-block capacity — are spent last.
    fn allocSub(fs: *Fs, n: u64) Error!u64 {
        std.debug.assert(n >= 1 and n < spb);
        for (&fs.wbb) |*w| {
            if (!w.used) continue;
            if (try fs.allocRunInGroup(w.group, n)) |a| return a;
        }
        for (0..fs.gcount) |g| {
            if (fs.gfree[g] == 0) continue; // conservative: free-byte gate
            if (try fs.allocRunInGroup(@intCast(g), n)) |a| return a;
        }
        return Error.NoSpace;
    }

    fn allocRunInGroup(fs: *Fs, group: u32, n: u64) Error!?u64 {
        // Pass 1 (sub-byte runs only): pack into partially-used bytes.
        if (n < spb) {
            if (try fs.scanGroup(group, n, .partial)) |a| return a;
        }
        return fs.scanGroup(group, n, .free_byte);
    }

    const ScanMode = enum { partial, free_byte };

    fn scanGroup(fs: *Fs, group: u32, n: u64, mode: ScanMode) Error!?u64 {
        const g_start = @as(u64, group) * fs.group_secs;
        for (0..fs.bblocks_per_group) |sub| {
            const w = try fs.wbbGet(group, @intCast(sub));
            const first_sec = @as(u64, sub) * bits_per_bblock;
            for (0..block_size) |bi| {
                const inner = first_sec + bi * 8;
                if (inner + spb > fs.group_secs) break; // partial tail: format marked it used
                const sec0 = g_start + inner;
                if (sec0 + spb > fs.nsecs) break;
                const b = w.data[bi];
                switch (mode) {
                    .free_byte => if (b != 0) continue,
                    .partial => if (b == 0 or b == 0xff) continue,
                }
                if (n == spb) {
                    if (fs.quarantineOverlaps(sec0, spb)) continue;
                    w.data[bi] = 0xff;
                    fs.gfree[group] -= 1;
                    return sec0;
                }
                // Find n contiguous free bits inside this byte.
                var shift: usize = 0;
                const mask_base: u8 = @intCast((@as(u16, 1) << @intCast(n)) - 1);
                while (shift + n <= 8) : (shift += 1) {
                    const mask = mask_base << @intCast(shift);
                    if (b & mask != 0) continue;
                    const sec = sec0 + shift;
                    if (fs.quarantineOverlaps(sec, n)) continue;
                    if (b == 0) fs.gfree[group] -= 1; // byte leaves the free pool
                    w.data[bi] |= mask;
                    return sec;
                }
            }
        }
        return null;
    }

    fn freeInBitmap(fs: *Fs, sector: u64, len: u64) Error!void {
        const group: u32 = @intCast(sector / fs.group_secs);
        const inner = sector % fs.group_secs;
        std.debug.assert(inner / 8 == (inner + len - 1) / 8); // never crosses a byte
        const w = try fs.wbbGet(group, @intCast(inner / bits_per_bblock));
        const bit_in_bb = inner % bits_per_bblock;
        const bi: usize = @intCast(bit_in_bb / 8);
        const off: usize = @intCast(bit_in_bb % 8);
        const was = w.data[bi];
        var mask: u8 = 0;
        for (0..len) |i| mask |= @as(u8, 1) << @intCast(off + i);
        w.data[bi] &= ~mask;
        if (was != 0 and w.data[bi] == 0) fs.gfree[group] += 1; // byte fully free again
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

    /// Storage class of a new block: `space` (bitmaps/group table — always
    /// plaintext, never compressed), `tree` (objmap + indirect nodes —
    /// encrypted on encrypted volumes, never compressed), `data` (object
    /// content — encrypted and compression-attempted).
    const Class = enum { space, tree, data };

    /// Allocate + write one logical block: compress (data class), csum/MAC
    /// the stored plaintext form, encrypt, write the run, cache the
    /// logical plaintext. Compress-then-encrypt, verify-before-decompress.
    fn writeNew(fs: *Fs, data: *const [block_size]u8, class: Class) Error!BlockPtr {
        var stored: [block_size]u8 = undefined;
        var ps: u64 = spb;
        var fl: u8 = 0;
        if (class == .data) {
            // Worth it only if at least one sector is saved.
            if (lz4.compress(data, stored[0 .. (spb - 1) * sector_size], &fs.lz_tbl)) |clen| {
                ps = (clen + sector_size - 1) / sector_size;
                @memset(stored[clen .. ps * sector_size], 0);
                fl |= flag_comp;
            }
        }
        if (fl & flag_comp == 0) @memcpy(&stored, data);
        if (fs.enc and class != .space) {
            if (!fs.key_ok) return Error.NoKey;
            fl |= flag_enc;
        }
        const sector = if (ps == spb) try fs.allocMeta() else try fs.allocSub(ps);
        const cs = fs.storedCsum(stored[0 .. ps * sector_size], fl & flag_enc != 0);
        if (fl & flag_enc != 0) {
            var i: u64 = 0;
            while (i < ps) : (i += 1) {
                fs.xts_ctx.encryptSector(stored[i * sector_size ..][0..sector_size], sector + i);
            }
        }
        try fs.writeRun(sector, ps, stored[0 .. ps * sector_size]);
        fs.cacheInsert(sector, data);
        return .{ .w = BlockPtr.pack(sector, ps, fl), .csum = cs };
    }

    /// Write a space-class block at a preallocated byte-aligned run
    /// (commit phase C: addresses were fixed in phase B).
    fn writeNewAt(fs: *Fs, sector: u64, data: *const [block_size]u8) Error!BlockPtr {
        try fs.writeRun(sector, spb, data);
        fs.cacheInsert(sector, data);
        return .{ .w = BlockPtr.pack(sector, spb, 0), .csum = xxsum(data) };
    }

    fn writeRun(fs: *Fs, sector: u64, ps: u64, bytes: []const u8) Error!void {
        if (dbg_track) {
            for (dbg_written[0..dbg_written_n]) |r| {
                const rs = r & 0xffff_ffff_ffff;
                const rl = r >> 48;
                if (sector < rs + rl and rs < sector + ps)
                    std.debug.panic("overlapping writes: sector {d}+{d} vs {d}+{d}", .{ sector, ps, rs, rl });
            }
            if (dbg_written_n < dbg_written.len) {
                dbg_written[dbg_written_n] = sector | (ps << 48);
                dbg_written_n += 1;
            }
        }
        fs.dev.write(sector, ps, bytes) catch return Error.IoError;
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
                    const np = try fs.writeNew(&dblk.data, .data);
                    // Free the committed version (trim already handled).
                    const oldp = try fs.origFileBlockPtr(e.obj, blkidx);
                    try fs.freeCommitted(oldp);
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

        const np = try fs.writeNew(&content, .tree);
        try fs.freeCommitted(old);
        return np;
    }

    /// Rebuild one dirty object's block tree, patching its overlay dnode.
    fn rebuildFile(fs: *Fs, e: *DirtyDnode) Error!void {
        if (e.dn.typ == .free) return; // freed: pointers already zeroed
        // Directs.
        for (0..3) |i| {
            if (fs.dirtyDataFind(e.obj, i)) |dblk| {
                const np = try fs.writeNew(&dblk.data, .data);
                const oldp = try fs.origFileBlockPtr(e.obj, i);
                try fs.freeCommitted(oldp);
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
            const np = try fs.writeNew(&content, .tree);
            try fs.freeCommitted(old);
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
        const np = try fs.writeNew(&content, .tree);
        try fs.freeCommitted(old);
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
                    const na = try fs.allocMeta();
                    w.new_addr = na;
                    try fs.freeCommitted(w.old);
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
                    g.new_addr = try fs.allocMeta();
                    try fs.freeCommitted(old);
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
                            pn.new_addr = try fs.allocMeta();
                            try fs.freeCommitted(old);
                            changed = true;
                        }
                    }
                }
            }
            if (!changed) break;
        }

        // --- C: fill + checksum + write the space subgraph, bottom-up. ---
        for (&fs.wbb) |*w| {
            if (w.used) w.new_ptr = try fs.writeNewAt(w.new_addr, &w.data);
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
            g.new_ptr = try fs.writeNewAt(g.new_addr, &content);
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
                g.new_ptr = try fs.writeNewAt(g.new_addr, &content);
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

    /// Fill a superblock slot image (sans slot-local fields set by caller).
    fn fillSuper(blk: *[block_size]u8, txg: u64, slot: u32, nsecs: u64, group_secs: u64, bbpg: u32, gcount: u32, obj_root: BlockPtr, obj_level: u8, gt_root: BlockPtr, gt_level: u8, free_hint: u32, enc: bool) void {
        @memset(blk, 0);
        @memcpy(blk[0..4], sb_magic);
        puU(u32, blk[4..8], fs_version);
        puU(u64, blk[8..16], txg);
        puU(u32, blk[16..20], slot);
        puU(u64, blk[24..32], nsecs);
        puU(u64, blk[32..40], group_secs);
        puU(u32, blk[40..44], bbpg);
        puU(u32, blk[44..48], gcount);
        putPtr(blk[48..], obj_root);
        blk[64] = obj_level;
        putPtr(blk[72..], gt_root);
        blk[88] = gt_level;
        puU(u32, blk[92..96], free_hint);
        blk[96] = @intFromBool(enc);
    }

    /// Seal a slot: keyed MAC (encrypted volumes) at [-16..-8], then the
    /// keyless full-slot self-checksum at [-8..] covering everything —
    /// slot election stays keyless; the MAC is what setKey verifies.
    fn sealSuper(blk: *[block_size]u8, enc: bool, sb_mac_key: *const [16]u8) void {
        if (enc) {
            const mac = SipMac.toInt(blk[0 .. block_size - 16], sb_mac_key);
            puU(u64, blk[block_size - 16 .. block_size - 8], mac);
        }
        const sc = std.hash.XxHash64.hash(0x5342, blk[0 .. block_size - 8]);
        puU(u64, blk[block_size - 8 ..], sc);
    }

    fn writeSuper(fs: *Fs, obj_root: BlockPtr, obj_level: u8, gt_root: BlockPtr) Error!void {
        var blk: [block_size]u8 = undefined;
        fillSuper(&blk, fs.txg + 1, fs.slot_next, fs.nsecs, fs.group_secs, fs.bblocks_per_group, fs.gcount, obj_root, obj_level, gt_root, fs.gt_level, fs.free_hint, fs.enc);
        sealSuper(&blk, fs.enc, &fs.sb_mac_key);
        fs.dev.write((fs.slot_next % sb_slots) * spb, spb, &blk) catch return Error.IoError;
    }

    pub fn mount(fs: *Fs, dev: BlockDev) Error!void {
        fs.* = .{ .dev = dev };
        var best_txg: u64 = 0;
        var best_slot: u32 = 0;
        var found = false;
        var blk: [block_size]u8 = undefined;
        for (0..sb_slots) |slot| {
            dev.read(slot * spb, spb, &blk) catch continue;
            if (!std.mem.eql(u8, blk[0..4], sb_magic)) continue;
            const ver = leU(u32, blk[4..8]);
            if (ver < fs_version_min or ver > fs_version) continue;
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
        dev.read(best_slot * spb, spb, &blk) catch return Error.IoError;
        fs.txg = best_txg;
        fs.slot_next = (best_slot + 1) % sb_slots;
        fs.nsecs = @min(leU(u64, blk[24..32]), dev.nsecs);
        fs.group_secs = leU(u64, blk[32..40]);
        fs.bblocks_per_group = leU(u32, blk[40..44]);
        fs.gcount = leU(u32, blk[44..48]);
        fs.obj_root = getPtr(blk[48..]);
        fs.obj_level = blk[64];
        fs.gt_root = getPtr(blk[72..]);
        fs.gt_level = blk[88];
        fs.free_hint = leU(u32, blk[92..96]);
        fs.enc = blk[96] != 0;
        if (fs.gcount > max_groups) return Error.TooLarge;
        // Free-byte counts, from the group table (lazy bitmaps; small).
        for (0..fs.gcount) |g| {
            const p = try fs.gtLeafPtr(g / gt_per_block);
            if (p.isHole()) return Error.Corrupt;
            const lb = try fs.readPtr(p);
            fs.gfree[g] = leU(u32, lb[(g % gt_per_block) * gt_entry_size + 128 ..][0..4]);
        }
    }

    /// Whether object operations are gated on setKey.
    pub fn keyRequired(fs: *Fs) bool {
        return fs.enc and !fs.key_ok;
    }

    /// Derive the key schedule from the 256-bit master key and verify it
    /// against the mounted superblock's keyed MAC. Wrong keys fail HERE —
    /// cleanly, before any object read could go wrong.
    pub fn setKey(fs: *Fs, master: *const [32]u8) Error!void {
        if (!fs.enc) return Error.BadKey; // plaintext volume takes no key
        fs.deriveKeys(master);
        // Re-read the elected slot and check its MAC.
        const slot = (fs.slot_next + sb_slots - 1) % sb_slots;
        var blk: [block_size]u8 = undefined;
        fs.dev.read(slot * spb, spb, &blk) catch return Error.IoError;
        const mac = SipMac.toInt(blk[0 .. block_size - 16], &fs.sb_mac_key);
        if (mac != leU(u64, blk[block_size - 16 .. block_size - 8])) {
            fs.key_ok = false;
            return Error.BadKey;
        }
        fs.key_ok = true;
    }

    fn deriveKeys(fs: *Fs, master: *const [32]u8) void {
        const ks = deriveSchedule(master);
        fs.xts_ctx = ks.xts_ctx;
        fs.mac_key = ks.mac_key;
        fs.sb_mac_key = ks.sb_mac_key;
    }

    // ------------------------------------------------------------ format

    /// Create a fresh filesystem. `group_blocks` tunes allocation-group
    /// size (1 GiB = 1 << 18 in production; small in tests) and must be a
    /// multiple of 32768 or exactly cover the volume in one group.
    /// Create a fresh filesystem. `group_secs` tunes allocation-group size
    /// in sectors (262144 = 128MB in production; small in tests); must be a
    /// multiple of 8 (bitmap-byte alignment). Pass a master key to create
    /// an encrypted volume (object data, indirect blocks, and the objmap
    /// are ciphertext; superblocks, group table, and bitmaps are not).
    pub fn format(dev: BlockDev, group_secs: u64, key: ?*const [32]u8) Error!void {
        const nsecs = dev.nsecs;
        if (nsecs < 512 or group_secs % 8 != 0) return Error.TooLarge;
        const gsecs = group_secs;
        const bbpg: u32 = @intCast((gsecs + bits_per_bblock - 1) / bits_per_bblock);
        if (bbpg > 8) return Error.TooLarge; // 8 ptrs per group entry
        const gcount: u32 = @intCast((nsecs + gsecs - 1) / gsecs);
        if (gcount > max_groups) return Error.TooLarge;
        const gt_leaves: u64 = (gcount + gt_per_block - 1) / gt_per_block;
        const gt_level: u8 = if (gt_leaves <= 1) 0 else if (gt_leaves <= ptrs_per_block) 1 else 2;
        const l1_count: u64 = if (gt_level == 2) (gt_leaves + ptrs_per_block - 1) / ptrs_per_block else 0;
        if (l1_count > ptrs_per_block) return Error.TooLarge;

        const ks: ?KeySchedule = if (key) |k| deriveSchedule(k) else null;

        // Bootstrap layout in group 0 (sector units, all runs 8-aligned):
        // SB slots at 0..63, then objmap leaf, group-table leaves, L1
        // nodes (gt_level 2), root (gt_level >= 1), group-0 bitmaps.
        // Other groups' bitmaps sit at their own first sectors.
        var cursor: u64 = sb_slots * spb;
        const objmap_sec = cursor;
        cursor += spb;
        const gtl_sec = cursor;
        cursor += gt_leaves * spb;
        const l1_sec = cursor;
        cursor += l1_count * spb;
        const gtr_sec = cursor;
        if (gt_level >= 1) cursor += spb;
        const g0_bitmap_sec = cursor;
        cursor += @as(u64, bbpg) * spb;
        if (cursor >= gsecs or cursor >= nsecs) return Error.TooLarge;

        var blk: [block_size]u8 = @splat(0);

        // Objmap leaf: root dir (obj 0) and the deleting set (obj 1) —
        // encrypted (tree class) on encrypted volumes.
        var dn_root: Dnode = .{ .typ = .dir };
        var dn_del: Dnode = .{ .typ = .file };
        putDnode(blk[0..], &dn_root);
        putDnode(blk[dnode_size..], &dn_del);
        const objmap_ptr = try writeFormatBlock(dev, objmap_sec, &blk, if (ks) |*k| k else null);

        // Bitmaps: written per group; group-table entries collected.
        var gt_leaf: [block_size]u8 = @splat(0);
        var leaf_idx: u64 = 0;
        var slot_in_leaf: u64 = 0;
        var gtl_ptrs: [ptrs_per_block]BlockPtr = @splat(.{});
        var l1_ptrs: [ptrs_per_block]BlockPtr = @splat(.{});

        var bm: [block_size]u8 = undefined;
        for (0..gcount) |g| {
            const g_start = @as(u64, g) * gsecs;
            const bm_base = if (g == 0) g0_bitmap_sec else g_start;
            var free_bytes: u32 = 0;
            var entry: [gt_entry_size]u8 = @splat(0);
            for (0..bbpg) |sub| {
                @memset(&bm, 0);
                const sec_base = g_start + sub * bits_per_bblock;
                for (0..block_size) |bi| {
                    var byte: u8 = 0;
                    for (0..8) |bit| {
                        const sec = sec_base + bi * 8 + bit;
                        const used = sec >= nsecs or sec >= g_start + gsecs or
                            (g == 0 and sec < cursor) or
                            (g != 0 and sec >= bm_base and sec < bm_base + @as(u64, bbpg) * spb);
                        if (used) byte |= @as(u8, 1) << @intCast(bit);
                    }
                    bm[bi] = byte;
                    if (byte == 0) free_bytes += 1;
                }
                const a = bm_base + sub * spb;
                dev.write(a, spb, &bm) catch return Error.IoError;
                putPtr(entry[sub * 16 ..], .{ .w = BlockPtr.pack(a, spb, 0), .csum = xxsum(&bm) });
            }
            puU(u32, entry[128..132], free_bytes);
            @memcpy(gt_leaf[@intCast(slot_in_leaf * gt_entry_size)..][0..gt_entry_size], &entry);
            slot_in_leaf += 1;
            if (slot_in_leaf == gt_per_block or g == gcount - 1) {
                const a = gtl_sec + leaf_idx * spb;
                dev.write(a, spb, &gt_leaf) catch return Error.IoError;
                gtl_ptrs[@intCast(leaf_idx % ptrs_per_block)] = .{ .w = BlockPtr.pack(a, spb, 0), .csum = xxsum(&gt_leaf) };
                leaf_idx += 1;
                slot_in_leaf = 0;
                @memset(&gt_leaf, 0);
                // gt_level 2: flush a full set of 256 leaves into an L1 node.
                if (gt_level == 2 and (leaf_idx % ptrs_per_block == 0 or g == gcount - 1)) {
                    @memset(&blk, 0);
                    const in_node = if (leaf_idx % ptrs_per_block == 0) ptrs_per_block else leaf_idx % ptrs_per_block;
                    for (0..in_node) |i| putPtr(blk[i * 16 ..], gtl_ptrs[i]);
                    const l1i = (leaf_idx - 1) / ptrs_per_block;
                    const a1 = l1_sec + l1i * spb;
                    dev.write(a1, spb, &blk) catch return Error.IoError;
                    l1_ptrs[@intCast(l1i)] = .{ .w = BlockPtr.pack(a1, spb, 0), .csum = xxsum(&blk) };
                    gtl_ptrs = @splat(.{});
                }
            }
        }
        var gt_root: BlockPtr = gtl_ptrs[0];
        if (gt_level >= 1) {
            @memset(&blk, 0);
            if (gt_level == 1) {
                for (0..gt_leaves) |i| putPtr(blk[i * 16 ..], gtl_ptrs[i]);
            } else {
                for (0..l1_count) |i| putPtr(blk[i * 16 ..], l1_ptrs[i]);
            }
            dev.write(gtr_sec, spb, &blk) catch return Error.IoError;
            gt_root = .{ .w = BlockPtr.pack(gtr_sec, spb, 0), .csum = xxsum(&blk) };
        }

        // Superblock slot 0 (txg 1); wipe the other slots so stale
        // filesystems can never win the mount election.
        @memset(&blk, 0);
        for (1..sb_slots) |slot| dev.write(slot * spb, spb, &blk) catch return Error.IoError;
        dev.flush() catch return Error.IoError;

        fillSuper(&blk, 1, 0, nsecs, gsecs, bbpg, gcount, objmap_ptr, 0, gt_root, gt_level, first_user_obj, ks != null);
        var zero_key: [16]u8 = @splat(0);
        sealSuper(&blk, ks != null, if (ks) |*k| &k.sb_mac_key else &zero_key);
        dev.write(0, spb, &blk) catch return Error.IoError;
        dev.flush() catch return Error.IoError;
    }

    /// Write one tree-class 4K block at format time (encrypt + MAC when
    /// the volume is encrypted); returns its pointer.
    fn writeFormatBlock(dev: BlockDev, sector: u64, content: *const [block_size]u8, ks: ?*const KeySchedule) Error!BlockPtr {
        var fl: u8 = 0;
        var stored: [block_size]u8 = undefined;
        @memcpy(&stored, content);
        var cs: u64 = undefined;
        if (ks) |k| {
            fl |= flag_enc;
            cs = SipMac.toInt(&stored, &k.mac_key);
            var i: u64 = 0;
            while (i < spb) : (i += 1) {
                k.xts_ctx.encryptSector(stored[i * sector_size ..][0..sector_size], sector + i);
            }
        } else {
            cs = xxsum(&stored);
        }
        dev.write(sector, spb, &stored) catch return Error.IoError;
        return .{ .w = BlockPtr.pack(sector, spb, fl), .csum = cs };
    }
};

// ======================================================================
// Host-side test support: RAM block device with write recording, crash
// injection (clean cuts AND torn final writes), and corruption flips.
// ======================================================================

pub const RamDev = struct {
    secs: [][sector_size]u8,
    /// Recorded write sequence since last reset: sector | count<<48.
    wlog: [16384]u64 = undefined,
    wlog_len: usize = 0,
    /// When set, write REQUESTS stop being applied after this many more;
    /// the final request can be torn inside the run at a sector boundary.
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
            .nsecs = rd.secs.len,
        };
    }

    fn doRead(ctx: *anyopaque, sector: u64, count: u64, dst: []u8) DevError!void {
        const rd: *RamDev = @ptrCast(@alignCast(ctx));
        if (sector + count > rd.secs.len or dst.len != count * sector_size) return DevError.IoError;
        for (0..count) |i| {
            @memcpy(dst[i * sector_size ..][0..sector_size], &rd.secs[@intCast(sector + i)]);
        }
    }

    fn doWrite(ctx: *anyopaque, sector: u64, count: u64, src: []const u8) DevError!void {
        const rd: *RamDev = @ptrCast(@alignCast(ctx));
        if (sector + count > rd.secs.len or src.len != count * sector_size) return DevError.IoError;
        if (rd.cut_after) |*n| {
            if (n.* == 0) {
                rd.dropped += 1;
                return; // power is gone: silently dropped
            }
            n.* -= 1;
            if (n.* == 0 and rd.tear_final) {
                // Torn request: a prefix of the run lands; one further
                // sector is garbage.
                const landed = rd.prng.random().uintLessThan(usize, @intCast(count));
                for (0..landed) |i| {
                    @memcpy(&rd.secs[@intCast(sector + i)], src[i * sector_size ..][0..sector_size]);
                }
                if (landed < count) rd.prng.random().bytes(&rd.secs[@intCast(sector + landed)]);
                rd.log(sector, count);
                return;
            }
        }
        for (0..count) |i| {
            @memcpy(&rd.secs[@intCast(sector + i)], src[i * sector_size ..][0..sector_size]);
        }
        rd.log(sector, count);
    }

    fn log(rd: *RamDev, sector: u64, count: u64) void {
        if (rd.wlog_len < rd.wlog.len) {
            rd.wlog[rd.wlog_len] = sector | (count << 48);
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

const test_secs = 16384; // 8MB volume
const test_group_secs = 4096; // tiny groups: multi-group on a toy volume

var t_storage: [test_secs][sector_size]u8 = undefined;
var t_snap: [test_secs][sector_size]u8 = undefined;
var t_fs: Fs = undefined;
var t_fs2: Fs = undefined;

const test_master_key: [32]u8 = blk: {
    var k: [32]u8 = undefined;
    for (&k, 0..) |*b, i| b.* = @intCast(i * 7 + 3);
    break :blk k;
};

/// Per-config key: null = plaintext volume; set = encrypted volume.
var t_key: ?*const [32]u8 = null;

fn freshDev(rd: *RamDev) BlockDev {
    for (&t_storage) |*b| @memset(b, 0xAA); // poison
    rd.* = .{ .secs = &t_storage };
    return rd.dev();
}

fn fmtDev(dev: BlockDev) !void {
    try Fs.format(dev, test_group_secs, t_key);
}

fn mountKeyed(f: *Fs, dev: BlockDev) !void {
    try f.mount(dev);
    if (t_key) |k| try f.setKey(k);
}

test "format, mount, small file round trip, remount persistence" {
    var rd: RamDev = undefined;
    const dev = freshDev(&rd);
    try fmtDev(dev);
    try t_fs.mount(dev);

    const obj = try t_fs.allocObject(.file, 100);
    try t_fs.dirAdd(root_obj, "hello.txt", obj, .file, 100);
    _ = try t_fs.writeObj(obj, 0, "hello mossfs v3", 101);
    try t_fs.sync(101);

    // Remount from scratch: everything must persist.
    try t_fs2.mount(dev);
    const found = (try t_fs2.dirLookup(root_obj, "hello.txt")).?;
    try testing.expectEqual(obj, found.obj);
    var buf: [64]u8 = undefined;
    const n = try t_fs2.readObj(found.obj, 0, &buf);
    try testing.expectEqualStrings("hello mossfs v3", buf[0..n]);
    const st = try t_fs2.statObj(found.obj);
    try testing.expectEqual(@as(u64, 101), st.mtime);
    try testing.expectEqual(ObjType.file, st.typ);
}

test "large file through indirect levels, sparse holes, truncate, delete" {
    var rd: RamDev = undefined;
    const dev = freshDev(&rd);
    try fmtDev(dev);
    try t_fs.mount(dev);

    const obj = try t_fs.allocObject(.file, 1);
    // Write into the second indirect level (idx 3 + 256 + 10); random
    // pattern so it exercises the raw (incompressible) path.
    const far: u64 = (3 + ptrs_per_block + 10) * block_size;
    var pat: [block_size]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    prng.random().bytes(&pat);
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

    // Delete entirely; the deleting set must fully drain.
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
    try fmtDev(dev);
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

test "hashed directories: conversion, splits, lookup, remove, list, remount" {
    var rd: RamDev = undefined;
    const dev = freshDev(&rd);
    try fmtDev(dev);
    try t_fs.mount(dev);

    const d = try t_fs.allocObject(.dir, 1);
    try t_fs.dirAdd(root_obj, "big", d, .dir, 1);
    // Well past one block and through several splits.
    const count: u32 = 700;
    var name: [16]u8 = undefined;
    for (0..count) |i| {
        const n = std.fmt.bufPrint(&name, "entry-{d}", .{i}) catch unreachable;
        try t_fs.dirAdd(d, n, @intCast(1000 + i), .file, 2);
        if (i % 50 == 0) try t_fs.maybeCommit(2);
    }
    try testing.expect(Fs.isHashed(&(try t_fs.dnodeOf(d))));
    for (0..count) |i| {
        const n = std.fmt.bufPrint(&name, "entry-{d}", .{i}) catch unreachable;
        const ref = (try t_fs.dirLookup(d, n)) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u32, @intCast(1000 + i)), ref.obj);
    }
    try testing.expect((try t_fs.dirLookup(d, "entry-700")) == null);
    try testing.expect((try t_fs.dirLookup(d, "entry")) == null);
    // Remove every third; the rest stay findable, the removed do not.
    for (0..count) |i| {
        if (i % 3 != 0) continue;
        const n = std.fmt.bufPrint(&name, "entry-{d}", .{i}) catch unreachable;
        try testing.expect(try t_fs.dirRemove(d, n, 3));
    }
    try t_fs.sync(3);
    try t_fs2.mount(dev);
    var live: usize = 0;
    for (0..count) |i| {
        const n = std.fmt.bufPrint(&name, "entry-{d}", .{i}) catch unreachable;
        const found = try t_fs2.dirLookup(d, n);
        if (i % 3 == 0) try testing.expect(found == null) else {
            try testing.expect(found != null);
            live += 1;
        }
    }
    // The listing has exactly the live names, each once.
    var out: [16384]u8 = undefined;
    const n = try t_fs2.dirList(d, &out);
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, out[0..n], '\n');
    while (it.next()) |l| {
        if (l.len > 0) lines += 1;
    }
    try testing.expectEqual(live, lines);
    try testing.expect(!try t_fs2.dirIsEmpty(d));
    // Re-adding a removed name lands in a free slot.
    try t_fs2.dirAdd(d, "entry-0", 5000, .file, 4);
    try testing.expectEqual(@as(u32, 5000), (try t_fs2.dirLookup(d, "entry-0")).?.obj);
    // Small directories stay linear, in insertion order.
    try testing.expect(!Fs.isHashed(&(try t_fs2.dnodeOf(root_obj))));
}

test "corruption is detected, never returned" {
    var rd: RamDev = undefined;
    const dev = freshDev(&rd);
    try fmtDev(dev);
    try t_fs.mount(dev);
    const obj = try t_fs.allocObject(.file, 1);
    var pat: [block_size]u8 = undefined;
    for (&pat, 0..) |*c, i| c.* = @truncate(i);
    _ = try t_fs.writeObj(obj, 0, &pat, 1);
    try t_fs.sync(1);

    // Find the file's data run on disk and flip one byte.
    try t_fs2.mount(dev);
    const dn = try t_fs2.dnodeOf(obj);
    const victim = dn.direct[0].sec();
    try testing.expect(victim != 0);
    t_storage[@intCast(victim)][100] ^= 0x40;

    var buf: [block_size]u8 = undefined;
    try testing.expectError(Error.Corrupt, t_fs2.readObj(obj, 0, &buf));
}

test "superblock rotation: older valid slot wins over a torn newest" {
    var rd: RamDev = undefined;
    const dev = freshDev(&rd);
    try fmtDev(dev);
    try t_fs.mount(dev);
    const obj = try t_fs.allocObject(.file, 1);
    _ = try t_fs.writeObj(obj, 0, "one", 1);
    try t_fs.sync(1);
    _ = try t_fs.writeObj(obj, 0, "two", 2);
    try t_fs.sync(2);
    const latest_slot = (t_fs.slot_next + sb_slots - 1) % sb_slots;
    // Corrupt the newest superblock: mount must fall back cleanly.
    t_storage[latest_slot * spb][500] ^= 0xFF;
    try t_fs2.mount(dev);
    var buf: [8]u8 = undefined;
    const n = try t_fs2.readObj(obj, 0, &buf);
    try testing.expectEqualStrings("one", buf[0..n]);
}

test "compression saves space; incompressible data stays raw" {
    var rd: RamDev = undefined;
    const dev = freshDev(&rd);
    try fmtDev(dev);
    try t_fs.mount(dev);
    const before = try t_fs.freeBlocksTotal();

    // 24 highly-compressible blocks.
    const zo = try t_fs.allocObject(.file, 1);
    var text: [block_size]u8 = undefined;
    for (0..block_size / 64) |i| @memcpy(text[i * 64 ..][0..64], "all work and no play makes moss a dull filesystem ~~~~~~~~~~~~~\n");
    for (0..24) |i| _ = try t_fs.writeObj(zo, i * block_size, &text, 1);
    try t_fs.sync(1);
    const after_comp = try t_fs.freeBlocksTotal();
    const comp_cost = before - after_comp;
    // 24 compressed blocks must cost far fewer than 24 free bytes
    // (sub-byte packing), plus a handful of metadata blocks.
    try testing.expect(comp_cost < 16);

    // 24 incompressible blocks cost at least one byte each.
    const ro = try t_fs.allocObject(.file, 2);
    var prng = std.Random.DefaultPrng.init(7);
    var rnd: [block_size]u8 = undefined;
    for (0..24) |i| {
        prng.random().bytes(&rnd);
        _ = try t_fs.writeObj(ro, i * block_size, &rnd, 2);
    }
    try t_fs.sync(2);
    const after_raw = try t_fs.freeBlocksTotal();
    try testing.expect(after_comp - after_raw >= 24);

    // Both read back exactly right after a remount.
    try t_fs2.mount(dev);
    var buf: [block_size]u8 = undefined;
    _ = try t_fs2.readObj(zo, 23 * block_size, &buf);
    try testing.expectEqualSlices(u8, &text, &buf);
    prng = std.Random.DefaultPrng.init(7);
    for (0..24) |i| {
        prng.random().bytes(&rnd);
        _ = try t_fs2.readObj(ro, i * block_size, &buf);
        try testing.expectEqualSlices(u8, &rnd, &buf);
    }
}

test "encrypted volume: roundtrip, key gating, wrong key fails at setKey" {
    var rd: RamDev = undefined;
    const dev = freshDev(&rd);
    try Fs.format(dev, test_group_secs, &test_master_key);
    try t_fs.mount(dev);
    try testing.expect(t_fs.keyRequired());

    // Keyless: allocation metadata is readable, objects are not.
    var buf: [64]u8 = undefined;
    try testing.expectError(Error.NoKey, t_fs.readObj(root_obj, 0, &buf));
    _ = try t_fs.freeBlocksTotal();

    // Wrong key: rejected at setKey by the superblock MAC, cleanly.
    var wrong = test_master_key;
    wrong[0] ^= 1;
    try testing.expectError(Error.BadKey, t_fs.setKey(&wrong));
    try testing.expect(t_fs.keyRequired());

    try t_fs.setKey(&test_master_key);
    const obj = try t_fs.allocObject(.file, 1);
    try t_fs.dirAdd(root_obj, "secret.txt", obj, .file, 1);
    _ = try t_fs.writeObj(obj, 0, "attack at dawn, obviously", 1);
    try t_fs.sync(1);

    // The plaintext must not appear anywhere on the device.
    const raw = @as([*]const u8, @ptrCast(&t_storage))[0 .. test_secs * sector_size];
    try testing.expect(std.mem.indexOf(u8, raw, "attack at dawn") == null);
    try testing.expect(std.mem.indexOf(u8, raw, "secret.txt") == null);

    // Remount + key: everything back.
    try t_fs2.mount(dev);
    try t_fs2.setKey(&test_master_key);
    const found = (try t_fs2.dirLookup(root_obj, "secret.txt")).?;
    const n = try t_fs2.readObj(found.obj, 0, &buf);
    try testing.expectEqualStrings("attack at dawn, obviously", buf[0..n]);
}

test "encrypted volume: ciphertext flip fails closed; SB splice is caught" {
    var rd: RamDev = undefined;
    const dev = freshDev(&rd);
    try Fs.format(dev, test_group_secs, &test_master_key);
    try t_fs.mount(dev);
    try t_fs.setKey(&test_master_key);
    const obj = try t_fs.allocObject(.file, 1);
    var pat: [block_size]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(3);
    prng.random().bytes(&pat);
    _ = try t_fs.writeObj(obj, 0, &pat, 1);
    try t_fs.sync(1);

    // Flip one ciphertext byte: the keyed MAC must reject the block.
    try t_fs2.mount(dev);
    try t_fs2.setKey(&test_master_key);
    const dn = try t_fs2.dnodeOf(obj);
    t_storage[@intCast(dn.direct[0].sec())][7] ^= 0x01;
    var buf: [block_size]u8 = undefined;
    try testing.expectError(Error.Corrupt, t_fs2.readObj(obj, 0, &buf));

    // SB splice: edit the elected slot and re-seal its keyless checksum.
    // Election still accepts it — but setKey's keyed MAC does not.
    const slot = (t_fs.slot_next + sb_slots - 1) % sb_slots;
    var sb: [block_size]u8 = undefined;
    for (0..spb) |i| @memcpy(sb[i * sector_size ..][0..sector_size], &t_storage[slot * spb + i]);
    sb[48] ^= 0x04; // graft a different objmap root pointer
    const sc = std.hash.XxHash64.hash(0x5342, sb[0 .. block_size - 8]);
    puU(u64, sb[block_size - 8 ..], sc);
    for (0..spb) |i| @memcpy(&t_storage[slot * spb + i], sb[i * sector_size ..][0..sector_size]);
    try t_fs2.mount(dev);
    try testing.expectError(Error.BadKey, t_fs2.setKey(&test_master_key));
}

// The heart of the matter: run a scripted workload; for every prefix of
// the write stream (clean cut AND torn final write), remount and verify
// the filesystem is consistent and equals either the pre- or post-txg
// state. Runs on both a plaintext and an encrypted volume.
fn crashSweep() !void {
    var rd: RamDev = undefined;
    var dev = freshDev(&rd);
    try fmtDev(dev);
    try mountKeyed(&t_fs, dev);
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
            rd = .{ .secs = &t_storage };
            rd.cut_after = cut;
            rd.tear_final = tear == 1 and cut > 0;
            dev = rd.dev();

            try mountKeyed(&t_fs2, dev);
            _ = try t_fs2.writeObj(obj, 0, "AFTER!-STATE", 2);
            const o2 = try t_fs2.allocObject(.file, 2);
            try t_fs2.dirAdd(root_obj, "g", o2, .file, 2);
            _ = try t_fs2.writeObj(o2, 0, "second file", 2);
            t_fs2.sync(2) catch {}; // the "crash" may surface as IoError

            // Power cycle: remount and verify exactly-old-or-new.
            rd.cut_after = null;
            rd.tear_final = false;
            try mountKeyed(&t_fs, dev);
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

test "crash injection sweep (plaintext)" {
    t_key = null;
    try crashSweep();
}

/// The same sweep across a directory's conversion to hashed and its
/// first split: every cut leaves either the 64-entry linear directory
/// or the converted one with 66 entries — never a torn table.
fn dirSweep() !void {
    var rd: RamDev = undefined;
    var dev = freshDev(&rd);
    try fmtDev(dev);
    try mountKeyed(&t_fs, dev);
    const d = try t_fs.allocObject(.dir, 1);
    try t_fs.dirAdd(root_obj, "d", d, .dir, 1);
    var name: [16]u8 = undefined;
    for (0..64) |i| {
        const n = std.fmt.bufPrint(&name, "n{d}", .{i}) catch unreachable;
        try t_fs.dirAdd(d, n, @intCast(100 + i), .file, 1);
    }
    try t_fs.sync(1);
    @memcpy(&t_snap, &t_storage);

    rd.wlog_len = 0;
    try t_fs.dirAdd(d, "n64", 164, .file, 2);
    try t_fs.dirAdd(d, "n65", 165, .file, 2);
    try t_fs.sync(2);
    const total_writes = rd.wlog_len;

    for (0..2) |tear| {
        var cut: usize = 0;
        while (cut <= total_writes) : (cut += 1) {
            @memcpy(&t_storage, &t_snap);
            rd = .{ .secs = &t_storage };
            rd.cut_after = cut;
            rd.tear_final = tear == 1 and cut > 0;
            dev = rd.dev();
            try mountKeyed(&t_fs2, dev);
            t_fs2.dirAdd(d, "n64", 164, .file, 2) catch {};
            t_fs2.dirAdd(d, "n65", 165, .file, 2) catch {};
            t_fs2.sync(2) catch {};

            rd.cut_after = null;
            rd.tear_final = false;
            try mountKeyed(&t_fs, dev);
            const dn = try t_fs.dnodeOf(d);
            const has64 = (try t_fs.dirLookup(d, "n64")) != null;
            const has65 = (try t_fs.dirLookup(d, "n65")) != null;
            try testing.expect(has64 == has65);
            try testing.expect(Fs.isHashed(&dn) == has64);
            for (0..64) |i| {
                const n = std.fmt.bufPrint(&name, "n{d}", .{i}) catch unreachable;
                try testing.expectEqual(@as(u32, @intCast(100 + i)), (try t_fs.dirLookup(d, n)).?.obj);
            }
        }
    }
}

test "crash injection sweep across a directory conversion (plaintext)" {
    t_key = null;
    try dirSweep();
}

test "crash injection sweep across a directory conversion (encrypted)" {
    t_key = &test_master_key;
    defer t_key = null;
    try dirSweep();
}

test "crash injection sweep (encrypted)" {
    t_key = &test_master_key;
    defer t_key = null;
    try crashSweep();
}

// Model-based randomized workload: mirror ops against a trivial in-memory
// model; verify equality after every commit and after remount. The data
// mix alternates compressible and incompressible content so both stored
// forms churn through the allocator.
fn modelRun() !void {
    var rd: RamDev = undefined;
    const dev = freshDev(&rd);
    try fmtDev(dev);
    try mountKeyed(&t_fs, dev);

    // 96 slots: the root directory outgrows one block and goes hashed
    // under the randomized churn, so both layouts see the model.
    const model_slots = 96;
    const Model = struct {
        used: [model_slots]bool = @splat(false),
        obj: [model_slots]u32 = undefined,
        content: [model_slots][96]u8 = undefined,
        len: [model_slots]usize = @splat(0),
    };
    var model: Model = .{};
    var prng = std.Random.DefaultPrng.init(0x6d6f5353);
    const rand = prng.random();

    var now: u64 = 10;
    for (0..1500) |_| {
        now += 1;
        const slot = rand.uintLessThan(usize, model_slots);
        const op = rand.uintLessThan(u8, 5);
        const name: [2]u8 = .{ 'a' + @as(u8, @intCast(slot / 10)), '0' + @as(u8, @intCast(slot % 10)) };
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
                if (rand.boolean()) {
                    rand.bytes(&data);
                } else {
                    @memset(&data, @as(u8, @intCast(slot)) + 'A');
                }
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
            try mountKeyed(&t_fs2, dev);
            break :blk &t_fs2;
        };
        for (0..model_slots) |slot| {
            const name: [2]u8 = .{ 'a' + @as(u8, @intCast(slot / 10)), '0' + @as(u8, @intCast(slot % 10)) };
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

test "randomized ops vs model (plaintext)" {
    t_key = null;
    try modelRun();
}

test "randomized ops vs model (encrypted)" {
    t_key = &test_master_key;
    defer t_key = null;
    try modelRun();
}
