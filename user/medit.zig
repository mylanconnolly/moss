//! Moss-native medit. The editing model is pure Zig; the picker alone holds a filesystem view.
const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const ml = @import("mosslib");
const core = ml.editor;
const usys = @import("usys.zig");
const wf = @import("windowframe.zig");
const ui = @import("widgets.zig");
const boot = @import("boot.zig");
const clip = @import("clipboard.zig");
const document = @import("document.zig");
const Document = document.Client;
const strip = @import("tabstrip.zig");
const k = shared.keyboard;
const mono: u64 = @intFromEnum(shared.FontRole.mono);
comptime {
    if (!builtin.is_test) asm (usys.imageHeader("medit"));
}
pub const panic = std.debug.FullPanic(uPanic);
fn uPanic(msg: []const u8, _: ?usize) noreturn {
    _ = usys.log(log_h, msg);
    usys.exit(255);
}
var log_h: u64 = 0;
var authority: u64 = 0;
var receiver: u64 = 0;
var test_mode = false;
var pool: ml.pool.Pool(64, 131072) = .{};
/// One undo/redo budget for every tab: a dozen documents share the
/// history a single one used to have, and the oldest snapshot anywhere
/// goes first, not the active tab's.
var history_budget: core.Budget = .{};
const Tab = struct {
    ed: core.Editor,
    doc: ?Document = null,
    top: usize = 0,
    left: usize = 0,
    needs_reveal: bool = true,
    finding: bool = false,
    query: ml.ui.text.Editor = .{},
    message: [180]u8 = undefined,
    message_len: usize = 0,
    untitled: [32]u8 = undefined,
    untitled_len: usize = 0,
    initial_placeholder: bool = false,
    fn title(self: *const Tab) []const u8 {
        if (self.doc) |*d| {
            const path = d.title();
            if (path.len > 0) return if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| path[slash + 1 ..] else path;
        }
        return self.untitled[0..self.untitled_len];
    }
};
var tabs: std.ArrayList(*Tab) = .empty;
var tab_items: std.ArrayList(strip.Item) = .empty;
var active: *Tab = undefined;
var active_index: usize = 0;
var next_untitled: usize = 1;
var tab_state: strip.State = .{};
var tab_rect: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var close_cursor: usize = 0;
var tab_close_pressed: ?usize = null;
var running = true;
var hidden = false;
var cell: usize = 10;
var line_h: usize = 24;
var area: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var gutter: usize = 50;
var find_rect: ui.Rect = undefined;
const Pending = enum { none, close_tab, close_window };
const Action = enum { new, open, close_tab, close_window };
var pending: Pending = .none;
var confirm_focus: usize = 2;
var confirm_buttons: [3]ui.Rect = undefined;
var drag_select = false;
var confirm_pressed: ?usize = null;
var last_click: u64 = 0; // ms; the toolkit's double-click window
var click_pos: core.Pos = .{ .line = 0, .col = 0 };
fn log(comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    var b: [400]u8 = undefined;
    _ = usys.log(log_h, std.fmt.bufPrint(&b, fmt, args) catch return);
}
fn status(text: []const u8) void {
    active.message_len = @min(text.len, active.message.len);
    @memcpy(active.message[0..active.message_len], text[0..active.message_len]);
}
fn failed(err: anyerror) void {
    status(switch (err) {
        error.OutOfMemory => "Not enough memory. Your document is unchanged.",
        error.FileNotFound => "The selected file was not found. Your document is unchanged.",
        error.InvalidPath => "Choose a valid file name within the selected folder.",
        error.NotFile => "Choose a regular text file.",
        error.DocumentBusy => "The document picker is busy. Please try again.",
        error.ReadOnly => "This document is read-only. Use Save As to make a copy.",
        error.FileTooLarge, error.TooManyLines => "Document limit: 256 KiB or 8192 lines.",
        error.InvalidUtf8, error.BinaryFile, error.NotText => "This file is not supported UTF-8 text.",
        error.DiskFull => "The disk is full. Your edits are still here.",
        error.SaveUncertain => "Save could not be confirmed. Your edits remain unsaved.",
        else => "The document service is unavailable. Your edits are still here.",
    });
    log("editor: error {s}", .{@errorName(err)});
}
fn rows() usize {
    return @max(1, area.h / line_h);
}
fn cols() usize {
    return @max(1, (area.w -| gutter -| 12) / cell);
}
// Display columns are the editing model's (lib/editor.zig): one arithmetic
// for the caret, the footer, the click-to-position and the renderer.
const visualCol = core.Editor.visualCol;
const byteCol = core.Editor.byteCol;
fn reveal() void {
    const r = rows();
    if (active.ed.cursor.line < active.top) active.top = active.ed.cursor.line;
    if (active.ed.cursor.line >= active.top + r) active.top = active.ed.cursor.line - r + 1;
    const c = visualCol(active.ed.buffer.lineSlice(active.ed.cursor.line), active.ed.cursor.col);
    if (c < active.left) active.left = c;
    if (c >= active.left + cols()) active.left = c - cols() + 1;
}
fn drawRun(x: usize, y: usize, text: []const u8, selected: bool, width: usize) void {
    const bg = if (selected) wf.pal.primary else wf.pal.bg;
    if (selected) wf.fillRect(x, y, width, line_h, bg);
    wf.drawStr(x, y, mono, text, if (selected) wf.pal.primary_ink else wf.pal.text, bg);
}
fn drawLine(index: usize, y: usize) void {
    const s = active.ed.buffer.lineSlice(index);
    var b: [4096]u8 = undefined;
    var n: usize = 0;
    var run_start: usize = 0;
    var col: usize = 0;
    var selected = false;
    var started = false;
    const selection = active.ed.selection();
    var i: usize = 0;
    while (i < s.len) {
        const step = core.Editor.cellStep(s, i, col);
        const end = step.next;
        const nc = step.col;
        if (col >= active.left + cols()) break;
        if (col >= active.left and nc <= active.left + cols() and s[i] != '\r') {
            const yes = if (selection) |r| !core.Pos.lessThan(.{ .line = index, .col = i }, r.start) and core.Pos.lessThan(.{ .line = index, .col = i }, r.end) else false;
            if (started and yes != selected) {
                drawRun(area.x + gutter + (run_start - active.left) * cell, y, b[0..n], selected, (col - run_start) * cell);
                n = 0;
                started = false;
            }
            if (!started) {
                run_start = col;
                selected = yes;
                started = true;
            }
            if (s[i] == '\t') {
                const spaces = nc - col;
                if (n + spaces > b.len) break;
                @memset(b[n..][0..spaces], ' ');
                n += spaces;
            } else {
                if (n + end - i > b.len) break;
                @memcpy(b[n..][0 .. end - i], s[i..end]);
                n += end - i;
            }
        }
        col = nc;
        i = end;
    }
    if (started) drawRun(area.x + gutter + (run_start - active.left) * cell, y, b[0..n], selected, (col - run_start) * cell);
    if (selection) |r| if (index >= r.start.line and index < r.end.line and col >= active.left and col < active.left + cols()) {
        wf.fillRect(area.x + gutter + (col - active.left) * cell, y, cell, line_h, wf.pal.primary);
    };
}
fn publishMenu() void {
    const menu = shared.menus;
    var enabled = menu.offered(.editor);
    if (pending != .none) {
        // The confirmation owns document state until explicitly resolved.
        enabled = 0;
    } else {
        const selected = if (active.finding) active.query.low() != active.query.high() else active.ed.selection() != null;
        const undo_count = if (active.finding) active.query.undo_len else active.ed.undo_history.len;
        const redo_count = if (active.finding) active.query.redo_len else active.ed.redo_history.len;
        if (undo_count == 0) enabled &= ~menu.bit(k.undo);
        if (redo_count == 0) enabled &= ~menu.bit(k.redo);
        if (!selected or clip.authority == 0) enabled &= ~(menu.bit(k.cut) | menu.bit(k.copy));
        if (clip.authority == 0) enabled &= ~menu.bit(k.paste);
        if (active.doc) |d| if (d.read_only) {
            enabled &= ~menu.bit(k.save_document);
        };
    }
    if (tabs.items.len < 2) enabled &= ~(menu.bit(k.next_tab) | menu.bit(k.previous_tab));
    wf.setMenuProfile(.editor, enabled);
}
fn logFrame() void {
    log("editor: frame x={d} y={d} w={d} h={d} title={d} maximized={}", .{ wf.win_x, wf.win_y, wf.win_w, wf.win_h, wf.title_h, wf.maximized });
}
fn render() void {
    publishMenu();
    wf.clipReset();
    wf.fillAll(wf.pal.bg);
    wf.drawChrome("Editor");
    cell = @max(1, wf.strW(mono, "M"));
    line_h = wf.lineOf(mono);
    const pad: usize = 16;
    const h = ui.height();
    var y = wf.title_h;
    tab_rect = .{ .x = 0, .y = y, .w = wf.win_w, .h = strip.height() };
    for (tabs.items, tab_items.items) |tab, *item| item.* = .{ .label = tab.title(), .dirty = tab.ed.dirty() };
    strip.draw(tab_rect, tab_items.items, active_index, &tab_state);
    y += tab_rect.h;
    const selected_document: ?*Document = if (active.doc) |*d| (if (d.name_len > 0) d else null) else null;
    // The tab already names the document. Only a parent path adds context.
    if (selected_document) |d| {
        if (std.mem.indexOfScalar(u8, d.title(), '/') != null) {
            wf.drawStrTrunc(pad, y, wf.R_UI, d.title(), wf.win_w -| pad * 2, wf.pal.text_muted, wf.pal.bg);
            y += wf.lineOf(wf.R_UI) + 12;
        }
    }
    if (active.finding) {
        find_rect = .{ .x = pad, .y = y, .w = wf.win_w -| pad * 2, .h = h };
        ui.input(find_rect, &active.query, true);
        if (active.query.len == 0) wf.drawStrTrunc(find_rect.x + 10, find_rect.y + (find_rect.h -| wf.lineOf(wf.R_UI)) / 2, wf.R_UI, "Find in document · Enter next · Esc close", find_rect.w -| 20, wf.pal.text_muted, wf.pal.field_bg);
        y += h + 10;
    }
    const status_h = wf.lineOf(wf.R_UI) + 20;
    area = .{ .x = 0, .y = y, .w = wf.win_w, .h = wf.win_h -| status_h -| y };
    var number: [24]u8 = undefined;
    const digits = std.fmt.bufPrint(&number, "{d}", .{active.ed.buffer.lineCount()}) catch "1";
    gutter = wf.strW(mono, digits) + 24;
    if (active.needs_reveal) {
        reveal();
        active.needs_reveal = false;
    }
    active.top = @min(active.top, active.ed.buffer.lineCount() - 1);
    wf.fillRect(area.x, area.y, gutter - 8, area.h, wf.pal.surface);
    wf.clip_x0 = area.x;
    wf.clip_y0 = area.y;
    wf.clip_x1 = area.x + area.w - 8;
    wf.clip_y1 = area.y + area.h;
    for (0..@min(rows(), active.ed.buffer.lineCount() - active.top)) |r| {
        const idx = active.top + r;
        const yy = area.y + r * line_h;
        const ns = std.fmt.bufPrint(&number, "{d}", .{idx + 1}) catch "";
        wf.drawStr(area.x + gutter - 16 - wf.strW(mono, ns), yy, mono, ns, wf.pal.text_muted, wf.pal.surface);
        drawLine(idx, yy);
    }
    if (wf.win_focused and !active.finding and pending == .none and active.ed.cursor.line >= active.top and active.ed.cursor.line < active.top + rows()) {
        const col = visualCol(active.ed.buffer.lineSlice(active.ed.cursor.line), active.ed.cursor.col);
        if (col >= active.left and col < active.left + cols()) wf.fillRect(area.x + gutter + (col - active.left) * cell, area.y + (active.ed.cursor.line - active.top) * line_h, 2, line_h, wf.pal.focus);
    }
    wf.clipReset();
    if (active.ed.buffer.lineCount() > rows() and area.h > 0) {
        const thumb = @max(16, area.h * rows() / active.ed.buffer.lineCount());
        const off = (area.h -| thumb) * active.top / @max(1, active.ed.buffer.lineCount() - 1);
        wf.fillRoundRect(area.x + area.w - 5, area.y + off, 4, thumb, 2, wf.pal.text_muted);
    }
    wf.fillRect(0, wf.win_h - status_h, wf.win_w, 1, wf.pal.border);
    var foot: [200]u8 = undefined;
    const read_only = if (selected_document) |d| d.read_only else false;
    const text = if (active.message_len > 0) active.message[0..active.message_len] else std.fmt.bufPrint(&foot, "{s}Ln {d}, Col {d}   ·   UTF-8   ·   {d} lines", .{ if (read_only) "Read-only · " else "", active.ed.cursor.line + 1, visualCol(active.ed.buffer.lineSlice(active.ed.cursor.line), active.ed.cursor.col) + 1, active.ed.buffer.lineCount() }) catch "UTF-8";
    wf.drawStrTrunc(pad, wf.win_h - status_h + 10, wf.R_UI, text, wf.win_w -| pad * 2, wf.pal.text_muted, wf.pal.bg);
    if (pending != .none) {
        const mw = @min(wf.win_w -| 32, @as(usize, 620));
        const mh = wf.lineOf(wf.R_UI) * 3 + h + 64;
        const mx = (wf.win_w - mw) / 2;
        const my = (wf.win_h -| mh) / 2;
        wf.panel(mx, my, mw, mh, 10, wf.pal.surface, wf.pal.border, 2);
        wf.drawStrTrunc(mx + 20, my + 20, wf.R_TITLE, "Save your changes?", mw - 40, wf.pal.title, wf.pal.surface);
        wf.drawStrTrunc(mx + 20, my + 24 + wf.lineOf(wf.R_TITLE), wf.R_UI, active.title(), mw - 40, wf.pal.text_muted, wf.pal.surface);
        const bw = (mw - 56) / 3;
        for ([_][]const u8{ "Save", "Discard", "Cancel" }, 0..) |label, i| {
            confirm_buttons[i] = .{ .x = mx + 20 + i * (bw + 8), .y = my + mh - h - 20, .w = bw, .h = h };
            ui.Button.draw(confirm_buttons[i], label, "", confirm_focus == i, i == 0, false);
        }
    }
    _ = wf.commitSurface();
}
fn digest(bytes: []const u8) void {
    if (!test_mode) return;
    var sum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &sum, .{});
    const hex = std.fmt.bytesToHex(sum, .lower);
    log("editor: digest {s}", .{hex});
}
fn save(as: bool) bool {
    const text = active.ed.contentAlloc(pool.allocator()) catch |e| {
        failed(e);
        return false;
    };
    var transferred = false;
    defer if (!transferred) pool.allocator().free(text);
    if (active.doc == null) active.doc = Document.init(authority) catch |e| {
        failed(e);
        return false;
    };
    if (!(active.doc.?.save(text, as) catch |e| {
        failed(e);
        return false;
    })) return false;
    active.ed.markSavedOwned(text);
    transferred = true;
    status("Saved");
    log("editor: saved {s} bytes={d}", .{ active.doc.?.title(), text.len });
    return true;
}
fn activate(index: usize) void {
    if (index >= tabs.items.len) return;
    if (tabs.items.len > 0) active.ed.breakGroup();
    active_index = index;
    active = tabs.items[index];
    tab_state.reveal(index);
    drag_select = false;
    confirm_pressed = null;
    last_click = 0;
    tab_close_pressed = null;
    log("editor: tab {d}/{d} {s}", .{ index + 1, tabs.items.len, active.title() });
}

