//! Minimal flattened devicetree (FDT) parsing: RAM, bootargs, and the
//! virtio-mmio transports (the device window and SPI range the kernel
//! mints device capabilities from). Pure code over a byte buffer — no
//! MMIO, no allocation — so it also runs in host-side unit tests.

const std = @import("std");

pub const MemRegion = struct {
    base: u64,
    size: u64,
};

/// The virtio-mmio transports as one window: every "virtio,mmio" node's
/// reg lies in [mmio_base, mmio_base + mmio_pages*4K) and its SPI in
/// [irq_base, irq_base + irq_count) as GIC intids. These are the two
/// device capabilities the kernel mints at boot; a driver scans the
/// window for its device id and binds the slot's interrupt.
pub const VirtioWindow = struct {
    mmio_base: u64,
    mmio_pages: u64,
    irq_base: u32,
    irq_count: u32,
};

pub const Error = error{
    BadMagic,
    Truncated,
    Malformed,
    TooManyRegions,
};

const magic: u32 = 0xd00dfeed;

const tok_begin_node: u32 = 1;
const tok_end_node: u32 = 2;
const tok_prop: u32 = 3;
const tok_nop: u32 = 4;
const tok_end: u32 = 9;

pub const Fdt = struct {
    blob: []const u8,
    struct_off: u32,
    strings_off: u32,

    pub fn parse(blob_ptr: [*]const u8) Error!Fdt {
        const header = blob_ptr[0..40];
        if (be32(header[0..4]) != magic) return Error.BadMagic;
        const total_size = be32(header[4..8]);
        if (total_size < 40) return Error.Truncated;
        return .{
            .blob = blob_ptr[0..total_size],
            .struct_off = be32(header[8..12]),
            .strings_off = be32(header[12..16]),
        };
    }

    pub fn totalSize(self: Fdt) usize {
        return self.blob.len;
    }

    /// Collect the "reg" entries of every top-level node named "memory" or
    /// "memory@...". Assumes 2 address cells and 2 size cells, which the
    /// root node on every 64-bit platform we target declares; the assumption
    /// is checked when the root declares otherwise.
    pub fn memoryRegions(self: Fdt, out: []MemRegion) Error![]MemRegion {
        var count: usize = 0;
        var depth: i32 = 0;
        var in_memory_node = false;
        var pos: usize = self.struct_off;

        while (true) {
            const tok = try self.word(&pos);
            switch (tok) {
                tok_begin_node => {
                    const name = try self.nodeName(&pos);
                    depth += 1;
                    if (depth == 2) {
                        in_memory_node = std.mem.eql(u8, name, "memory") or
                            std.mem.startsWith(u8, name, "memory@");
                    }
                },
                tok_end_node => {
                    if (depth == 2) in_memory_node = false;
                    depth -= 1;
                    if (depth < 0) return Error.Malformed;
                    if (depth == 0) return out[0..count];
                },
                tok_prop => {
                    const len = try self.word(&pos);
                    const name_off = try self.word(&pos);
                    const data = try self.bytes(&pos, len);
                    const name = try self.string(name_off);
                    if (depth == 1 and
                        (std.mem.eql(u8, name, "#address-cells") or
                            std.mem.eql(u8, name, "#size-cells")))
                    {
                        if (data.len != 4 or be32(data[0..4]) != 2) return Error.Malformed;
                    }
                    if (in_memory_node and depth == 2 and std.mem.eql(u8, name, "reg")) {
                        var off: usize = 0;
                        while (off + 16 <= data.len) : (off += 16) {
                            if (count == out.len) return Error.TooManyRegions;
                            out[count] = .{
                                .base = be64(data[off..][0..8]),
                                .size = be64(data[off + 8 ..][0..8]),
                            };
                            count += 1;
                        }
                    }
                },
                tok_nop => {},
                tok_end => return out[0..count],
                else => return Error.Malformed,
            }
        }
    }

    /// Walk the top-level "virtio,mmio" nodes: the span of their reg
    /// windows and SPIs. Null when the tree has none. Assumes the root's
    /// 2/2 address/size cells and 3-cell GIC interrupt specifiers
    /// (type, number, flags; type 0 = SPI, intid = number + 32).
    pub fn virtioWindow(self: Fdt) ?VirtioWindow {
        var lo: u64 = std.math.maxInt(u64);
        var hi: u64 = 0;
        var spi_lo: u32 = std.math.maxInt(u32);
        var spi_hi: u32 = 0;
        var found = false;
        var depth: i32 = 0;
        var pos: usize = self.struct_off;
        // Per node: seen while inside it, applied at end-node when the
        // compatible string matched.
        var is_virtio = false;
        var reg_base: u64 = 0;
        var reg_size: u64 = 0;
        var spi: ?u32 = null;
        while (true) {
            const tok = self.word(&pos) catch return null;
            switch (tok) {
                tok_begin_node => {
                    _ = self.nodeName(&pos) catch return null;
                    depth += 1;
                    if (depth == 2) {
                        is_virtio = false;
                        reg_size = 0;
                        spi = null;
                    }
                },
                tok_end_node => {
                    if (depth == 2 and is_virtio and reg_size > 0) {
                        found = true;
                        lo = @min(lo, reg_base);
                        hi = @max(hi, reg_base + reg_size);
                        if (spi) |s| {
                            spi_lo = @min(spi_lo, s);
                            spi_hi = @max(spi_hi, s);
                        }
                    }
                    depth -= 1;
                    if (depth <= 0) break;
                },
                tok_prop => {
                    const len = self.word(&pos) catch return null;
                    const name_off = self.word(&pos) catch return null;
                    const data = self.bytes(&pos, len) catch return null;
                    const name = self.string(name_off) catch return null;
                    if (depth != 2) continue;
                    if (std.mem.eql(u8, name, "compatible")) {
                        is_virtio = std.mem.indexOf(u8, data, "virtio,mmio") != null;
                    } else if (std.mem.eql(u8, name, "reg") and data.len >= 16) {
                        reg_base = be64(data[0..8]);
                        reg_size = be64(data[8..16]);
                    } else if (std.mem.eql(u8, name, "interrupts") and data.len >= 12) {
                        if (be32(data[0..4]) == 0) spi = be32(data[4..8]) + 32;
                    }
                },
                tok_nop => {},
                else => break,
            }
        }
        if (!found) return null;
        const base = lo & ~@as(u64, 0xfff);
        const end = std.mem.alignForward(u64, hi, 0x1000);
        return .{
            .mmio_base = base,
            .mmio_pages = (end - base) / 0x1000,
            .irq_base = if (spi_lo == std.math.maxInt(u32)) 0 else spi_lo,
            .irq_count = if (spi_lo == std.math.maxInt(u32)) 0 else spi_hi - spi_lo + 1,
        };
    }

    /// The /chosen bootargs string (QEMU -append), if present.
    pub fn bootargs(self: Fdt) ?[]const u8 {
        var depth: i32 = 0;
        var in_chosen = false;
        var pos: usize = self.struct_off;
        while (true) {
            const tok = self.word(&pos) catch return null;
            switch (tok) {
                tok_begin_node => {
                    const name = self.nodeName(&pos) catch return null;
                    depth += 1;
                    if (depth == 2) in_chosen = std.mem.eql(u8, name, "chosen");
                },
                tok_end_node => {
                    if (depth == 2) in_chosen = false;
                    depth -= 1;
                    if (depth <= 0) return null;
                },
                tok_prop => {
                    const len = self.word(&pos) catch return null;
                    const name_off = self.word(&pos) catch return null;
                    const data = self.bytes(&pos, len) catch return null;
                    const name = self.string(name_off) catch return null;
                    if (in_chosen and std.mem.eql(u8, name, "bootargs") and data.len > 0) {
                        // Nul-terminated.
                        var n: usize = 0;
                        while (n < data.len and data[n] != 0) n += 1;
                        return data[0..n];
                    }
                },
                tok_nop => {},
                else => return null,
            }
        }
    }

    fn word(self: Fdt, pos: *usize) Error!u32 {
        if (pos.* + 4 > self.blob.len) return Error.Truncated;
        const v = be32(self.blob[pos.*..][0..4]);
        pos.* += 4;
        return v;
    }

    fn bytes(self: Fdt, pos: *usize, len: u32) Error![]const u8 {
        if (pos.* + len > self.blob.len) return Error.Truncated;
        const data = self.blob[pos.*..][0..len];
        pos.* = std.mem.alignForward(usize, pos.* + len, 4);
        return data;
    }

    fn nodeName(self: Fdt, pos: *usize) Error![]const u8 {
        const start = pos.*;
        const end = std.mem.indexOfScalarPos(u8, self.blob, start, 0) orelse
            return Error.Truncated;
        pos.* = std.mem.alignForward(usize, end + 1, 4);
        return self.blob[start..end];
    }

    fn string(self: Fdt, off: u32) Error![]const u8 {
        const start = self.strings_off + off;
        if (start >= self.blob.len) return Error.Truncated;
        const end = std.mem.indexOfScalarPos(u8, self.blob, start, 0) orelse
            return Error.Truncated;
        return self.blob[start..end];
    }
};

