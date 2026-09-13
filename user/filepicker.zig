//! Session file chooser. Only this broker owns a directory view; registered
//! clients can read/write only a document explicitly selected in its window.
const std = @import("std");
const shared = @import("shared");
const p = shared.picker;
const usys = @import("usys.zig");
const boot = @import("boot.zig");
const fs = @import("fsclient.zig");
const file = @import("editorfile.zig");
const wf = @import("windowframe.zig");
const widgets = @import("widgets.zig");
const clipboard = @import("clipboard.zig");
comptime {
    asm (usys.imageHeader("filepicker"));
}
pub const panic = std.debug.FullPanic(uPanic);
fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}
const Client = struct { badge: u64 = 0, va: u64 = 0, path: [256]u8 = undefined, len: usize = 0 };
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
    const st = fs.fsStatfs(view);
    return .{ .document = .{ .len = len, .name_len = c.len, .read_only = @intFromBool(st == null or st.?.read_only) } };
}

const Row = struct { name: [56]u8 = undefined, len: usize = 0, dir: bool = false };
var rows: [256]Row = @splat(.{});
var count: usize = 0;
var directory: [256]u8 = undefined;
var dir_len: usize = 0;
var edit: shared.TextEdit = .{};
var status: []const u8 = "";
var scroll: usize = 0;
var selected: usize = 0;
var listing_ok = false;
var focus: usize = 0; // filename, listing, cancel, action, up
var replacing = false;
var read_only = false;
var field_rect: wf.Rect = undefined;
var list_rect: wf.Rect = undefined;
var cancel_rect: wf.Rect = undefined;
var action_rect: wf.Rect = undefined;
var up_rect: wf.Rect = undefined;
var row_height: usize = 0;
fn setName(name: []const u8) void {
    edit = .{};
    const n = @min(name.len, edit.buf.len);
    @memcpy(edit.buf[0..n], name[0..n]);
    edit.len = n;
    edit.cursor = n;
    edit.anchor = 0;
    replacing = false;
}
fn join(dst: []u8, name: []const u8) ?[]const u8 {
    const extra: usize = @intFromBool(dir_len > 0);
    if (dir_len + extra + name.len > dst.len) return null;
    @memcpy(dst[0..dir_len], directory[0..dir_len]);
    if (extra != 0) dst[dir_len] = '/';
    @memcpy(dst[dir_len + extra ..][0..name.len], name);
    return dst[0 .. dir_len + extra + name.len];
}
fn refresh() void {
    listing_ok = false;
    count = 0;
    scroll = 0;
    selected = 0;
    const n = fs.fsList(view, buffer, directory[0..dir_len]) orelse {
        status = "Unable to list this folder.";
        return;
    };
    if (n > 2048) {
        status = "Unable to list this folder.";
        return;
    }
    listing_ok = true;
    if (n > 2048 - 57) status = "Folder list may be incomplete. Type a name to open an unlisted file.";
    var names: [2048]u8 = undefined;
    @memcpy(names[0..n], buffer[0..n]);
    var it = std.mem.splitScalar(u8, names[0..n], '\n');
    while (it.next()) |name| {
        if (name.len == 0 or name.len > 56) continue;
        if (count == rows.len) {
            status = "Folder list is incomplete. Type a name to open an unlisted file.";
            break;
        }
        var full: [256]u8 = undefined;
        const path = join(&full, name) orelse continue;
        const st = fs.fsStat(view, buffer, path) orelse continue;
        if (st.typ != @intFromEnum(shared.FsType.file) and st.typ != @intFromEnum(shared.FsType.dir)) continue;
        @memcpy(rows[count].name[0..name.len], name);
        rows[count].len = name.len;
        rows[count].dir = st.typ == @intFromEnum(shared.FsType.dir);
        count += 1;
    }
}
fn up() void {
    dir_len = std.mem.lastIndexOfScalar(u8, directory[0..dir_len], '/') orelse 0;
    refresh();
    replacing = false;
}
fn enterRow() void {
    if (selected >= count) return;
    const r = &rows[selected];
    if (r.dir) {
        var full: [256]u8 = undefined;
        const path = join(&full, r.name[0..r.len]) orelse return;
        @memcpy(directory[0..path.len], path);
        dir_len = path.len;
        refresh();
    } else {
        setName(r.name[0..r.len]);
        focus = 0;
    }
}
fn draw(saving: bool) void {
    wf.refreshAppearance();
    wf.clipReset();
    wf.fillAll(wf.pal.bg);
    wf.drawChrome(if (saving) "Save document" else "Open document");
    const area = wf.contentRect();
    const gap: usize = 12;
    const h = @max(wf.lineOf(wf.R_UI), wf.iconSize()) + 20;
    const x = area.x + gap;
    const w = area.w -| (2 * gap);
    up_rect = .{ .x = x, .y = area.y + gap, .w = @min(w, wf.strW(wf.R_UI, "Up") + wf.iconSize() + 36), .h = h };
    widgets.Button.draw(up_rect, "Up", "up", focus == 4, false, dir_len == 0);
    wf.drawStrTrunc(x + up_rect.w + gap, up_rect.y + 10, wf.R_UI, if (dir_len == 0) (if (read_only) "Home · Read-only" else "Home") else directory[0..dir_len], w -| (up_rect.w + gap), wf.pal.text, wf.pal.bg);
    field_rect = .{ .x = x, .y = up_rect.y + h + gap, .w = w, .h = h };
    widgets.input(field_rect, &edit, focus == 0);
    const footer_y = area.y + area.h -| (h + gap);
    const bw = @min(w / 2 -| 6, wf.strW(wf.R_UI, "Replace") + 40);
    cancel_rect = .{ .x = x, .y = footer_y, .w = bw, .h = h };
    action_rect = .{ .x = x + w -| bw, .y = footer_y, .w = bw, .h = h };
    widgets.Button.draw(cancel_rect, "Cancel", "", focus == 2, false, false);
    widgets.Button.draw(action_rect, if (saving) (if (replacing) "Replace" else "Save") else "Open", "", focus == 3, true, edit.len == 0 or (saving and read_only));
    const status_y = footer_y -| (wf.lineOf(wf.R_UI) + gap);
    wf.drawStrTrunc(x, status_y, wf.R_UI, status, w, wf.pal.text_muted, wf.pal.bg);
    list_rect = .{ .x = x, .y = field_rect.y + h + gap, .w = w, .h = status_y -| (field_rect.y + h + gap + gap) };
    wf.panel(list_rect.x, list_rect.y, list_rect.w, list_rect.h, 6, wf.pal.field_bg, if (focus == 1) wf.pal.focus else wf.pal.border, wf.pal.border_w);
    row_height = @max(wf.lineOf(wf.R_UI), wf.iconSize()) + 12;
    const visible = list_rect.h / row_height;
    if (count == 0 and listing_ok and visible > 0) wf.drawStrTrunc(list_rect.x + 12, list_rect.y + 12, wf.R_UI, "This folder is empty.", list_rect.w -| 24, wf.pal.text_muted, wf.pal.field_bg);
    if (selected < scroll) scroll = selected;
    if (visible > 0 and selected >= scroll + visible) scroll = selected - visible + 1;
    var i = scroll;
    while (i < count and i < scroll + visible) : (i += 1) {
        const y = list_rect.y + (i - scroll) * row_height;
        const fill = if (selected == i and focus == 1) wf.pal.primary else wf.pal.field_bg;
        wf.fillRect(list_rect.x + 2, y + 2, list_rect.w -| 4, row_height -| 4, fill);
        wf.drawIcon(x + 8, y + 6, wf.iconSize(), if (rows[i].dir) "folder" else "file", wf.pal.text);
        wf.drawStrTrunc(x + wf.iconSize() + 20, y + 6, wf.R_UI, rows[i].name[0..rows[i].len], w -| (wf.iconSize() + 28), wf.pal.text, fill);
    }
    _ = wf.commitSurface();
}
fn choose(c: *Client, saving: bool, out: *[256]u8) ?[]const u8 {
    dir_len = 0;
    edit = .{};
    focus = 0;
    replacing = false;
    status = if (saving) "Choose a name and folder. Existing files require confirmation." else "Choose a file, or type its name. Enter opens a folder.";
    if (c.len > 0) {
        if (std.mem.lastIndexOfScalar(u8, c.path[0..c.len], '/')) |slash| {
            @memcpy(directory[0..slash], c.path[0..slash]);
            dir_len = slash;
            setName(c.path[slash + 1 .. c.len]);
        } else setName(c.path[0..c.len]);
    } else if (saving) setName("Untitled.txt");
    const volume = fs.fsStatfs(view);
    read_only = volume == null or volume.?.read_only;
    if (read_only) status = if (saving) "This folder is read-only. Saving is unavailable." else "Read-only folder. You can open documents and make edits in memory.";
    wf.fontReady();
    wf.useOrdinaryChannel();
    wf.ptr_down = false;
    wf.pending_dot = null;
    wf.dragging = false;
    wf.win_focused = true;
    const area = wf.workArea();
    wf.win_w = @min(820, area.w);
    wf.win_h = @min(680, area.h);
    wf.win_x = area.x + (area.w - wf.win_w) / 2;
    wf.win_y = area.y + (area.h - wf.win_h) / 2;
    if (!wf.openSurface(false)) return null;
    defer wf.closeSurface();
    wf.setSurfaceTitle(if (saving) "Save document" else "Open document");
    refresh();
    draw(saving);
    _ = usys.log(glog, if (saving) "filepicker: save dialog" else "filepicker: open dialog");
    while (true) {
        const ev = wf.nextInput() orelse return null;
        var submit = false;
        const wheel = if (ev.kind == 1) shared.ptrWheel(ev.btn) else 0;
        if (wheel != 0 and count > 0 and widgets.contains(list_rect, ev.x, ev.y)) {
            selected = if (wheel > 0) selected -| 3 else @min(count - 1, selected + 3);
            draw(saving);
            continue;
        }
        switch (ev.kind) {
            0 => switch (ev.ch) {
                27, shared.keyboard.close_window => return null,
                9 => focus = (focus + 1) % 5,
                shared.keyboard.back_tab => focus = (focus + 4) % 5,
                13, 10 => switch (focus) {
                    1 => {
                        const is_file = selected < count and !rows[selected].dir;
                        enterRow();
                        submit = is_file;
                    },
                    2 => return null,
                    4 => up(),
                    else => submit = true,
                },
                shared.keyboard.up => {
                    if (focus == 1 and selected > 0) selected -= 1;
                },
                shared.keyboard.down => {
                    if (focus == 1 and selected + 1 < count) selected += 1;
                },
                else => {
                    if (focus == 0) {
                        _ = widgets.fieldKey(&edit, ev.ch);
                        replacing = false;
                    }
                },
            },
            1 => switch (wf.onPointer(ev, if (saving) "Save document" else "Open document")) {
                .close, .resize_failed => return null,
                .content => |pos| {
                    if (widgets.contains(cancel_rect, pos.x, pos.y)) return null;
                    if (widgets.contains(action_rect, pos.x, pos.y)) {
                        focus = 3;
                        submit = true;
                    }
                    if (widgets.contains(up_rect, pos.x, pos.y)) {
                        up();
                        focus = 4;
                    }
                    if (widgets.contains(field_rect, pos.x, pos.y)) focus = 0;
                    if (widgets.contains(list_rect, pos.x, pos.y) and row_height > 0) {
                        const idx = scroll + (pos.y - list_rect.y) / row_height;
                        if (idx < count) {
                            selected = idx;
                            focus = 1;
                            enterRow();
                        }
                    }
                },
                .minimized => wf.setSurfaceVisible(true),
                else => {},
            },
            4 => wf.win_focused = ev.ch != 0,
            3 => wf.setSurfaceVisible(true),
            7 => {
                if (!wf.outputChanged(ev, "Choose document", false)) return null;
            },
            255 => return null,
            else => {},
        }
        if (submit and edit.len > 0 and !(saving and read_only)) {
            const path = join(out, edit.buf[0..edit.len]) orelse {
                status = "This path is too long.";
                draw(saving);
                continue;
            };
            file.validatePath(path) catch {
                status = "Enter a valid relative file name.";
                draw(saving);
                continue;
            };
            const st = fs.fsStat(view, buffer, path);
            if (st != null and st.?.typ == @intFromEnum(shared.FsType.dir)) {
                @memcpy(directory[0..path.len], path);
                dir_len = path.len;
                setName("");
                refresh();
            } else if (saving and st != null and !replacing) {
                replacing = true;
                status = "This file exists. Choose Replace to overwrite it.";
                _ = usys.log(glog, "filepicker: replace confirmation");
            } else return path;
        }
        draw(saving);
    }
}

