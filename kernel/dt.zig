//! Minimal flattened devicetree (FDT) parsing: just enough to find RAM.
//! Pure code over a byte buffer — no MMIO, no allocation — so it also runs
//! in host-side unit tests.

const std = @import("std");

pub const MemRegion = struct {
    base: u64,
    size: u64,
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

    // Strings block: "reg" at 0, "#address-cells" at 4, "#size-cells" at 19.
    const strings = "reg\x00#address-cells\x00#size-cells\x00";

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
}
