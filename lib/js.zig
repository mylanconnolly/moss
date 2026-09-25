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

test {
    _ = lexer;
    _ = parser;
}
