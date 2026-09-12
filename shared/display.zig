//! Output modes offered by the current virtual GPU backend. Hardware drivers
//! will supply their own validated timing catalog behind the same output API.
const std = @import("std");
pub const max_w = 1920;
pub const max_h = 1200;
pub const max_pages = (max_w * max_h * 4 + 4095) / 4096;
pub const Mode = struct { w: u32, h: u32 };
pub const modes = [_]Mode{ .{ .w = 1024, .h = 768 }, .{ .w = 1280, .h = 720 }, .{ .w = 1280, .h = 800 }, .{ .w = 1280, .h = 1024 }, .{ .w = 1600, .h = 900 }, .{ .w = 1920, .h = 1080 }, .{ .w = 1920, .h = 1200 } };
pub fn valid(w: u32, h: u32) bool {
    return w >= 1024 and h >= 720 and w <= max_w and h <= max_h;
}
pub fn offered(w: u32, h: u32, preferred: Mode) bool {
    if (!valid(w, h)) return false;
    if (w == preferred.w and h == preferred.h) return true;
    for (modes) |m| if (m.w == w and m.h == h) return true;
    return false;
}
test "output modes respect backing limits and reject arbitrary requests" {
    const preferred: Mode = .{ .w = 1366, .h = 768 };
    for (modes) |m| {
        try std.testing.expect(offered(m.w, m.h, preferred));
        try std.testing.expect((@as(usize, m.w) * m.h * 4 + 4095) / 4096 <= max_pages);
    }
    try std.testing.expect(offered(1366, 768, preferred));
    try std.testing.expect(!offered(1000, 800, preferred));
    try std.testing.expect(!offered(3840, 2160, .{ .w = 3840, .h = 2160 }));
}