/// Reserve a tab and its list capacity before requesting another document.
fn prepareTab() !*Tab {
    const gpa = pool.allocator();
    const tab = try gpa.create(Tab);
    errdefer gpa.destroy(tab);
    tab.* = .{ .ed = try core.Editor.init(gpa) };
    errdefer tab.ed.deinit();
    tab.ed.attach(&history_budget);
    const name = try std.fmt.bufPrint(&tab.untitled, "Untitled {d}", .{next_untitled});
    tab.untitled_len = name.len;
    try tabs.ensureUnusedCapacity(gpa, 1);
    try tab_items.ensureUnusedCapacity(gpa, 1);
    return tab;
}
fn discardPrepared(tab: *Tab) void {
    tab.ed.deinit();
    pool.allocator().destroy(tab);
}
fn publishTab(tab: *Tab, selected: ?Document) void {
    tab.doc = selected;
    const first = tabs.items.len == 0;
    tabs.appendAssumeCapacity(tab);
    tab_items.appendAssumeCapacity(.{ .label = tab.title(), .dirty = tab.ed.dirty() });
    next_untitled += 1;
    if (first) active = tab;
    activate(tabs.items.len - 1);
}
/// All allocations and text validation finish before a new tab is published.
/// `selected` transfers ownership only on success.
fn addTab(text: ?[]const u8, selected: ?Document) !void {
    const tab = try prepareTab();
    errdefer discardPrepared(tab);
    if (text) |bytes| try tab.ed.load(bytes);
    publishTab(tab, selected);
}

