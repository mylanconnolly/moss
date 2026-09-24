# The web

## In one breath

A browser is a page's sandbox with a window around it. The engine —
URLs, encodings, HTML, CSS, layout, paint — is a set of pure Zig
libraries under `lib/web/`, host-tested against the public conformance
corpora so that compliance is a number the tests print. Untrusted
content *runs* in exactly one place: a **page domain**, a spawned
`webpage` program whose whole world is one badged channel to the
program that spawned it. That program is its **host and broker**: it
answers the page's requests for its buffers, feeds it the next command,
fetches what the page opens over its own network view and trust roots,
and takes the events the page reports. A page paints into a pixel
buffer its host granted, and the host blits those pixels inside the
page's rectangle and nowhere else, so the address bar above a page is
the window's pixels whatever the page paints.

Three programs are hosts today: the shell's `web-render URL`, which
loads a page headlessly and hands back its document; `webpagecli`, the
drill's native client; and the desktop's **Web** app, an mshl window
whose tabs are page domains.

## How it works

### The libraries

`lib/web.zig` is the module root. `url` is the WHATWG parser and
serializer; `encoding` decodes the byte streams the web sends;
`tokenizer` and `html` are the HTML Standard's parser into `dom`;
`selectors` matches CSS selectors; `text` is the readable text of a
page; `css`, `color` and `media` are CSS syntax, colours and media
queries, `style` the cascade (with a `Loader` for linked sheets and
their imports, a direct parse mode that keeps a sheet at a tenth
of what its parse needs, cascade layers, custom properties and
`var()`, `calc()`, logical properties, masks, HTML's
presentational hints, and the page zoom as `px_scale`, device pixels
per CSS pixel); `fonts` sets text in real faces with fallback across
them and synthesized bold; `layout` places boxes and lines (tables and
flexbox and grid included, quirks mode's line heights too)
(CSS 2.1's visual formatting model, with a `Fonts` vtable for text and an
`Images` provider for pictures), and `paint` draws them into the
toolkit's canvas (backgrounds, gradients and rounded corners
included); `lib/image.zig` decodes PNG, GIF and JPEG (baseline
and progressive) into RGBA and `lib/svg.zig` draws SVG at any scale, tested against a corpus `tools/mkimages.sh`
generates with ImageMagick. The corpora under
`tools/testdata/web/` are vendored at pinned commits; every `zig build
test` prints the counts (see [Testing](testing.md)) and asserts a floor,
and the layout engine's reftests — pairs of pages that must paint the
same pixels, Acid1 among them — must all agree.

In the shell (see [Networking](networking.md)), `fetch` is the HTTP
client, and `html-parse`, `html-select`, `html-text`, `html-style` and
`css-parse` are the libraries as commands; they parse in the caller's
process and execute nothing.

### The page domain and its host

`shared/web.zig` is the seam, and the kernel's IPC decided its shape.
A channel has a serving end and a calling end, a call blocks until the
reply, and a page may hold one capability — so the page holds the
calling end and only calls. It asks for a data buffer (URLs, resource
chunks and document dumps pass through it), a viewport-sized pixel
buffer, and a pack of font files; then it asks for the `next` command,
which the host parks until it has one: load a URL, scroll, the pointer,
a key, a dump, a new viewport, stop. To load, the page `open`s the URL
through the host and `read`s it in chunks; the host — the broker — is
the only thing with a network view. With each thing that happens the
page calls back with an event: `title`, `url`, `load` (loading, done,
failed and why), `commit` (it painted), `hover` (the link under the
pointer), `extent` (how tall the document is), `dumped`.

`user/webpage.zig` is the domain: static arenas that are the page's
whole memory budget (a program's memory here is its image's static
size, charged at spawn) — the document's, 12 MB, holding the bytes,
the tree, its sheets and every later edit until the next navigation,
the layout's, 12 MB, reset whole on every relayout, the picture store
(6 MB of decoded pixels) and a per-picture scratch the file bytes and
the decoder pass through —
`lib/font` over the packed faces with a bounded glyph cache, the parser,
cascade, layout and painter over the granted pixels, a hit test that
walks the DOM up to a link, hover when the link under the pointer
changes, a click on the element the press landed on navigating,
scrolling as a repaint at the new offset. A page that runs out of arena
logs it and exits; its host hears the death as its badge's
`client_dead`. It holds no filesystem, no network, no font service.

