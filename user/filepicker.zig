//! Session document broker. Chooser and Files selections keep directory views
//! here; Editor clients can read/write only their explicitly selected document.
//!
//! The broker is headless and never blocks on a human. Open and Save As
//! need a dialog, which runs in the chooser — its own process
//! (user/chooser.zig) that this broker starts through init and hands one
//! private endpoint. The chooser pulls jobs (`chooser_ready`/`chooser_done`
//! park here until one is queued); the application's own call is parked
//! by token meanwhile, so while a dialog is up every other client's save,
//! load and handoff is served as usual. Every reply goes by token.
const std = @import("std");
const shared = @import("shared");
const p = shared.picker;
const usys = @import("usys.zig");
const boot = @import("boot.zig");
const fs = @import("fsclient.zig");
const file = @import("editorfile.zig");
comptime {
    asm (usys.imageHeader("filepicker"));
}
pub const panic = std.debug.FullPanic(uPanic);
fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}
const Client = struct {
    badge: u64 = 0,
    va: u64 = 0,
    path: [256]u8 = undefined,
    len: usize = 0,
    selected_view: u64 = 0,
    view_va: u64 = 0,
    held_cap: u64 = 0,
    sender: u64 = 0,
    queued: bool = false,
    offered_at: u64 = 0, // cycles when the sender committed (enqueue)
};
const receiver_badge: u64 = 1;
const ClientSlab = struct {
    next: ?*ClientSlab = null,
    count: usize = 0,
    clients: [(4096 - 16) / @sizeOf(Client)]Client = @splat(.{}),
};
comptime {
    std.debug.assert(@sizeOf(ClientSlab) <= 4096);
}
var clients: ?*ClientSlab = null;
var next_badge: u64 = 2;
var view: u64 = 0;
var buffer: [*]u8 = undefined;
var scratch: [p.max_bytes]u8 = undefined;
var glog: u64 = 0;
fn find(badge: u64) ?*Client {
    if (badge == 0) return null;
    var cur = clients;
    while (cur) |slab| : (cur = slab.next) {
        for (&slab.clients) |*c| if (c.badge == badge) return c;
    }
    return null;
}
fn allocate(badge: u64) ?*Client {
    var cur = clients;
    while (cur) |slab| : (cur = slab.next) {
        for (&slab.clients) |*c| if (c.badge == 0) {
            c.* = .{ .badge = badge };
            slab.count += 1;
            return c;
        };
    }
    const sh = usys.shmCreate(1);
    if (sh.err != .ok) return null;
    const m = usys.shmMap(sh.data[0]);
    _ = usys.capDrop(sh.data[0]);
    if (m.err != .ok) return null;
    const slab: *ClientSlab = @ptrFromInt(m.data[0]);
    slab.* = .{ .next = clients, .count = 1 };
    slab.clients[0] = .{ .badge = badge };
    clients = slab;
    return &slab.clients[0];
}
fn release(badge: u64) void {
    if (badge == 0) return;
    var link = &clients;
    while (link.*) |slab| {
        for (&slab.clients) |*c| if (c.badge == badge) {
            if (c.va != 0) _ = usys.shmUnmap(c.va);
            dropSelectedView(c);
            if (c.held_cap != 0) _ = usys.capDrop(c.held_cap);
            c.* = .{};
            slab.count -= 1;
            if (slab.count == 0) {
                link.* = slab.next;
                _ = usys.shmUnmap(@intFromPtr(slab));
            }
            return;
        };
        link = &slab.next;
    }
}
fn documentView(c: *Client) u64 {
    return if (c.selected_view != 0) c.selected_view else view;
}
fn documentBuffer(c: *Client) [*]u8 {
    return if (c.view_va != 0) @ptrFromInt(c.view_va) else buffer;
}
fn dropSelectedView(c: *Client) void {
    if (c.view_va != 0) _ = usys.shmUnmap(c.view_va);
    if (c.selected_view != 0) _ = usys.capDrop(c.selected_view);
    c.view_va = 0;
    c.selected_view = 0;
}
fn firstPending(sender: ?u64, queued: bool) ?*Client {
    var found: ?*Client = null;
    var slab = clients;
    while (slab) |sl| : (slab = sl.next) {
        for (&sl.clients) |*c| {
            if (c.badge == 0 or c.held_cap == 0 or c.queued != queued) continue;
            if (sender) |owner| if (c.sender != owner) continue;
            if (found == null or c.badge < found.?.badge) found = c;
        }
    }
    return found;
}
fn cancelUncommitted(sender: u64) void {
    while (firstPending(sender, false)) |c| release(c.badge);
}
/// Takes ownership of a fresh derived parent view, never the sender's shared
/// view/buffer. Only the selected basename is exposed through the new endpoint.
fn offerDocument(chan: u64, sender: *Client, parent_view: u64, name_len: u64) p.Resp {
    var transferred = false;
    defer if (!transferred and parent_view != 0) {
        _ = usys.capDrop(parent_view);
    };
    if (sender.va == 0 or parent_view == 0 or name_len == 0 or name_len > 56) return failure(error.BadPath);
    // The broker calls on this cap (attach, load, later save), so it must
    // be a filesystem view — an endpoint of the same service as the home
    // view granted at setup — and never a stranger's channel, least of
    // all one of this broker's own endpoints (a self-call would hang the
    // whole session's document workflow; the kernel refuses it too).
    if (!usys.chanSame(parent_view, view)) {
        _ = usys.log(glog, "filepicker: offer refused: not a filesystem view");
        return failure(error.Unavailable);
    }
    var name: [56]u8 = undefined;
    const source: [*]const u8 = @ptrFromInt(sender.va);
    @memcpy(name[0..@intCast(name_len)], source[p.name_offset..][0..@intCast(name_len)]);
    const basename = name[0..@intCast(name_len)];
    file.validatePath(basename) catch |err| return failure(err);
    if (std.mem.indexOfScalar(u8, basename, '/') != null) return failure(error.BadPath);
    if (next_badge == std.math.maxInt(u64)) return failure(error.TemporaryFileBusy);
    const badge = next_badge;
    next_badge += 1;
    const offered_client = allocate(badge) orelse return failure(error.TemporaryFileBusy);
    var accepted = false;
    defer if (!accepted) {
        release(badge);
    };
    offered_client.selected_view = parent_view;
    transferred = true;
    const sh = usys.shmCreate(shared.fs_buf_pages);
    if (sh.err != .ok) return failure(error.Unavailable);
    defer _ = usys.capDrop(sh.data[0]);
    const mapped = usys.shmMap(sh.data[0]);
    if (mapped.err != .ok) return failure(error.Unavailable);
    offered_client.view_va = mapped.data[0];
    const attached = switch (usys.callTyped(shared.FsReq, shared.FsResp, parent_view, .attach_buf, sh.data[0])) {
        .ok => |rep| rep == .ok,
        .err => false,
    };
    if (!attached) return failure(error.Unavailable);
    _ = file.load(parent_view, documentBuffer(offered_client), basename, &scratch) catch |err| return failure(err);
    const minted = usys.chanMint(chan, badge);
    if (minted.err != .ok) return failure(error.Unavailable);
    offered_client.held_cap = minted.data[1];
    offered_client.sender = sender.badge;
    @memcpy(offered_client.path[0..basename.len], basename);
    offered_client.len = basename.len;
    accepted = true;
    _ = usys.log(glog, "filepicker: document offered");
    return .{ .offered = .{ .ticket = badge } };
}

