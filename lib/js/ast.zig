//! The syntax tree the parser builds and the compiler reads: ECMA-262's
//! productions as a tagged union of nodes in the parser's arena. Nodes
//! carry the source position that made them, for error messages and
//! `Function.prototype.toString`. Patterns (binding and assignment
//! targets) are nodes of their own; the parser converts an object or
//! array literal into one when the grammar turns out to want a target
//! (the cover grammars of §13.15.5 and §15.3).
const std = @import("std");

pub const Pos = u32;

pub const Node = struct {
    pos: Pos,
    /// Wrapped in parentheses in the source: `(a) = 1` is fine, `({a}) = 1`
    /// is not, and `(a, b) => c` is only an arrow with the parens.
    parenthesized: bool = false,
    /// An array or object literal whose last element is a spread followed
    /// by a comma: fine as a literal, an error as a pattern.
    comma_after_spread: bool = false,
    data: Data,

    pub const Data = union(enum) {
        // ----------------------------------------------- expressions
        identifier: []const u8,
        private_name: []const u8,
        number: f64,
        bigint: []const u8,
        string: []const u8,
        template: Template,
        tagged_template: struct { tag: *Node, quasi: *Node },
        regexp: struct { pattern: []const u8, flags: []const u8 },
        null_lit,
        bool_lit: bool,
        this,
        super,
        array: []?*Node, // null = hole
        object: []Property,
        function: *Function,
        class: *Class,
        unary: struct { op: UnaryOp, arg: *Node },
        update: struct { increment: bool, prefix: bool, arg: *Node },
        binary: struct { op: BinaryOp, left: *Node, right: *Node },
        logical: struct { op: LogicalOp, left: *Node, right: *Node },
        assign: struct { op: AssignOp, target: *Node, value: *Node },
        conditional: struct { cond: *Node, then: *Node, otherwise: *Node },
        call: struct { callee: *Node, args: []*Node, optional: bool },
        new: struct { callee: *Node, args: []*Node },
        member: struct { object: *Node, property: *Node, computed: bool, optional: bool },
        /// The end of an optional chain (`a?.b.c` is chain(member(member(a,b),c))).
        optional_chain: *Node,
        sequence: []*Node,
        spread: *Node,
        yield: struct { arg: ?*Node, delegate: bool },
        await: *Node,
        new_target,
        import_meta,
        import_call: struct { source: *Node, options: ?*Node },
        // -------------------------------------------------- patterns
        object_pattern: []PatternProperty,
        array_pattern: []?*Node,
        assign_pattern: struct { target: *Node, default: *Node },
        rest: *Node,
        // ------------------------------------------------ statements
        program: Program,
        var_decl: struct { kind: DeclKind, decls: []Declarator },
        function_decl: *Function,
        class_decl: *Class,
        block: []*Node,
        empty,
        expr_stmt: *Node,
        if_stmt: struct { cond: *Node, then: *Node, otherwise: ?*Node },
        for_stmt: struct { init: ?*Node, cond: ?*Node, update: ?*Node, body: *Node },
        for_in: struct { left: *Node, right: *Node, body: *Node },
        for_of: struct { left: *Node, right: *Node, body: *Node, is_await: bool },
        while_stmt: struct { cond: *Node, body: *Node },
        do_while: struct { body: *Node, cond: *Node },
        return_stmt: ?*Node,
        break_stmt: ?[]const u8,
        continue_stmt: ?[]const u8,
        throw_stmt: *Node,
        try_stmt: struct { block: *Node, param: ?*Node, handler: ?*Node, finalizer: ?*Node },
        switch_stmt: struct { discriminant: *Node, cases: []Case },
        labeled: struct { label: []const u8, body: *Node },
        with_stmt: struct { object: *Node, body: *Node },
        debugger,
        import_decl: Import,
        export_decl: Export,
    };
};

pub const Template = struct {
    /// Cooked strings between substitutions; null where an invalid
    /// escape left it undefined (only a tagged template gets that far).
    cooked: []?[]const u8,
    raws: [][]const u8,
    exprs: []*Node,
};

