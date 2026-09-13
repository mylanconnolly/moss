//! Byte-oriented seat keys. Extended editing actions are private to the GUI;
//! terminals translate them to console sequences before forwarding to apps.
const std = @import("std");
pub const switch_window = 128;
pub const back_tab = 129;
pub const home = 130;
pub const end = 131;
pub const delete = 132;
pub const word_left = 133;
pub const word_right = 134;
pub const select_all = 135;
pub const select_left = 136;
pub const select_right = 137;
pub const select_home = 138;
pub const select_end = 139;
pub const select_word_left = 140;
pub const select_word_right = 141;
pub const delete_word = 142;
pub const up = 143;
pub const down = 144;
pub const left = 145;
pub const right = 146;

pub const copy = 147;
pub const cut = 148;
pub const paste = 149;
pub const undo = 150;
pub const redo = 151;

// Window-level document actions, never forwarded as literal terminal bytes.
pub const new_document = 152;
pub const open_document = 153;
pub const save_document = 154;
pub const save_as = 155;
pub const find = 156;
pub const close_window = 157;
pub const doc_home = 158;
pub const doc_end = 159;
pub const select_up = 160;
pub const select_down = 161;
pub const select_doc_home = 162;
pub const select_doc_end = 163;
pub const menu_focus = 168;
pub const next_tab = 169;
pub const previous_tab = 170;
pub const close_all = 171;
pub const launcher = 172;
pub const readonly_view = 176;
pub const leave_view = 177;
/// Cmd-W closes the active document in tabbed apps, otherwise its window.
pub const close_document = close_window;

pub const Decoder = struct {
    held: [8]bool = @splat(false),
    pub fn feed(self: *Decoder, code: u16, value: u32) u8 {
        const modifier: ?usize = switch (code) {
            42 => 0,
            54 => 1,
            29 => 2,
            97 => 3,
            56 => 4,
            100 => 5,
            125 => 6,
            126 => 7,
            else => null,
        };
        if (modifier) |i| {
            self.held[i] = value != 0;
            return 0;
        }
        if (value != 1 and value != 2) return 0;
        const shift = self.held[0] or self.held[1];
        const ctrl = self.held[2] or self.held[3];
        const alt = self.held[4] or self.held[5];
        const meta = self.held[6] or self.held[7];
        if (!alt and !meta and ((code == 68 and !ctrl and !shift) or (code == 60 and ctrl and !shift))) return menu_focus;
        if (meta and code == 57 and !ctrl and !alt) return launcher;
        if (code == 15) return if (alt) switch_window else if (ctrl) (if (shift) previous_tab else next_tab) else if (shift) back_tab else '\t';
        if (meta and code == 38 and shift) return readonly_view;
        if (meta and code == 38 and alt) return leave_view;
        if (meta) switch (code) {
            46 => return copy,
            45 => return cut,
            47 => return paste,
            44 => return if (shift) redo else undo,
            49 => return new_document,
            24 => return open_document,
            31 => return if (shift) save_as else save_document,
            33 => return find,
            17 => return if (shift) close_all else close_window,
            else => {},
        };
        if (meta and code == 30) return select_all;
        if (code == 105 or code == 106 or code == 102 or code == 107) {
            const to_left = code == 105 or code == 102;
            if (meta or code == 102 or code == 107) return if (shift) (if (to_left) select_home else select_end) else (if (to_left) home else end);
            if (alt) return if (shift) (if (to_left) select_word_left else select_word_right) else (if (to_left) word_left else word_right);
            return if (shift) (if (to_left) select_left else select_right) else (if (to_left) left else right);
        }
        if (code == 103 or code == 108) {
            const to_up = code == 103;
            if (meta) return if (shift) (if (to_up) select_doc_home else select_doc_end) else (if (to_up) doc_home else doc_end);
            if (shift) return if (to_up) select_up else select_down;
        }
        if (code == 111) return delete;
        if (alt and code == 14) return delete_word;
        var ch = base(code);
        if (ctrl and ch >= 'a' and ch <= 'z') return ch - 'a' + 1;
        if (alt or meta) return 0; // unsupported shortcuts must not insert text
        if (shift) {
            if (ch >= 'a' and ch <= 'z') return ch - 'a' + 'A';
            const plain = "1234567890-=[];'`,./\\";
            const shifted = "!@#$%^&*()_+{}:\"~<>?|";
            if (std.mem.indexOfScalar(u8, plain, ch)) |i| ch = shifted[i];
        }
        return ch;
    }
};

