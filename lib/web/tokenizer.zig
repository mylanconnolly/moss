//! The HTML Standard's tokenizer (§13.2.5), state by state: tags with
//! their attributes, comments, doctypes, CDATA, character references
//! (numeric with the windows-1252 replacements, named against the
//! generated table with the legacy no-semicolon forms and the attribute
//! exception), the RCDATA / RAWTEXT / script data / PLAINTEXT states the
//! tree builder switches into. Input is UTF-8 (the decoder before it saw
//! to that); CR and CR LF become LF up front, as the input stream
//! algorithm says. Characters are emitted as runs, not one at a time —
//! the tree builder splits a run where a mode cares — and every token's
//! text lives in the caller's allocator. Parse errors are noted, not
//! reported: the output is what a browser shows.
const std = @import("std");
const entities = @import("entities.zig");

pub const Error = error{OutOfMemory};

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Tag = struct {
    name: []const u8,
    attrs: []const Attr = &.{},
    self_closing: bool = false,
};

pub const Doctype = struct {
    name: ?[]const u8 = null,
    public_id: ?[]const u8 = null,
    system_id: ?[]const u8 = null,
    force_quirks: bool = false,
};

pub const Token = union(enum) {
    doctype: Doctype,
    start_tag: Tag,
    end_tag: Tag,
    comment: []const u8,
    /// A run of characters; the tree builder looks inside.
    chars: []const u8,
    eof,
};

pub const State = enum {
    data,
    rcdata,
    rawtext,
    script_data,
    plaintext,
    tag_open,
    end_tag_open,
    tag_name,
    rcdata_lt,
    rcdata_end_tag_open,
    rcdata_end_tag_name,
    rawtext_lt,
    rawtext_end_tag_open,
    rawtext_end_tag_name,
    script_data_lt,
    script_data_end_tag_open,
    script_data_end_tag_name,
    script_data_escape_start,
    script_data_escape_start_dash,
    script_data_escaped,
    script_data_escaped_dash,
    script_data_escaped_dash_dash,
    script_data_escaped_lt,
    script_data_escaped_end_tag_open,
    script_data_escaped_end_tag_name,
    script_data_double_escape_start,
    script_data_double_escaped,
    script_data_double_escaped_dash,
    script_data_double_escaped_dash_dash,
    script_data_double_escaped_lt,
    script_data_double_escape_end,
    before_attr_name,
    attr_name,
    after_attr_name,
    before_attr_value,
    attr_value_dq,
    attr_value_sq,
    attr_value_unq,
    after_attr_value_q,
    self_closing_start_tag,
    bogus_comment,
    markup_decl_open,
    comment_start,
    comment_start_dash,
    comment,
    comment_lt,
    comment_lt_bang,
    comment_lt_bang_dash,
    comment_lt_bang_dash_dash,
    comment_end_dash,
    comment_end,
    comment_end_bang,
    doctype,
    before_doctype_name,
    doctype_name,
    after_doctype_name,
    after_doctype_public_kw,
    before_doctype_public_id,
    doctype_public_id_dq,
    doctype_public_id_sq,
    after_doctype_public_id,
    between_doctype_ids,
    after_doctype_system_kw,
    before_doctype_system_id,
    doctype_system_id_dq,
    doctype_system_id_sq,
    after_doctype_system_id,
    bogus_doctype,
    cdata_section,
    cdata_section_bracket,
    cdata_section_end,
    /// The character reference states, run to completion in one step.
    char_ref,
};

const eof: ?u8 = null;
const replacement = "\u{fffd}";

