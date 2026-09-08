//! The graphical seat's demo session: a tiny shell loop that runs on a
//! console with no idea whether it is a serial port, a virtio-console, or
//! the graphical terminal — it just speaks the console protocol (ConsReq:
//! setup a byte buffer, write output, read input). It prints a prompt,
//! reads a line (echoing each key), and on Enter logs and echoes the line
//! back. The whole point is the loop: a key pressed on the (virtual)
//! keyboard travels inputsvc -> term -> here and back out to the screen.
//!
//! The real msh runs on the same interface; this stands in for it in the
//! automated drill, where the host types a line over QMP.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");

comptime {
    asm (usys.imageHeader("gsh"));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

var cons: u64 = 0;
var buf: [*]volatile u8 = undefined;
var buf_len: u64 = 0;

fn write(bytes: []const u8) void {
    if (bytes.len > buf_len) return;
    for (bytes, 0..) |b, i| buf[i] = b;
    _ = usys.callTyped(shared.ConsReq, shared.ConsResp, cons, .{ .write = .{ .len = bytes.len } }, 0);
}

/// Read up to `dst.len` bytes (blocks until at least one); returns count.
fn read(dst: []u8) u64 {
    const n = switch (usys.callTyped(shared.ConsReq, shared.ConsResp, cons, .{ .read = .{ .max = dst.len } }, 0)) {
        .ok => |rep| switch (rep) {
            .n => |x| x.n,
            else => 0,
        },
        .err => 0,
    };
    var i: u64 = 0;
    while (i < n and i < dst.len) : (i += 1) dst[i] = buf[i];
    return i;
}

export fn umain(log_h: u64, chan_h: u64, _: u64) callconv(.c) noreturn {
    const setup = boot.take(chan_h);
    cons = setup.cap(.console);
    if (cons == 0) {
        _ = usys.log(log_h, "gsh: no console");
        usys.exit(169);
    }
    const s = usys.shmCreate(1);
    if (s.err != .ok) usys.exit(170);
    const m = usys.shmMap(s.data[0]);
    if (m.err != .ok) usys.exit(171);
    buf = @ptrFromInt(m.data[0]);
    buf_len = m.data[1] * 4096;
    switch (usys.callTyped(shared.ConsReq, shared.ConsResp, cons, .setup, s.data[0])) {
        .ok => {},
        .err => usys.exit(172),
    }

    write("moss graphical console\nmoss$ ");
    _ = usys.log(log_h, "gsh: ready");

    var line: [128]u8 = undefined;
    var n: usize = 0;
    var one: [8]u8 = undefined;
    while (true) {
        const got = read(one[0..]);
        var i: u64 = 0;
        while (i < got) : (i += 1) {
            const c = one[i];
            if (c == '\n') {
                write("\n");
                // "Run" the line: echo it back and log it, then done.
                write(line[0..n]);
                write("\nmoss$ ");
                var lg: [160]u8 = undefined;
                const msg = std.fmt.bufPrint(&lg, "gsh: line {s}", .{line[0..n]}) catch "gsh: line";
                _ = usys.log(log_h, msg);
                usys.sleepMs(3000); // hold for the host's screendump
                usys.exit(0);
            } else if (c == 8) { // backspace
                if (n > 0) {
                    n -= 1;
                    write("\x08 \x08");
                }
            } else {
                if (n < line.len) line[n] = c;
                n += 1;
                write(one[i .. i + 1]); // echo
            }
        }
    }
}
