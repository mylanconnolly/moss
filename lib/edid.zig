//! EDID: what a monitor says about itself. The base block (128 bytes)
//! carries the maker's three-letter id, a product code and a serial —
//! together, an identity a display preference can be keyed by, so a
//! laptop docked to a different monitor gets that monitor's resolution —
//! and a first detailed timing that is the panel's native (preferred)
//! mode: for a fixed-pixel display, the highest resolution it can show.
//! QEMU's virtio-gpu synthesizes one of these too (name "QEMU Monitor",
//! preferred = the window's configured size), so the same path serves
//! the virtual seat and real hardware. Pure and host-tested.
const std = @import("std");

pub const Mode = struct { w: u32, h: u32 };

pub const Info = struct {
    /// "MFR-PPPP-SSSSSSSS": maker, product code, serial — filename-safe.
    id: [24]u8 = @splat(0),
    id_len: usize = 0,
    /// The monitor-name descriptor, if the block carries one.
    name: [13]u8 = @splat(0),
    name_len: usize = 0,
    /// The first detailed timing's active area: the native mode.
    preferred: ?Mode = null,

    pub fn idSlice(self: *const Info) []const u8 {
        return self.id[0..self.id_len];
    }
    pub fn nameSlice(self: *const Info) []const u8 {
        return self.name[0..self.name_len];
    }
};

const header = [_]u8{ 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00 };

/// Parse a base block. Null when the header or checksum is wrong; a
/// block without a preferred timing or a name still yields its identity.
pub fn parse(bytes: []const u8) ?Info {
    if (bytes.len < 128 or !std.mem.eql(u8, bytes[0..8], &header)) return null;
    var sum: u8 = 0;
    for (bytes[0..128]) |b| sum +%= b;
    if (sum != 0) return null;
    var info: Info = .{};
    // Manufacturer: three 5-bit letters, big-endian, 'A' = 1.
    const mfr = (@as(u16, bytes[8]) << 8) | bytes[9];
    const letters = [3]u8{ letter((mfr >> 10) & 0x1f), letter((mfr >> 5) & 0x1f), letter(mfr & 0x1f) };
    const product = @as(u16, bytes[10]) | (@as(u16, bytes[11]) << 8);
    const serial = @as(u32, bytes[12]) | (@as(u32, bytes[13]) << 8) | (@as(u32, bytes[14]) << 16) | (@as(u32, bytes[15]) << 24);
    const id = std.fmt.bufPrint(&info.id, "{s}-{X:0>4}-{X:0>8}", .{ letters, product, serial }) catch return null;
    info.id_len = id.len;
    // Four 18-byte descriptors. A detailed timing has a nonzero pixel
    // clock; a display descriptor starts with a zero clock and a tag.
    var d: usize = 54;
    while (d + 18 <= 126) : (d += 18) {
        const desc = bytes[d .. d + 18];
        const clock = @as(u16, desc[0]) | (@as(u16, desc[1]) << 8);
        if (clock != 0) {
            if (info.preferred == null) {
                const w = @as(u32, desc[2]) | (@as(u32, desc[4] & 0xf0) << 4);
                const h = @as(u32, desc[5]) | (@as(u32, desc[7] & 0xf0) << 4);
                if (w > 0 and h > 0) info.preferred = .{ .w = w, .h = h };
            }
        } else if (desc[3] == 0xfc and info.name_len == 0) {
            // The name: up to 13 ASCII bytes, newline-terminated, space-padded.
            var n: usize = 0;
            while (n < 13 and desc[5 + n] != 0x0a) : (n += 1) info.name[n] = if (desc[5 + n] < 0x20 or desc[5 + n] > 0x7e) '?' else desc[5 + n];
            while (n > 0 and info.name[n - 1] == ' ') n -= 1;
            info.name_len = n;
        }
    }
    return info;
}

fn fixChecksum(b: *[128]u8) void {
    var sum: u8 = 0;
    for (b[0..127]) |x| sum +%= x;
    b[127] = 0 -% sum;
}

fn letter(code: u16) u8 {
    return if (code >= 1 and code <= 26) @intCast('A' + code - 1) else '?';
}

// ------------------------------------------------------------------ tests

/// A base block the way a generator writes one: header, identity, one
/// detailed timing for `w`x`h`, a name descriptor, a valid checksum.
fn block(mfr: [3]u8, product: u16, serial: u32, w: u32, h: u32, name: []const u8) [128]u8 {
    var b: [128]u8 = @splat(0);
    @memcpy(b[0..8], &header);
    const code: u16 = (@as(u16, mfr[0] - 'A' + 1) << 10) | (@as(u16, mfr[1] - 'A' + 1) << 5) | (mfr[2] - 'A' + 1);
    b[8] = @intCast(code >> 8);
    b[9] = @intCast(code & 0xff);
    b[10] = @intCast(product & 0xff);
    b[11] = @intCast(product >> 8);
    b[12] = @intCast(serial & 0xff);
    b[13] = @intCast((serial >> 8) & 0xff);
    b[14] = @intCast((serial >> 16) & 0xff);
    b[15] = @intCast(serial >> 24);
    b[18] = 1; // EDID 1.4
    b[19] = 4;
    // Detailed timing 1 at 54: pixel clock, then h/v active with the high nibbles.
    b[54] = 0x30;
    b[55] = 0x2a;
    b[56] = @intCast(w & 0xff);
    b[58] = @intCast((w >> 8) << 4);
    b[59] = @intCast(h & 0xff);
    b[61] = @intCast((h >> 8) << 4);
    // Descriptor 2 at 72: the monitor name.
    b[75] = 0xfc;
    var i: usize = 0;
    while (i < 13) : (i += 1) b[77 + i] = if (i < name.len) name[i] else if (i == name.len) 0x0a else ' ';
    // Descriptors 3 and 4: dummy (tag 0x10).
    b[93] = 0x10;
    b[111] = 0x10;
    var sum: u8 = 0;
    for (b[0..127]) |x| sum +%= x;
    b[127] = 0 -% sum;
    return b;
}

test "identity, native mode and name come out of a generated block" {
    const b = block(.{ 'Q', 'E', 'M' }, 0x1234, 1, 1920, 1200, "QEMU Monitor");
    const info = parse(&b).?;
    try std.testing.expectEqualStrings("QEM-1234-00000001", info.idSlice());
    try std.testing.expectEqualStrings("QEMU Monitor", info.nameSlice());
    try std.testing.expectEqual(Mode{ .w = 1920, .h = 1200 }, info.preferred.?);
    // The id is filename-safe: letters, digits and dashes only.
    for (info.idSlice()) |c| try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '-');
}

test "a corrupt block is refused; a nameless one still has an identity" {
    var b = block(.{ 'D', 'E', 'L' }, 0xa0c1, 0x30313233, 2560, 1440, "DELL U2720Q");
    try std.testing.expectEqual(Mode{ .w = 2560, .h = 1440 }, parse(&b).?.preferred.?);
    b[127] +%= 1;
    try std.testing.expect(parse(&b) == null);
    b[127] -%= 1;
    b[0] = 1;
    try std.testing.expect(parse(&b) == null);
    var short = block(.{ 'A', 'B', 'C' }, 1, 2, 1024, 768, "");
    short[75] = 0x10; // no name descriptor
    fixChecksum(&short);
    const info = parse(&short).?;
    try std.testing.expectEqual(@as(usize, 0), info.name_len);
    try std.testing.expectEqualStrings("ABC-0001-00000002", info.idSlice());
    try std.testing.expect(parse(short[0..100]) == null);
}
