//! The scripting seam: the protocol between a script domain (`jsrun`,
//! where a JavaScript program runs with the engine and nothing else)
//! and the host that spawned it. The shape is the page domain's: the
//! script holds exactly one capability, a badged calling end to its
//! host, so every message here is the script's call and the host's
//! reply. It asks for its data buffer (the source is already in it),
//! reports each `print` line, and reports how the run ended; the host
//! never calls the script. A script that dies of its heap or a fault
//! is heard by the host as its badge's `client_dead`.
//!
//! Wire rules as everywhere in shared/: a message is a tag and up to
//! three words; text rides in the data buffer, named by offset and
//! length.
const std = @import("std");

/// The spawn argument that tells `jsrun` to serve a host on its channel.
pub const run_arg: u64 = 9;

/// The data buffer: the source comes in through it, output lines and
/// the result text go out through it, so each is at most this.
pub const data_pages: u64 = 64;

pub const RunReq = union(enum(u64)) {
    /// The script's data buffer: the reply carries the shm cap and the
    /// length of the source at data[0..len].
    attach_data: void,
    /// A `print` line, at data[0..len].
    output: struct { len: u64 },
    /// The run is over: `ok` = 1 with the completion value's text at
    /// data[0..len], 0 with the uncaught exception's text there.
    done: struct { ok: u64, len: u64 },
};

pub const HostResp = union(enum(u64)) {
    ok: void,
    none: void,
    data_buf: struct { pages: u64, len: u64 },
};

test "encode/decode round trip" {
    const shared = @import("lib.zig");
    const words = shared.encodeMsg(RunReq, .{ .done = .{ .ok = 1, .len = 42 } });
    const back = shared.decodeMsg(RunReq, words) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 42), back.done.len);
}