pub const Property = struct {
    kind: enum { init, get, set, spread, shorthand, method },
    key: *Node, // identifier (as string), string, number, computed expr, private_name
    computed: bool = false,
    value: *Node,
    /// `{ a = 1 }`: a CoverInitializedName, legal only once the object
    /// becomes a pattern.
    cover_init: bool = false,
};

pub const PatternProperty = struct {
    key: *Node,
    computed: bool = false,
    value: *Node, // a pattern (or assign_pattern), or rest
    is_rest: bool = false,
};

pub const Declarator = struct { target: *Node, init: ?*Node };
pub const DeclKind = enum { @"var", let, @"const" };

pub const Case = struct { cond: ?*Node, body: []*Node };

pub const UnaryOp = enum { neg, pos, not, bitnot, typeof, void, delete };
pub const BinaryOp = enum { add, sub, mul, div, mod, exp, shl, shr, ushr, lt, gt, le, ge, eq, ne, eq_strict, ne_strict, bitand, bitor, bitxor, in, instanceof };
pub const LogicalOp = enum { @"and", @"or", nullish };
pub const AssignOp = enum { assign, add, sub, mul, div, mod, exp, shl, shr, ushr, bitand, bitor, bitxor, @"and", @"or", nullish };

pub const Function = struct {
    name: ?[]const u8 = null,
    params: []*Node, // patterns; a trailing `rest`
    body: Body,
    kind: Kind = .normal,
    is_async: bool = false,
    is_generator: bool = false,
    is_arrow: bool = false,
    /// A "use strict" directive of its own, or inherited.
    strict: bool = false,
    /// Every parameter a plain identifier: what `arguments` mapping and
    /// duplicate-parameter tolerance depend on.
    simple_params: bool = true,
    /// Source span for `toString`.
    start: Pos = 0,
    end: Pos = 0,
    /// Where the parameter list opens (a method compiled lazily is
    /// parsed again from here; arrows from `start`).
    params_start: Pos = 0,
    pub const Body = union(enum) {
        block: []*Node,
        expr: *Node,
        /// The body was parsed, summarised and dropped (the parser's
        /// preparse): what the analysis needs of it, and no tree. The
        /// function compiles on its first call from its source.
        lazy: Lazy,
    };
    pub const Lazy = struct {
        /// Names the body reaches for that it does not declare itself,
        /// `arguments` among them when an arrow uses it.
        free: []const []const u8,
        uses_this: bool = false,
        uses_new_target: bool = false,
        uses_super: bool = false,
        uses_super_call: bool = false,
        /// Parsed as a declaration (its name is the enclosing scope's).
        is_decl: bool = false,
    };
    pub const Kind = enum { normal, method, getter, setter, constructor, derived_constructor, class_field_init, static_block };
};

pub const Class = struct {
    name: ?[]const u8 = null,
    super_class: ?*Node = null,
    members: []Member,
    start: Pos = 0,
    end: Pos = 0,
    pub const Member = struct {
        kind: enum { method, getter, setter, field, static_block },
        key: *Node, // identifier-as-string, string, number, computed expr, private_name
        computed: bool = false,
        is_static: bool = false,
        value: ?*Node = null, // the function, or a field's initializer (as a function), or a static block's function
    };
};

pub const Program = struct {
    body: []*Node,
    module: bool,
    strict: bool,
};

pub const Import = struct {
    source: []const u8,
    default: ?[]const u8 = null,
    namespace: ?[]const u8 = null,
    named: []Named,
    pub const Named = struct { imported: []const u8, local: []const u8 };
};

pub const Export = union(enum) {
    /// `export var/let/const/function/class ...`
    declaration: *Node,
    /// `export default expr` (an expression, or a function/class node).
    default: *Node,
    /// `export { a as b, c } [from "m"]`
    named: struct { specifiers: []Named, source: ?[]const u8 },
    /// `export * [as ns] from "m"`
    all: struct { as: ?[]const u8, source: []const u8 },
    pub const Named = struct { local: []const u8, exported: []const u8 };
};