fn canReplaceInitial() bool {
    if (tabs.items.len != 1) return false;
    const tab = tabs.items[0];
    return tab.initial_placeholder and tab.doc == null and !tab.ed.dirty() and
        tab.ed.undo_history.len == 0 and tab.ed.redo_history.len == 0 and
        tab.ed.buffer.lineCount() == 1 and tab.ed.buffer.lineSlice(0).len == 0;
}

/// Consume both the reserved tab and offered authority on every outcome.
fn adoptSelected(tab: *Tab, selected: Document) void {
    var candidate = selected;
    var retained = false;
    defer if (!retained) {
        candidate.deinit();
        discardPrepared(tab);
    };
    const text = (candidate.load() catch |err| {
        failed(err);
        return;
    }) orelse return;
    tab.ed.load(text) catch |err| {
        failed(err);
        return;
    };
    if (canReplaceInitial()) {
        const old = tabs.items[0];
        tab.doc = candidate;
        tabs.items[0] = tab;
        tab_items.items[0] = .{ .label = tab.title(), .dirty = tab.ed.dirty() };
        if (old.doc) |*d| d.deinit();
        discardPrepared(old);
        active = tab;
        next_untitled += 1;
        activate(0);
    } else publishTab(tab, candidate);
    retained = true;
    log("editor: loaded {s} bytes={d}", .{ candidate.title(), text.len });
    digest(text);
    hidden = false;
    wf.setSurfaceVisible(true);
}
fn pollHandoff() bool {
    // Reserve UI/model capacity before removing anything from the broker queue.
    const tab = prepareTab() catch |err| {
        failed(err);
        return true;
    };
    const candidate = (Document.take(receiver) catch |err| {
        discardPrepared(tab);
        failed(err);
        return true;
    }) orelse {
        discardPrepared(tab);
        return false;
    };
    adoptSelected(tab, candidate);
    return true;
}

