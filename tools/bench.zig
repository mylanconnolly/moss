//! Host baseline benchmarks for the mossfs v3 stack: crypto/compression
//! primitives and the filesystem core end-to-end over a RAM device.
//! Run with `zig build bench`. Numbers land in DESIGN.md as the baseline
//! the FP/SIMD + hardware-AES work will be measured against.
//!
//! Honesty note: on this host std.crypto's AES uses the CPU's AES
//! instructions; moss userspace today is built without NEON and gets the
//! software fallback. `zig build bench-soft` builds this same program
//! with the AES feature stripped to approximate that path.

const std = @import("std");
const mosslib = @import("mosslib");
const lz4 = mosslib.lz4;
const xts = mosslib.xts;
const mossfs = @import("mossfs");

const block = 4096;
const meg = 1 << 20;

var g_io: std.Io = undefined;
var t0: std.Io.Clock.Timestamp = undefined;

const timer = struct {
    fn reset() void {
        t0 = std.Io.Clock.Timestamp.now(g_io, .awake);
    }
    fn read() u64 {
        const t1 = std.Io.Clock.Timestamp.now(g_io, .awake);
        return @intCast(t0.durationTo(t1).raw.toNanoseconds());
    }
};

fn mbps(bytes: u64, ns: u64) u64 {
    if (ns == 0) return 0;
    return bytes * 1_000_000_000 / ns / meg;
}

fn corpus(kind: enum { text, random, zeros }, buf: *[block]u8) void {
    switch (kind) {
        .text => {
            for (0..block / 64) |i| {
                @memcpy(buf[i * 64 ..][0..64], "all work and no play makes moss a dull filesystem ~~~~~~~~~~~~~\n");
            }
        },
        .random => {
            var prng = std.Random.DefaultPrng.init(0xbe7c);
            prng.random().bytes(buf);
        },
        .zeros => @memset(buf, 0),
    }
}

pub fn main(init: std.process.Init) !void {
    g_io = init.io;
    const aes_impl = if (std.crypto.core.aes.has_hardware_support) "hardware" else "software";
    std.debug.print("== mossfs v3 baselines ({s} AES on this build) ==\n\n", .{aes_impl});

    try primitives();
    try coreBench();
}

fn primitives() !void {
    var buf: [block]u8 = undefined;
    var out: [block]u8 = undefined;
    const iters = 4096; // 16MB per measurement
    const total: u64 = iters * block;

    // Checksums.
    corpus(.random, &buf);
    var sink: u64 = 0;
    timer.reset();
    for (0..iters) |_| sink +%= std.hash.XxHash64.hash(0x6d6f7373, &buf);
    std.debug.print("xxhash64        {d:>6} MB/s\n", .{mbps(total, timer.read())});

    const SipMac = std.crypto.auth.siphash.SipHash64(2, 4);
    const mkey: [16]u8 = @splat(0x5a);
    timer.reset();
    for (0..iters) |_| sink +%= SipMac.toInt(&buf, &mkey);
    std.debug.print("siphash-2-4 MAC {d:>6} MB/s\n", .{mbps(total, timer.read())});

    // XTS (per 4K block = 8 sectors).
    var xkey: [64]u8 = undefined;
    for (&xkey, 0..) |*b, i| b.* = @intCast(i);
    const ctx = xts.Xts256.init(xkey);
    timer.reset();
    for (0..iters) |it| {
        for (0..8) |s| ctx.encryptSector(buf[s * 512 ..][0..512], it * 8 + s);
    }
    std.debug.print("xts encrypt     {d:>6} MB/s\n", .{mbps(total, timer.read())});
    timer.reset();
    for (0..iters) |it| {
        for (0..8) |s| ctx.decryptSector(buf[s * 512 ..][0..512], it * 8 + s);
    }
    std.debug.print("xts decrypt     {d:>6} MB/s\n", .{mbps(total, timer.read())});

    // LZ4 on the three corpora.
    var tbl: lz4.EncTable = .{};
    inline for (.{ .text, .zeros, .random }) |kind| {
        corpus(kind, &buf);
        var clen: usize = 0;
        timer.reset();
        for (0..iters) |_| {
            clen = lz4.compress(&buf, &out, &tbl) orelse block;
        }
        const enc_ns = timer.read();
        var dlen: usize = 0;
        timer.reset();
        if (clen < block) {
            for (0..iters) |_| dlen = try lz4.decompress(out[0..clen], &buf);
        }
        const dec_ns = timer.read();
        std.debug.print("lz4 {s:<7} c {d:>6} MB/s  d {d:>6} MB/s  ratio {d}%\n", .{
            @tagName(kind),                               mbps(total, enc_ns),
            if (clen < block) mbps(total, dec_ns) else 0, clen * 100 / block,
        });
        sink +%= dlen;
    }
    std.mem.doNotOptimizeAway(sink);
    std.debug.print("\n", .{});
}

// ---------------------------------------------------------- core bench

const vol_secs = 65536; // 32MB RAM volume
var storage: [vol_secs][512]u8 = undefined;
var rd: mossfs.RamDev = undefined;
var fs: mossfs.Fs = undefined;

const master_key: [32]u8 = @splat(0x42);

fn coreBench() !void {
    std.debug.print("mossfs core, 32MB RAM volume, 8MB file, 4K writes:\n", .{});
    inline for (.{ false, true }) |enc| {
        inline for (.{ .text, .random }) |kind| {
            try oneConfig(enc, kind);
        }
    }
}

fn oneConfig(comptime enc: bool, comptime kind: anytype) !void {
    for (&storage) |*s| @memset(s, 0);
    rd = .{ .secs = &storage };
    const dev = rd.dev();
    const key: ?*const [32]u8 = if (enc) &master_key else null;
    try mossfs.Fs.format(dev, 32768, key);
    try fs.mount(dev);
    if (enc) try fs.setKey(&master_key);

    var buf: [block]u8 = undefined;
    corpus(kind, &buf);
    const nblocks = 2048; // 8MB
    const free_before = try fs.freeBlocksTotal();
    const obj = try fs.allocObject(.file, 1);

    timer.reset();
    for (0..nblocks) |i| {
        buf[0] = @truncate(i); // defeat trivial dedup-like effects
        _ = try fs.writeObj(obj, i * block, &buf, 1);
        try fs.maybeCommit(1);
    }
    try fs.sync(1);
    const w_ns = timer.read();

    var sum: u64 = 0;
    timer.reset();
    for (0..nblocks) |i| {
        _ = try fs.readObj(obj, i * block, &buf);
        sum +%= buf[1];
    }
    const r_ns = timer.read();
    std.mem.doNotOptimizeAway(sum);

    const free_after = try fs.freeBlocksTotal();
    const cfg = if (enc) "enc  " else "plain";
    std.debug.print("  {s} {s:<7} write+sync {d:>5} MB/s   read {d:>5} MB/s   disk cost {d} blocks for {d}\n", .{
        cfg,                      @tagName(kind), mbps(nblocks * block, w_ns), mbps(nblocks * block, r_ns),
        free_before - free_after, nblocks,
    });
}