pub fn terminal(ch: u8) []const u8 {
    return switch (ch) {
        up => "\x1b[A",
        down => "\x1b[B",
        left => "\x1b[D",
        right => "\x1b[C",
        home => "\x1b[H",
        end => "\x1b[F",
        delete => "\x1b[3~",
        back_tab => "\x1b[Z",
        else => "",
    };
}

/// Stateful conversion at the terminal boundary. Paste bytes are literal,
/// never seat actions, even when their UTF-8 values overlap private keys.
pub const ConsoleKeys = struct {
    pending: []const u8 = "",
    pub fn pop(self: *ConsoleKeys) ?u8 {
        if (self.pending.len == 0) return null;
        const ch = self.pending[0];
        self.pending = self.pending[1..];
        return ch;
    }
    pub fn feed(self: *ConsoleKeys, ch: u8, literal: bool) ?u8 {
        std.debug.assert(self.pending.len == 0);
        if (literal or ch < 128) return ch;
        self.pending = terminal(ch);
        return self.pop();
    }
};

test "terminal navigation is VT, pasted UTF-8 is literal, GUI actions are dropped" {
    var keys: ConsoleKeys = .{};
    try std.testing.expectEqual(@as(?u8, 27), keys.feed(left, false));
    try std.testing.expectEqual(@as(?u8, '['), keys.pop());
    try std.testing.expectEqual(@as(?u8, 'D'), keys.pop());
    try std.testing.expectEqual(@as(?u8, null), keys.pop());
    try std.testing.expectEqual(@as(?u8, null), keys.feed(select_all, false));
    for ("é世界") |byte| try std.testing.expectEqual(@as(?u8, byte), keys.feed(byte, true));
    for (128..256) |byte| try std.testing.expectEqual(@as(?u8, @intCast(byte)), keys.feed(@intCast(byte), true));
    try std.testing.expectEqual(@as(?u8, '\t'), keys.feed('\t', false));
}

fn base(code: u16) u8 {
    return switch (code) {
        2...11 => "1234567890"[code - 2],
        16 => 'q',
        17 => 'w',
        18 => 'e',
        19 => 'r',
        20 => 't',
        21 => 'y',
        22 => 'u',
        23 => 'i',
        24 => 'o',
        25 => 'p',
        30 => 'a',
        31 => 's',
        32 => 'd',
        33 => 'f',
        34 => 'g',
        35 => 'h',
        36 => 'j',
        37 => 'k',
        38 => 'l',
        44 => 'z',
        45 => 'x',
        46 => 'c',
        47 => 'v',
        48 => 'b',
        49 => 'n',
        50 => 'm',
        57 => ' ',
        28 => '\n', // enter
        15 => '\t', // Tab belongs to the focused window
        1 => 27, // escape (ASCII ESC — dismiss a popup, close the dock)
        13 => '=',
        26 => '[',
        27 => ']',
        39 => ';',
        40 => '\'',
        41 => '`',
        43 => '\\',
        51 => ',',
        52 => '.',
        53 => '/',
        12 => '-', // minus/hyphen
        14 => 8, // backspace (ASCII BS)
        // Arrow keys → private control bytes a GUI uses for navigation
        // (a scrollable list moves its selection); no ASCII of their own.
        103 => up,
        108 => down,
        105 => left,
        106 => right,
        // Page up/down → private control bytes a scrollback client
        // (the terminal) intercepts; no ASCII, ignored by everyone else.
        104 => 0x1e, // page up   (RS)
        109 => 0x1f, // page down (US)
        else => 0,
    };
}

