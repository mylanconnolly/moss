//! The scripting seam: the protocol between a script domain (`jsrun`,
//! where a JavaScript program runs with the engine and nothing else)
//! and the host that spawned it. The shape is the page domain's: the
//! script holds exactly one capability, a badged calling end to its
//! host, so every message here is the script's call and the host's
//! reply. It asks for its data buffer (the source is already in it),
//! reports each `print` line, reaches the one filesystem view its
//! host may offer — a program gets exactly what its domain holds, and
//! the host is the domain's keeper — and reports how the run ended;
//! the host never calls the script. A script that dies of its heap or
//! a fault is heard by the host as its badge's `client_dead`.
//!
//! Wire rules as everywhere in shared/: a message is a tag and up to
//! three words; text rides in the data buffer, named by offset and
//! length.
const std = @import("std");

/// The spawn argument that tells `jsrun` to serve a host on its channel.
pub const run_arg: u64 = 9;

/// The data buffer: the source comes in through it, output lines,
/// file contents and the result text go out through it, so each is at
/// most this.
pub const data_pages: u64 = 64;

/// `data_buf.flags` bits.
pub const flag_fs: u64 = 1 << 0;
/// The source is a module: `import`/`export` and top-level `await`.
pub const flag_module: u64 = 1 << 1;

pub const RunReq = union(enum(u64)) {
    /// The script's data buffer: the reply carries the shm cap, the
    /// length of the source at data[0..len] and the flags.
    attach_data: void,
    /// A `print` line, at data[0..len].
    output: struct { len: u64 },
    /// The run is over: `ok` = 1 with the completion value's text at
    /// data[0..len], 0 with the uncaught exception's text there.
    done: struct { ok: u64, len: u64 },
    /// The file at the path data[0..len] of the offered view: the
    /// reply is `text` with its bytes at data[0..], or `refused`.
    fs_read: struct { len: u64 },
    /// Write data[path_len..path_len+data_len] to the path at
    /// data[0..path_len], creating or truncating it.
    fs_write: struct { path_len: u64, data_len: u64 },
    /// The entries of the directory at data[0..len]: the reply is `text`
    /// with one `kind size name` line per entry (kind: f, d or l).
    fs_list: struct { len: u64 },
    /// The object at data[0..len]: the reply is `stat`, or `refused`.
    fs_stat: struct { len: u64 },
};

pub const HostResp = union(enum(u64)) {
    ok: void,
    none: void,
    data_buf: struct { pages: u64, len: u64, flags: u64 },
    /// `len` bytes at data[0..].
    text: struct { len: u64 },
    /// A filesystem request failed: `code` is a `FsErr`, or 0 when the
    /// host offers no view.
    refused: struct { code: u64 },
    /// `kind` is a `FsType`.
    stat: struct { kind: u64, size: u64 },
};

test "encode/decode round trip" {
    const shared = @import("lib.zig");
    const words = shared.encodeMsg(RunReq, .{ .fs_write = .{ .path_len = 3, .data_len = 42 } });
    const back = shared.decodeMsg(RunReq, words) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 42), back.fs_write.data_len);
}
