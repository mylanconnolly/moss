//! Finding a program image by name in a set of stores, and staging it
//! into a loader.Stage for `spawn`. The shell's `run` and a `spawn`
//! worker both do this — a manifest under `img/<name>.msh` names the
//! image by digest, the image itself is content-addressed by that
//! digest, and staging reads it into a buffer the kernel copies into
//! the child. Factored here so a host holding a spawner (the shell, or
//! any script under mshrun) loads a worker the same way.

const std = @import("std");
const shared = @import("shared");
const fsc = @import("fsclient.zig");
const fscmds = @import("fscmds.zig");
const loader = @import("loader.zig");
const mshl = @import("mosslib").mshl;
const Value = mshl.Value;
const Store = fscmds.Store;

pub const Program = struct {
    store: Store,
    digest: [shared.img_digest_hex_len]u8,
    manifest: Value,
};

/// The program named `name`, found by its manifest in the first of
/// `stores` that holds one. Its `manifest` is the parsed record; the
/// caller reads its grants and gives. null = in none of the stores.
pub fn find(it: *mshl.Interp, name: []const u8, stores: []const ?Store) mshl.Error!?Program {
    for (stores) |maybe| {
        const st = maybe orelse continue;
        var mpath: [64]u8 = undefined;
        if (name.len + shared.img_manifest_ext.len > mpath.len) return it.fail("run: name too long", .{});
        @memcpy(mpath[0..name.len], name);
        @memcpy(mpath[name.len .. name.len + shared.img_manifest_ext.len], shared.img_manifest_ext);
        const mp = mpath[0 .. name.len + shared.img_manifest_ext.len];
        const text = fscmds.readFileVia(it, st.chan, st.buf, mp) catch continue;
        const v = try it.parseData(text);
        if (v != .record) return it.fail("run: {s}: the manifest in {s} is not a record", .{ name, st.name });
        const img = v.record.get("image") orelse return it.fail("run: {s}: manifest names no image", .{name});
        if (img != .str or img.str.len != shared.img_digest_hex_len) return it.fail("run: {s}: manifest image is not a digest", .{name});
        var p: Program = .{ .store = st, .digest = undefined, .manifest = v };
        @memcpy(&p.digest, img.str);
        return p;
    }
    return null;
}

/// Read a content-addressed image (named by `digest`) from a store's
/// channel into `stage`, returning its length — null if the store
/// cannot give it. The image is opened by its digest (its own name in
/// the content-addressed store).
pub fn stageDigest(chan: u64, buf: [*]u8, digest: *const [shared.img_digest_hex_len]u8, stage: *loader.Stage) ?usize {
    const fd = switch (fsc.fsOpen(chan, buf, digest, 0)) {
        .fd => |fd| fd,
        .err => return null,
    };
    defer fsc.fsClose(chan, fd);
    var off: usize = 0;
    while (off < stage.bytes) {
        const n = fsc.fsReadAt(chan, fd, off, @min(shared.fs_max_io, stage.bytes - off)) orelse return null;
        if (n == 0) break;
        @memcpy(stage.slice(off + n)[off..], buf[0..n]);
        off += n;
    }
    return off;
}

/// Stage a found program's image (by its digest, from its store).
pub fn stageInto(prog: *const Program, stage: *loader.Stage) ?usize {
    return stageDigest(prog.store.chan, prog.store.buf, &prog.digest, stage);
}

/// Find `name` in `stores` and stage its verified image into `stage`,
/// returning the stage handle for `spawn` — null on any failure. The
/// loadStage callback a worker host wires into workcmds.
pub fn loadImage(it: *mshl.Interp, name: []const u8, stores: []const ?Store, stage: *loader.Stage) ?u64 {
    const prog = (find(it, name, stores) catch return null) orelse return null;
    const len = stageInto(&prog, stage) orelse return null;
    if (!stage.verify(len, &prog.digest)) return null;
    return stage.handle;
}
