//! The web engine's libraries: pure, freestanding-safe, host-tested
//! against the public conformance corpora under tools/testdata/web/ —
//! the arc's rule that compliance is a number the tests print. `url` is
//! the WHATWG URL Standard's parser and serializer; `encoding` decodes
//! the byte streams the web sends (labels, BOMs, `<meta charset>`) to
//! the UTF-8 the language guarantees; `tokenizer` and `html` are the HTML
//! parser into `dom`; `selectors` matches CSS selectors against it; `text`
//! is the readable text of a page; `css`, `color` and `media` are CSS
//! syntax, colours and media queries, and `style` is the cascade that
//! turns them into every element's computed values.
pub const url = @import("web/url.zig");
pub const encoding = @import("web/encoding.zig");
pub const dom = @import("web/dom.zig");
pub const tokenizer = @import("web/tokenizer.zig");
pub const html = @import("web/html.zig");
pub const selectors = @import("web/selectors.zig");
pub const text = @import("web/text.zig");
pub const css = @import("web/css.zig");
pub const color = @import("web/color.zig");
pub const media = @import("web/media.zig");
pub const style = @import("web/style.zig");

test {
    _ = url;
    _ = encoding;
    _ = dom;
    _ = tokenizer;
    _ = html;
    _ = selectors;
    _ = text;
    _ = css;
    _ = color;
    _ = media;
    _ = style;
}
