//! Image staging for spawners. The kernel holds no image table: a spawner
//! copies the program it wants to run out of the boot archive (granted
//! read-only at spawn; later: an `img/` view on disk) into a shared
//! buffer, and spawn() copies from that buffer into the child. One
//! stage per spawner, reused for every spawn — the kernel's copy is
//! complete when spawn returns, so the stage is free again immediately.
//! Static linking makes this the whole loader: no relocation, no symbol
//! resolution, nothing in the kernel but a copy.

const shared = @import("shared");
const usys = @import("usys.zig");

pub const Stage = struct {
    handle: u64,
    va: u64,
    bytes: u64,

    /// The shm ceiling (64 pages = 256K) — comfortably above the largest
    /// image (fabric, ~140K carrying its own crypto).
    pub const default_pages: u64 = 64;

    pub fn init(pages: u64) ?Stage {
        const s = usys.shmCreate(pages);
        if (s.err != .ok) return null;
        const m = usys.shmMap(s.data[0]);
        if (m.err != .ok) return null;
        return .{ .handle = s.data[0], .va = m.data[0], .bytes = m.data[1] * 4096 };
    }

    /// Copy catalog image `id` out of a boot archive into the stage.
    /// Refuses an entry that is missing, oversized, not a MOSS image, or
    /// whose self-declared name disagrees with the catalog — a mislabeled
    /// archive is caught here, not by running the wrong program.
    pub fn load(self: *Stage, blob_va: u64, blob_len: u64, id: shared.ImageId) bool {
        const blob = @as([*]const u8, @ptrFromInt(blob_va))[0..blob_len];
        const image = shared.marcFind(blob, shared.imagePath(id)) orelse return false;
        if (image.len < @sizeOf(shared.UserImageHeader) or image.len > self.bytes) return false;
        var hdr: shared.UserImageHeader = undefined;
        @memcpy(@as([*]u8, @ptrCast(&hdr))[0..@sizeOf(shared.UserImageHeader)], image[0..@sizeOf(shared.UserImageHeader)]);
        if (hdr.magic != shared.UserImageHeader.expected_magic) return false;
        const want = @tagName(id);
        const have = hdr.nameSlice();
        if (have.len != want.len) return false;
        for (have, want) |a, b| {
            if (a != b) return false;
        }
        const dst = @as([*]u8, @ptrFromInt(self.va))[0..image.len];
        @memcpy(dst, image);
        return true;
    }
};