pub const Tokenizer = struct {
    a: std.mem.Allocator,
    input: []const u8,
    pos: usize = 0,
    state: State = .data,
    return_state: State = .data,
    /// The tree builder says whether `<![CDATA[` is a section (the
    /// adjusted current node is foreign) or a bogus comment.
    allow_cdata: bool = false,
    last_start_tag: []const u8 = "",
    /// Characters waiting to go out as one run.
    pending: std.ArrayList(u8) = .empty,
    /// The token under construction.
    tag_name: std.ArrayList(u8) = .empty,
    tag_is_end: bool = false,
    tag_self_closing: bool = false,
    attrs: std.ArrayList(Attr) = .empty,
    attr_name: std.ArrayList(u8) = .empty,
    attr_value: std.ArrayList(u8) = .empty,
    attr_dup: bool = false,
    comment: std.ArrayList(u8) = .empty,
    doctype: Doctype = .{},
    doctype_name: std.ArrayList(u8) = .empty,
    doctype_public: std.ArrayList(u8) = .empty,
    doctype_system: std.ArrayList(u8) = .empty,
    temp: std.ArrayList(u8) = .empty,
    char_ref_code: u32 = 0,
    /// Tokens ready to go out before the next state runs: a run of
    /// characters flushed ahead of a tag, and the EOF behind a comment
    /// or doctype the end of input finished.
    queue: [2]?Token = .{ null, null },
    done: bool = false,

    pub fn init(a: std.mem.Allocator, input: []const u8) Error!Tokenizer {
        // The input stream: CR LF and lone CR become LF.
        var norm: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < input.len) : (i += 1) {
            if (input[i] == '\r') {
                try norm.append(a, '\n');
                if (i + 1 < input.len and input[i + 1] == '\n') i += 1;
            } else try norm.append(a, input[i]);
        }
        return .{ .a = a, .input = norm.items };
    }

    fn peek(t: *const Tokenizer) ?u8 {
        return if (t.pos < t.input.len) t.input[t.pos] else null;
    }

    fn consume(t: *Tokenizer) ?u8 {
        if (t.pos >= t.input.len) {
            t.pos += 1; // EOF consumed; a reconsume steps back over it
            return null;
        }
        const c = t.input[t.pos];
        t.pos += 1;
        return c;
    }

    fn reconsume(t: *Tokenizer, s: State) void {
        t.pos -= 1;
        t.state = s;
    }

    fn startsWithIgnoreCase(t: *const Tokenizer, s: []const u8) bool {
        return t.pos + s.len <= t.input.len and std.ascii.eqlIgnoreCase(t.input[t.pos .. t.pos + s.len], s);
    }

    fn startsWith(t: *const Tokenizer, s: []const u8) bool {
        return t.pos + s.len <= t.input.len and std.mem.eql(u8, t.input[t.pos .. t.pos + s.len], s);
    }

    fn push(t: *Tokenizer, c: u8) Error!void {
        try t.pending.append(t.a, c);
    }

    fn pushSlice(t: *Tokenizer, s: []const u8) Error!void {
        try t.pending.appendSlice(t.a, s);
    }

    /// Hand back a finished non-character token, letting any pending
    /// characters out first.
    fn emit(t: *Tokenizer, tok: Token) Error!Token {
        if (t.pending.items.len == 0) return tok;
        t.enqueue(tok);
        return t.flushChars();
    }

    fn enqueue(t: *Tokenizer, tok: Token) void {
        if (t.queue[0] == null) t.queue[0] = tok else t.queue[1] = tok;
    }

    fn flushChars(t: *Tokenizer) Error!Token {
        const run = try t.a.dupe(u8, t.pending.items);
        t.pending.clearRetainingCapacity();
        return .{ .chars = run };
    }

    fn newTag(t: *Tokenizer, is_end: bool) void {
        t.tag_name.clearRetainingCapacity();
        t.tag_is_end = is_end;
        t.tag_self_closing = false;
        t.attrs = .empty;
        t.attr_name.clearRetainingCapacity();
        t.attr_value.clearRetainingCapacity();
        t.attr_dup = false;
    }

    fn startAttr(t: *Tokenizer) Error!void {
        try t.finishAttr();
        t.attr_name.clearRetainingCapacity();
        t.attr_value.clearRetainingCapacity();
        t.attr_dup = false;
    }

    /// The attribute under construction joins the tag unless its name
    /// repeats one already there (the first wins; the later one is
    /// consumed and dropped).
    fn finishAttr(t: *Tokenizer) Error!void {
        if (t.attr_name.items.len == 0) return;
        if (!t.attr_dup) try t.attrs.append(t.a, .{ .name = try t.a.dupe(u8, t.attr_name.items), .value = try t.a.dupe(u8, t.attr_value.items) });
        t.attr_name.clearRetainingCapacity();
        t.attr_value.clearRetainingCapacity();
        t.attr_dup = false;
    }

    fn markAttrNameDone(t: *Tokenizer) void {
        for (t.attrs.items) |at| if (std.mem.eql(u8, at.name, t.attr_name.items)) {
            t.attr_dup = true;
        };
    }

    fn emitTag(t: *Tokenizer) Error!Token {
        try t.finishAttr();
        const name = try t.a.dupe(u8, t.tag_name.items);
        if (t.tag_is_end) return t.emit(.{ .end_tag = .{ .name = name } });
        t.last_start_tag = name;
        return t.emit(.{ .start_tag = .{ .name = name, .attrs = t.attrs.items, .self_closing = t.tag_self_closing } });
    }

    fn emitComment(t: *Tokenizer) Error!Token {
        return t.emit(.{ .comment = try t.a.dupe(u8, t.comment.items) });
    }

    fn emitDoctype(t: *Tokenizer) Error!Token {
        var d = t.doctype;
        if (d.name != null) d.name = try t.a.dupe(u8, t.doctype_name.items);
        if (d.public_id != null) d.public_id = try t.a.dupe(u8, t.doctype_public.items);
        if (d.system_id != null) d.system_id = try t.a.dupe(u8, t.doctype_system.items);
        return t.emit(.{ .doctype = d });
    }

    fn emitEof(t: *Tokenizer) Error!Token {
        t.done = true;
        return t.emit(.eof);
    }

    fn isAppropriateEndTag(t: *const Tokenizer) bool {
        return t.tag_is_end and std.mem.eql(u8, t.tag_name.items, t.last_start_tag);
    }

    fn isSpace(c: u8) bool {
        return c == '\t' or c == '\n' or c == 0x0c or c == ' ';
    }

    /// Run the machine until a token is ready.
    pub fn next(t: *Tokenizer) Error!Token {
        if (t.queue[0]) |q| {
            t.queue[0] = t.queue[1];
            t.queue[1] = null;
            return q;
        }
        if (t.done) return .eof;
        while (true) {
            if (try t.step()) |tok| return tok;
        }
    }

    fn step(t: *Tokenizer) Error!?Token {
        switch (t.state) {
            .data => {
                const c = t.consume();
                if (c == '&') {
                    t.return_state = .data;
                    t.state = .char_ref;
                } else if (c == '<') {
                    t.state = .tag_open;
                } else if (c == null) {
                    return try t.emitEof();
                } else try t.push(c.?);
            },
            .rcdata => {
                const c = t.consume();
                if (c == '&') {
                    t.return_state = .rcdata;
                    t.state = .char_ref;
                } else if (c == '<') {
                    t.state = .rcdata_lt;
                } else if (c == 0) {
                    try t.pushSlice(replacement);
                } else if (c == null) {
                    return try t.emitEof();
                } else try t.push(c.?);
            },
            .rawtext => {
                const c = t.consume();
                if (c == '<') {
                    t.state = .rawtext_lt;
                } else if (c == 0) {
                    try t.pushSlice(replacement);
                } else if (c == null) {
                    return try t.emitEof();
                } else try t.push(c.?);
            },
            .script_data => {
                const c = t.consume();
                if (c == '<') {
                    t.state = .script_data_lt;
                } else if (c == 0) {
                    try t.pushSlice(replacement);
                } else if (c == null) {
                    return try t.emitEof();
                } else try t.push(c.?);
            },
            .plaintext => {
                const c = t.consume();
                if (c == 0) {
                    try t.pushSlice(replacement);
                } else if (c == null) {
                    return try t.emitEof();
                } else try t.push(c.?);
            },
            .tag_open => {
                const c = t.consume();
                if (c == '!') {
                    t.state = .markup_decl_open;
                } else if (c == '/') {
                    t.state = .end_tag_open;
                } else if (c != null and std.ascii.isAlphabetic(c.?)) {
                    t.newTag(false);
                    t.reconsume(.tag_name);
                } else if (c == '?') {
                    t.comment.clearRetainingCapacity();
                    t.reconsume(.bogus_comment);
                } else if (c == null) {
                    try t.push('<');
                    return try t.emitEof();
                } else {
                    try t.push('<');
                    t.reconsume(.data);
                }
            },
            .end_tag_open => {
                const c = t.consume();
                if (c != null and std.ascii.isAlphabetic(c.?)) {
                    t.newTag(true);
                    t.reconsume(.tag_name);
                } else if (c == '>') {
                    t.state = .data;
                } else if (c == null) {
                    try t.pushSlice("</");
                    return try t.emitEof();
                } else {
                    t.comment.clearRetainingCapacity();
                    t.reconsume(.bogus_comment);
                }
            },
            .tag_name => {
                const c = t.consume();
                if (c != null and isSpace(c.?)) {
                    t.state = .before_attr_name;
                } else if (c == '/') {
                    t.state = .self_closing_start_tag;
                } else if (c == '>') {
                    t.state = .data;
                    return try t.emitTag();
                } else if (c == 0) {
                    try t.tag_name.appendSlice(t.a, replacement);
                } else if (c == null) {
                    return try t.emitEof();
                } else try t.tag_name.append(t.a, std.ascii.toLower(c.?));
            },
            .rcdata_lt, .rawtext_lt, .script_data_lt => {
                const c = t.consume();
                const base: State = switch (t.state) {
                    .rcdata_lt => .rcdata,
                    .rawtext_lt => .rawtext,
                    else => .script_data,
                };
                if (c == '/') {
                    t.temp.clearRetainingCapacity();
                    t.state = switch (base) {
                        .rcdata => .rcdata_end_tag_open,
                        .rawtext => .rawtext_end_tag_open,
                        else => .script_data_end_tag_open,
                    };
                } else if (base == .script_data and c == '!') {
                    t.state = .script_data_escape_start;
                    try t.pushSlice("<!");
                } else {
                    try t.push('<');
                    t.reconsume(base);
                }
            },
            .rcdata_end_tag_open, .rawtext_end_tag_open, .script_data_end_tag_open, .script_data_escaped_end_tag_open => {
                const c = t.consume();
                if (c != null and std.ascii.isAlphabetic(c.?)) {
                    t.newTag(true);
                    t.reconsume(switch (t.state) {
                        .rcdata_end_tag_open => .rcdata_end_tag_name,
                        .rawtext_end_tag_open => .rawtext_end_tag_name,
                        .script_data_end_tag_open => .script_data_end_tag_name,
                        else => .script_data_escaped_end_tag_name,
                    });
                } else {
                    try t.pushSlice("</");
                    t.reconsume(switch (t.state) {
                        .rcdata_end_tag_open => .rcdata,
                        .rawtext_end_tag_open => .rawtext,
                        .script_data_end_tag_open => .script_data,
                        else => .script_data_escaped,
                    });
                }
            },
            .rcdata_end_tag_name, .rawtext_end_tag_name, .script_data_end_tag_name, .script_data_escaped_end_tag_name => {
                const c = t.consume();
                const base: State = switch (t.state) {
                    .rcdata_end_tag_name => .rcdata,
                    .rawtext_end_tag_name => .rawtext,
                    .script_data_end_tag_name => .script_data,
                    else => .script_data_escaped,
                };
                if (c != null and isSpace(c.?) and t.isAppropriateEndTag()) {
                    t.state = .before_attr_name;
                } else if (c == '/' and t.isAppropriateEndTag()) {
                    t.state = .self_closing_start_tag;
                } else if (c == '>' and t.isAppropriateEndTag()) {
                    t.state = .data;
                    return try t.emitTag();
                } else if (c != null and std.ascii.isAlphabetic(c.?)) {
                    try t.tag_name.append(t.a, std.ascii.toLower(c.?));
                    try t.temp.append(t.a, c.?);
                } else {
                    try t.pushSlice("</");
                    try t.pushSlice(t.temp.items);
                    t.reconsume(base);
                }
            },
            .script_data_escape_start => {
                if (t.consume() == '-') {
                    t.state = .script_data_escape_start_dash;
                    try t.push('-');
                } else t.reconsume(.script_data);
            },
            .script_data_escape_start_dash => {
                if (t.consume() == '-') {
                    t.state = .script_data_escaped_dash_dash;
                    try t.push('-');
                } else t.reconsume(.script_data);
            },
            .script_data_escaped => {
                const c = t.consume();
                if (c == '-') {
                    t.state = .script_data_escaped_dash;
                    try t.push('-');
                } else if (c == '<') {
                    t.state = .script_data_escaped_lt;
                } else if (c == 0) {
                    try t.pushSlice(replacement);
                } else if (c == null) {
                    return try t.emitEof();
                } else try t.push(c.?);
            },
            .script_data_escaped_dash => {
                const c = t.consume();
                if (c == '-') {
                    t.state = .script_data_escaped_dash_dash;
                    try t.push('-');
                } else if (c == '<') {
                    t.state = .script_data_escaped_lt;
                } else if (c == 0) {
                    t.state = .script_data_escaped;
                    try t.pushSlice(replacement);
                } else if (c == null) {
                    return try t.emitEof();
                } else {
                    t.state = .script_data_escaped;
                    try t.push(c.?);
                }
            },
            .script_data_escaped_dash_dash => {
                const c = t.consume();
                if (c == '-') {
                    try t.push('-');
                } else if (c == '<') {
                    t.state = .script_data_escaped_lt;
                } else if (c == '>') {
                    t.state = .script_data;
                    try t.push('>');
                } else if (c == 0) {
                    t.state = .script_data_escaped;
                    try t.pushSlice(replacement);
                } else if (c == null) {
                    return try t.emitEof();
                } else {
                    t.state = .script_data_escaped;
                    try t.push(c.?);
                }
            },
            .script_data_escaped_lt => {
                const c = t.consume();
                if (c == '/') {
                    t.temp.clearRetainingCapacity();
                    t.state = .script_data_escaped_end_tag_open;
                } else if (c != null and std.ascii.isAlphabetic(c.?)) {
                    t.temp.clearRetainingCapacity();
                    try t.push('<');
                    t.reconsume(.script_data_double_escape_start);
                } else {
                    try t.push('<');
                    t.reconsume(.script_data_escaped);
                }
            },
            .script_data_double_escape_start, .script_data_double_escape_end => {
                const c = t.consume();
                const starting = t.state == .script_data_double_escape_start;
                if (c != null and (isSpace(c.?) or c.? == '/' or c.? == '>')) {
                    const is_script = std.mem.eql(u8, t.temp.items, "script");
                    t.state = if (starting) (if (is_script) .script_data_double_escaped else .script_data_escaped) else (if (is_script) .script_data_escaped else .script_data_double_escaped);
                    try t.push(c.?);
                } else if (c != null and std.ascii.isAlphabetic(c.?)) {
                    try t.temp.append(t.a, std.ascii.toLower(c.?));
                    try t.push(c.?);
                } else t.reconsume(if (starting) .script_data_escaped else .script_data_double_escaped);
            },
            .script_data_double_escaped => {
                const c = t.consume();
                if (c == '-') {
                    t.state = .script_data_double_escaped_dash;
                    try t.push('-');
                } else if (c == '<') {
                    t.state = .script_data_double_escaped_lt;
                    try t.push('<');
                } else if (c == 0) {
                    try t.pushSlice(replacement);
                } else if (c == null) {
                    return try t.emitEof();
                } else try t.push(c.?);
            },
            .script_data_double_escaped_dash => {
                const c = t.consume();
                if (c == '-') {
                    t.state = .script_data_double_escaped_dash_dash;
                    try t.push('-');
                } else if (c == '<') {
                    t.state = .script_data_double_escaped_lt;
                    try t.push('<');
                } else if (c == 0) {
                    t.state = .script_data_double_escaped;
                    try t.pushSlice(replacement);
                } else if (c == null) {
                    return try t.emitEof();
                } else {
                    t.state = .script_data_double_escaped;
                    try t.push(c.?);
                }
            },
            .script_data_double_escaped_dash_dash => {
                const c = t.consume();
                if (c == '-') {
                    try t.push('-');
                } else if (c == '<') {
                    t.state = .script_data_double_escaped_lt;
                    try t.push('<');
                } else if (c == '>') {
                    t.state = .script_data;
                    try t.push('>');
                } else if (c == 0) {
                    t.state = .script_data_double_escaped;
                    try t.pushSlice(replacement);
                } else if (c == null) {
                    return try t.emitEof();
                } else {
                    t.state = .script_data_double_escaped;
                    try t.push(c.?);
                }
            },
            .script_data_double_escaped_lt => {
                if (t.consume() == '/') {
                    t.temp.clearRetainingCapacity();
                    t.state = .script_data_double_escape_end;
                    try t.push('/');
                } else t.reconsume(.script_data_double_escaped);
            },
            .before_attr_name => {
                const c = t.consume();
                if (c != null and isSpace(c.?)) {
                    // ignore
                } else if (c == '/' or c == '>' or c == null) {
                    t.reconsume(.after_attr_name);
                } else if (c == '=') {
                    try t.startAttr();
                    try t.attr_name.append(t.a, '=');
                    t.state = .attr_name;
                } else {
                    try t.startAttr();
                    t.reconsume(.attr_name);
                }
            },
            .attr_name => {
                const c = t.consume();
                if (c == null or isSpace(c.?) or c.? == '/' or c.? == '>') {
                    t.markAttrNameDone();
                    t.reconsume(.after_attr_name);
                } else if (c == '=') {
                    t.markAttrNameDone();
                    t.state = .before_attr_value;
                } else if (c == 0) {
                    try t.attr_name.appendSlice(t.a, replacement);
                } else try t.attr_name.append(t.a, std.ascii.toLower(c.?));
            },
            .after_attr_name => {
                const c = t.consume();
                if (c != null and isSpace(c.?)) {
                    // ignore
                } else if (c == '/') {
                    t.state = .self_closing_start_tag;
                } else if (c == '=') {
                    t.state = .before_attr_value;
                } else if (c == '>') {
                    t.state = .data;
                    return try t.emitTag();
                } else if (c == null) {
                    return try t.emitEof();
                } else {
                    try t.startAttr();
                    t.reconsume(.attr_name);
                }
            },
            .before_attr_value => {
                const c = t.consume();
                if (c != null and isSpace(c.?)) {
                    // ignore
                } else if (c == '"') {
                    t.state = .attr_value_dq;
                } else if (c == '\'') {
                    t.state = .attr_value_sq;
                } else if (c == '>') {
                    t.state = .data;
                    return try t.emitTag();
                } else t.reconsume(.attr_value_unq);
            },
            .attr_value_dq, .attr_value_sq => {
                const c = t.consume();
                const quote: u8 = if (t.state == .attr_value_dq) '"' else '\'';
                if (c == quote) {
                    t.state = .after_attr_value_q;
                } else if (c == '&') {
                    t.return_state = t.state;
                    t.state = .char_ref;
                } else if (c == 0) {
                    try t.attr_value.appendSlice(t.a, replacement);
                } else if (c == null) {
                    return try t.emitEof();
                } else try t.attr_value.append(t.a, c.?);
            },
            .attr_value_unq => {
                const c = t.consume();
                if (c != null and isSpace(c.?)) {
                    t.state = .before_attr_name;
                } else if (c == '&') {
                    t.return_state = .attr_value_unq;
                    t.state = .char_ref;
                } else if (c == '>') {
                    t.state = .data;
                    return try t.emitTag();
                } else if (c == 0) {
                    try t.attr_value.appendSlice(t.a, replacement);
                } else if (c == null) {
                    return try t.emitEof();
                } else try t.attr_value.append(t.a, c.?);
            },
            .after_attr_value_q => {
                const c = t.consume();
                if (c != null and isSpace(c.?)) {
                    t.state = .before_attr_name;
                } else if (c == '/') {
                    t.state = .self_closing_start_tag;
                } else if (c == '>') {
                    t.state = .data;
                    return try t.emitTag();
                } else if (c == null) {
                    return try t.emitEof();
                } else t.reconsume(.before_attr_name);
            },
            .self_closing_start_tag => {
                const c = t.consume();
                if (c == '>') {
                    t.tag_self_closing = true;
                    t.state = .data;
                    return try t.emitTag();
                } else if (c == null) {
                    return try t.emitEof();
                } else t.reconsume(.before_attr_name);
            },
            .bogus_comment => {
                const c = t.consume();
                if (c == '>') {
                    t.state = .data;
                    return try t.emitComment();
                } else if (c == null) {
                    return try t.commentThenEof();
                } else if (c == 0) {
                    try t.comment.appendSlice(t.a, replacement);
                } else try t.comment.append(t.a, c.?);
            },
            .markup_decl_open => {
                if (t.startsWith("--")) {
                    t.pos += 2;
                    t.comment.clearRetainingCapacity();
                    t.state = .comment_start;
                } else if (t.startsWithIgnoreCase("DOCTYPE")) {
                    t.pos += 7;
                    t.state = .doctype;
                } else if (t.startsWith("[CDATA[")) {
                    t.pos += 7;
                    if (t.allow_cdata) {
                        t.state = .cdata_section;
                    } else {
                        t.comment.clearRetainingCapacity();
                        try t.comment.appendSlice(t.a, "[CDATA[");
                        t.state = .bogus_comment;
                    }
                } else {
                    t.comment.clearRetainingCapacity();
                    t.state = .bogus_comment;
                }
            },
            .comment_start => {
                const c = t.consume();
                if (c == '-') {
                    t.state = .comment_start_dash;
                } else if (c == '>') {
                    t.state = .data;
                    return try t.emitComment();
                } else t.reconsume(.comment);
            },
            .comment_start_dash => {
                const c = t.consume();
                if (c == '-') {
                    t.state = .comment_end;
                } else if (c == '>') {
                    t.state = .data;
                    return try t.emitComment();
                } else if (c == null) {
                    return try t.commentThenEof();
                } else {
                    try t.comment.append(t.a, '-');
                    t.reconsume(.comment);
                }
            },
            .comment => {
                const c = t.consume();
                if (c == '<') {
                    try t.comment.append(t.a, '<');
                    t.state = .comment_lt;
                } else if (c == '-') {
                    t.state = .comment_end_dash;
                } else if (c == 0) {
                    try t.comment.appendSlice(t.a, replacement);
                } else if (c == null) {
                    return try t.commentThenEof();
                } else try t.comment.append(t.a, c.?);
            },
            .comment_lt => {
                const c = t.consume();
                if (c == '!') {
                    try t.comment.append(t.a, '!');
                    t.state = .comment_lt_bang;
                } else if (c == '<') {
                    try t.comment.append(t.a, '<');
                } else t.reconsume(.comment);
            },
            .comment_lt_bang => {
                if (t.consume() == '-') t.state = .comment_lt_bang_dash else t.reconsume(.comment);
            },
            .comment_lt_bang_dash => {
                if (t.consume() == '-') t.state = .comment_lt_bang_dash_dash else t.reconsume(.comment_end_dash);
            },
            .comment_lt_bang_dash_dash => {
                const c = t.consume();
                if (c == '>' or c == null) t.reconsume(.comment_end) else t.reconsume(.comment_end);
            },
            .comment_end_dash => {
                const c = t.consume();
                if (c == '-') {
                    t.state = .comment_end;
                } else if (c == null) {
                    return try t.commentThenEof();
                } else {
                    try t.comment.append(t.a, '-');
                    t.reconsume(.comment);
                }
            },
            .comment_end => {
                const c = t.consume();
                if (c == '>') {
                    t.state = .data;
                    return try t.emitComment();
                } else if (c == '!') {
                    t.state = .comment_end_bang;
                } else if (c == '-') {
                    try t.comment.append(t.a, '-');
                } else if (c == null) {
                    return try t.commentThenEof();
                } else {
                    try t.comment.appendSlice(t.a, "--");
                    t.reconsume(.comment);
                }
            },
            .comment_end_bang => {
                const c = t.consume();
                if (c == '-') {
                    try t.comment.appendSlice(t.a, "--!");
                    t.state = .comment_end_dash;
                } else if (c == '>') {
                    t.state = .data;
                    return try t.emitComment();
                } else if (c == null) {
                    return try t.commentThenEof();
                } else {
                    try t.comment.appendSlice(t.a, "--!");
                    t.reconsume(.comment);
                }
            },
            .doctype => {
                const c = t.consume();
                if (c != null and isSpace(c.?)) {
                    t.state = .before_doctype_name;
                } else if (c == '>') {
                    t.reconsume(.before_doctype_name);
                } else if (c == null) {
                    t.doctype = .{ .force_quirks = true };
                    return try t.doctypeThenEof();
                } else t.reconsume(.before_doctype_name);
            },
            .before_doctype_name => {
                const c = t.consume();
                if (c != null and isSpace(c.?)) {
                    // ignore
                } else if (c == 0) {
                    t.doctype = .{ .name = "" };
                    t.doctype_name.clearRetainingCapacity();
                    try t.doctype_name.appendSlice(t.a, replacement);
                    t.state = .doctype_name;
                } else if (c == '>') {
                    t.doctype = .{ .force_quirks = true };
                    t.state = .data;
                    return try t.emitDoctype();
                } else if (c == null) {
                    t.doctype = .{ .force_quirks = true };
                    return try t.doctypeThenEof();
                } else {
                    t.doctype = .{ .name = "" };
                    t.doctype_name.clearRetainingCapacity();
                    try t.doctype_name.append(t.a, std.ascii.toLower(c.?));
                    t.state = .doctype_name;
                }
            },
            .doctype_name => {
                const c = t.consume();
                if (c != null and isSpace(c.?)) {
                    t.state = .after_doctype_name;
                } else if (c == '>') {
                    t.state = .data;
                    return try t.emitDoctype();
                } else if (c == 0) {
                    try t.doctype_name.appendSlice(t.a, replacement);
                } else if (c == null) {
                    t.doctype.force_quirks = true;
                    return try t.doctypeThenEof();
                } else try t.doctype_name.append(t.a, std.ascii.toLower(c.?));
            },
            .after_doctype_name => {
                const c = t.consume();
                if (c != null and isSpace(c.?)) {
                    // ignore
                } else if (c == '>') {
                    t.state = .data;
                    return try t.emitDoctype();
                } else if (c == null) {
                    t.doctype.force_quirks = true;
                    return try t.doctypeThenEof();
                } else {
                    t.pos -= 1;
                    if (t.startsWithIgnoreCase("PUBLIC")) {
                        t.pos += 6;
                        t.state = .after_doctype_public_kw;
                    } else if (t.startsWithIgnoreCase("SYSTEM")) {
                        t.pos += 6;
                        t.state = .after_doctype_system_kw;
                    } else {
                        t.pos += 1;
                        t.doctype.force_quirks = true;
                        t.reconsume(.bogus_doctype);
                    }
                }
            },
            .after_doctype_public_kw, .before_doctype_public_id => {
                const c = t.consume();
                if (c != null and isSpace(c.?)) {
                    if (t.state == .after_doctype_public_kw) t.state = .before_doctype_public_id;
                } else if (c == '"' or c == '\'') {
                    t.doctype.public_id = "";
                    t.doctype_public.clearRetainingCapacity();
                    t.state = if (c == '"') .doctype_public_id_dq else .doctype_public_id_sq;
                } else if (c == '>') {
                    t.doctype.force_quirks = true;
                    t.state = .data;
                    return try t.emitDoctype();
                } else if (c == null) {
                    t.doctype.force_quirks = true;
                    return try t.doctypeThenEof();
                } else {
                    t.doctype.force_quirks = true;
                    t.reconsume(.bogus_doctype);
                }
            },
            .doctype_public_id_dq, .doctype_public_id_sq => {
                const c = t.consume();
                const quote: u8 = if (t.state == .doctype_public_id_dq) '"' else '\'';
                if (c == quote) {
                    t.state = .after_doctype_public_id;
                } else if (c == 0) {
                    try t.doctype_public.appendSlice(t.a, replacement);
                } else if (c == '>') {
                    t.doctype.force_quirks = true;
                    t.state = .data;
                    return try t.emitDoctype();
                } else if (c == null) {
                    t.doctype.force_quirks = true;
                    return try t.doctypeThenEof();
                } else try t.doctype_public.append(t.a, c.?);
            },
            .after_doctype_public_id, .between_doctype_ids => {
                const c = t.consume();
                if (c != null and isSpace(c.?)) {
                    if (t.state == .after_doctype_public_id) t.state = .between_doctype_ids;
                } else if (c == '>') {
                    t.state = .data;
                    return try t.emitDoctype();
                } else if (c == '"' or c == '\'') {
                    t.doctype.system_id = "";
                    t.doctype_system.clearRetainingCapacity();
                    t.state = if (c == '"') .doctype_system_id_dq else .doctype_system_id_sq;
                } else if (c == null) {
                    t.doctype.force_quirks = true;
                    return try t.doctypeThenEof();
                } else {
                    t.doctype.force_quirks = true;
                    t.reconsume(.bogus_doctype);
                }
            },
            .after_doctype_system_kw, .before_doctype_system_id => {
                const c = t.consume();
                if (c != null and isSpace(c.?)) {
                    if (t.state == .after_doctype_system_kw) t.state = .before_doctype_system_id;
                } else if (c == '"' or c == '\'') {
                    t.doctype.system_id = "";
                    t.doctype_system.clearRetainingCapacity();
                    t.state = if (c == '"') .doctype_system_id_dq else .doctype_system_id_sq;
                } else if (c == '>') {
                    t.doctype.force_quirks = true;
                    t.state = .data;
                    return try t.emitDoctype();
                } else if (c == null) {
                    t.doctype.force_quirks = true;
                    return try t.doctypeThenEof();
                } else {
                    t.doctype.force_quirks = true;
                    t.reconsume(.bogus_doctype);
                }
            },
            .doctype_system_id_dq, .doctype_system_id_sq => {
                const c = t.consume();
                const quote: u8 = if (t.state == .doctype_system_id_dq) '"' else '\'';
                if (c == quote) {
                    t.state = .after_doctype_system_id;
                } else if (c == 0) {
                    try t.doctype_system.appendSlice(t.a, replacement);
                } else if (c == '>') {
                    t.doctype.force_quirks = true;
                    t.state = .data;
                    return try t.emitDoctype();
                } else if (c == null) {
                    t.doctype.force_quirks = true;
                    return try t.doctypeThenEof();
                } else try t.doctype_system.append(t.a, c.?);
            },
            .after_doctype_system_id => {
                const c = t.consume();
                if (c != null and isSpace(c.?)) {
                    // ignore
                } else if (c == '>') {
                    t.state = .data;
                    return try t.emitDoctype();
                } else if (c == null) {
                    t.doctype.force_quirks = true;
                    return try t.doctypeThenEof();
                } else t.reconsume(.bogus_doctype);
            },
            .bogus_doctype => {
                const c = t.consume();
                if (c == '>') {
                    t.state = .data;
                    return try t.emitDoctype();
                } else if (c == null) {
                    return try t.doctypeThenEof();
                }
            },
            .cdata_section => {
                const c = t.consume();
                if (c == ']') {
                    t.state = .cdata_section_bracket;
                } else if (c == null) {
                    return try t.emitEof();
                } else try t.push(c.?);
            },
            .cdata_section_bracket => {
                if (t.consume() == ']') {
                    t.state = .cdata_section_end;
                } else {
                    try t.push(']');
                    t.reconsume(.cdata_section);
                }
            },
            .cdata_section_end => {
                const c = t.consume();
                if (c == ']') {
                    try t.push(']');
                } else if (c == '>') {
                    t.state = .data;
                } else {
                    try t.pushSlice("]]");
                    t.reconsume(.cdata_section);
                }
            },
            .char_ref => try t.charRef(),
        }
        return null;
    }

    fn commentThenEof(t: *Tokenizer) Error!Token {
        const tok = try t.emitComment();
        t.enqueue(.eof);
        t.done = true;
        return tok;
    }

    fn doctypeThenEof(t: *Tokenizer) Error!Token {
        const tok = try t.emitDoctype();
        t.enqueue(.eof);
        t.done = true;
        return tok;
    }

    fn inAttribute(t: *const Tokenizer) bool {
        return t.return_state == .attr_value_dq or t.return_state == .attr_value_sq or t.return_state == .attr_value_unq;
    }

    /// Where a decoded reference (or the literal text) goes: the
    /// attribute value or the character run.
    fn flushRef(t: *Tokenizer, s: []const u8) Error!void {
        if (t.inAttribute()) try t.attr_value.appendSlice(t.a, s) else try t.pushSlice(s);
    }

    fn flushCp(t: *Tokenizer, cp: u21) Error!void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch {
            return t.flushRef(replacement);
        };
        try t.flushRef(buf[0..n]);
    }

    /// The character reference states (§13.2.5.72–80), run to completion
    /// here rather than one step at a time: the whole reference is in
    /// hand, and the tokenizer resumes in its return state.
    fn charRef(t: *Tokenizer) Error!void {
        t.state = t.return_state;
        const c = t.peek();
        if (c != null and (std.ascii.isAlphanumeric(c.?))) return t.namedRef();
        if (c == '#') {
            t.pos += 1;
            return t.numericRef();
        }
        try t.flushRef("&");
    }

    fn namedRef(t: *Tokenizer) Error!void {
        // The longest name in the table that the input continues with.
        const avail = @min(entities.max_name_len, t.input.len - t.pos);
        var len = avail;
        while (len > 0) : (len -= 1) {
            const cand = t.input[t.pos .. t.pos + len];
            // A candidate name is alphanumerics with an optional ';'.
            if (lookup(cand)) |e| {
                const last = cand[cand.len - 1];
                if (last != ';' and t.inAttribute()) {
                    const after: ?u8 = if (t.pos + len < t.input.len) t.input[t.pos + len] else null;
                    if (after != null and (after.? == '=' or std.ascii.isAlphanumeric(after.?))) {
                        // The historical attribute exception: the text is
                        // left as it was.
                        try t.flushRef("&");
                        try t.flushRef(cand);
                        t.pos += len;
                        return;
                    }
                }
                t.pos += len;
                try t.flushCp(e.cps[0]);
                if (e.cps[1] != 0) try t.flushCp(e.cps[1]);
                return;
            }
        }
        // No match: the ambiguous ampersand state — alphanumerics pass
        // through as they are, a ';' among them is an error but stays.
        try t.flushRef("&");
    }

    fn lookup(cand: []const u8) ?entities.Entry {
        var lo: usize = 0;
        var hi: usize = entities.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const e = entities.entries[mid];
            switch (std.mem.order(u8, e.name, cand)) {
                .eq => return e,
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return null;
    }

    fn numericRef(t: *Tokenizer) Error!void {
        var code: u32 = 0;
        var digits: usize = 0;
        const c = t.peek();
        const hex = c == 'x' or c == 'X';
        if (hex) t.pos += 1;
        while (t.peek()) |d| {
            const v: u32 = if (hex) (hexVal(d) orelse break) else (if (std.ascii.isDigit(d)) d - '0' else break);
            code = @min(code * (if (hex) @as(u32, 16) else 10) + v, 0x11_0000);
            digits += 1;
            t.pos += 1;
        }
        if (digits == 0) {
            // "&#" or "&#x" with no digits: the text stays as written.
            try t.flushRef(if (hex) "&#x" else "&#");
            // `&#X` keeps its case.
            if (hex and t.input[t.pos - 1] == 'X') {
                t.attrOrRunFixCase();
            }
            return;
        }
        if (t.peek() == ';') t.pos += 1;
        const cp: u21 = numericFixup(code);
        try t.flushCp(cp);
    }

    fn attrOrRunFixCase(t: *Tokenizer) void {
        // The last three bytes written are "&#x"; make it "&#X".
        if (t.inAttribute()) {
            const v = t.attr_value.items;
            if (v.len >= 1) v[v.len - 1] = 'X';
        } else {
            const v = t.pending.items;
            if (v.len >= 1) v[v.len - 1] = 'X';
        }
    }

    fn hexVal(c: u8) ?u32 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => null,
        };
    }

    /// The numeric character reference end state's table and rules.
    fn numericFixup(code: u32) u21 {
        if (code == 0 or code > 0x10ffff or (code >= 0xd800 and code <= 0xdfff)) return 0xfffd;
        const table = [_]struct { from: u32, to: u21 }{
            .{ .from = 0x80, .to = 0x20ac }, .{ .from = 0x82, .to = 0x201a }, .{ .from = 0x83, .to = 0x0192 }, .{ .from = 0x84, .to = 0x201e },
            .{ .from = 0x85, .to = 0x2026 }, .{ .from = 0x86, .to = 0x2020 }, .{ .from = 0x87, .to = 0x2021 }, .{ .from = 0x88, .to = 0x02c6 },
            .{ .from = 0x89, .to = 0x2030 }, .{ .from = 0x8a, .to = 0x0160 }, .{ .from = 0x8b, .to = 0x2039 }, .{ .from = 0x8c, .to = 0x0152 },
            .{ .from = 0x8e, .to = 0x017d }, .{ .from = 0x91, .to = 0x2018 }, .{ .from = 0x92, .to = 0x2019 }, .{ .from = 0x93, .to = 0x201c },
            .{ .from = 0x94, .to = 0x201d }, .{ .from = 0x95, .to = 0x2022 }, .{ .from = 0x96, .to = 0x2013 }, .{ .from = 0x97, .to = 0x2014 },
            .{ .from = 0x98, .to = 0x02dc }, .{ .from = 0x99, .to = 0x2122 }, .{ .from = 0x9a, .to = 0x0161 }, .{ .from = 0x9b, .to = 0x203a },
            .{ .from = 0x9c, .to = 0x0153 }, .{ .from = 0x9e, .to = 0x017e }, .{ .from = 0x9f, .to = 0x0178 },
        };
        for (table) |e| if (e.from == code) return e.to;
        return @intCast(code);
    }
};