test "modifiers, releases, repeat, and window Tab are distinct" {
    var d: Decoder = .{};
    try std.testing.expectEqual(@as(u8, 9), d.feed(15, 1));
    _ = d.feed(56, 1);
    try std.testing.expectEqual(@as(u8, switch_window), d.feed(15, 1));
    _ = d.feed(56, 0);
    _ = d.feed(42, 1);
    try std.testing.expectEqual(@as(u8, 'A'), d.feed(30, 2));
    try std.testing.expectEqual(@as(u8, select_left), d.feed(105, 1));
    _ = d.feed(54, 1);
    _ = d.feed(42, 0);
    try std.testing.expectEqual(@as(u8, back_tab), d.feed(15, 1));
    _ = d.feed(54, 0);
    _ = d.feed(29, 1);
    try std.testing.expectEqual(@as(u8, 1), d.feed(30, 1));
    try std.testing.expectEqual(@as(u8, 0), d.feed(30, 0));
}

test "Command clipboard and undo preserve Control Emacs actions" {
    var d: Decoder = .{};
    _ = d.feed(125, 1);
    try std.testing.expectEqual(@as(u8, copy), d.feed(46, 1));
    try std.testing.expectEqual(@as(u8, cut), d.feed(45, 1));
    try std.testing.expectEqual(@as(u8, paste), d.feed(47, 1));
    try std.testing.expectEqual(@as(u8, undo), d.feed(44, 1));
    _ = d.feed(42, 1);
    try std.testing.expectEqual(@as(u8, redo), d.feed(44, 1));
    _ = d.feed(125, 0);
    _ = d.feed(42, 0);
    _ = d.feed(29, 1);
    try std.testing.expectEqual(@as(u8, 25), d.feed(21, 1));
    try std.testing.expectEqual(@as(u8, 1), d.feed(30, 1));
}

test "document shortcuts and vertical selection remain window actions" {
    var d: Decoder = .{};
    _ = d.feed(125, 1);
    try std.testing.expectEqual(@as(u8, save_document), d.feed(31, 1));
    try std.testing.expectEqual(@as(u8, open_document), d.feed(24, 1));
    _ = d.feed(42, 1);
    try std.testing.expectEqual(@as(u8, save_as), d.feed(31, 1));
    try std.testing.expectEqual(@as(u8, select_doc_home), d.feed(103, 1));
    _ = d.feed(125, 0);
    try std.testing.expectEqual(@as(u8, select_down), d.feed(108, 1));
    try std.testing.expectEqualStrings("", terminal(save_document));
}

test "global menu keyboard entry is reserved and ignores release" {
    var d: Decoder = .{};
    try std.testing.expectEqual(@as(u8, menu_focus), d.feed(68, 1));
    try std.testing.expectEqual(@as(u8, 0), d.feed(68, 0));
    _ = d.feed(29, 1);
    try std.testing.expectEqual(@as(u8, menu_focus), d.feed(60, 1));
}

test "tab navigation and close all remain distinct from widget and window traversal" {
    var d: Decoder = .{};
    _ = d.feed(29, 1);
    try std.testing.expectEqual(@as(u8, next_tab), d.feed(15, 1));
    _ = d.feed(42, 1);
    try std.testing.expectEqual(@as(u8, previous_tab), d.feed(15, 1));
    _ = d.feed(29, 0);
    _ = d.feed(125, 1);
    try std.testing.expectEqual(@as(u8, close_all), d.feed(17, 1));
    _ = d.feed(42, 0);
    try std.testing.expectEqual(@as(u8, close_document), d.feed(17, 1));
}

test "application launcher is a seat shortcut and not text" {
    var d: Decoder = .{};
    _ = d.feed(125, 1);
    try std.testing.expectEqual(@as(u8, launcher), d.feed(57, 1));
    try std.testing.expectEqual(@as(u8, 0), d.feed(57, 0));
    var console: ConsoleKeys = .{};
    try std.testing.expectEqual(@as(?u8, null), console.feed(launcher, false));
}