fn failure(err: file.Error) p.Resp {
    return .{ .failed = .{ .code = @intFromEnum(switch (err) {
        error.BadPath => p.Error.bad_path,
        error.NotFound => .not_found,
        error.ReadOnly => .read_only,
        error.NoSpace => .no_space,
        error.NotText => .not_text,
        error.TooLarge => .too_large,
        error.NotFile => .not_file,
        error.TemporaryFileBusy => .busy,
        error.CommitUncertain => .commit_uncertain,
        else => .unavailable,
    }) } };
}
fn metadata(c: *Client, len: usize) p.Resp {
    const dst: [*]u8 = @ptrFromInt(c.va);
    @memcpy(dst[p.name_offset..][0..c.len], c.path[0..c.len]);
    const st = fs.fsStatfs(documentView(c));
    return .{ .document = .{ .len = len, .name_len = c.len, .read_only = @intFromBool(st == null or st.?.read_only) } };
}

// ---------------------------------------------------------------- jobs
//
// Open and Save As need a human: the dialog runs in the chooser, so this
// loop never blocks on one. A request becomes a Job — the caller's reply
// is deferred by token — and the chooser takes jobs one at a time.
const Job = struct {
    badge: u64 = 0, // the application client; 0 = an orphan (it died meanwhile)
    token: u64 = 0,
    saving: bool = false,
    len: usize = 0, // save_as: bytes to write, read from the client's buffer at completion
    name: [256]u8 = undefined,
    name_len: usize = 0,
};
const max_jobs = 4;
var jobs: [max_jobs]Job = @splat(.{});
var job_count: usize = 0; // jobs[0] is with the chooser while `job_active`
var job_active = false;
var chooser_badge: u64 = 0; // the badge minted for the chooser; 0 = not up
var chooser_token: u64 = 0; // the chooser's parked ready/done call
var init_cap: u64 = 0;