// ------------------------------------------------------------------ tests

test "tokenizer: tags, references, comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t = try Tokenizer.init(a, "<p class=\"x\" id=y>a &amp; b &lt;c&gt; &notin; &#x41;&#65;&copy</p><!-- c -->");
    var tok = try t.next();
    try std.testing.expect(tok == .start_tag);
    try std.testing.expectEqualStrings("p", tok.start_tag.name);
    try std.testing.expectEqual(@as(usize, 2), tok.start_tag.attrs.len);
    try std.testing.expectEqualStrings("y", tok.start_tag.attrs[1].value);
    tok = try t.next();
    try std.testing.expectEqualStrings("a & b <c> \u{2209} AA\u{a9}", tok.chars);
    tok = try t.next();
    try std.testing.expect(tok == .end_tag);
    tok = try t.next();
    try std.testing.expectEqualStrings(" c ", tok.comment);
    try std.testing.expect((try t.next()) == .eof);
}

test "tokenizer: the attribute exception and rcdata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t = try Tokenizer.init(a, "<a href=\"?a=1&copy=2&copy\">");
    const tok = try t.next();
    try std.testing.expectEqualStrings("?a=1&copy=2\u{a9}", tok.start_tag.attrs[0].value);
    var r = try Tokenizer.init(a, "x</b>&amp;</title>y");
    r.state = .rcdata;
    r.last_start_tag = "title";
    const run = try r.next();
    try std.testing.expectEqualStrings("x</b>&", run.chars);
    try std.testing.expectEqualStrings("title", (try r.next()).end_tag.name);
}

