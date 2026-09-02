//! The run-tool boot handshake: a program started by msh serves its boot
//! channel until `go`, collecting the console (channel + shared buffer),
//! an optional filesystem view, and its argument text. After takeSetup
//! returns, tty is wired and the tool owns the console until it exits.

const shared = @import("shared");
const usys = @import("usys.zig");
const tty = @import("tty.zig");

pub const Setup = struct {
    view: u64 = 0,
    arg_buf: [24]u8 = @splat(0),
    arg_len: usize = 0,

    pub fn arg(s: *const Setup) []const u8 {
        return s.arg_buf[0..s.arg_len];
    }
};

pub fn takeSetup(chan_h: u64) Setup {
    var s: Setup = .{};
    var cons_chan: u64 = 0;
    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err != .ok) usys.exit(200);
        const req = shared.decodeMsg(shared.RunReq, r.data) orelse usys.exit(201);
        switch (req) {
            .console => cons_chan = r.cap,
            .console_buf => {
                const m = usys.shmMap(r.cap);
                if (m.err != .ok) usys.exit(202);
                tty.init(cons_chan, m.data[0]);
            },
            .view => s.view = r.cap,
            .arg => |a| {
                const text = shared.wordsToStr(&s.arg_buf, .{ a.a, a.b, a.c });
                s.arg_len = text.len;
            },
            .go => {
                _ = usys.replyTyped(shared.RunResp, chan_h, .ok, 0);
                break;
            },
        }
        _ = usys.replyTyped(shared.RunResp, chan_h, .ok, 0);
    }
    if (cons_chan == 0 or tty.cons_buf == 0) usys.exit(203);
    return s;
}
