//! The web engine's libraries: pure, freestanding-safe, host-tested
//! against the public conformance corpora under tools/testdata/web/ —
//! the arc's rule that compliance is a number the tests print. `url` is
//! the WHATWG URL Standard's parser and serializer; `encoding` decodes
//! the byte streams the web sends (labels, BOMs, `<meta charset>`) to
//! the UTF-8 the language guarantees.
pub const url = @import("web/url.zig");
pub const encoding = @import("web/encoding.zig");

test {
    _ = url;
    _ = encoding;
}