fn be32(b: *const [4]u8) u32 {
    return std.mem.readInt(u32, b, .big);
}

fn be64(b: *const [8]u8) u64 {
    return std.mem.readInt(u64, b, .big);
}

test "parses memory regions from a synthetic FDT" {
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    const w = struct {
        fn word(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u32) !void {
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, v, .big);
            try list.appendSlice(alloc, &buf);
        }
        fn str(list: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
            try list.appendSlice(alloc, s);
            try list.append(alloc, 0);
            while (list.items.len % 4 != 0) try list.append(alloc, 0);
        }
    };

    // Strings block: "reg" at 0, "#address-cells" at 4, "#size-cells" at 19,
    // "compatible" at 31, "interrupts" at 42.
    const strings = "reg\x00#address-cells\x00#size-cells\x00compatible\x00interrupts\x00";

    // Header (40 bytes), then struct block, then strings block.
    try blob.appendSlice(a, &[_]u8{0} ** 40);
    const struct_off: u32 = 40;

    try w.word(&blob, a, tok_begin_node);
    try w.str(&blob, a, ""); // root node name
    try w.word(&blob, a, tok_prop); // #address-cells = 2
    try w.word(&blob, a, 4);
    try w.word(&blob, a, 4);
    try w.word(&blob, a, 2);
    try w.word(&blob, a, tok_prop); // #size-cells = 2
    try w.word(&blob, a, 4);
    try w.word(&blob, a, 19);
    try w.word(&blob, a, 2);
    try w.word(&blob, a, tok_begin_node);
    try w.str(&blob, a, "memory@40000000");
    try w.word(&blob, a, tok_prop); // reg = <0x40000000 0x20000000>
    try w.word(&blob, a, 16);
    try w.word(&blob, a, 0);
    try w.word(&blob, a, 0);
    try w.word(&blob, a, 0x40000000);
    try w.word(&blob, a, 0);
    try w.word(&blob, a, 0x20000000);
    try w.word(&blob, a, tok_end_node);
    // Two virtio-mmio transports, 0x200 apart, SPIs 16 and 17.
    for ([_]u32{ 0x0a000000, 0x0a000200 }, [_]u32{ 16, 17 }) |base, spi| {
        try w.word(&blob, a, tok_begin_node);
        try w.str(&blob, a, "virtio_mmio@a000000");
        try w.word(&blob, a, tok_prop); // compatible = "virtio,mmio"
        try w.word(&blob, a, 12);
        try w.word(&blob, a, 31);
        try w.str(&blob, a, "virtio,mmio");
        try w.word(&blob, a, tok_prop); // reg = <0 base 0 0x200>
        try w.word(&blob, a, 16);
        try w.word(&blob, a, 0);
        try w.word(&blob, a, 0);
        try w.word(&blob, a, base);
        try w.word(&blob, a, 0);
        try w.word(&blob, a, 0x200);
        try w.word(&blob, a, tok_prop); // interrupts = <0 spi 1>
        try w.word(&blob, a, 12);
        try w.word(&blob, a, 42);
        try w.word(&blob, a, 0);
        try w.word(&blob, a, spi);
        try w.word(&blob, a, 1);
        try w.word(&blob, a, tok_end_node);
    }
    try w.word(&blob, a, tok_end_node);
    try w.word(&blob, a, tok_end);

    const strings_off: u32 = @intCast(blob.items.len);
    try blob.appendSlice(a, strings);

    // Patch the header.
    std.mem.writeInt(u32, blob.items[0..4], magic, .big);
    std.mem.writeInt(u32, blob.items[4..8], @intCast(blob.items.len), .big);
    std.mem.writeInt(u32, blob.items[8..12], struct_off, .big);
    std.mem.writeInt(u32, blob.items[12..16], strings_off, .big);

    const fdt = try Fdt.parse(blob.items.ptr);
    var regions: [4]MemRegion = undefined;
    const found = try fdt.memoryRegions(&regions);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(@as(u64, 0x40000000), found[0].base);
    try std.testing.expectEqual(@as(u64, 0x20000000), found[0].size);

    const vw = fdt.virtioWindow().?;
    try std.testing.expectEqual(@as(u64, 0x0a000000), vw.mmio_base);
    try std.testing.expectEqual(@as(u64, 1), vw.mmio_pages);
    try std.testing.expectEqual(@as(u32, 48), vw.irq_base);
    try std.testing.expectEqual(@as(u32, 2), vw.irq_count);
}