`user/webhost.zig` is the host and broker in one module. `spawn` mints
a badge, spawns the page under it and creates its buffers; `step`
receives one message and does what it can itself (an attach, an open, a
read, parking a `next`) and reports an event or a death to the program;
`send` queues a command and answers a parked page at once; `resize`
gives a page a new viewport (none for a hidden one). The broker is
deliberately plain: one connection per open, redirects followed on the
host's side, `http` and `https` only (TLS verified against the host's
trust roots), no content coding requested, a 24 MB cap, a 10 s stall
limit. A host that serves pages from one thread while another commands
them (a window) takes the host's lock around its state.

### The window: Web

The desktop's **Web** app (`boot/scripts/browser.msh`, unit
`boot/conf/sessiongui/browser.msh`) is an ordinary mshl GUI: its state
is its tab list, and every event — a button, the tab strip, a page's
title, URL, load state, hover or death — is a coarse record to
`update`. The one new widget is the runtime's `page` leaf:

```
{ kind: "page", id: "t1", url: "https://…", nav: 0, visible: true, h: 560, grow: true }
```

A `page` leaf is a page domain. The runtime spawns one the first time it
sees the id, navigates it when `url` (or the `nav` nonce) changes,
gives it a pixel buffer the size of the leaf's rect while it is visible
and takes it back when it is not (a hidden tab keeps its document and
holds no pixels), blits its pixels inside the rect on every render,
routes the pointer, wheel and keys inside the rect to the page, and
reaps the domain when the leaf is gone from the tree — lifetime is the
tree's, like a scroll slot, so a closed tab is a dead domain and the
window's exit takes every page with it. What the page reports reaches
`update` as `{ id, kind, text, code }` with `kind` one of `title`,
`url`, `load`, `hover`, `crashed`, `unavailable`. The pages are served
on a thread of their own (the GUI loop blocks on the compositor); while
a page is alive the loop ticks every 40 ms to blit fresh commits and
deliver queued events.

A session app that hosts pages needs a `spawner`, the session's
network view, the assets tier (`{ tag: assets, session: true }`: the
trust roots and the fonts the pages rasterize — a session's own view is
its home, never the disk root) and the system store the `webpage` image
is staged from, and a budget for its pages: 44 MB each. `Web` is 104 MB
for two.

### Using it

The first tab opens blank; a home page is a URL as data in
`state/browser/home.msh` in the home. A real site opens over http or
https — the system's trust roots are the drills' test CA followed by
the Mozilla bundle — through the session's network view, which in the
desktop is the cluster stack with its leased NIC as the way out. A
site's linked stylesheets and their imports are fetched through the
broker and join the cascade, and flexbox lays its rows and columns
out; what a real site still lacks is grid, sticky boxes and tables
beyond block rows, the rest of stage 9.

The chrome's buttons are Phosphor glyphs (hover shows nothing yet; the
labels are the buttons' names for the keyboard and the drills): carets
for back and forward, a refresh arrow, the accent arrow to go, plus and
X for tabs, a bookmark and the bookmarks list with its count, a
magnifier to find, the zoom pair around the percentage, and an info
glyph for the site panel.

Forms work inside the page: the painter draws text and password
fields, check boxes and radios, buttons, selects and text areas
itself; the page keeps a focused element (Tab and Shift-Tab walk links
and controls, Enter and Space activate, Escape hands focus back to the
window's chrome), typing edits a field, and a submit sends the form's
controls form-urlencoded as a GET query or a POST body through the
broker. Find highlights every match of a word and scrolls to one; a
drag selects text and the window's Copy puts it on the session
clipboard; `+` and `-` zoom the text (seeded from the user's font
scale), and the session's dark or high-contrast appearance reaches the
page's media queries. Back and Forward keep a history per tab (every
URL also goes to `state/browser/history.msh`); Bookmark and the
Bookmarks list keep `state/browser/bookmarks.msh`. A download is a
resource the page will not show: it reports it, the app fetches it
over its own network view, and the Save dialog asks where — the same
picker the editor saves through, so a download is a grant the user
makes and, for now, UTF-8 text. The Site panel shows the origin, the
page domain's memory against its budget, and what it holds.