// The html5lib tokenizer corpus: every `.test` file's tests, run from
// each initial state, character runs coalesced as the expected output
// is; the count printed.
test "tokenizer: the html5lib corpus, counted" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_][]const u8{ "contentModelFlags", "domjs", "entities", "escapeFlag", "namedEntities", "numericEntities", "pendingSpecChanges", "test1", "test2", "test3", "test4", "unicodeChars", "unicodeCharsProblematic" };
    var total: usize = 0;
    var passed: usize = 0;
    var skipped: usize = 0;
    for (files) |f| {
        const path = try std.fmt.allocPrint(a, "tools/testdata/web/html5lib-tests/tokenizer/{s}.test", .{f});
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(8 << 20)) catch return error.SkipZigTest;
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
        const tests = parsed.object.get("tests") orelse continue;
        for (tests.array.items) |tc| {
            const obj = tc.object;
            const double = if (obj.get("doubleEscaped")) |d| d == .bool and d.bool else false;
            const input = unescapeMaybe(a, obj.get("input").?.string, double) catch {
                skipped += 1;
                continue;
            };
            const want = try expectedTokens(a, obj.get("output").?.array.items, double);
            var states: [6]State = undefined;
            var nstates: usize = 0;
            if (obj.get("initialStates")) |st| {
                for (st.array.items) |sv| {
                    states[nstates] = stateNamed(sv.string) orelse continue;
                    nstates += 1;
                }
            } else {
                states[0] = .data;
                nstates = 1;
            }
            for (states[0..nstates]) |st| {
                total += 1;
                var t = try Tokenizer.init(a, input);
                t.state = st;
                if (obj.get("lastStartTag")) |l| t.last_start_tag = l.string;
                const got = try tokenizeAll(a, &t);
                if (std.mem.eql(u8, got, want)) passed += 1 else if (verbose) std.debug.print("  {s}: {s}\n    got  {s}\n    want {s}\n", .{ f, obj.get("description").?.string, got, want });
            }
        }
    }
    std.debug.print("tokenizer: {d}/{d} of the html5lib corpus agree ({d} skipped: lone surrogates)\n", .{ passed, total, skipped });
    // The floor is the count as of 2026-09-18 (all of them); `verbose`
    // lists any that regress.
    try std.testing.expect(passed >= 7028);
}

