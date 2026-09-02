//! The boot handshake every program starts with: serve the boot channel
//! until `go`, collecting capabilities by tag, secret bytes, and
//! argument text (shared.BootReq). Whoever spawned us holds the caps and
//! decides what we get; we only learn what each one is FOR.

const shared = @import("shared");
const usys = @import("usys.zig");

pub const max_secret = 256;
pub const max_data = 256;

pub const Setup = struct {
    caps: [shared.cap_tag_count]u64 = @splat(0),
    buf_va: u64 = 0, // the `buf` cap, mapped
    buf_pages: u64 = 0,
    secret_buf: [max_secret]u8 = @splat(0),
    secret_len: usize = 0,
    data_buf: [max_data]u8 = @splat(0),
    data_len: usize = 0,
    arg_buf: [24]u8 = @splat(0),
    arg_len: usize = 0,

    pub fn cap(s: *const Setup, tag: shared.CapTag) u64 {
        return s.caps[@intFromEnum(tag)];
    }

    pub fn has(s: *const Setup, tag: shared.CapTag) bool {
        return s.cap(tag) != 0;
    }

    pub fn arg(s: *const Setup) []const u8 {
        return s.arg_buf[0..s.arg_len];
    }

    pub fn secret(s: *const Setup) []const u8 {
        return s.secret_buf[0..s.secret_len];
    }

    pub fn data(s: *const Setup) []const u8 {
        return s.data_buf[0..s.data_len];
    }

    /// Wipe the secret once it has been used.
    pub fn wipeSecret(s: *Setup) void {
        @memset(&s.secret_buf, 0);
        s.secret_len = 0;
    }
};

/// Take the whole setup. Exits loudly on a protocol violation: a program
/// that cannot even be handed its world should not run.
pub fn take(chan_h: u64) Setup {
    var s: Setup = .{};
    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err != .ok) usys.exit(200);
        const req = shared.decodeMsg(shared.BootReq, r.data) orelse {
            _ = usys.replyTyped(shared.BootResp, chan_h, .refused, 0);
            continue;
        };
        var ok = true;
        switch (req) {
            .cap => |c| {
                if (c.tag < shared.cap_tag_count and r.cap != 0) {
                    s.caps[c.tag] = r.cap;
                    if (c.tag == @intFromEnum(shared.CapTag.buf)) {
                        const m = usys.shmMap(r.cap);
                        if (m.err == .ok) {
                            s.buf_va = m.data[0];
                            s.buf_pages = m.data[1];
                        } else ok = false;
                    }
                } else ok = false;
            },
            .secret => |sec| {
                if (s.buf_va == 0 or sec.len > max_secret or sec.off + sec.len > 4096) {
                    ok = false;
                } else {
                    const src: [*]volatile u8 = @ptrFromInt(s.buf_va + sec.off);
                    for (0..sec.len) |i| {
                        s.secret_buf[i] = src[i];
                        src[i] = 0; // the secret now lives only here
                    }
                    s.secret_len = sec.len;
                }
            },
            .data => |dat| {
                if (s.buf_va == 0 or dat.len > max_data or dat.off + dat.len > s.buf_pages * 4096) {
                    ok = false;
                } else {
                    const src: [*]const volatile u8 = @ptrFromInt(s.buf_va + dat.off);
                    for (0..dat.len) |i| s.data_buf[i] = src[i];
                    s.data_len = dat.len;
                }
            },
            .arg => |a| {
                const text = shared.wordsToStr(&s.arg_buf, .{ a.a, a.b, a.c });
                s.arg_len = text.len;
            },
            .go => {
                _ = usys.replyTyped(shared.BootResp, chan_h, .ok, 0);
                return s;
            },
        }
        _ = usys.replyTyped(shared.BootResp, chan_h, if (ok) .ok else .refused, 0);
    }
}

/// The spawner's side: hand a cap (tag) or `go` and wait for the ack.
pub fn give(boot_chan: u64, req: shared.BootReq, cap: u64) bool {
    return switch (usys.callTyped(shared.BootReq, shared.BootResp, boot_chan, req, cap)) {
        .ok => |rep| rep == .ok,
        .err => false,
    };
}

pub fn giveCap(boot_chan: u64, tag: shared.CapTag, cap: u64) bool {
    return give(boot_chan, .{ .cap = .{ .tag = @intFromEnum(tag) } }, cap);
}