export fn umain(log_h: u64, chan_h: u64, arg: u64, blob_va: u64, blob_len: u64) callconv(.c) noreturn {
    _ = arg;
    _ = blob_va;
    _ = blob_len;
    glog = log_h;
    const setup = boot.take(chan_h);
    view = setup.cap(.view);
    const attached = fs.attachBuf(view);
    if (attached.va == 0) {
        _ = usys.log(glog, "filepicker: filesystem buffer unavailable");
        usys.exit(1);
    }
    buffer = @ptrFromInt(attached.va);
    _ = usys.capDrop(attached.cap); // the two service mappings retain the buffer
    wf.setup(setup.cap(.display), log_h, setup.secret(), setup.cap(.font));
    clipboard.authority = setup.cap(.clip);
    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err == .client_dead) {
            release(r.badge);
            continue;
        }
        if (r.err != .ok) continue;
        const req = shared.decodeMsg(p.Req, r.data) orelse {
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            _ = usys.replyTyped(p.Resp, chan_h, failure(error.Unavailable), 0);
            continue;
        };
        if (req != .attach_buf and r.cap != 0) _ = usys.capDrop(r.cap);
        if (req == .register) {
            if (next_badge == std.math.maxInt(u64)) {
                _ = usys.replyTyped(p.Resp, chan_h, failure(error.TemporaryFileBusy), 0);
                continue;
            }
            _ = allocate(next_badge) orelse {
                _ = usys.replyTyped(p.Resp, chan_h, failure(error.TemporaryFileBusy), 0);
                continue;
            };
            const minted = usys.chanMint(chan_h, next_badge);
            if (minted.err != .ok) {
                release(next_badge);
                _ = usys.replyTyped(p.Resp, chan_h, failure(error.Unavailable), 0);
                continue;
            }
            const badge = next_badge;
            next_badge += 1;
            const replied = usys.replyTyped(p.Resp, chan_h, .registered, minted.data[1]);
            // Reply copies the endpoint. Keeping our copy would prevent the
            // last real client's drop from generating client_dead forever.
            _ = usys.capDrop(minted.data[1]);
            if (replied != .ok) release(badge);
            continue;
        }
        const c = find(r.badge) orelse {
            if (req == .attach_buf and r.cap != 0) _ = usys.capDrop(r.cap);
            _ = usys.replyTyped(p.Resp, chan_h, failure(error.Unavailable), 0);
            continue;
        };
        if (req == .attach_buf) {
            const mapped = usys.shmMap(r.cap);
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            if (mapped.err != .ok) {
                _ = usys.replyTyped(p.Resp, chan_h, failure(error.Unavailable), 0);
                continue;
            }
            if (mapped.data[1] < p.pages) {
                _ = usys.shmUnmap(mapped.data[0]);
                _ = usys.replyTyped(p.Resp, chan_h, failure(error.TooLarge), 0);
                continue;
            }
            if (c.va != 0) _ = usys.shmUnmap(c.va);
            c.va = mapped.data[0];
            _ = usys.replyTyped(p.Resp, chan_h, .ok, 0);
            continue;
        }
        if (c.va == 0) {
            _ = usys.replyTyped(p.Resp, chan_h, failure(error.Unavailable), 0);
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
            _ = usys.replyTyped(p.Resp, chan_h, failure(error.TooLarge), 0);
            continue;
        }
        // Snapshot hostile/shared client bytes before showing any confirmation.
        if (saving) @memcpy(scratch[0..n], data[0..n]);
        var chosen: [256]u8 = undefined;
        const path = if (req == .open or req == .save_as) choose(c, saving, &chosen) orelse {
            _ = usys.replyTyped(p.Resp, chan_h, .cancelled, 0);
            continue;
        } else c.path[0..c.len];
        const len = if (saving) blk: {
            file.save(view, buffer, path, scratch[0..n]) catch |err| {
                _ = usys.replyTyped(p.Resp, chan_h, failure(err), 0);
                continue;
            };
            break :blk n;
        } else blk: {
            const loaded = file.load(view, buffer, path, &scratch) catch |err| {
                _ = usys.replyTyped(p.Resp, chan_h, failure(err), 0);
                continue;
            };
            @memcpy(data[0..loaded.len], loaded);
            break :blk loaded.len;
        };
        if (path.ptr != c.path[0..].ptr) @memcpy(c.path[0..path.len], path);
        c.len = path.len;
        _ = usys.replyTyped(p.Resp, chan_h, metadata(c, len), 0);
    }
}
