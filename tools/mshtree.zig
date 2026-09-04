//! The tree-sitter parser for mshl, for the tools built on it (mshfmt,
//! mshlint): the generated parser in tools/tree-sitter-mshl/src and the
//! runtime the host provides, behind a few helpers so a tool reads the
//! tree in Zig terms — node kinds as slices, a node's text, its fields.

const std = @import("std");
pub const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_mshl() callconv(.c) *const c.TSLanguage;

pub const Error = error{ OutOfMemory, ParseError };

pub const Tree = struct {
    parser: *c.TSParser,
    tree: *c.TSTree,

    pub fn parse(src: []const u8) Error!Tree {
        const parser = c.ts_parser_new() orelse return Error.OutOfMemory;
        errdefer c.ts_parser_delete(parser);
        if (!c.ts_parser_set_language(parser, tree_sitter_mshl())) return Error.ParseError;
        const tree = c.ts_parser_parse_string(parser, null, src.ptr, @intCast(src.len)) orelse return Error.OutOfMemory;
        return .{ .parser = parser, .tree = tree };
    }

    pub fn deinit(t: Tree) void {
        c.ts_tree_delete(t.tree);
        c.ts_parser_delete(t.parser);
    }

    pub fn root(t: Tree) c.TSNode {
        return c.ts_tree_root_node(t.tree);
    }
};

/// The node's kind (`record_field`, `variable`, `{` …).
pub fn kind(node: c.TSNode) []const u8 {
    return std.mem.span(c.ts_node_type(node));
}

pub fn is(node: c.TSNode, k: []const u8) bool {
    return std.mem.eql(u8, kind(node), k);
}

pub fn text(src: []const u8, node: c.TSNode) []const u8 {
    return src[c.ts_node_start_byte(node)..c.ts_node_end_byte(node)];
}

pub fn field(node: c.TSNode, name: []const u8) ?c.TSNode {
    const n = c.ts_node_child_by_field_name(node, name.ptr, @intCast(name.len));
    return if (c.ts_node_is_null(n)) null else n;
}

pub fn childCount(node: c.TSNode) u32 {
    return c.ts_node_child_count(node);
}

pub fn child(node: c.TSNode, i: u32) c.TSNode {
    return c.ts_node_child(node, i);
}

pub fn isNamed(node: c.TSNode) bool {
    return c.ts_node_is_named(node);
}

pub fn startByte(node: c.TSNode) u32 {
    return c.ts_node_start_byte(node);
}

pub fn endByte(node: c.TSNode) u32 {
    return c.ts_node_end_byte(node);
}

pub fn startRow(node: c.TSNode) u32 {
    return c.ts_node_start_point(node).row;
}

pub fn endRow(node: c.TSNode) u32 {
    return c.ts_node_end_point(node).row;
}

/// Line and column, 1-based, as editors count.
pub fn lineCol(node: c.TSNode) struct { line: u32, col: u32 } {
    const p = c.ts_node_start_point(node);
    return .{ .line = p.row + 1, .col = p.column + 1 };
}

/// The tree's shape as an S-expression without positions.
pub fn sexp(a: std.mem.Allocator, src: []const u8) Error![]u8 {
    const t = try Tree.parse(src);
    defer t.deinit();
    const s = c.ts_node_string(t.root());
    defer std.c.free(s);
    return a.dupe(u8, std.mem.span(s));
}
