//! Console text output for msh and the programs it runs: a byte pipe to
//! the console driver (channel + shared buffer) and a small line builder.
//! Text exists only here, at the human boundary.

const shared = @import("shared");
const usys = @import("usys.zig");

pub var cons_chan: u64 = 0;
pub var cons_buf: u64 = 0;

pub fn init(chan: u64, buf_va: u64) void {
    cons_chan = chan;
    cons_buf = buf_va;
}

pub fn out(s: []const u8) void {
    var off: usize = 0;
    while (off < s.len) {
        const chunk = @min(s.len - off, 2048);
        const dst: [*]volatile u8 = @ptrFromInt(cons_buf);
        for (0..chunk) |i| dst[i] = s[off + i];
        switch (usys.callTyped(shared.ConsReq, shared.ConsResp, cons_chan, .{
            .write = .{ .len = chunk },
        }, 0)) {
            .ok => {},
            .err => usys.exit(146),
        }
        off += chunk;
    }
}

pub const Line = struct {
    buf: [256]u8 = undefined,
    n: usize = 0,

    pub fn str(l: *Line, s: []const u8) *Line {
        const k = @min(s.len, l.buf.len - l.n);
        @memcpy(l.buf[l.n .. l.n + k], s[0..k]);
        l.n += k;
        return l;
    }

    pub fn num(l: *Line, v: u64) *Line {
        var ds: [20]u8 = undefined;
        var d: usize = 0;
        var x = v;
        while (true) {
            ds[d] = '0' + @as(u8, @intCast(x % 10));
            d += 1;
            x /= 10;
            if (x == 0) break;
        }
        while (d > 0) {
            d -= 1;
            _ = l.str(ds[d .. d + 1]);
        }
        return l;
    }

    pub fn hex(l: *Line, bytes: []const u8) *Line {
        const digits_ = "0123456789abcdef";
        for (bytes) |b| {
            _ = l.str(&[_]u8{ digits_[b >> 4], digits_[b & 15] });
        }
        return l;
    }

    /// Right-pad with spaces to column `col` (from line start).
    pub fn pad(l: *Line, col: usize) *Line {
        while (l.n < col and l.n < l.buf.len) {
            l.buf[l.n] = ' ';
            l.n += 1;
        }
        return l;
    }

    pub fn flush(l: *Line) void {
        _ = l.str("\r\n");
        out(l.buf[0..l.n]);
        l.n = 0;
    }
};

/// The `ps` table, rendered from domain_list records: shared by msh's
/// builtin and the standalone ps tool so both read the same.
pub fn domainTable(recs: []const u8, count: u64) void {
    var l: Line = .{};
    _ = l.str("  ID NAME             ST     THR  KOBJ KB (used/max)  USER KB (used/max)");
    l.flush();
    for (0..count) |i| {
        const rec = shared.DomainRec.decode(recs[i * shared.DomainRec.size ..][0..shared.DomainRec.size]);
        const w = digits(rec.id);
        if (w < 4) _ = l.pad(4 - w);
        _ = l.num(rec.id).str(" ").str(rec.nameSlice());
        _ = l.pad(21).str(switch (rec.state) {
            .alive => "alive",
            .dying => "dying",
            .dead => "dead",
        });
        _ = l.pad(28).num(rec.threads);
        _ = l.pad(33).num(rec.kobj_kb >> 32).str("/").num(rec.kobj_kb & 0xffff_ffff);
        _ = l.pad(53).num(rec.user_kb >> 32).str("/").num(rec.user_kb & 0xffff_ffff);
        l.flush();
    }
}

pub fn digits(v: u64) usize {
    var n: usize = 1;
    var x = v;
    while (x >= 10) : (x /= 10) n += 1;
    return n;
}

/// Wire the console from a boot setup (console channel + its buffer).
/// Exits if either is missing: a console program without a console has
/// nothing to do.
pub fn attach(setup: *const @import("boot.zig").Setup) void {
    const chan = setup.cap(.console);
    const buf_cap = setup.cap(.console_buf);
    if (chan == 0 or buf_cap == 0) usys.exit(203);
    const m = usys.shmMap(buf_cap);
    if (m.err != .ok) usys.exit(202);
    init(chan, m.data[0]);
}