/// A committed handoff that no Editor claims is not kept forever: the
/// Editor may have exited between Files' connect and its enqueue, or
/// crashed before its first poll, and nothing else would ever release the
/// view slot and buffer it pins — or stop a much later Editor launch from
/// silently opening that file.
var queued_offer_ttl_s: u64 = 10; // arg 1 (the editor drill): 1 s, so a probe can see it

fn ensureChooser(chan_h: u64) bool {
    if (chooser_badge != 0) return true;
    if (init_cap == 0) return false;
    const name = shared.strToWords("chooser");
    const chan = switch (usys.callTypedCap(shared.InitRequest, shared.InitReply, init_cap, .{ .connect_named = .{ .a = name[0], .b = name[1] } }, 0)) {
        .ok => |r| blk: {
            if (r.rep == .connected) break :blk r.cap;
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            break :blk 0;
        },
        .err => 0,
    };
    if (chan == 0) {
        _ = usys.log(glog, "filepicker: chooser could not start");
        return false;
    }
    defer _ = usys.capDrop(chan);
    if (next_badge == std.math.maxInt(u64)) return false;
    const badge = next_badge;
    next_badge += 1;
    _ = allocate(badge) orelse return false;
    const minted = usys.chanMint(chan_h, badge);
    if (minted.err != .ok) {
        release(badge);
        return false;
    }
    // The one call this broker makes on the chooser: a unit init just
    // started for us, not a client-supplied cap, and it answers at once.
    // Our copy of the minted endpoint goes right after the call, so the
    // chooser's death reaches us as client_dead on its badge.
    const hello = usys.callTypedCap(p.ChooserReq, p.ChooserResp, chan, .hello, minted.data[1]);
    _ = usys.capDrop(minted.data[1]);
    const ok = switch (hello) {
        .ok => |r| r.rep == .ok,
        .err => false,
    };
    if (!ok) {
        release(badge);
        _ = usys.log(glog, "filepicker: chooser refused the handshake");
        return false;
    }
    chooser_badge = badge;
    _ = usys.log(glog, "filepicker: chooser attached");
    return true;
}

/// Hand the chooser its next job, if it is parked and one is queued.
fn dispatchJob(chan_h: u64) void {
    if (chooser_token == 0 or job_active or job_count == 0) return;
    const cc = find(chooser_badge) orelse return;
    if (cc.va == 0) return;
    const j = &jobs[0];
    const dst: [*]u8 = @ptrFromInt(cc.va);
    @memcpy(dst[p.name_offset..][0..j.name_len], j.name[0..j.name_len]);
    const t = chooser_token;
    chooser_token = 0;
    job_active = true;
    _ = usys.replyTypedTo(p.Resp, chan_h, .{ .job = .{ .saving = @intFromBool(j.saving), .name_len = j.name_len } }, 0, t);
}

fn popJob() void {
    std.mem.copyForwards(Job, jobs[0 .. job_count - 1], jobs[1..job_count]);
    job_count -= 1;
    job_active = false;
}