Pictures and web fonts are the page's own work. The cascade collects a
sheet's `@font-face` rules; on load the page fetches each face through
its broker, inflates WOFF or WOFF2 to SFNT and parses it with
`lib/font`, and text whose family list names the face is set in it
(the page logs `web face in use: NAME` the first time one draws). The
`img`s laid out within a screen of the viewport are fetched and
decoded as the page loads and scrolls — at most 64 pictures, 6 MB
decoded, 2 MB a file — and painted at their laid-out size; an image
whose decoded size differs from what the page declared relays out.

Every load is timed in the log: the broker's `webhost: page N: URL:
resolve+connect A ms, handshake B ms, head C ms` and `body K KB in D ms`,
the page's `webpage: loaded in T ms: fetch, parse, sheets, fonts,
style+layout, paint, pictures`, and the resolver's `netsvc: resolved
NAME`. Under emulation a first page is under a second and a cached host
under half; a page with pictures pays a fresh TLS connection per
picture.

Three host commands serve the app: `save-as NAME DATA` (the Save
dialog; answers with the chosen name), `page-info ID` (a page
domain's memory and whether it is alive) and `log TEXT` (a line to the
log from inside `update`, where `echo` waits for the window to close).

### What is not built

Very large pages (30,000 nodes) outgrow the page's 24 MB for a document
and its layout and die; no `position: fixed`/`sticky` beyond relative, no scaling or rotating
transforms (translations only), no merged `border-collapse` borders,
no `overflow` scroll containers, no subgrid or masonry, no WebP,
animated GIF (the first frame shows) or `srcset`; SVG draws its shapes,
paths, strokes and `use`s but not gradients (their mean colour), clips,
masks, filters or text; the scripts that need shaping or bidi (Arabic,
Hebrew, the Indic scripts) show as boxes, and emoji too (Han, kana and
Hangul come from the fallback face); bold is synthesized and there is
no italic; no cache, no cookie jar and no connection pool yet (the
session's `webfetch` unit of the plan); no content coding in the page;
no stop button; a select cycles its options rather than opening a
list; binary downloads wait for a bytes save in the picker; no
JavaScript (stages 10–11: our own engine, off until it lands). Menus
are the generic window menu until client-defined menus exist. The
`page` leaf does not yet follow a window resize with a fresh buffer of
the new size in one step: the leaf's rect changes on the next render
and the page is told, so a maximized window shows the page relaid out
after a tick.

### Looking at a real site

`zig build webshot -- URL OUT.ppm [WIDTH] [HEIGHT] [ZOOM%]` renders a
URL on the host with the page domain's own pipeline and faces, caching
what it fetches under `zig-out/webshot-cache` (delete it to refetch).
`WEBSHOT_DUMP=needle` prints the box subtree of every element whose id
or class holds the needle; `WEBSHOT_FRAG=text` prints the fragments
carrying a string and the lines that reach them; `WEBSHOT_AT=x,y` the
boxes under a point and `WEBSHOT_BOX=n` a box's ancestors;
`WEBSHOT_PAGE=1` runs the sheets, cascade and layout in the page
domain's memory and says what each took. Headless Chrome with
the page's User-Agent (`moss/0.0 (webpage)`) makes the reference.

## Dig deeper

- `ROADMAP.md`, "A web browser": the arc, its locked decisions and
  stages, each with its exit criterion and what it found.
- `DESIGN.md`, "The web": the as-built story of every stage.
- `docs/networking.md`: `fetch`, the HTML and CSS commands, `web-render`.
- `docs/testing.md`: the `web`, `webpage` and `browser` drills.