fn removeActive() void {
    const old = active;
    _ = tabs.orderedRemove(active_index);
    _ = tab_items.orderedRemove(active_index);
    if (old.doc) |*d| d.deinit();
    old.ed.deinit();
    pool.allocator().destroy(old);
    if (tabs.items.len == 0) {
        running = false;
        return;
    }
    // The previous active pointer was freed; establish its replacement before
    // activate breaks the current typing group.
    active = tabs.items[@min(active_index, tabs.items.len - 1)];
    activate(@min(active_index, tabs.items.len - 1));
}

fn continueWindowClose() void {
    while (close_cursor < tabs.items.len) : (close_cursor += 1) {
        if (tabs.items[close_cursor].ed.dirty()) {
            activate(close_cursor);
            pending = .close_window;
            confirm_focus = 2;
            return;
        }
    }
    // All tabs remain alive until the entire close sequence is accepted. A
    // Cancel at any earlier prompt preserves even previously discarded tabs.
    pending = .none;
    running = false;
}

fn request(action: Action) void {
    active.initial_placeholder = false;
    active.ed.breakGroup();
    switch (action) {
        .new => addTab(null, null) catch |err| failed(err),
        .open => {
            var candidate = Document.init(authority) catch |err| {
                failed(err);
                return;
            };
            var retained = false;
            defer if (!retained) candidate.deinit();
            const text = (candidate.open() catch |err| {
                failed(err);
                return;
            }) orelse return;
            addTab(text, candidate) catch |err| {
                failed(err);
                return;
            };
            retained = true;
            log("editor: loaded {s} bytes={d}", .{ candidate.title(), text.len });
            digest(text);
        },
        .close_tab => {
            if (active.ed.dirty()) {
                pending = .close_tab;
                confirm_focus = 2;
            } else removeActive();
        },
        .close_window => {
            close_cursor = 0;
            continueWindowClose();
        },
    }
}
fn confirm(which: usize) void {
    if (which == 2) {
        pending = .none;
        close_cursor = 0;
        log("editor: close cancelled", .{});
        return;
    }
    if (which == 0 and !save(false)) return;
    const action = pending;
    pending = .none;
    if (which == 1) log("editor: discarded", .{});
    if (action == .close_window) {
        close_cursor += 1;
        continueWindowClose();
    } else if (action == .close_tab) removeActive();
}
fn findNext(back: bool) void {
    if (active.query.len == 0) return;
    if (active.ed.find(active.query.buf[0..active.query.len], back) catch |e| {
        failed(e);
        return;
    }) {
        status("");
        reveal();
    } else status("No matches");
}
fn key(ch: u8) void {
    if (ch != 0) active.initial_placeholder = false;
    if (ch == shared.menus.minimize) {
        if (pending == .none) {
            wf.setSurfaceVisible(false);
            hidden = true;
        }
        return;
    }
    if (pending != .none) {
        if (ch == 27) confirm(2) else if (ch == '\t') {
            confirm_focus = (confirm_focus + 1) % 3;
        } else if (ch == k.back_tab) {
            confirm_focus = (confirm_focus + 2) % 3;
        } else if (ch == '\n') confirm(confirm_focus);
        return;
    }
    if (ch == k.next_tab or ch == k.previous_tab) {
        const count = tabs.items.len;
        activate(if (ch == k.next_tab) (active_index + 1) % count else (active_index + count - 1) % count);
        return;
    }
    if (ch == k.close_all) {
        request(.close_window);
        return;
    }
    if (ch == k.close_document) {
        request(.close_tab);
        return;
    }
    if (ch == k.new_document) {
        request(.new);
        return;
    }
    if (ch == k.open_document) {
        request(.open);
        return;
    }
    if (ch == k.save_document) {
        _ = save(false);
        return;
    }
    if (ch == k.save_as) {
        _ = save(true);
        return;
    }
    if (ch == k.find) {
        active.finding = true;
        active.query = .{};
        return;
    }
    if (active.finding) {
        if (ch == 27) {
            active.finding = false;
        } else if (ch == '\n') findNext(false) else if (ch == k.back_tab) findNext(true) else {
            _ = ui.fieldKey(&active.query, ch);
        }
        return;
    }
    if (ch == k.back_tab) return;
    active.message_len = 0;
    const movement: ?core.Movement = switch (ch) {
        k.left, k.select_left, 2 => .left,
        k.right, k.select_right, 6 => .right,
        k.up, k.select_up, 16 => .up,
        k.down, k.select_down, 14 => .down,
        k.home, k.select_home, 1 => .line_start,
        k.end, k.select_end, 5 => .line_end,
        k.word_left, k.select_word_left => .word_left,
        k.word_right, k.select_word_right => .word_right,
        k.doc_home, k.select_doc_home => .document_start,
        k.doc_end, k.select_doc_end => .document_end,
        else => null,
    };
    if (movement) |m| {
        const extend = ch == k.select_left or ch == k.select_right or ch == k.select_up or ch == k.select_down or ch == k.select_home or ch == k.select_end or ch == k.select_word_left or ch == k.select_word_right or ch == k.select_doc_home or ch == k.select_doc_end;
        active.ed.move(m, extend);
        reveal();
        return;
    }
    switch (ch) {
        k.select_all => active.ed.selectAll(),
        k.copy, k.cut, 3, 24 => {
            active.ed.breakGroup();
            const text = active.ed.selectionAlloc(pool.allocator()) catch |e| {
                failed(e);
                return;
            };
            defer pool.allocator().free(text);
            if (text.len > 0) {
                if (clip.set(text)) {
                    if (ch == k.cut or ch == 24) active.ed.backspace() catch |e| {
                        failed(e);
                        return;
                    };
                } else status("Clipboard unavailable or selection exceeds 4 KiB.");
            }
        },
        k.paste, 22 => {
            active.ed.breakGroup();
            if (clip.get()) |text| active.ed.insert(text) catch |e| {
                failed(e);
                return;
            } else status("Clipboard unavailable.");
            active.ed.breakGroup();
        },
        k.undo, 26 => {
            _ = active.ed.undo() catch |e| {
                failed(e);
                return;
            };
        },
        k.redo => {
            _ = active.ed.redo() catch |e| {
                failed(e);
                return;
            };
        },
        8, 127 => active.ed.backspace() catch |e| {
            failed(e);
            return;
        },
        k.delete, 4 => active.ed.deleteForward() catch |e| {
            failed(e);
            return;
        },
        k.delete_word, 23 => {
            if (active.ed.selection() == null) active.ed.move(.word_left, true);
            active.ed.backspace() catch |e| {
                failed(e);
                return;
            };
        },
        11 => {
            if (active.ed.selection() == null) {
                active.ed.move(.line_end, true);
                if (active.ed.selection() == null) active.ed.move(.right, true);
            }
            const text = active.ed.selectionAlloc(pool.allocator()) catch |e| {
                failed(e);
                return;
            };
            defer pool.allocator().free(text);
            if (clip.set(text)) active.ed.backspace() catch |e| {
                failed(e);
                return;
            };
        },
        25 => {
            if (clip.get()) |text| active.ed.insert(text) catch |e| {
                failed(e);
                return;
            };
        },
        0x1e, 0x1f => {
            for (0..rows()) |_| active.ed.move(if (ch == 0x1e) .up else .down, false);
        },
        '\n' => active.ed.newline() catch |e| {
            failed(e);
            return;
        },
        '\t' => {
            const n = 4 - visualCol(active.ed.buffer.lineSlice(active.ed.cursor.line), active.ed.cursor.col) % 4;
            active.ed.breakGroup();
            active.ed.insert("    "[0..n]) catch |e| {
                failed(e);
                return;
            };
            active.ed.breakGroup();
        },
        27 => active.ed.setCursor(active.ed.cursor, false),
        else => if (ch >= 32 and ch < 127) {
            active.ed.insert(&.{ch}) catch |e| {
                failed(e);
                return;
            };
        },
    }
    reveal();
}
fn hitPos(x: usize, y: usize) core.Pos {
    const line = @min(active.ed.buffer.lineCount() - 1, active.top + (y -| area.y) / line_h);
    return .{ .line = line, .col = byteCol(active.ed.buffer.lineSlice(line), active.left + (x -| area.x -| gutter) / cell) };
}
fn pointer(ev: wf.Event) void {
    const down = ev.btn & 1 != 0;
    const press = down and !wf.ptr_down;
    const release = !down and wf.ptr_down;
    const wheel = shared.ptrWheel(ev.btn);
    if (press or wheel != 0) active.initial_placeholder = false;
    if (wheel != 0) {
        active.top = @intCast(std.math.clamp(@as(isize, @intCast(active.top)) - @as(isize, wheel) * 3, 0, @as(isize, @intCast(active.ed.buffer.lineCount() -| rows()))));
        return;
    }
    if (drag_select) {
        if (down) {
            active.ed.setCursor(hitPos(ev.x, ev.y), true);
            reveal();
        } else drag_select = false;
    }
    const event = wf.onPointer(ev, "Editor");
    switch (event) {
        .close => {
            if (pending != .none) confirm(2) else request(.close_window);
        },
        .minimized => hidden = true,
        .resize_failed => {
            // The frame put the geometry back itself; only the word is ours.
            status("Not enough display memory to resize. Your edits are safe.");
        },
        .resized => {
            logFrame();
            for (tabs.items) |tab| tab.needs_reveal = true;
        },
        else => {},
    }
    if (pending != .none) {
        if (press) for (confirm_buttons, 0..) |r, i| {
            if (ui.contains(r, ev.x, ev.y)) {
                confirm_focus = i;
                confirm_pressed = i;
            }
        };
        if (release) {
            if (confirm_pressed) |i| {
                if (i < 3 and ui.contains(confirm_buttons[i], ev.x, ev.y)) confirm(i);
            }
            confirm_pressed = null;
        }
        return;
    }
    if (release) {
        if (tab_close_pressed) |index| {
            tab_close_pressed = null;
            const hit = strip.hit(tab_rect, tab_items.items, tab_state, ev.x, ev.y);
            if (hit == .close and hit.close == index) {
                activate(index);
                request(.close_tab);
            }
            return;
        }
    }
    if (press and ui.contains(tab_rect, ev.x, ev.y)) {
        switch (strip.hit(tab_rect, tab_items.items, tab_state, ev.x, ev.y)) {
            .select => |index| activate(index),
            .close => |index| tab_close_pressed = index,
            .previous => {
                tab_state.previous();
            },
            .next => {
                tab_state.next(tabs.items.len);
            },
            .none => {},
        }
        return;
    }
    if (press) {
        if (ui.contains(area, ev.x, ev.y)) {
            active.finding = false;
            const pos = hitPos(ev.x, ev.y);
            active.ed.setCursor(pos, false);
            const now = usys.nowMs();
            if (pos.eql(click_pos) and now - last_click < ml.ui.pointer.double_click_ms) {
                active.ed.selectWordAt(pos);
                last_click = 0;
            } else {
                last_click = now;
                click_pos = pos;
            }
            drag_select = true;
        }
    }
}
export fn umain(log_cap: u64, chan_h: u64, arg: u64) callconv(.c) noreturn {
    log_h = log_cap;
    test_mode = arg == 1;
    const setup = boot.take(chan_h);
    authority = setup.cap(.picker);
    receiver = setup.cap(.documents);
    clip.authority = setup.cap(.clip);
    if (test_mode) {
        document.probeQueueAuthority(authority) catch {
            log("editor: handoff authority FAILED", .{});
            usys.exit(1);
        };
        log("editor: handoff authority verified", .{});
        document.probeHandoff(authority, receiver, setup.cap(.view)) catch |err| {
            log("editor: handoff lifecycle FAILED: {s}", .{@errorName(err)});
            usys.exit(1);
        };
        log("editor: handoff lifecycle and readonly scope verified", .{});
        document.probeSelfCall(chan_h) catch |err| {
            log("editor: self-call guard FAILED: {s}", .{@errorName(err)});
            usys.exit(1);
        };
        log("editor: self-call refused by the kernel", .{});
        // Exercise real registered-client teardown beyond the old small pool
        // sizes, and prove a client cannot save before a user chooses a file.
        for (0..128) |_| {
            var probe = Document.init(authority) catch {
                usys.exit(1);
            };
            const rep = usys.callTyped(shared.picker.Req, shared.picker.Resp, probe.chan, .{ .save = .{ .len = 0 } }, 0);
            const denied = switch (rep) {
                .ok => |r| r == .failed and r.failed.code == @intFromEnum(shared.picker.Error.bad_path),
                .err => false,
            };
            probe.deinit();
            if (!denied) {
                log("editor: selection boundary FAILED", .{});
                usys.exit(1);
            }
        }
        log("editor: document clients reclaimed; unselected save denied", .{});
    }
    addTab(null, null) catch {
        usys.exit(1);
    };
    active.initial_placeholder = true;
    wf.setup(setup.cap(.display), log_h, setup.secret(), setup.cap(.font));
    wf.fontReady();
    wf.refreshAppearance();
    wf.useOrdinaryChannel();
    _ = wf.refreshOutput();
    const work = wf.workArea();
    wf.win_w = @min(960, work.w);
    wf.win_h = @min(760, work.h);
    wf.win_x = work.x + (work.w - wf.win_w) / 2;
    wf.win_y = work.y + (work.h - wf.win_h) / 2;
    wf.pointer_tracking = true;
    wf.tick_ms = 250;
    if (!wf.openSurface(true)) usys.exit(1);
    wf.setSurfaceTitle("Editor");
    render();
    logFrame();
    log("editor: ready", .{});
    while (running) {
        const ev = wf.nextInput() orelse break;
        var repaint = true;
        if (ev.kind == 7) {
            if (!wf.outputChanged(ev, "Editor", hidden)) status("Display resize failed. Your document is still open.");
            for (tabs.items) |tab| tab.needs_reveal = true;
        } else if (ev.kind == 4) {
            wf.win_focused = ev.ch != 0;
            if (!wf.win_focused) {
                drag_select = false;
                confirm_pressed = null;
                tab_close_pressed = null;
            }
        } else if (ev.kind == 3) {
            hidden = false;
        } else if (ev.kind == 2) {
            if (wf.refreshFontMetrics()) {
                wf.refreshAppearance();
                for (tabs.items) |tab| tab.needs_reveal = true;
            } else repaint = false;
        } else if (ev.kind == 1) pointer(ev) else key(ev.ch);
        // Finish the event on its original tab before adopting a handoff. A
        // queued keystroke must never be applied to the newly arrived file.
        // Polling reserves a tab's model first, so it is done on the tick
        // and on window events, not for every keystroke and pointer move.
        const poll_due = ev.kind != 0 and ev.kind != 1 and ev.kind != 6;
        if (running and poll_due and pending == .none and receiver != 0 and pollHandoff()) repaint = true;
        if (running and !hidden and repaint) render();
    }
    freeTabs();
    wf.closeSurface();
    log("editor: exit", .{});
    usys.exit(0);
}