/// The chooser's verdict on jobs[0]: load or save on our view and answer
/// the application's parked call. An orphan is simply dropped.
fn completeJob(chan_h: u64, path: []const u8) void {
    const j = jobs[0];
    popJob();
    if (j.badge == 0) return;
    const c = find(j.badge) orelse return;
    if (path.len == 0) {
        _ = usys.replyTypedTo(p.Resp, chan_h, .cancelled, 0, j.token);
        return;
    }
    file.validatePath(path) catch {
        _ = usys.replyTypedTo(p.Resp, chan_h, failure(error.BadPath), 0, j.token);
        return;
    };
    if (c.va == 0) {
        _ = usys.replyTypedTo(p.Resp, chan_h, failure(error.Unavailable), 0, j.token);
        return;
    }
    const data: [*]u8 = @ptrFromInt(c.va);
    const len = if (j.saving) blk: {
        // Read once, now, into our own scratch: the bytes the client's
        // buffer holds at the moment of the user's decision.
        @memcpy(scratch[0..j.len], data[0..j.len]);
        file.save(view, buffer, path, scratch[0..j.len]) catch |err| {
            _ = usys.replyTypedTo(p.Resp, chan_h, failure(err), 0, j.token);
            return;
        };
        break :blk j.len;
    } else blk: {
        const loaded = file.load(view, buffer, path, &scratch) catch |err| {
            _ = usys.replyTypedTo(p.Resp, chan_h, failure(err), 0, j.token);
            return;
        };
        @memcpy(data[0..loaded.len], loaded);
        break :blk loaded.len;
    };
    dropSelectedView(c);
    @memcpy(c.path[0..path.len], path);
    c.len = path.len;
    _ = usys.replyTypedTo(p.Resp, chan_h, metadata(c, len), 0, j.token);
}

/// A client died: its queued jobs go; the one with the chooser becomes an
/// orphan, dropped when the dialog ends.
fn dropJobsOf(badge: u64) void {
    var i: usize = 0;
    while (i < job_count) {
        if (jobs[i].badge != badge) {
            i += 1;
            continue;
        }
        if (i == 0 and job_active) {
            jobs[0].badge = 0;
            i += 1;
            continue;
        }
        std.mem.copyForwards(Job, jobs[i .. job_count - 1], jobs[i + 1 .. job_count]);
        job_count -= 1;
    }
}

/// The chooser died: its dialog vanished, so the application hears
/// "cancelled"; queued jobs wait for a fresh chooser.
fn chooserDied(chan_h: u64) void {
    chooser_badge = 0;
    chooser_token = 0;
    _ = usys.log(glog, "filepicker: chooser exited");
    if (job_active) {
        const j = jobs[0];
        popJob();
        if (j.badge != 0) _ = usys.replyTypedTo(p.Resp, chan_h, .cancelled, 0, j.token);
    }
    if (job_count > 0 and !ensureChooser(chan_h)) {
        while (job_count > 0) {
            const j = jobs[0];
            popJob();
            if (j.badge != 0) _ = usys.replyTypedTo(p.Resp, chan_h, failure(error.TemporaryFileBusy), 0, j.token);
        }
    }
}

fn expireQueued() void {
    const hz = usys.cycleHz();
    if (hz == 0) return;
    while (true) {
        const now = usys.cycles();
        var expired: u64 = 0;
        var slab = clients;
        scan: while (slab) |sl| : (slab = sl.next) {
            for (&sl.clients) |*c| {
                if (c.badge != 0 and c.held_cap != 0 and c.queued and (now -% c.offered_at) / hz >= queued_offer_ttl_s) {
                    expired = c.badge;
                    break :scan;
                }
            }
        }
        if (expired == 0) return;
        _ = usys.log(glog, "filepicker: queued document expired");
        release(expired); // may unmap a slab: rescan from the top
    }
}

