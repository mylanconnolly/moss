//! fontcli — the runtime font-install drill's client. It plays a user
//! installing a font: copy an uninstalled .ttf from the staging tier into
//! the filesystem fonts directory, then tell fontsvc to `rescan`. fontsvc
//! (in filesystem mode) picks the new family up with no restart, which is
//! the whole point — a font a user drops in appears live.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");
const fsc = @import("fsclient.zig");

comptime {
    asm (usys.imageHeader("fontcli"));
}

pub const panic = std.debug.FullPanic(uPanic);
fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

var glog: u64 = 0;
var font_data: [256 << 10]u8 = undefined; // IBM Plex Serif is ~163 KB

fn fail(msg: []const u8) noreturn {
    _ = usys.log(glog, msg);
    usys.exit(1);
}

export fn umain(log_h: u64, chan_h: u64, _: u64) callconv(.c) noreturn {
    glog = log_h;
    const setup = boot.take(chan_h);
    if (!setup.has(.view) or !setup.has(.font)) fail("fontcli: missing view or font cap");
    const view = setup.cap(.view); // rooted at the assets tier (rw)
    const fontc = setup.cap(.font);

    // Sync: a round-trip to fontsvc guarantees it has finished its
    // start-up scan (Sans + Mono) before we install — so the new family is
    // picked up by the `rescan` below, not that first scan.
    switch (usys.callTyped(shared.FontReq, shared.FontResp, fontc, .{ .metrics = .{ .role = 0 } }, 0)) {
        .ok => {},
        .err => fail("fontcli: fontsvc did not answer"),
    }

    const ab = fsc.attachBuf(view);
    if (ab.va == 0) fail("fontcli: no view buffer");
    const buf: [*]u8 = @ptrFromInt(ab.va);

    // Read the uninstalled font from the staging tier.
    const src = "available/IBMPlexSerif-Regular.ttf";
    const bytes = fsc.readWhole(view, buf, src, &font_data) orelse fail("fontcli: cannot read the staged font");

    // Install it: write it into the fonts directory fontsvc watches.
    const dst = "fonts/IBMPlexSerif-Regular.ttf";
    const fd = switch (fsc.fsOpen(view, buf, dst, 1)) {
        .fd => |f| f,
        .err => fail("fontcli: cannot create the font file"),
    };
    var off: usize = 0;
    while (off < bytes.len) {
        const n = @min(shared.fs_max_io, bytes.len - off);
        if (!fsc.fsWriteAt(view, buf, fd, off, bytes[off .. off + n])) fail("fontcli: write failed");
        off += n;
    }
    fsc.fsClose(view, fd);
    _ = usys.log(glog, "fontcli: installed a font into the fonts directory");

    // Tell fontsvc to pick it up live — no restart.
    switch (usys.callTyped(shared.FontReq, shared.FontResp, fontc, .rescan, 0)) {
        .ok => |rep| if (rep != .ok) fail("fontcli: rescan refused"),
        .err => fail("fontcli: rescan did not answer"),
    }
    _ = usys.log(glog, "fontrescan: rescanned");
    usys.exit(0);
}