fn freeTabs() void {
    for (tabs.items) |tab| {
        if (tab.doc) |*d| d.deinit();
        tab.ed.deinit();
        pool.allocator().destroy(tab);
    }
    tabs.deinit(pool.allocator());
    tab_items.deinit(pool.allocator());
    tabs = .empty;
    tab_items = .empty;
    pending = .none;
    close_cursor = 0;
    active_index = 0;
    running = true;
}

test "document tabs isolate text history caret scroll and find state" {
    defer freeTabs();
    try addTab(null, null);
    const first = active;
    try active.ed.insert("first");
    active.top = 7;
    active.left = 3;
    active.finding = true;
    active.query.paste("needle");
    try addTab(null, null);
    const second = active;
    try active.ed.insert("second");
    try std.testing.expectEqual(@as(usize, 2), tabs.items.len);
    activate(0);
    try std.testing.expect(active == first);
    try std.testing.expectEqualStrings("first", active.ed.buffer.lineSlice(0));
    try std.testing.expectEqual(@as(usize, 5), active.ed.cursor.col);
    try std.testing.expectEqual(@as(usize, 7), active.top);
    try std.testing.expectEqual(@as(usize, 3), active.left);
    try std.testing.expectEqualStrings("needle", active.query.buf[0..active.query.len]);
    try std.testing.expect(active.finding);
    try std.testing.expect(try active.ed.undo());
    try std.testing.expectEqualStrings("", active.ed.buffer.lineSlice(0));
    try std.testing.expectEqualStrings("second", second.ed.buffer.lineSlice(0));
    request(.close_tab);
    try std.testing.expectEqual(@as(usize, 1), tabs.items.len);
    try std.testing.expect(active == second);
}