export fn umain(log_h: u64, chan_h: u64, arg: u64, blob_va: u64, blob_len: u64) callconv(.c) noreturn {
    _ = blob_va;
    _ = blob_len;
    glog = log_h;
    if (arg == 1) queued_offer_ttl_s = 1;
    const receiver = usys.chanMint(chan_h, receiver_badge);
    if (receiver.err != .ok) usys.exit(1);
    const setup = boot.takeExport(chan_h, receiver.data[1]);
    _ = usys.capDrop(receiver.data[1]);
    view = setup.cap(.view);
    const attached = fs.attachBuf(view);
    if (attached.va == 0) {
        _ = usys.log(glog, "filepicker: filesystem buffer unavailable");
        usys.exit(1);
    }
    buffer = @ptrFromInt(attached.va);
    _ = usys.capDrop(attached.cap); // the two service mappings retain the buffer
    init_cap = setup.cap(.init);
    if (init_cap == 0) _ = usys.log(glog, "filepicker: no init channel; dialogs unavailable");
    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .peer_dead) usys.exit(0);
        expireQueued();
        if (r.err == .client_dead) {
            if (r.badge != 0 and r.badge == chooser_badge) {
                release(r.badge);
                chooserDied(chan_h);
                continue;
            }
            dropJobsOf(r.badge);
            cancelUncommitted(r.badge);
            release(r.badge);
            continue;
        }
        if (r.err != .ok) continue;
        const req = shared.decodeMsg(p.Req, r.data) orelse {
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            _ = usys.replyTypedTo(p.Resp, chan_h, failure(error.Unavailable), 0, r.token);
            continue;
        };
        if (req == .take) {
            if (r.badge != receiver_badge) {
                _ = usys.replyTypedTo(p.Resp, chan_h, failure(error.Unavailable), 0, r.token);
            } else if (firstPending(null, true)) |offered_client| {
                const cap = offered_client.held_cap;
                offered_client.held_cap = 0;
                offered_client.sender = 0;
                offered_client.queued = false;
                _ = usys.log(glog, "filepicker: document handoff claimed");
                const replied = usys.replyTypedTo(p.Resp, chan_h, .selected, cap, r.token);
                _ = usys.capDrop(cap);
                if (replied != .ok) release(offered_client.badge);
            } else _ = usys.replyTypedTo(p.Resp, chan_h, .empty, 0, r.token);
            continue;
        }
        if (req == .register) {
            if (next_badge == std.math.maxInt(u64)) {
                _ = usys.replyTypedTo(p.Resp, chan_h, failure(error.TemporaryFileBusy), 0, r.token);
                continue;
            }
            _ = allocate(next_badge) orelse {
                _ = usys.replyTypedTo(p.Resp, chan_h, failure(error.TemporaryFileBusy), 0, r.token);
                continue;
            };
            const minted = usys.chanMint(chan_h, next_badge);
            if (minted.err != .ok) {
                release(next_badge);
                _ = usys.replyTypedTo(p.Resp, chan_h, failure(error.Unavailable), 0, r.token);
                continue;
            }
            const badge = next_badge;
            next_badge += 1;
            const replied = usys.replyTypedTo(p.Resp, chan_h, .registered, minted.data[1], r.token);
            // Reply copies the endpoint. Keeping our copy would prevent the
            // last real client's drop from generating client_dead forever.
            _ = usys.capDrop(minted.data[1]);
            if (replied != .ok) release(badge);
            continue;
        }
        const c = find(r.badge) orelse {
            if ((req == .attach_buf or req == .offer) and r.cap != 0) _ = usys.capDrop(r.cap);
            _ = usys.replyTypedTo(p.Resp, chan_h, failure(error.Unavailable), 0, r.token);
            continue;
        };
        if (req == .offer) {
            const rep = offerDocument(chan_h, c, r.cap, req.offer.path_len);
            const replied = usys.replyTypedTo(p.Resp, chan_h, rep, 0, r.token);
            if (replied != .ok and rep == .offered) release(rep.offered.ticket);
            continue;
        }
        if (req == .enqueue or req == .cancel_offer) {
            const ticket = if (req == .enqueue) req.enqueue.ticket else req.cancel_offer.ticket;
            const offered_client = find(ticket);
            if (offered_client == null or offered_client.?.sender != r.badge or offered_client.?.held_cap == 0) {
                _ = usys.replyTypedTo(p.Resp, chan_h, failure(error.Unavailable), 0, r.token);
            } else {
                if (req == .enqueue) {
                    offered_client.?.queued = true;
                    offered_client.?.offered_at = usys.cycles();
                    _ = usys.log(glog, "filepicker: document queued");
                } else release(ticket);
                _ = usys.replyTypedTo(p.Resp, chan_h, .ok, 0, r.token);
            }
            continue;
        }
        if (req == .attach_buf) {
            const mapped = usys.shmMap(r.cap);
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            if (mapped.err != .ok) {
                _ = usys.replyTypedTo(p.Resp, chan_h, failure(error.Unavailable), 0, r.token);
                continue;
            }
            if (mapped.data[1] < p.pages) {
                _ = usys.shmUnmap(mapped.data[0]);
                _ = usys.replyTypedTo(p.Resp, chan_h, failure(error.TooLarge), 0, r.token);
                continue;
            }
            if (c.va != 0) _ = usys.shmUnmap(c.va);
            c.va = mapped.data[0];
            _ = usys.replyTypedTo(p.Resp, chan_h, .ok, 0, r.token);
            continue;
        }
        if (req == .chooser_ready or req == .chooser_done) {
            // Only the badge minted in the handshake pulls jobs: an
            // application posing as the chooser could otherwise "choose"
            // a path the user never picked.
            if (chooser_badge == 0 or r.badge != chooser_badge or c.va == 0) {
                _ = usys.replyTypedTo(p.Resp, chan_h, failure(error.Unavailable), 0, r.token);
                continue;
            }
            if (req == .chooser_done and job_active) {
                const n = req.chooser_done.path_len;
                var path: [256]u8 = undefined;
                if (n <= path.len) {
                    const src: [*]const u8 = @ptrFromInt(c.va);
                    @memcpy(path[0..@intCast(n)], src[p.name_offset..][0..@intCast(n)]);
                    completeJob(chan_h, path[0..@intCast(n)]);
                } else completeJob(chan_h, "");
            }
            chooser_token = r.token;
            dispatchJob(chan_h);
            continue;
        }
        if (c.va == 0) {
            _ = usys.replyTypedTo(p.Resp, chan_h, failure(error.Unavailable), 0, r.token);
            continue;
        }
        if (req != .open and req != .load and req != .save and req != .save_as) {
            _ = usys.replyTypedTo(p.Resp, chan_h, failure(error.Unavailable), 0, r.token);
            continue;
        }
        const data: [*]u8 = @ptrFromInt(c.va);
        const saving = req == .save or req == .save_as;
        const n: usize = switch (req) {
            .save => |v| v.len,
            .save_as => |v| v.len,
            else => 0,
        };
        if (n > p.max_bytes) {
            _ = usys.replyTypedTo(p.Resp, chan_h, failure(error.TooLarge), 0, r.token);
            continue;
        }
        if (req == .open or req == .save_as) {
            // A dialog: queue the job and answer when the chooser reports.
            if (job_count == max_jobs or !ensureChooser(chan_h)) {
                _ = usys.replyTypedTo(p.Resp, chan_h, failure(error.TemporaryFileBusy), 0, r.token);
                continue;
            }
            var j: Job = .{ .badge = r.badge, .token = r.token, .saving = saving, .len = n };
            @memcpy(j.name[0..c.len], c.path[0..c.len]);
            j.name_len = c.len;
            jobs[job_count] = j;
            job_count += 1;
            dispatchJob(chan_h);
            continue;
        }
        // load / save: the already selected document, no dialog.
        if (saving) @memcpy(scratch[0..n], data[0..n]);
        const path = c.path[0..c.len];
        const len = if (saving) blk: {
            file.save(documentView(c), documentBuffer(c), path, scratch[0..n]) catch |err| {
                _ = usys.replyTypedTo(p.Resp, chan_h, failure(err), 0, r.token);
                continue;
            };
            break :blk n;
        } else blk: {
            const loaded = file.load(documentView(c), documentBuffer(c), path, &scratch) catch |err| {
                _ = usys.replyTypedTo(p.Resp, chan_h, failure(err), 0, r.token);
                continue;
            };
            @memcpy(data[0..loaded.len], loaded);
            break :blk loaded.len;
        };
        _ = usys.replyTypedTo(p.Resp, chan_h, metadata(c, len), 0, r.token);
    }
}