const verbose = false;

fn stateNamed(s: []const u8) ?State {
    const eq = std.mem.eql;
    if (eq(u8, s, "Data state")) return .data;
    if (eq(u8, s, "PLAINTEXT state")) return .plaintext;
    if (eq(u8, s, "RCDATA state")) return .rcdata;
    if (eq(u8, s, "RAWTEXT state")) return .rawtext;
    if (eq(u8, s, "Script data state")) return .script_data;
    if (eq(u8, s, "CDATA section state")) return .cdata_section;
    return null;
}

/// A JSON string that was double-escaped (`\\uXXXX` in the file) is
/// unescaped once more; a lone surrogate cannot be UTF-8 and is an
/// error the caller skips.
fn unescapeMaybe(a: std.mem.Allocator, s: []const u8, double: bool) ![]const u8 {
    if (!double) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 5 < s.len + 0 and i + 1 < s.len and s[i + 1] == 'u' and i + 6 <= s.len) {
            var cp: u21 = @intCast(try std.fmt.parseInt(u16, s[i + 2 .. i + 6], 16));
            i += 6;
            if (cp >= 0xd800 and cp < 0xdc00) {
                if (i + 6 <= s.len and s[i] == '\\' and s[i + 1] == 'u') {
                    const low: u21 = @intCast(try std.fmt.parseInt(u16, s[i + 2 .. i + 6], 16));
                    if (low >= 0xdc00 and low < 0xe000) {
                        cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
                        i += 6;
                    } else return error.LoneSurrogate;
                } else return error.LoneSurrogate;
            } else if (cp >= 0xdc00 and cp < 0xe000) return error.LoneSurrogate;
            var buf: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(cp, &buf);
            try out.appendSlice(a, buf[0..n]);
            continue;
        }
        try out.append(a, s[i]);
        i += 1;
    }
    return out.items;
}

