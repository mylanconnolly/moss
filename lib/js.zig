//! The JavaScript engine (ECMA-262, ES2023): a library with no authority
//! of its own — it knows no file, channel or DOM — that a host domain
//! embeds: `webpage` with the DOM and the HTML event loop, `jsrun` with
//! the domain's capabilities offered as modules. Freestanding-safe and
//! allocation-explicit like `lib/web`; measured on the host against
//! test262 at a pinned commit (`zig build test262`), whose counts are
//! the compliance claim. No machine code is ever generated: the
//! interpreter is where the speed goes (decision row "JavaScript").
//! `lexer` is the lexical grammar; the parser, compiler and virtual
//! machine follow in the stages the arc lists.
pub const lexer = @import("js/lexer.zig");
pub const ast = @import("js/ast.zig");
pub const parser = @import("js/parser.zig");
pub const value = @import("js/value.zig");
pub const heap = @import("js/heap.zig");
pub const string = @import("js/string.zig");
pub const object = @import("js/object.zig");
pub const bytecode = @import("js/bytecode.zig");
pub const scope = @import("js/scope.zig");
pub const compiler = @import("js/compiler.zig");
pub const vm = @import("js/vm.zig");
pub const interp = @import("js/interp.zig");
pub const realm = @import("js/realm.zig");
pub const builtins = @import("js/builtins.zig");

test {
    _ = lexer;
    _ = parser;
    _ = value;
    _ = heap;
    _ = string;
    _ = object;
    _ = bytecode;
    _ = scope;
    _ = compiler;
    _ = vm;
    _ = interp;
    _ = builtins.number;
}