test "cancelling window close preserves every tab including prior discard choices" {
    defer freeTabs();
    try addTab(null, null);
    const first = active;
    try active.ed.insert("first dirty");
    try addTab(null, null);
    const second = active;
    try active.ed.insert("second dirty");
    request(.close_window);
    try std.testing.expectEqual(Pending.close_window, pending);
    try std.testing.expect(active == first);
    confirm(1);
    try std.testing.expect(active == second);
    try std.testing.expectEqual(@as(usize, 2), tabs.items.len);
    try std.testing.expect(first.ed.dirty());
    confirm(2);
    try std.testing.expectEqual(Pending.none, pending);
    try std.testing.expect(running);
    try std.testing.expectEqual(@as(usize, 2), tabs.items.len);
    try std.testing.expectEqualStrings("first dirty", first.ed.buffer.lineSlice(0));
    try std.testing.expectEqualStrings("second dirty", second.ed.buffer.lineSlice(0));
    request(.close_window);
    confirm(1);
    confirm(1);
    try std.testing.expect(!running);
    try std.testing.expectEqual(@as(usize, 2), tabs.items.len);
}

test "tab allocation failure does not replace or mutate the current document" {
    defer freeTabs();
    try addTab(null, null);
    const original = active;
    try active.ed.insert("keep my edits");
    var reservations: std.ArrayList([]u8) = .empty;
    defer {
        for (reservations.items) |bytes| pool.allocator().free(bytes);
        reservations.deinit(std.testing.allocator);
    }
    for ([_]usize{ 64 * 1024, 1024 }) |size| {
        while (pool.allocator().alloc(u8, size)) |bytes| {
            try reservations.append(std.testing.allocator, bytes);
        } else |_| {}
    }
    try std.testing.expectError(error.OutOfMemory, addTab(null, null));
    try std.testing.expect(active == original);
    try std.testing.expectEqual(@as(usize, 1), tabs.items.len);
    try std.testing.expectEqualStrings("keep my edits", active.ed.buffer.lineSlice(0));
}

test "only the untouched initial blank is replaceable by a Files handoff" {
    defer freeTabs();
    try addTab(null, null);
    active.initial_placeholder = true;
    try std.testing.expect(canReplaceInitial());
    try active.ed.insert("x");
    try std.testing.expect(!canReplaceInitial());
    try std.testing.expect(try active.ed.undo());
    try std.testing.expect(!canReplaceInitial()); // redo history is still meaningful
    try active.ed.load("");
    active.initial_placeholder = false;
    try std.testing.expect(!canReplaceInitial());
    active.initial_placeholder = true;
    try addTab(null, null);
    try std.testing.expect(!canReplaceInitial());
}