/// Tokens as one comparable line: `D(name,pub,sys,ok) S(name;a=v;..;/) E(name) C(data) T(text)`,
/// attributes sorted, adjacent character tokens joined.
fn expectedTokens(a: std.mem.Allocator, items: []const std.json.Value, double: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var text: std.ArrayList(u8) = .empty;
    for (items) |item| {
        const arr = item.array.items;
        const kind = arr[0].string;
        if (std.mem.eql(u8, kind, "Character")) {
            try text.appendSlice(a, unescapeMaybe(a, arr[1].string, double) catch return error.LoneSurrogate);
            continue;
        }
        try flushText(a, &out, &text);
        if (std.mem.eql(u8, kind, "DOCTYPE")) {
            try out.print(a, "D({s},{s},{s},{s}) ", .{ jsonStr(arr[1]), jsonStr(arr[2]), jsonStr(arr[3]), if (arr[4].bool) "ok" else "quirks" });
        } else if (std.mem.eql(u8, kind, "StartTag")) {
            try out.print(a, "S({s}", .{try unescapeMaybe(a, arr[1].string, double)});
            var names: std.ArrayList([]const u8) = .empty;
            var it = arr[2].object.iterator();
            while (it.next()) |e| try names.append(a, e.key_ptr.*);
            std.mem.sort([]const u8, names.items, {}, lessStr);
            for (names.items) |nm| try out.print(a, ";{s}={s}", .{ try unescapeMaybe(a, nm, double), try unescapeMaybe(a, arr[2].object.get(nm).?.string, double) });
            if (arr.len > 3 and arr[3] == .bool and arr[3].bool) try out.appendSlice(a, ";/");
            try out.appendSlice(a, ") ");
        } else if (std.mem.eql(u8, kind, "EndTag")) {
            try out.print(a, "E({s}) ", .{try unescapeMaybe(a, arr[1].string, double)});
        } else if (std.mem.eql(u8, kind, "Comment")) {
            try out.print(a, "C({s}) ", .{try unescapeMaybe(a, arr[1].string, double)});
        }
    }
    try flushText(a, &out, &text);
    return out.items;
}

fn jsonStr(v: std.json.Value) []const u8 {
    return if (v == .string) v.string else "null";
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn flushText(a: std.mem.Allocator, out: *std.ArrayList(u8), text: *std.ArrayList(u8)) !void {
    if (text.items.len == 0) return;
    try out.print(a, "T({s}) ", .{text.items});
    text.clearRetainingCapacity();
}

fn tokenizeAll(a: std.mem.Allocator, t: *Tokenizer) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var text: std.ArrayList(u8) = .empty;
    var guard: usize = 0;
    while (true) : (guard += 1) {
        if (guard > 100_000) return error.Runaway;
        const tok = try t.next();
        switch (tok) {
            .chars => |c| try text.appendSlice(a, c),
            .eof => break,
            else => {
                try flushText(a, &out, &text);
                switch (tok) {
                    .doctype => |d| try out.print(a, "D({s},{s},{s},{s}) ", .{ d.name orelse "null", d.public_id orelse "null", d.system_id orelse "null", if (d.force_quirks) "quirks" else "ok" }),
                    .start_tag => |s| {
                        try out.print(a, "S({s}", .{s.name});
                        const attrs = try a.dupe(Attr, s.attrs);
                        std.mem.sort(Attr, attrs, {}, struct {
                            fn f(_: void, x: Attr, y: Attr) bool {
                                return std.mem.order(u8, x.name, y.name) == .lt;
                            }
                        }.f);
                        for (attrs) |at| try out.print(a, ";{s}={s}", .{ at.name, at.value });
                        if (s.self_closing) try out.appendSlice(a, ";/");
                        try out.appendSlice(a, ") ");
                    },
                    .end_tag => |e| try out.print(a, "E({s}) ", .{e.name}),
                    .comment => |c| try out.print(a, "C({s}) ", .{c}),
                    else => unreachable,
                }
            },
        }
    }
    try flushText(a, &out, &text);
    return out.items;
}
