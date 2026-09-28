//! Scripts meet the page: the DOM a script sees, over `dom.Document`,
//! for the JavaScript engine in `lib/js`. One comptime interface table
//! (`interfaces`) names every interface, its parent, its methods,
//! attributes and constants; `Page.init` walks it once to build the
//! prototype chain (EventTarget → Node → Element → HTMLElement …) and
//! the constructors on the global, so a binding is one table row and
//! one native. A node's wrapper is an object of class `dom` whose
//! internal slot is the node's index — made on first touch, kept in a
//! table the collector traces, so `a === a.parentNode.firstChild` holds
//! and listeners live on the wrapper. Events dispatch through the DOM
//! Events phases (capture, target, bubble) over the wrappers that exist
//! — a node no script has touched has no listeners. Timers and animation
//! frames queue here and run when the page's loop asks (`runDue`); the
//! engine's own job queue is the microtask queue. The page that embeds
//! this decides what a mutation means (`takeDirty`: lay out again) and
//! where `console` goes (`Host.log`); this file knows no channel.
const std = @import("std");
const js = @import("../js.zig");
const dom = @import("dom.zig");
const html = @import("html.zig");
const selectors = @import("selectors.zig");
const url = @import("url.zig");
const css = @import("css.zig");
const stylelib = @import("style.zig");
const Vm = js.vm.Vm;
const Value = js.value.Value;
const Object = js.object.Object;
const Symbol = js.object.Symbol;
const Key = js.object.Key;
const Error = js.vm.Error;
const NativeFn = js.vm.NativeFn;
const NodeId = dom.NodeId;

pub const Level = enum { log, warn, err };

/// What the embedder provides: where console lines and script errors
/// go, and how an external script's text is fetched (null: `src`
/// scripts are skipped, with a log line).
pub const Host = struct {
    ctx: *anyopaque,
    log: *const fn (ctx: *anyopaque, level: Level, text: []const u8) void,
    fetch: ?*const fn (ctx: *anyopaque, abs_url: []const u8) ?[]const u8 = null,
    /// An element's box in CSS pixels relative to the viewport (x, y, w,
    /// h), laid out fresh if the document changed; null when it has no box.
    rect: ?*const fn (ctx: *anyopaque, id: NodeId) ?[4]f64 = null,
    /// A computed property's value as CSS text, into `buf`; null when the
    /// property is not one the cascade computes.
    computed: ?*const fn (ctx: *anyopaque, id: NodeId, name: []const u8, buf: []u8) ?[]const u8 = null,
    /// Scroll the viewport to a document position (CSS pixels).
    scroll: ?*const fn (ctx: *anyopaque, x: f64, y: f64) void = null,
    /// A script's own request (`fetch`, XMLHttpRequest): the whole
    /// resource through the host's broker into `a`; false when refused,
    /// with `out.refused` saying why. `origin` is the page's for a
    /// cross-origin request (the host does the CORS check), else empty.
    request: ?*const fn (ctx: *anyopaque, a: std.mem.Allocator, abs_url: []const u8, post: bool, body: []const u8, origin: []const u8, out: *Response) bool = null,
    /// `localStorage`, kept by the host per origin under a quota.
    storage: ?*const fn (ctx: *anyopaque, op: StorageOp, key: []const u8, value: []const u8, buf: []u8) StorageResult = null,
    /// The user-agent stylesheet, parsed: what `getComputedStyle` runs
    /// the cascade with for a document that is not the page's (an
    /// iframe's, one a script made), which the page does not lay out.
    ua_sheet: ?*const stylelib.Sheet = null,
    /// An allocator for a native's heavy transient work (a frame's
    /// cascade), used as a stack within one native and freed before it
    /// returns: the page's layout scratch, not the script heap, whose
    /// size classes never give a big block back (2026-09-28: three
    /// hundred frame cascades exhausted a 16 MB heap). Null: `a`.
    scratch: ?*const fn (ctx: *anyopaque) std.mem.Allocator = null,
    /// A script navigates (`location.href = …`, `assign`, `reload`): the
    /// host loads the URL once the script is done.
    navigate: ?*const fn (ctx: *anyopaque, abs_url: []const u8) void = null,
    /// The document's URL (pushState, a hash) or title changed under
    /// script: the host's chrome follows.
    changed: ?*const fn (ctx: *anyopaque, what: Changed, text: []const u8) void = null,
    /// `form.submit()`: the host submits the form as a click would.
    submit: ?*const fn (ctx: *anyopaque, form: NodeId) void = null,
    /// `el.click()` not prevented: the host does what a click does.
    activate: ?*const fn (ctx: *anyopaque, id: NodeId) void = null,
};

pub const Changed = enum { url, title };

pub const StorageOp = enum { get, set, remove, clear, key_at, length };
pub const StorageResult = union(enum) { ok, none, text: []const u8, count: u32, quota };

/// What a request came back with.
pub const Response = struct {
    status: u16 = 0,
    url: []const u8 = "",
    content_type: []const u8 = "",
    body: []const u8 = "",
    refused: []const u8 = "",
};

/// A node wrapper's, token list's or event's internal slot.
const Slot = extern struct {
    kind: u32,
    id: u32,
    flags: u32 = 0,
    /// Which of the page's documents the node is in (0: the page's own).
    doc: u32 = 0,
};
const slot_node: u32 = 0;
const slot_tokens: u32 = 1;
const slot_event: u32 = 2;
/// An element's `style` (flags 0) or its computed style (flags 1).
const slot_style: u32 = 3;
const style_computed: u32 = 1;
/// A Storage: flags 0 = the host's `localStorage`, 1 = `sessionStorage`.
const slot_storage: u32 = 4;
const storage_session: u32 = 1;
/// A CSSStyleSheet over a `<style>` or `<link>` element (`id`).
const slot_sheet: u32 = 5;
/// A NodeIterator or TreeWalker (`id` = its root; the rest in properties).
const slot_traversal: u32 = 6;
/// A Range (`id` unused; the boundary points in properties).
const slot_range: u32 = 7;

// Event flags.
const ev_stop: u32 = 1 << 0;
const ev_stop_immediate: u32 = 1 << 1;
const ev_canceled: u32 = 1 << 2;
const ev_dispatching: u32 = 1 << 3;
const ev_bubbles: u32 = 1 << 4;
const ev_cancelable: u32 = 1 << 5;
const ev_trusted: u32 = 1 << 6;

const Method = struct { name: []const u8, len: u32 = 0, f: NativeFn };
const Attr = struct { name: []const u8, get: NativeFn, set: ?NativeFn = null };
const Const = struct { name: []const u8, value: i32 };
const Iface = struct {
    name: []const u8,
    parent: ?[]const u8 = null,
    /// `new X(...)` is allowed (Event); every other constructor throws.
    constructible: bool = false,
    methods: []const Method = &.{},
    attrs: []const Attr = &.{},
    consts: []const Const = &.{},
};

const node_consts = [_]Const{
    .{ .name = "ELEMENT_NODE", .value = 1 },
    .{ .name = "ATTRIBUTE_NODE", .value = 2 },
    .{ .name = "TEXT_NODE", .value = 3 },
    .{ .name = "CDATA_SECTION_NODE", .value = 4 },
    .{ .name = "PROCESSING_INSTRUCTION_NODE", .value = 7 },
    .{ .name = "COMMENT_NODE", .value = 8 },
    .{ .name = "DOCUMENT_NODE", .value = 9 },
    .{ .name = "DOCUMENT_TYPE_NODE", .value = 10 },
    .{ .name = "DOCUMENT_FRAGMENT_NODE", .value = 11 },
};

/// The query methods any node with children answers.
const parent_methods = [_]Method{
    .{ .name = "querySelector", .len = 1, .f = querySelector },
    .{ .name = "querySelectorAll", .len = 1, .f = querySelectorAll },
    .{ .name = "getElementsByTagName", .len = 1, .f = getElementsByTagName },
    .{ .name = "getElementsByClassName", .len = 1, .f = getElementsByClassName },
    .{ .name = "append", .f = appendNodes },
    .{ .name = "prepend", .f = prependNodes },
    .{ .name = "replaceChildren", .f = replaceChildren },
};
const parent_attrs = [_]Attr{
    .{ .name = "children", .get = getChildren },
    .{ .name = "firstElementChild", .get = getFirstElementChild },
    .{ .name = "lastElementChild", .get = getLastElementChild },
    .{ .name = "childElementCount", .get = getChildElementCount },
};

/// The table. Parents come before their children: the chain is built
/// in one pass.
pub const interfaces = [_]Iface{
    .{ .name = "EventTarget", .constructible = true, .methods = &.{
        .{ .name = "addEventListener", .len = 2, .f = addEventListener },
        .{ .name = "removeEventListener", .len = 2, .f = removeEventListener },
        .{ .name = "dispatchEvent", .len = 1, .f = dispatchEventNative },
    } },
    .{ .name = "Node", .parent = "EventTarget", .consts = &node_consts, .attrs = &.{
        .{ .name = "nodeType", .get = getNodeType },
        .{ .name = "nodeName", .get = getNodeName },
        .{ .name = "nodeValue", .get = getNodeValue, .set = setNodeValue },
        .{ .name = "textContent", .get = getTextContent, .set = setTextContent },
        .{ .name = "parentNode", .get = getParentNode },
        .{ .name = "parentElement", .get = getParentElement },
        .{ .name = "childNodes", .get = getChildNodes },
        .{ .name = "firstChild", .get = getFirstChild },
        .{ .name = "lastChild", .get = getLastChild },
        .{ .name = "previousSibling", .get = getPreviousSibling },
        .{ .name = "nextSibling", .get = getNextSibling },
        .{ .name = "ownerDocument", .get = getOwnerDocument },
        .{ .name = "isConnected", .get = getIsConnected },
        .{ .name = "baseURI", .get = getBaseURI },
    }, .methods = &.{
        .{ .name = "appendChild", .len = 1, .f = appendChild },
        .{ .name = "insertBefore", .len = 2, .f = insertBefore },
        .{ .name = "removeChild", .len = 1, .f = removeChild },
        .{ .name = "replaceChild", .len = 2, .f = replaceChild },
        .{ .name = "cloneNode", .f = cloneNode },
        .{ .name = "contains", .len = 1, .f = containsNode },
        .{ .name = "hasChildNodes", .f = hasChildNodes },
        .{ .name = "compareDocumentPosition", .len = 1, .f = compareDocumentPosition },
        .{ .name = "getRootNode", .f = getRootNode },
        .{ .name = "isSameNode", .len = 1, .f = isSameNode },
        .{ .name = "isEqualNode", .len = 1, .f = isEqualNode },
        .{ .name = "normalize", .f = normalizeNode },
    } },
    .{ .name = "Document", .parent = "Node", .attrs = &parent_attrs ++ [_]Attr{
        .{ .name = "documentElement", .get = getDocumentElement },
        .{ .name = "head", .get = getHead },
        .{ .name = "body", .get = getBody },
        .{ .name = "title", .get = getTitle, .set = setTitle },
        .{ .name = "URL", .get = getDocumentURL },
        .{ .name = "documentURI", .get = getDocumentURL },
        .{ .name = "readyState", .get = getReadyState },
        .{ .name = "defaultView", .get = getDefaultView },
        .{ .name = "characterSet", .get = getCharacterSet },
        .{ .name = "compatMode", .get = getCompatMode },
        .{ .name = "activeElement", .get = getActiveElement },
        .{ .name = "implementation", .get = getImplementation },
        .{ .name = "doctype", .get = getDoctype },
        .{ .name = "location", .get = getLocation },
        .{ .name = "forms", .get = getForms },
        .{ .name = "images", .get = getImages },
        .{ .name = "links", .get = getLinks },
        .{ .name = "scripts", .get = getScripts },
        .{ .name = "styleSheets", .get = getStyleSheets },
    }, .methods = &parent_methods ++ [_]Method{
        .{ .name = "getElementById", .len = 1, .f = getElementById },
        .{ .name = "createElement", .len = 1, .f = createElement },
        .{ .name = "createElementNS", .len = 2, .f = createElementNS },
        .{ .name = "createTextNode", .len = 1, .f = createTextNode },
        .{ .name = "createComment", .len = 1, .f = createComment },
        .{ .name = "createDocumentFragment", .f = createDocumentFragment },
        .{ .name = "createEvent", .len = 1, .f = createEvent },
        .{ .name = "createNodeIterator", .len = 1, .f = createNodeIterator },
        .{ .name = "createTreeWalker", .len = 1, .f = createTreeWalker },
        .{ .name = "createRange", .f = createRange },
        .{ .name = "hasFocus", .f = hasFocus },
        .{ .name = "write", .f = documentWrite },
        .{ .name = "writeln", .f = documentWriteln },
        .{ .name = "open", .f = documentOpen },
        .{ .name = "close", .f = documentClose },
    } },
    .{ .name = "DocumentFragment", .parent = "Node", .attrs = &parent_attrs, .methods = &parent_methods ++ [_]Method{
        .{ .name = "getElementById", .len = 1, .f = getElementById },
    } },
    .{ .name = "DocumentType", .parent = "Node", .attrs = &.{
        .{ .name = "name", .get = getNodeName },
        .{ .name = "publicId", .get = getPublicId },
        .{ .name = "systemId", .get = getSystemId },
    } },
    .{ .name = "CharacterData", .parent = "Node", .attrs = &.{
        .{ .name = "data", .get = getNodeValue, .set = setNodeValue },
        .{ .name = "length", .get = getDataLength },
    }, .methods = &.{
        .{ .name = "remove", .f = removeSelf },
        .{ .name = "before", .f = insertBeforeSelf },
        .{ .name = "after", .f = insertAfterSelf },
        .{ .name = "replaceWith", .f = replaceWith },
        .{ .name = "substringData", .len = 2, .f = cdSubstringData },
        .{ .name = "appendData", .len = 1, .f = cdAppendData },
        .{ .name = "insertData", .len = 2, .f = cdInsertData },
        .{ .name = "deleteData", .len = 2, .f = cdDeleteData },
        .{ .name = "replaceData", .len = 3, .f = cdReplaceData },
    } },
    .{ .name = "Text", .parent = "CharacterData", .attrs = &.{
        .{ .name = "wholeText", .get = getNodeValue },
    }, .methods = &.{
        .{ .name = "splitText", .len = 1, .f = textSplit },
    } },
    .{ .name = "NodeIterator", .attrs = &.{
        .{ .name = "root", .get = travRoot },
        .{ .name = "whatToShow", .get = travWhatToShow },
        .{ .name = "filter", .get = travFilter },
        .{ .name = "referenceNode", .get = iterReferenceNode },
        .{ .name = "pointerBeforeReferenceNode", .get = iterPointerBefore },
    }, .methods = &.{
        .{ .name = "nextNode", .f = iterNextNode },
        .{ .name = "previousNode", .f = iterPreviousNode },
        .{ .name = "detach", .f = noopNative },
    } },
    .{ .name = "TreeWalker", .attrs = &.{
        .{ .name = "root", .get = travRoot },
        .{ .name = "whatToShow", .get = travWhatToShow },
        .{ .name = "filter", .get = travFilter },
        .{ .name = "currentNode", .get = walkerCurrent, .set = walkerSetCurrent },
    }, .methods = &.{
        .{ .name = "parentNode", .f = walkerParentNode },
        .{ .name = "firstChild", .f = walkerFirstChild },
        .{ .name = "lastChild", .f = walkerLastChild },
        .{ .name = "previousSibling", .f = walkerPreviousSibling },
        .{ .name = "nextSibling", .f = walkerNextSibling },
        .{ .name = "previousNode", .f = walkerPreviousNode },
        .{ .name = "nextNode", .f = walkerNextNode },
    } },
    .{ .name = "Range", .constructible = true, .consts = &.{
        .{ .name = "START_TO_START", .value = 0 },
        .{ .name = "START_TO_END", .value = 1 },
        .{ .name = "END_TO_END", .value = 2 },
        .{ .name = "END_TO_START", .value = 3 },
    }, .attrs = &.{
        .{ .name = "startContainer", .get = rangeStartContainer },
        .{ .name = "startOffset", .get = rangeStartOffset },
        .{ .name = "endContainer", .get = rangeEndContainer },
        .{ .name = "endOffset", .get = rangeEndOffset },
        .{ .name = "collapsed", .get = rangeCollapsed },
        .{ .name = "commonAncestorContainer", .get = rangeCommonAncestor },
    }, .methods = &.{
        .{ .name = "setStart", .len = 2, .f = rangeSetStart },
        .{ .name = "setEnd", .len = 2, .f = rangeSetEnd },
        .{ .name = "setStartBefore", .len = 1, .f = rangeSetStartBefore },
        .{ .name = "setStartAfter", .len = 1, .f = rangeSetStartAfter },
        .{ .name = "setEndBefore", .len = 1, .f = rangeSetEndBefore },
        .{ .name = "setEndAfter", .len = 1, .f = rangeSetEndAfter },
        .{ .name = "collapse", .f = rangeCollapse },
        .{ .name = "selectNode", .len = 1, .f = rangeSelectNode },
        .{ .name = "selectNodeContents", .len = 1, .f = rangeSelectNodeContents },
        .{ .name = "compareBoundaryPoints", .len = 2, .f = rangeCompareBoundaryPoints },
        .{ .name = "deleteContents", .f = rangeDeleteContents },
        .{ .name = "extractContents", .f = rangeExtractContents },
        .{ .name = "cloneContents", .f = rangeCloneContents },
        .{ .name = "insertNode", .len = 1, .f = rangeInsertNode },
        .{ .name = "surroundContents", .len = 1, .f = rangeSurroundContents },
        .{ .name = "cloneRange", .f = rangeCloneRange },
        .{ .name = "detach", .f = noopNative },
        .{ .name = "toString", .f = rangeToString },
        .{ .name = "isPointInRange", .len = 2, .f = rangeIsPointInRange },
        .{ .name = "comparePoint", .len = 2, .f = rangeComparePoint },
        .{ .name = "intersectsNode", .len = 1, .f = rangeIntersectsNode },
    } },
    .{ .name = "Comment", .parent = "CharacterData" },
    .{ .name = "Element", .parent = "Node", .attrs = &parent_attrs ++ [_]Attr{
        .{ .name = "tagName", .get = getTagName },
        .{ .name = "localName", .get = getLocalName },
        .{ .name = "prefix", .get = getPrefix },
        .{ .name = "namespaceURI", .get = getNamespaceURI },
        .{ .name = "id", .get = getId, .set = setId },
        .{ .name = "className", .get = getClassName, .set = setClassName },
        .{ .name = "classList", .get = getClassList },
        .{ .name = "innerHTML", .get = getInnerHTML, .set = setInnerHTML },
        .{ .name = "outerHTML", .get = getOuterHTML, .set = setOuterHTML },
        .{ .name = "nextElementSibling", .get = getNextElementSibling },
        .{ .name = "previousElementSibling", .get = getPreviousElementSibling },
        .{ .name = "attributes", .get = getAttributes },
        .{ .name = "style", .get = getStyle },
        .{ .name = "clientWidth", .get = getClientWidth },
        .{ .name = "clientHeight", .get = getClientHeight },
        .{ .name = "clientTop", .get = getZero },
        .{ .name = "clientLeft", .get = getZero },
        .{ .name = "scrollTop", .get = getZero, .set = setIgnored },
        .{ .name = "scrollLeft", .get = getZero, .set = setIgnored },
        .{ .name = "scrollWidth", .get = getClientWidth },
        .{ .name = "scrollHeight", .get = getClientHeight },
    }, .methods = &parent_methods ++ [_]Method{
        .{ .name = "getBoundingClientRect", .f = getBoundingClientRect },
        .{ .name = "getClientRects", .f = getClientRects },
        .{ .name = "scrollIntoView", .f = scrollIntoView },
        .{ .name = "getAttribute", .len = 1, .f = getAttribute },
        .{ .name = "setAttribute", .len = 2, .f = setAttribute },
        .{ .name = "removeAttribute", .len = 1, .f = removeAttribute },
        .{ .name = "hasAttribute", .len = 1, .f = hasAttribute },
        .{ .name = "hasAttributes", .f = hasAttributes },
        .{ .name = "toggleAttribute", .len = 1, .f = toggleAttribute },
        .{ .name = "getAttributeNames", .f = getAttributeNames },
        .{ .name = "matches", .len = 1, .f = matchesSelector },
        .{ .name = "closest", .len = 1, .f = closest },
        .{ .name = "remove", .f = removeSelf },
        .{ .name = "before", .f = insertBeforeSelf },
        .{ .name = "after", .f = insertAfterSelf },
        .{ .name = "replaceWith", .f = replaceWith },
        .{ .name = "insertAdjacentHTML", .len = 2, .f = insertAdjacentHTML },
        .{ .name = "insertAdjacentElement", .len = 2, .f = insertAdjacentElement },
        .{ .name = "insertAdjacentText", .len = 2, .f = insertAdjacentText },
    } },
    .{ .name = "HTMLElement", .parent = "Element", .attrs = &.{
        .{ .name = "innerText", .get = getTextContent, .set = setTextContent },
        .{ .name = "outerText", .get = getTextContent, .set = setTextContent },
        .{ .name = "hidden", .get = getHidden, .set = setHidden },
        .{ .name = "title", .get = getTitleAttr, .set = setTitleAttr },
        .{ .name = "lang", .get = getLang, .set = setLang },
        .{ .name = "dir", .get = getDir, .set = setDir },
        .{ .name = "tabIndex", .get = getTabIndex, .set = setTabIndex },
        .{ .name = "htmlFor", .get = getHtmlFor, .set = setHtmlFor },
        .{ .name = "data", .get = getDataAttr, .set = setDataAttr },
        .{ .name = "src", .get = getSrcAttr, .set = setSrcAttr },
        .{ .name = "alt", .get = getAltAttr, .set = setAltAttr },
        .{ .name = "offsetWidth", .get = getClientWidth },
        .{ .name = "offsetHeight", .get = getClientHeight },
        .{ .name = "offsetTop", .get = getOffsetTop },
        .{ .name = "offsetLeft", .get = getOffsetLeft },
        .{ .name = "offsetParent", .get = getParentElement },
        .{ .name = "contentDocument", .get = getContentDocument },
        .{ .name = "contentWindow", .get = getContentWindow },
    }, .methods = &.{
        .{ .name = "getSVGDocument", .f = getContentDocument },
        .{ .name = "click", .f = clickNative },
        .{ .name = "focus", .f = noopNative },
        .{ .name = "blur", .f = noopNative },
    } },
    .{ .name = "HTMLInputElement", .parent = "HTMLElement", .attrs = &.{
        .{ .name = "value", .get = getValueAttr, .set = setValueAttr },
        .{ .name = "checked", .get = getChecked, .set = setChecked },
        .{ .name = "disabled", .get = getDisabled, .set = setDisabled },
        .{ .name = "type", .get = getTypeAttr, .set = setTypeAttr },
        .{ .name = "name", .get = getNameAttr, .set = setNameAttr },
        .{ .name = "placeholder", .get = getPlaceholder, .set = setPlaceholder },
        .{ .name = "form", .get = getOwnerForm },
        .{ .name = "selectedIndex", .get = getSelectedIndex, .set = setSelectedIndex },
        .{ .name = "options", .get = getOptions },
        .{ .name = "defaultValue", .get = getValueAttrRaw, .set = setValueAttrRaw },
        .{ .name = "defaultChecked", .get = getDefaultChecked, .set = setDefaultChecked },
        .{ .name = "maxLength", .get = getMaxLength, .set = setMaxLength },
    }, .methods = &.{
        .{ .name = "add", .len = 1, .f = selectAdd },
        .{ .name = "remove", .f = selectRemove },
        .{ .name = "select", .f = noopNative },
        .{ .name = "checkValidity", .f = trueNative },
        .{ .name = "reportValidity", .f = trueNative },
    } },
    .{ .name = "HTMLTableElement", .parent = "HTMLElement", .attrs = &.{
        .{ .name = "caption", .get = tableCaption, .set = tableSetCaption },
        .{ .name = "tHead", .get = tableTHead, .set = tableSetTHead },
        .{ .name = "tFoot", .get = tableTFoot, .set = tableSetTFoot },
        .{ .name = "tBodies", .get = tableTBodies },
        .{ .name = "rows", .get = tableRows },
    }, .methods = &.{
        .{ .name = "createCaption", .f = tableCreateCaption },
        .{ .name = "deleteCaption", .f = tableDeleteCaption },
        .{ .name = "createTHead", .f = tableCreateTHead },
        .{ .name = "deleteTHead", .f = tableDeleteTHead },
        .{ .name = "createTFoot", .f = tableCreateTFoot },
        .{ .name = "deleteTFoot", .f = tableDeleteTFoot },
        .{ .name = "createTBody", .f = tableCreateTBody },
        .{ .name = "insertRow", .f = tableInsertRow },
        .{ .name = "deleteRow", .len = 1, .f = tableDeleteRow },
    } },
    .{ .name = "HTMLTableSectionElement", .parent = "HTMLElement", .attrs = &.{
        .{ .name = "rows", .get = sectionRows },
    }, .methods = &.{
        .{ .name = "insertRow", .f = sectionInsertRow },
        .{ .name = "deleteRow", .len = 1, .f = sectionDeleteRow },
    } },
    .{ .name = "HTMLTableRowElement", .parent = "HTMLElement", .attrs = &.{
        .{ .name = "rowIndex", .get = rowIndex },
        .{ .name = "sectionRowIndex", .get = sectionRowIndex },
        .{ .name = "cells", .get = rowCells },
    }, .methods = &.{
        .{ .name = "insertCell", .f = rowInsertCell },
        .{ .name = "deleteCell", .len = 1, .f = rowDeleteCell },
    } },
    .{ .name = "HTMLTableCellElement", .parent = "HTMLElement", .attrs = &.{
        .{ .name = "cellIndex", .get = cellIndex },
    } },
    .{ .name = "SVGElement", .parent = "Element", .attrs = &.{
        .{ .name = "ownerSVGElement", .get = svgOwner },
    } },
    .{ .name = "SVGRectElement", .parent = "SVGElement", .attrs = &.{
        .{ .name = "x", .get = svgLengthX },
        .{ .name = "y", .get = svgLengthY },
        .{ .name = "width", .get = svgLengthWidth },
        .{ .name = "height", .get = svgLengthHeight },
    } },
    .{ .name = "SVGTextContentElement", .parent = "SVGElement", .methods = &.{
        .{ .name = "getNumberOfChars", .f = svgNumberOfChars },
        .{ .name = "getComputedTextLength", .f = svgComputedTextLength },
    } },
    .{ .name = "HTMLTemplateElement", .parent = "HTMLElement", .attrs = &.{
        .{ .name = "content", .get = templateContent },
    } },
    .{ .name = "HTMLMetaElement", .parent = "HTMLElement", .attrs = &.{
        .{ .name = "httpEquiv", .get = getHttpEquiv, .set = setHttpEquiv },
        .{ .name = "content", .get = getContentAttr, .set = setContentAttr },
        .{ .name = "media", .get = getMediaAttr, .set = setMediaAttr },
    } },
    .{ .name = "HTMLLinkElement", .parent = "HTMLElement", .attrs = &.{
        .{ .name = "href", .get = getHrefAttrResolved, .set = setHrefAttrRaw },
        .{ .name = "rel", .get = getRelAttr, .set = setRelAttr },
        .{ .name = "type", .get = getTypeAttrRaw, .set = setTypeAttr },
        .{ .name = "media", .get = getMediaAttr, .set = setMediaAttr },
        .{ .name = "as", .get = getAsAttr, .set = setAsAttr },
        .{ .name = "crossOrigin", .get = getCrossOriginAttr, .set = setCrossOriginAttr },
        .{ .name = "integrity", .get = getIntegrityAttr, .set = setIntegrityAttr },
        .{ .name = "disabled", .get = getDisabled, .set = setDisabled },
    } },
    .{ .name = "HTMLScriptElement", .parent = "HTMLElement", .attrs = &.{
        .{ .name = "src", .get = getSrcAttr, .set = setSrcAttr },
        .{ .name = "type", .get = getTypeAttrRaw, .set = setTypeAttr },
        .{ .name = "async", .get = getAsyncAttr, .set = setAsyncAttr },
        .{ .name = "defer", .get = getDeferAttr, .set = setDeferAttr },
        .{ .name = "noModule", .get = getNoModuleAttr, .set = setNoModuleAttr },
        .{ .name = "text", .get = getTextContent, .set = setTextContent },
        .{ .name = "crossOrigin", .get = getCrossOriginAttr, .set = setCrossOriginAttr },
        .{ .name = "integrity", .get = getIntegrityAttr, .set = setIntegrityAttr },
    } },
    .{ .name = "HTMLImageElement", .parent = "HTMLElement", .attrs = &.{
        .{ .name = "width", .get = imageWidth, .set = setWidthAttr },
        .{ .name = "height", .get = imageHeight, .set = setHeightAttr },
        .{ .name = "naturalWidth", .get = imageWidth },
        .{ .name = "naturalHeight", .get = imageHeight },
        .{ .name = "complete", .get = trueNative },
    } },
    .{ .name = "HTMLOptionElement", .parent = "HTMLElement", .attrs = &.{
        .{ .name = "defaultSelected", .get = getSelectedAttr, .set = setSelectedAttr },
        .{ .name = "selected", .get = getSelectedAttr, .set = setSelectedAttr },
        .{ .name = "value", .get = optionValueAttr, .set = setValueAttr },
        .{ .name = "text", .get = getTextContent, .set = setTextContent },
        .{ .name = "index", .get = optionIndex },
        .{ .name = "disabled", .get = getDisabled, .set = setDisabled },
    } },
    .{ .name = "HTMLFormElement", .parent = "HTMLElement", .attrs = &.{
        .{ .name = "action", .get = getActionAttr, .set = setActionAttr },
        .{ .name = "method", .get = getMethodAttr, .set = setMethodAttr },
        .{ .name = "name", .get = getNameAttr, .set = setNameAttr },
        .{ .name = "elements", .get = getFormElements },
        .{ .name = "length", .get = getFormLength },
    }, .methods = &.{
        .{ .name = "submit", .f = formSubmit },
        .{ .name = "requestSubmit", .f = formRequestSubmit },
        .{ .name = "reset", .f = formReset },
    } },
    .{ .name = "HTMLAnchorElement", .parent = "HTMLElement", .attrs = &.{
        .{ .name = "href", .get = getHref, .set = setHref },
    } },
    .{ .name = "CSSStyleDeclaration", .attrs = styleAttrs() ++ [_]Attr{
        .{ .name = "cssText", .get = styleCssText, .set = styleSetCssText },
        .{ .name = "length", .get = styleLength },
        .{ .name = "parentRule", .get = getNull },
    }, .methods = &.{
        .{ .name = "getPropertyValue", .len = 1, .f = styleGetPropertyValue },
        .{ .name = "getPropertyPriority", .len = 1, .f = styleGetPropertyPriority },
        .{ .name = "setProperty", .len = 2, .f = styleSetProperty },
        .{ .name = "removeProperty", .len = 1, .f = styleRemoveProperty },
        .{ .name = "item", .len = 1, .f = styleItem },
    } },
    .{ .name = "DOMTokenList", .attrs = &.{
        .{ .name = "length", .get = tokensLength },
        .{ .name = "value", .get = tokensValue, .set = tokensSetValue },
    }, .methods = &.{
        .{ .name = "item", .len = 1, .f = tokensItem },
        .{ .name = "contains", .len = 1, .f = tokensContains },
        .{ .name = "add", .f = tokensAdd },
        .{ .name = "remove", .f = tokensRemove },
        .{ .name = "toggle", .len = 1, .f = tokensToggle },
        .{ .name = "replace", .len = 2, .f = tokensReplace },
        .{ .name = "toString", .f = tokensValue },
    } },
    .{ .name = "Event", .constructible = true, .consts = &.{
        .{ .name = "NONE", .value = 0 },
        .{ .name = "CAPTURING_PHASE", .value = 1 },
        .{ .name = "AT_TARGET", .value = 2 },
        .{ .name = "BUBBLING_PHASE", .value = 3 },
    }, .attrs = &.{
        .{ .name = "bubbles", .get = eventBubbles },
        .{ .name = "cancelable", .get = eventCancelable },
        .{ .name = "defaultPrevented", .get = eventDefaultPrevented },
        .{ .name = "isTrusted", .get = eventIsTrusted },
        .{ .name = "composed", .get = eventComposed },
    }, .methods = &.{
        .{ .name = "preventDefault", .f = eventPreventDefault },
        .{ .name = "stopPropagation", .f = eventStopPropagation },
        .{ .name = "stopImmediatePropagation", .f = eventStopImmediate },
        .{ .name = "composedPath", .f = eventComposedPath },
    } },
    .{ .name = "CustomEvent", .parent = "Event", .constructible = true },
    .{ .name = "CSSStyleSheet", .attrs = &.{
        .{ .name = "href", .get = sheetHref },
        .{ .name = "ownerNode", .get = sheetOwnerNode },
        .{ .name = "type", .get = sheetType },
        .{ .name = "media", .get = sheetMedia },
        .{ .name = "title", .get = sheetTitle },
        .{ .name = "disabled", .get = sheetDisabled, .set = sheetSetDisabled },
        .{ .name = "cssRules", .get = sheetRules },
        .{ .name = "rules", .get = sheetRules },
    }, .methods = &.{
        .{ .name = "insertRule", .len = 1, .f = sheetInsertRule },
        .{ .name = "deleteRule", .len = 1, .f = sheetDeleteRule },
    } },
    .{ .name = "MutationObserver", .constructible = true, .methods = &.{
        .{ .name = "observe", .len = 1, .f = moObserve },
        .{ .name = "disconnect", .f = moDisconnect },
        .{ .name = "takeRecords", .f = moTakeRecords },
    } },
    .{ .name = "Storage", .attrs = &.{
        .{ .name = "length", .get = storageLength },
    }, .methods = &.{
        .{ .name = "getItem", .len = 1, .f = storageGetItem },
        .{ .name = "setItem", .len = 2, .f = storageSetItem },
        .{ .name = "removeItem", .len = 1, .f = storageRemoveItem },
        .{ .name = "clear", .f = storageClear },
        .{ .name = "key", .len = 1, .f = storageKey },
    } },
    .{ .name = "XMLHttpRequest", .parent = "EventTarget", .constructible = true, .consts = &.{
        .{ .name = "UNSENT", .value = 0 },
        .{ .name = "OPENED", .value = 1 },
        .{ .name = "HEADERS_RECEIVED", .value = 2 },
        .{ .name = "LOADING", .value = 3 },
        .{ .name = "DONE", .value = 4 },
    }, .methods = &.{
        .{ .name = "open", .len = 2, .f = xhrOpen },
        .{ .name = "setRequestHeader", .len = 2, .f = noopNative },
        .{ .name = "overrideMimeType", .len = 1, .f = noopNative },
        .{ .name = "send", .f = xhrSend },
        .{ .name = "abort", .f = noopNative },
        .{ .name = "getResponseHeader", .len = 1, .f = xhrGetResponseHeader },
        .{ .name = "getAllResponseHeaders", .f = xhrGetAllResponseHeaders },
    } },
    .{ .name = "UIEvent", .parent = "Event", .constructible = true },
    .{ .name = "MouseEvent", .parent = "UIEvent", .constructible = true },
    .{ .name = "KeyboardEvent", .parent = "UIEvent", .constructible = true },
};

/// The CSS properties `style` and `getComputedStyle` name as camelCase
/// members (`backgroundColor`); any other is reached by `getPropertyValue`.
const css_properties = [_][]const u8{
    "display",             "position",          "float",            "clear",                 "visibility",
    "opacity",             "z-index",           "box-sizing",       "overflow",              "overflow-x",
    "overflow-y",          "width",             "height",           "min-width",             "min-height",
    "max-width",           "max-height",        "top",              "right",                 "bottom",
    "left",                "margin",            "margin-top",       "margin-right",          "margin-bottom",
    "margin-left",         "padding",           "padding-top",      "padding-right",         "padding-bottom",
    "padding-left",        "border",            "border-width",     "border-style",          "border-color",
    "border-top",          "border-right",      "border-bottom",    "border-left",           "border-radius",
    "color",               "background",        "background-color", "background-image",      "background-position",
    "background-size",     "background-repeat", "font",             "font-size",             "font-weight",
    "font-style",          "font-family",       "line-height",      "text-align",            "text-decoration",
    "text-transform",      "text-indent",       "white-space",      "vertical-align",        "letter-spacing",
    "word-spacing",        "list-style",        "list-style-type",  "cursor",                "pointer-events",
    "transform",           "translate",         "transition",       "animation",             "flex",
    "flex-direction",      "flex-wrap",         "flex-grow",        "flex-shrink",           "flex-basis",
    "justify-content",     "align-items",       "align-self",       "align-content",         "gap",
    "row-gap",             "column-gap",        "order",            "grid-template-columns", "grid-template-rows",
    "grid-template-areas", "grid-area",         "grid-column",      "grid-row",              "outline",
    "box-shadow",          "text-shadow",       "content",          "fill",                  "stroke",
};

/// `background-color` → `backgroundColor`; `float` is `cssFloat` too.
fn camelCase(comptime kebab: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(20000);
        var out: [kebab.len]u8 = undefined;
        var n: usize = 0;
        var up = false;
        for (kebab) |c| {
            if (c == '-') {
                up = true;
                continue;
            }
            out[n] = if (up) std.ascii.toUpper(c) else c;
            up = false;
            n += 1;
        }
        const final = out[0..n].*;
        return &final;
    }
}

fn styleAttrs() []const Attr {
    comptime {
        @setEvalBranchQuota(20000);
        var attrs: [css_properties.len + 1]Attr = undefined;
        for (css_properties, 0..) |name, i| {
            const gen = struct {
                fn get(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
                    return stylePropertyGet(vm, this, name);
                }
                fn set(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
                    return stylePropertySet(vm, this, name, arg(args, 0), false);
                }
            };
            attrs[i] = .{ .name = camelCase(name), .get = gen.get, .set = gen.set };
        }
        attrs[css_properties.len] = .{ .name = "cssFloat", .get = struct {
            fn get(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
                return stylePropertyGet(vm, this, "float");
            }
        }.get, .set = struct {
            fn set(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
                return stylePropertySet(vm, this, "float", arg(args, 0), false);
            }
        }.set };
        const final = attrs;
        return &final;
    }
}

fn ifaceIndex(comptime name: []const u8) comptime_int {
    comptime {
        @setEvalBranchQuota(100_000);
        for (interfaces, 0..) |i, k| if (std.mem.eql(u8, i.name, name)) return k;
        @compileError("no interface " ++ name);
    }
}

const I = struct {
    const event_target = ifaceIndex("EventTarget");
    const node = ifaceIndex("Node");
    const document = ifaceIndex("Document");
    const fragment = ifaceIndex("DocumentFragment");
    const doctype = ifaceIndex("DocumentType");
    const text = ifaceIndex("Text");
    const comment = ifaceIndex("Comment");
    const element = ifaceIndex("Element");
    const html_element = ifaceIndex("HTMLElement");
    const input = ifaceIndex("HTMLInputElement");
    const anchor = ifaceIndex("HTMLAnchorElement");
    const form = ifaceIndex("HTMLFormElement");
    const table = ifaceIndex("HTMLTableElement");
    const table_section = ifaceIndex("HTMLTableSectionElement");
    const table_row = ifaceIndex("HTMLTableRowElement");
    const table_cell = ifaceIndex("HTMLTableCellElement");
    const option = ifaceIndex("HTMLOptionElement");
    const image = ifaceIndex("HTMLImageElement");
    const script_el = ifaceIndex("HTMLScriptElement");
    const link = ifaceIndex("HTMLLinkElement");
    const template = ifaceIndex("HTMLTemplateElement");
    const meta = ifaceIndex("HTMLMetaElement");
    const svg_element = ifaceIndex("SVGElement");
    const svg_rect = ifaceIndex("SVGRectElement");
    const svg_text = ifaceIndex("SVGTextContentElement");
    const tokens = ifaceIndex("DOMTokenList");
    const style = ifaceIndex("CSSStyleDeclaration");
    const event = ifaceIndex("Event");
    const custom_event = ifaceIndex("CustomEvent");
    const xhr = ifaceIndex("XMLHttpRequest");
    const storage = ifaceIndex("Storage");
    const sheet = ifaceIndex("CSSStyleSheet");
    const mutation_observer = ifaceIndex("MutationObserver");
    const node_iterator = ifaceIndex("NodeIterator");
    const tree_walker = ifaceIndex("TreeWalker");
    const range = ifaceIndex("Range");
    const keyboard_event = ifaceIndex("KeyboardEvent");
    const mouse_event = ifaceIndex("MouseEvent");
};

const Timer = struct {
    id: u32,
    when: f64,
    /// Repeats every this many ms; null for a one-shot.
    interval: ?f64,
    func: Value,
    args: [4]Value,
    argc: u8,
    /// An animation frame: the callback takes the time.
    raf: bool,
};

pub const ReadyState = enum { loading, interactive, complete };

const HistoryEntry = struct { url: []u8, state: Value };
const SessionItem = struct { key: []u8, value: []u8 };
const Observation = struct { observer: Value, doc: u32, target: NodeId, child_list: bool, attributes: bool, character_data: bool, subtree: bool };
const PendingRecord = struct { observer: Value, record: Value };
const MutationKind = enum { child_list, attributes, character_data };
const session_quota: usize = 256 << 10;

/// A document the page holds: its own (index 0), an iframe's or an
/// `<object>`'s (fetched and parsed on first `contentDocument`), or one a
/// script made through `document.implementation`. `doc` on the page is
/// the current one: every native switches to its `this` node's.
const DocEntry = struct {
    doc: *dom.Document,
    /// The arena the document lives in (null: the page's, not ours).
    arena: ?*std.heap.ArenaAllocator,
    is_html: bool,
    /// The element that holds it (an iframe, an object), if any.
    owner: ?struct { doc: u32, id: NodeId },
    /// Its `defaultView`, made on first use.
    view: Value,
    url: []const u8,
    /// `document.open()`'s state: what `write` gathers until `close`.
    open: bool = false,
    write_buf: std.ArrayList(u8) = .empty,
};

const ImportEntry = struct { key: []const u8, value: []const u8 };

pub const Page = struct {
    vm: *Vm,
    /// The current document (see `DocEntry`).
    doc: *dom.Document,
    docs: std.ArrayList(DocEntry) = .empty,
    cur: u32 = 0,
    /// Bookkeeping memory (the wrapper table, timers).
    a: std.mem.Allocator,
    host: Host,
    url: []const u8 = "about:blank",
    viewport_w: u32 = 800,
    viewport_h: u32 = 600,
    scroll_x: f64 = 0,
    scroll_y: f64 = 0,
    /// Node wrappers by (document, node).
    wrappers: std.AutoHashMapUnmanaged(u64, *Object) = .empty,
    protos: [interfaces.len]*Object = undefined,
    ctors: [interfaces.len]*Object = undefined,
    sym_listeners: *Symbol = undefined,
    sym_slot: *Symbol = undefined,
    sym_style: *Symbol = undefined,
    document_obj: *Object = undefined,
    location_obj: *Object = undefined,
    dom_exception_proto: Value = Value.undefined_,
    timers: std.ArrayList(Timer) = .empty,
    next_timer: u32 = 1,
    /// Every script's text, kept: the engine holds slices of it.
    url_owned: bool = false,
    /// The DOM changed since the embedder last asked.
    dirty: bool = false,
    /// A stylesheet changed too (a `<style>`'s text, a `<link>`, a rule
    /// inserted): the embedder must read the sheets again, which costs
    /// a parse it should not pay for every other mutation.
    sheets_dirty: bool = false,
    ready_state: ReadyState = .loading,
    /// When no host clock is set: the time the tests advance by hand.
    fake_now: f64 = 0,
    scripts_run: u32 = 0,
    script_errors: u32 = 0,
    /// A line per compile (a tool's diagnosis of a site's scripts).
    verbose: bool = false,
    /// The parser-inserted script running now: `document.write` puts
    /// its markup right after it, as the parser would have.
    current_script: ?NodeId = null,
    /// Live ranges and node iterators: the DOM's mutations move them.
    ranges: std.ArrayList(Value) = .empty,
    iterators: std.ArrayList(Value) = .empty,
    /// The import map's `imports`, keys and values as given, read from
    /// the document on the first module load (null until then).
    import_map: ?std.ArrayList(ImportEntry) = null,
    /// Frames and pictures inserted by script: each gets its `load`
    /// event from the next turn of the loop (a task, not a microtask).
    pending_loads: std.ArrayList(struct { doc: u32, id: NodeId }) = .empty,
    /// The session history the page's scripts made: `pushState` entries
    /// and where the page is in them (the host keeps the real history).
    history: std.ArrayList(HistoryEntry) = .empty,
    history_index: usize = 0,
    modules_run: u32 = 0,
    /// `sessionStorage`: the page's own, gone with the document.
    session_items: std.ArrayList(SessionItem) = .empty,
    /// MutationObservers: what each watches, and the records queued for
    /// it until the delivery microtask runs.
    observers: std.ArrayList(Observation) = .empty,
    mutation_records: std.ArrayList(PendingRecord) = .empty,
    deliver_fn: Value = Value.undefined_,
    delivery_queued: bool = false,

    /// Install the bindings into `vm` for `doc`. The VM's `host_data`
    /// becomes this page and its embedder roots this page's tables.
    pub fn init(p: *Page, vm: *Vm, doc: *dom.Document, a: std.mem.Allocator, host: Host) Error!void {
        p.* = .{ .vm = vm, .doc = doc, .a = a, .host = host };
        try p.docs.append(a, .{ .doc = doc, .arena = null, .is_html = true, .owner = null, .view = Value.undefined_, .url = "" });
        vm.host_data = p;
        vm.embedder_roots = .{ .ctx = p, .trace = trace };
        p.sym_listeners = try vm.newSymbol(try vm.strings.fromUtf8("listeners"));
        p.sym_slot = try vm.newSymbol(try vm.strings.fromUtf8("slot"));
        p.sym_style = try vm.newSymbol(try vm.strings.fromUtf8("style"));
        try p.installInterfaces();
        try p.installWindow();
        vm.host_load = hostLoad;
        vm.host_import_meta = hostImportMeta;
    }

    pub fn deinit(p: *Page) void {
        for (p.docs.items) |d| if (d.arena) |ar| {
            ar.deinit();
            p.a.destroy(ar);
        };
        for (p.docs.items) |*d| d.write_buf.deinit(p.a);
        p.docs.deinit(p.a);
        p.wrappers.deinit(p.a);
        p.timers.deinit(p.a);
        for (p.history.items) |h| p.a.free(h.url);
        p.history.deinit(p.a);
        for (p.session_items.items) |it| {
            p.a.free(it.key);
            p.a.free(it.value);
        }
        p.session_items.deinit(p.a);
        p.observers.deinit(p.a);
        p.mutation_records.deinit(p.a);
        p.ranges.deinit(p.a);
        p.iterators.deinit(p.a);
        p.pending_loads.deinit(p.a);
        if (p.import_map) |*m| {
            for (m.items) |e| {
                p.a.free(e.key);
                p.a.free(e.value);
            }
            m.deinit(p.a);
        }
        if (p.url_owned) p.a.free(p.url);
        p.vm.embedder_roots = null;
        p.vm.host_data = null;
        p.vm.compile_scratch = null;
    }

    fn trace(ctx: *anyopaque, m: *js.heap.Marker) void {
        const p: *Page = @ptrCast(@alignCast(ctx));
        var it = p.wrappers.valueIterator();
        while (it.next()) |o| m.markCell(o.*.cell());
        for (p.protos) |o| m.markCell(o.cell());
        for (p.ctors) |o| m.markCell(o.cell());
        m.markCell(&p.sym_listeners.header);
        m.markCell(&p.sym_slot.header);
        m.markCell(&p.sym_style.header);
        m.markCell(p.document_obj.cell());
        m.markCell(p.location_obj.cell());
        m.markValue(p.dom_exception_proto);
        for (p.timers.items) |t| {
            m.markValue(t.func);
            for (t.args[0..t.argc]) |v| m.markValue(v);
        }
        for (p.history.items) |h| m.markValue(h.state);
        for (p.observers.items) |o| m.markValue(o.observer);
        for (p.mutation_records.items) |r| {
            m.markValue(r.observer);
            m.markValue(r.record);
        }
        m.markValue(p.deliver_fn);
        for (p.docs.items) |d| m.markValue(d.view);
        for (p.ranges.items) |r| m.markValue(r);
        for (p.iterators.items) |r| m.markValue(r);
    }

    // ---------------------------------------------------- documents

    fn key(p: *Page, id: NodeId) u64 {
        return (@as(u64, p.cur) << 32) | id;
    }

    /// Make document `i` the current one.
    fn switchTo(p: *Page, i: u32) void {
        if (i >= p.docs.items.len) return;
        p.cur = i;
        p.doc = p.docs.items[i].doc;
    }

    /// Back to the page's own document (every entry from the embedder).
    fn resetDoc(p: *Page) void {
        p.switchTo(0);
    }

    fn isHtmlDoc(p: *Page) bool {
        return p.docs.items[p.cur].is_html;
    }

    /// A new document of the page's, in an arena of its own.
    fn newDocument(p: *Page, markup: ?[]const u8, is_html: bool, owner: ?struct { doc: u32, id: NodeId }, url_text: []const u8) Error!u32 {
        const ar = try p.a.create(std.heap.ArenaAllocator);
        ar.* = std.heap.ArenaAllocator.init(p.a);
        errdefer {
            ar.deinit();
            p.a.destroy(ar);
        }
        const a = ar.allocator();
        const doc: *dom.Document = if (markup) |m| try html.parse(a, m, .{ .scripting = true }) else blk: {
            const d = try a.create(dom.Document);
            d.* = try dom.Document.init(a);
            break :blk d;
        };
        const idx: u32 = @intCast(p.docs.items.len);
        try p.docs.append(p.a, .{ .doc = doc, .arena = ar, .is_html = is_html, .owner = if (owner) |o| .{ .doc = o.doc, .id = o.id } else null, .view = Value.undefined_, .url = try a.dupe(u8, url_text) });
        return idx;
    }

    /// The document an iframe or object holds, loaded on first touch:
    /// its `src` (an object's `data`) fetched through the host, parsed
    /// as the page's document was; nothing to fetch gives an empty one.
    fn frameDocument(p: *Page, id: NodeId) Error!u32 {
        for (p.docs.items, 0..) |d, i| if (d.owner) |o| if (o.doc == p.cur and o.id == id) return @intCast(i);
        const owner_doc = p.cur;
        var scratch = std.heap.ArenaAllocator.init(p.a);
        defer scratch.deinit();
        const sa = scratch.allocator();
        var markup: []const u8 = "";
        var abs: []const u8 = "about:blank";
        const attr = if (p.doc.isHtml(id, "object")) "data" else "src";
        if (p.doc.getAttr(id, attr)) |raw| if (raw.len > 0) {
            const base = url.parse(sa, p.url, null) catch null;
            if (url.parse(sa, raw, if (base) |*b| b else null)) |u| {
                abs = try u.href(sa);
                if (p.host.fetch) |f| if (f(p.host.ctx, abs)) |text| {
                    markup = text;
                };
            } else |_| {}
        };
        // A picture or plain text in a frame is a document around it.
        const lower = try std.ascii.allocLowerString(sa, abs);
        if (std.mem.endsWith(u8, lower, ".png") or std.mem.endsWith(u8, lower, ".jpg") or std.mem.endsWith(u8, lower, ".jpeg") or std.mem.endsWith(u8, lower, ".gif") or std.mem.endsWith(u8, lower, ".webp")) {
            markup = try std.fmt.allocPrint(sa, "<html><head><title></title></head><body><img src=\"{s}\"></body></html>", .{abs});
        } else if (std.mem.endsWith(u8, lower, ".txt")) {
            var esc: std.ArrayList(u8) = .empty;
            for (markup) |ch| switch (ch) {
                '<' => try esc.appendSlice(sa, "&lt;"),
                '&' => try esc.appendSlice(sa, "&amp;"),
                else => try esc.append(sa, ch),
            };
            markup = try std.fmt.allocPrint(sa, "<html><head><title></title></head><body><pre>{s}</pre></body></html>", .{esc.items});
        }
        return p.newDocument(markup, true, .{ .doc = owner_doc, .id = id }, abs);
    }

    /// A document's `defaultView`: the window for the page's own, a
    /// window-like object for the others (their `document`, and
    /// `getComputedStyle`), made once.
    fn viewOf(p: *Page, i: u32) Error!Value {
        if (i == 0) return p.vm.global.asValue();
        if (p.docs.items[i].view.isObject()) return p.docs.items[i].view;
        const vm = p.vm;
        const o = try vm.newObject();
        const saved = p.cur;
        p.switchTo(i);
        const docv = try p.wrapValue(dom.document_id);
        p.switchTo(saved);
        try vm.defineValue(o, "document", docv, .default);
        try vm.defineValue(o, "window", o.asValue(), .default);
        try vm.defineValue(o, "self", o.asValue(), .default);
        try vm.defineValue(o, "parent", vm.global.asValue(), .default);
        try vm.defineValue(o, "top", vm.global.asValue(), .default);
        _ = try vm.defineNative(o, "getComputedStyle", 1, getComputedStyle);
        _ = try vm.defineNative(o, "postMessage", 1, noopNative);
        p.docs.items[i].view = o.asValue();
        return o.asValue();
    }

    /// Whether the DOM changed since the last call (and forget it).
    pub fn takeDirty(p: *Page) bool {
        const d = p.dirty;
        p.dirty = false;
        return d;
    }

    /// Whether a stylesheet changed since the last call (and forget it).
    pub fn takeSheetsDirty(p: *Page) bool {
        const d = p.sheets_dirty;
        p.sheets_dirty = false;
        return d;
    }

    /// The frames, pictures and stylesheet links in a subtree about to
    /// be inserted get a `load` event from the loop's next turn.
    fn scheduleLoads(p: *Page, id: NodeId) void {
        var w = p.doc.walk(id);
        var cur: ?NodeId = if (p.doc.get(id).kind == .element) id else null;
        while (true) {
            const n = cur orelse (w.next() orelse break);
            cur = null;
            if (p.doc.isHtml(n, "iframe") or p.doc.isHtml(n, "object") or p.doc.isHtml(n, "frame") or p.doc.isHtml(n, "img") or p.doc.isHtml(n, "link") or p.doc.isHtml(n, "script")) {
                p.pending_loads.append(p.a, .{ .doc = p.cur, .id = n }) catch {};
            }
        }
    }

    /// Whether `id` is, or holds, a stylesheet element.
    fn touchesSheets(p: *Page, id: NodeId) bool {
        var w = p.doc.walk(id);
        while (w.next()) |n| if (isSheetElement(p, n) or p.doc.isHtml(n, "style")) return true;
        return false;
    }

    pub fn now(p: *Page) f64 {
        return if (p.vm.host_now) |f| f() else p.fake_now;
    }

    // ------------------------------------------------------- install

    fn installInterfaces(p: *Page) Error!void {
        const vm = p.vm;
        @setEvalBranchQuota(100_000);
        inline for (interfaces, 0..) |iface, k| {
            const parent_proto: Value = if (iface.parent) |pn| p.protos[ifaceIndex(pn)].asValue() else vm.intrinsics.object_prototype.asValue();
            const proto = try vm.objects.create(parent_proto, .ordinary, 0);
            p.protos[k] = proto;
            const ctor = try vm.newNativeNamed(try vm.str(iface.name), 0, construct, Value.fromInt(@intCast(k)), true);
            p.ctors[k] = ctor;
            if (iface.parent) |pn| _ = try vm.setPrototypeOf(ctor, p.ctors[ifaceIndex(pn)].asValue());
            try vm.defineValue(ctor, "prototype", proto.asValue(), .frozen);
            try vm.defineValue(proto, "constructor", ctor.asValue(), .hidden);
            try vm.defineValue(vm.global, iface.name, ctor.asValue(), .hidden);
            inline for (iface.methods) |m| _ = try vm.defineNative(proto, m.name, m.len, m.f);
            inline for (iface.attrs) |at| {
                const g = try vm.newNativeNamed(try vm.str("get " ++ at.name), 0, at.get, Value.undefined_, false);
                const s: ?*Object = if (at.set) |sf| try vm.newNativeNamed(try vm.str("set " ++ at.name), 1, sf, Value.undefined_, false) else null;
                try vm.defineAccessor(proto, .{ .atom = try vm.atom(at.name) }, g, s, .{ .enumerable = true, .configurable = true });
            }
            inline for (iface.consts) |c| {
                try vm.defineValue(ctor, c.name, Value.fromInt(c.value), .frozen);
                try vm.defineValue(proto, c.name, Value.fromInt(c.value), .frozen);
            }
            _ = try vm.objects.defineOwn(proto, .{ .symbol = vm.symbols.to_string_tag }, try vm.str(iface.name), .{ .writable = false, .enumerable = false, .configurable = true });
        }
    }

    fn installWindow(p: *Page) Error!void {
        const vm = p.vm;
        const g = vm.global;
        // The window is the global: an EventTarget with the Window's
        // members on it.
        _ = try vm.setPrototypeOf(g, p.protos[I.event_target].asValue());
        try vm.defineValue(g, "window", g.asValue(), .hidden);
        try vm.defineValue(g, "self", g.asValue(), .hidden);
        try vm.defineValue(g, "frames", g.asValue(), .hidden);
        try vm.defineValue(g, "parent", g.asValue(), .hidden);
        try vm.defineValue(g, "top", g.asValue(), .hidden);
        p.document_obj = try p.wrap(dom.document_id);
        try vm.defineValue(g, "document", p.document_obj.asValue(), .hidden);
        p.location_obj = try vm.newObject();
        try p.fillLocation();
        try vm.defineValue(g, "location", p.location_obj.asValue(), .hidden);
        const nav = try vm.newObject();
        try vm.defineValue(nav, "userAgent", try vm.str("Mozilla/5.0 (moss) moss/0.1"), .default);
        try vm.defineValue(nav, "language", try vm.str("en"), .default);
        try vm.defineValue(nav, "languages", (try vm.arrayFromList(&.{try vm.str("en")})).asValue(), .default);
        try vm.defineValue(nav, "platform", try vm.str("moss"), .default);
        try vm.defineValue(nav, "onLine", Value.true_, .default);
        try vm.defineValue(nav, "cookieEnabled", Value.false_, .default);
        try vm.defineValue(g, "navigator", nav.asValue(), .hidden);
        const console = try vm.newObject();
        _ = try vm.defineNative(console, "log", 0, consoleLog);
        _ = try vm.defineNative(console, "info", 0, consoleLog);
        _ = try vm.defineNative(console, "debug", 0, consoleLog);
        _ = try vm.defineNative(console, "trace", 0, consoleLog);
        _ = try vm.defineNative(console, "warn", 0, consoleWarn);
        _ = try vm.defineNative(console, "error", 0, consoleError);
        _ = try vm.defineNative(console, "assert", 0, consoleAssert);
        _ = try vm.defineNative(console, "group", 0, noopNative);
        _ = try vm.defineNative(console, "groupEnd", 0, noopNative);
        _ = try vm.defineNative(console, "time", 0, noopNative);
        _ = try vm.defineNative(console, "timeEnd", 0, noopNative);
        try vm.defineValue(g, "console", console.asValue(), .hidden);
        _ = try vm.defineNative(g, "setTimeout", 1, setTimeout);
        _ = try vm.defineNative(g, "setInterval", 1, setInterval);
        _ = try vm.defineNative(g, "clearTimeout", 1, clearTimer);
        _ = try vm.defineNative(g, "clearInterval", 1, clearTimer);
        _ = try vm.defineNative(g, "requestAnimationFrame", 1, requestAnimationFrame);
        _ = try vm.defineNative(g, "cancelAnimationFrame", 1, clearTimer);
        _ = try vm.defineNative(g, "queueMicrotask", 1, queueMicrotask);
        _ = try vm.defineNative(g, "alert", 0, alert);
        _ = try vm.defineNative(g, "confirm", 0, confirmNative);
        _ = try vm.defineNative(g, "prompt", 0, promptNative);
        _ = try vm.defineNative(g, "getComputedStyle", 1, getComputedStyle);
        _ = try vm.defineNative(g, "fetch", 1, fetchNative);
        const hist = try vm.newObject();
        _ = try vm.defineNative(hist, "pushState", 2, historyPushState);
        _ = try vm.defineNative(hist, "replaceState", 2, historyReplaceState);
        _ = try vm.defineNative(hist, "back", 0, historyBack);
        _ = try vm.defineNative(hist, "forward", 0, historyForward);
        _ = try vm.defineNative(hist, "go", 0, historyGoNative);
        try vm.defineGetter(hist, "length", historyLength);
        try vm.defineGetter(hist, "state", historyState);
        try vm.defineValue(hist, "scrollRestoration", try vm.str("auto"), .default);
        try vm.defineValue(g, "history", hist.asValue(), .hidden);
        const local = try vm.objects.create(p.protos[I.storage].asValue(), .dom, @sizeOf(Slot));
        local.internal(Slot).* = .{ .kind = slot_storage, .id = 0, .flags = 0 };
        try vm.defineValue(g, "localStorage", local.asValue(), .hidden);
        const session = try vm.objects.create(p.protos[I.storage].asValue(), .dom, @sizeOf(Slot));
        session.internal(Slot).* = .{ .kind = slot_storage, .id = 0, .flags = storage_session };
        try vm.defineValue(g, "sessionStorage", session.asValue(), .hidden);
        p.deliver_fn = (try vm.newNative("deliverMutations", 0, deliverMutations, Value.undefined_)).asValue();
        // Named access (`localStorage.foo`) through a Proxy over each store,
        // made by the engine's own Proxy: the bindings have no exotic
        // objects, the language has.
        p.runSource(named_storage_source, "the storage proxies");
        p.runSource(live_rules_source, "the live rule lists");
        // The platform's smaller APIs, in JavaScript (`script_prelude.zig`),
        // over three natives: the URL parser, the clock, the current script.
        _ = try vm.defineNative(g, "__urlParse", 2, urlParseNative);
        _ = try vm.defineNative(g, "__perfNow", 0, perfNowNative);
        _ = try vm.defineNative(g, "__currentScript", 0, currentScriptNative);
        p.runSource(@import("script_prelude.zig").source, "the web APIs prelude");
        p.scripts_run = 0; // the page's own count starts at its scripts
        _ = try vm.defineNative(g, "matchMedia", 1, matchMedia);
        try p.installDomException();
        _ = try vm.defineNative(g, "postMessage", 1, noopNative);
        _ = try vm.defineNative(g, "open", 0, windowOpen);
        _ = try vm.defineNative(g, "close", 0, noopNative);
        _ = try vm.defineNative(g, "focus", 0, noopNative);
        _ = try vm.defineNative(g, "blur", 0, noopNative);
        _ = try vm.defineNative(g, "scrollTo", 0, scrollToNative);
        _ = try vm.defineNative(g, "scroll", 0, scrollToNative);
        _ = try vm.defineNative(g, "scrollBy", 0, scrollByNative);
        try vm.defineValue(g, "innerWidth", Value.fromInt(@intCast(p.viewport_w)), .hidden);
        try vm.defineValue(g, "innerHeight", Value.fromInt(@intCast(p.viewport_h)), .hidden);
        try vm.defineValue(g, "devicePixelRatio", Value.fromInt(1), .hidden);
        try vm.defineValue(g, "scrollX", Value.fromInt(0), .hidden);
        try vm.defineValue(g, "scrollY", Value.fromInt(0), .hidden);
        try vm.defineValue(g, "pageXOffset", Value.fromInt(0), .hidden);
        try vm.defineValue(g, "pageYOffset", Value.fromInt(0), .hidden);
    }

    /// `DOMException`: an Error with a `name` and the legacy `code`, and
    /// the code constants on the constructor; `NodeFilter`'s constants.
    fn installDomException(p: *Page) Error!void {
        const vm = p.vm;
        const proto = try vm.objects.create(vm.intrinsics.error_prototype.asValue(), .ordinary, 0);
        const ctor = try vm.newNativeNamed(try vm.str("DOMException"), 0, domExceptionCtor, Value.undefined_, true);
        try vm.defineValue(ctor, "prototype", proto.asValue(), .frozen);
        try vm.defineValue(proto, "constructor", ctor.asValue(), .hidden);
        try vm.defineValue(proto, "name", try vm.str("Error"), .hidden);
        try vm.defineValue(proto, "message", try vm.str(""), .hidden);
        try vm.defineValue(proto, "code", Value.fromInt(0), .hidden);
        inline for (dom_codes) |c| {
            try vm.defineValue(ctor, c.legacy, Value.fromInt(c.code), .frozen);
            try vm.defineValue(proto, c.legacy, Value.fromInt(c.code), .frozen);
        }
        try vm.defineValue(vm.global, "DOMException", ctor.asValue(), .hidden);
        p.dom_exception_proto = proto.asValue();
        const nf = try vm.newObject();
        inline for (node_filter_consts) |c| try vm.defineValue(nf, c.name, Value.fromF64(c.value), .frozen);
        try vm.defineValue(vm.global, "NodeFilter", nf.asValue(), .hidden);
    }

    /// The viewport size the window reports.
    pub fn setViewport(p: *Page, w: u32, h: u32) void {
        p.viewport_w = w;
        p.viewport_h = h;
        p.vm.defineValue(p.vm.global, "innerWidth", Value.fromInt(@intCast(w)), .hidden) catch {};
        p.vm.defineValue(p.vm.global, "innerHeight", Value.fromInt(@intCast(h)), .hidden) catch {};
    }

    /// The viewport's scroll position, for `window.scrollX/Y`.
    pub fn setScroll(p: *Page, x: f64, y: f64) void {
        p.scroll_x = x;
        p.scroll_y = y;
        const g = p.vm.global;
        p.vm.defineValue(g, "scrollX", Value.fromF64(x), .hidden) catch {};
        p.vm.defineValue(g, "scrollY", Value.fromF64(y), .hidden) catch {};
        p.vm.defineValue(g, "pageXOffset", Value.fromF64(x), .hidden) catch {};
        p.vm.defineValue(g, "pageYOffset", Value.fromF64(y), .hidden) catch {};
    }

    /// The document's URL: `location` and `document.URL` follow.
    pub fn setUrl(p: *Page, text: []const u8) Error!void {
        const copy = try p.a.dupe(u8, text);
        if (p.url_owned) p.a.free(p.url);
        p.url = copy;
        p.url_owned = true;
        try p.fillLocation();
    }

    fn fillLocation(p: *Page) Error!void {
        const vm = p.vm;
        const loc = p.location_obj;
        var scratch = std.heap.ArenaAllocator.init(p.a);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const u = url.parse(sa, p.url, null) catch null;
        var href: []const u8 = p.url;
        var protocol: []const u8 = "";
        var hostport: []const u8 = "";
        var hostname: []const u8 = "";
        var port: []const u8 = "";
        var pathname: []const u8 = "";
        var search: []const u8 = "";
        var origin: []const u8 = "null";
        if (u) |*uu| {
            href = try uu.href(sa);
            protocol = try std.fmt.allocPrint(sa, "{s}:", .{uu.scheme});
            if (uu.host != null) {
                // `hostString` is host:port when there is a port.
                hostport = try uu.hostString(sa);
                hostname = hostport;
                if (uu.port) |pt| {
                    port = try std.fmt.allocPrint(sa, "{d}", .{pt});
                    if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |i| hostname = hostport[0..i];
                }
            }
            if (uu.query) |q| search = try std.fmt.allocPrint(sa, "?{s}", .{q});
            origin = try uu.origin(sa);
            var copy = uu.*;
            copy.query = null;
            copy.fragment = null;
            const no_qf = try copy.serialize(sa, true);
            const prefix_len = protocol.len + (if (uu.host != null) 2 + hostport.len else 0);
            pathname = if (no_qf.len >= prefix_len) no_qf[prefix_len..] else "";
        }
        // `href` and `hash` are accessors: assigning them navigates.
        if (try vm.objects.getOwn(loc, .{ .atom = try vm.atom("href") }) == null) {
            const g = try vm.newNativeNamed(try vm.str("get href"), 0, locationGetHref, Value.undefined_, false);
            const s = try vm.newNativeNamed(try vm.str("set href"), 1, locationSetHref, Value.undefined_, false);
            try vm.defineAccessor(loc, .{ .atom = try vm.atom("href") }, g, s, .{ .enumerable = true, .configurable = true });
            const hg = try vm.newNativeNamed(try vm.str("get hash"), 0, locationGetHash, Value.undefined_, false);
            const hs = try vm.newNativeNamed(try vm.str("set hash"), 1, locationSetHash, Value.undefined_, false);
            try vm.defineAccessor(loc, .{ .atom = try vm.atom("hash") }, hg, hs, .{ .enumerable = true, .configurable = true });
        }
        try vm.defineValue(loc, "protocol", try vm.str(protocol), .default);
        try vm.defineValue(loc, "host", try vm.str(hostport), .default);
        try vm.defineValue(loc, "hostname", try vm.str(hostname), .default);
        try vm.defineValue(loc, "port", try vm.str(port), .default);
        try vm.defineValue(loc, "pathname", try vm.str(pathname), .default);
        try vm.defineValue(loc, "search", try vm.str(search), .default);
        try vm.defineValue(loc, "origin", try vm.str(origin), .default);
        _ = try vm.defineNative(loc, "toString", 0, locationToString);
        _ = try vm.defineNative(loc, "reload", 0, locationReload);
        _ = try vm.defineNative(loc, "assign", 1, locationAssign);
        _ = try vm.defineNative(loc, "replace", 1, locationAssign);
    }

    /// The document's URL changed under script (a hash, `pushState`):
    /// `location` follows and the host is told.
    fn urlChanged(p: *Page, abs: []const u8) Error!void {
        try p.setUrl(abs);
        if (p.host.changed) |f| f(p.host.ctx, .url, p.url);
    }

    /// A script's navigation: resolved against the document, handed to
    /// the host for when the script is done.
    fn navigateTo(p: *Page, raw: []const u8) Error!void {
        var scratch = std.heap.ArenaAllocator.init(p.a);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const base = url.parse(sa, p.url, null) catch null;
        const u = url.parse(sa, raw, if (base) |*b| b else null) catch return p.vm.throwError(.SyntaxError, "not a valid URL");
        const abs = try u.href(sa);
        // A change of fragment only is not a navigation.
        if (base) |*b| {
            const here = try b.serialize(sa, true);
            const there = try u.serialize(sa, true);
            if (std.mem.eql(u8, here, there) and u.fragment != null) {
                try p.urlChanged(abs);
                _ = p.fireSimple(p.vm.global.asValue(), "hashchange", false, false);
                return;
            }
        }
        if (p.host.navigate) |f| f(p.host.ctx, abs) else p.logf(.warn, "script: navigation to {s} has no host", .{abs});
    }

    // ------------------------------------------------------- history

    fn historySeed(p: *Page) Error!void {
        if (p.history.items.len > 0) return;
        try p.history.append(p.a, .{ .url = try p.a.dupe(u8, p.url), .state = Value.null_ });
        p.history_index = 0;
    }

    fn historyGo(p: *Page, delta: i64) Error!void {
        try p.historySeed();
        const target: i64 = @as(i64, @intCast(p.history_index)) + delta;
        if (target < 0 or target >= @as(i64, @intCast(p.history.items.len))) return; // past the page's own entries: the host's history, not ours
        p.history_index = @intCast(target);
        const e = p.history.items[p.history_index];
        try p.urlChanged(e.url);
        const ev = try p.newEvent(I.event, "popstate", false, false, true);
        try p.setEventProp(ev, "state", e.state);
        _ = p.dispatch(p.vm.global.asValue(), ev) catch |err| p.reportError(err, "popstate");
    }

    // ------------------------------------------------------ wrappers

    /// The node's wrapper, made on first touch.
    pub fn wrap(p: *Page, id: NodeId) Error!*Object {
        if (p.wrappers.get(p.key(id))) |o| return o;
        const n = p.doc.get(id);
        const k: usize = switch (n.kind) {
            .document => I.document,
            .fragment => I.fragment,
            .doctype => I.doctype,
            .text => I.text,
            .comment => I.comment,
            .element => if (n.namespace == .svg) svgInterfaceFor(n.name) else if (n.namespace != .html or !p.isHtmlDoc()) I.element else htmlInterfaceFor(n.name),
        };
        const o = try p.vm.objects.create(p.protos[k].asValue(), .dom, @sizeOf(Slot));
        o.internal(Slot).* = .{ .kind = slot_node, .id = id, .doc = p.cur };
        try p.wrappers.put(p.a, p.key(id), o);
        return o;
    }

    fn htmlInterfaceFor(name: []const u8) usize {
        const eq = std.mem.eql;
        if (eq(u8, name, "input") or eq(u8, name, "textarea") or eq(u8, name, "select") or eq(u8, name, "button")) return I.input;
        if (eq(u8, name, "a") or eq(u8, name, "area")) return I.anchor;
        if (eq(u8, name, "form")) return I.form;
        if (eq(u8, name, "table")) return I.table;
        if (eq(u8, name, "thead") or eq(u8, name, "tbody") or eq(u8, name, "tfoot")) return I.table_section;
        if (eq(u8, name, "tr")) return I.table_row;
        if (eq(u8, name, "td") or eq(u8, name, "th")) return I.table_cell;
        if (eq(u8, name, "option")) return I.option;
        if (eq(u8, name, "img")) return I.image;
        if (eq(u8, name, "script")) return I.script_el;
        if (eq(u8, name, "link")) return I.link;
        if (eq(u8, name, "template")) return I.template;
        if (eq(u8, name, "meta")) return I.meta;
        return I.html_element;
    }

    fn svgInterfaceFor(name: []const u8) usize {
        const eq = std.mem.eql;
        if (eq(u8, name, "rect")) return I.svg_rect;
        if (eq(u8, name, "text") or eq(u8, name, "tspan") or eq(u8, name, "textPath")) return I.svg_text;
        return I.svg_element;
    }

    fn wrapValue(p: *Page, id: ?NodeId) Error!Value {
        const i = id orelse return Value.null_;
        return (try p.wrap(i)).asValue();
    }

    // ------------------------------------------------------- scripts

    /// Run the document's `<script>` elements in document order (the
    /// classic, parser-inserted ones: inline text or a fetched `src`),
    /// then fire `DOMContentLoaded` and `load`.
    pub fn runScripts(p: *Page) void {
        p.resetDoc();
        var list: std.ArrayList(NodeId) = .empty;
        defer list.deinit(p.a);
        var w = p.doc.walk(dom.document_id);
        while (w.next()) |id| if (p.doc.isHtml(id, "script")) list.append(p.a, id) catch return;
        // Classic scripts as the parser meets them; module scripts are
        // deferred, so they run after, in document order.
        for (list.items) |id| {
            p.resetDoc();
            if (!isModuleScript(p, id)) p.runScriptElement(id);
        }
        for (list.items) |id| {
            p.resetDoc();
            if (isModuleScript(p, id)) p.runScriptElement(id);
        }
        p.resetDoc();
        p.ready_state = .interactive;
        _ = p.fireSimple(p.document_obj.asValue(), "DOMContentLoaded", true, false);
        p.ready_state = .complete;
        _ = p.fireSimple(p.vm.global.asValue(), "load", false, false);
    }

    fn isModuleScript(p: *Page, id: NodeId) bool {
        const t = p.doc.getAttr(id, "type") orelse return false;
        return std.ascii.eqlIgnoreCase(std.mem.trim(u8, t, " \t\r\n"), "module");
    }

    fn runScriptElement(p: *Page, id: NodeId) void {
        p.resetDoc();
        const doc = p.doc;
        p.current_script = id;
        defer p.current_script = null;
        const module = isModuleScript(p, id);
        if (!module) if (doc.getAttr(id, "type")) |t| {
            const tt = std.mem.trim(u8, t, " \t\r\n");
            const classic = tt.len == 0 or std.ascii.eqlIgnoreCase(tt, "text/javascript") or std.ascii.eqlIgnoreCase(tt, "application/javascript") or std.ascii.eqlIgnoreCase(tt, "text/ecmascript") or std.ascii.eqlIgnoreCase(tt, "application/ecmascript");
            if (!classic) return;
        };
        if (doc.getAttr(id, "nomodule") != null) return;
        if (doc.getAttr(id, "src")) |src| {
            const fetch = p.host.fetch orelse {
                p.logf(.warn, "script: no way to fetch {s}", .{src});
                return;
            };
            var scratch = std.heap.ArenaAllocator.init(p.a);
            defer scratch.deinit();
            const sa = scratch.allocator();
            const base = url.parse(sa, p.url, null) catch null;
            const abs = blk: {
                const u = url.parse(sa, src, if (base) |*b| b else null) catch break :blk src;
                break :blk u.href(sa) catch src;
            };
            const text: []const u8 = if (url.decodeData(sa, abs) catch null) |d| d.bytes else (fetch(p.host.ctx, abs) orelse {
                p.logf(.err, "script: could not load {s}", .{abs});
                return;
            });
            if (module) p.runModule(text, abs) else p.runSource(text, abs);
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(p.a);
        defer scratch.deinit();
        const text = doc.textContent(id, scratch.allocator()) catch return;
        if (module) {
            // An inline module is named after the document, so its
            // imports resolve against it; a fragment keeps each distinct.
            p.modules_run += 1;
            const name = std.fmt.allocPrint(scratch.allocator(), "{s}#module{d}", .{ p.url, p.modules_run }) catch return;
            p.runModule(text, name);
        } else p.runSource(text, "inline script");
    }

    /// Run a module script: link its graph through the host loader,
    /// evaluate, and report how its promise settled.
    pub fn runModule(p: *Page, source: []const u8, name: []const u8) void {
        p.resetDoc();
        const vm = p.vm;
        p.scripts_run += 1;
        const promise = js.module.runEntry(vm, name, source) catch |e| {
            p.reportError(e, name);
            return;
        };
        p.runJobs();
        if (!promise.isObject()) return;
        const pd = Vm.asObject(promise).internal(js.vm.PromiseData);
        if (pd.state == 2) {
            vm.exception = pd.result;
            p.reportError(error.Exception, name);
        }
    }

    /// Compile and run one classic script; errors go to the log.
    pub fn runSource(p: *Page, source: []const u8, name: []const u8) void {
        p.resetDoc();
        const vm = p.vm;
        // The compile copies the source into the code (a function keeps
        // its text): no second copy here. Its scratch is the script
        // heap itself, in fixed chunks the heap gives back whole: the
        // page's layout stack held the document and the layout too, and
        // a big bundle's compile ran it out on the device (2026-09-28).
        vm.compile_scratch = null;
        const code = js.compiler.compile(vm.meta, &vm.heap, &vm.strings, source, .{ .name = name }) catch |e| switch (e) {
            error.OutOfMemory => {
                p.log(.err, "script: out of memory compiling");
                return;
            },
            error.SyntaxError => {
                p.script_errors += 1;
                p.logf(.err, "script: SyntaxError: {s} ({s})", .{ js.compiler.last_error, name });
                return;
            },
        };
        p.scripts_run += 1;
        if (p.verbose) {
            var t: CodeTally = .{};
            t.add(code);
            p.logf(.log, "script: compiled {s}: {d} KB of source; {d} functions, {d} instructions ({d} KB), {d} positions ({d} KB), {d} property sites ({d} KB), {d} global sites ({d} KB), {d} constants ({d} KB)", .{ name[0..@min(name.len, 100)], source.len / 1024, t.functions, t.insns, t.insns * @sizeOf(js.bytecode.Insn) / 1024, t.positions, t.positions * @sizeOf(js.bytecode.Position) / 1024, t.props, t.props * @sizeOf(js.bytecode.PropSite) / 1024, t.globals, t.globals * @sizeOf(js.bytecode.GlobalSite) / 1024, t.consts, t.consts * @sizeOf(Value) / 1024 });
        }
        _ = js.interp.runScript(vm, code, vm.global.asValue(), null, null, Value.undefined_) catch |e| p.reportError(e, name);
        p.runJobs();
    }

    /// What a compiled script holds, over every nested function.
    const CodeTally = struct {
        functions: usize = 0,
        insns: usize = 0,
        positions: usize = 0,
        props: usize = 0,
        globals: usize = 0,
        consts: usize = 0,
        fn add(t: *CodeTally, code: *js.bytecode.Code) void {
            t.functions += 1;
            t.insns += code.data.insns.len;
            t.positions += code.data.positions.len;
            t.props += code.data.props.len;
            t.globals += code.data.globals.len;
            t.consts += code.data.consts.len;
            for (code.data.functions) |f| t.add(f);
        }
    };

    /// A host's expression, run as a script: its completion value as
    /// text (an exception's text prefixed `error:`), or null when the
    /// source does not compile. For a headless render to ask the page
    /// what its scripts concluded.
    pub fn evalText(p: *Page, source: []const u8, a: std.mem.Allocator) ?[]const u8 {
        p.resetDoc();
        const vm = p.vm;
        const code = js.compiler.compile(vm.meta, &vm.heap, &vm.strings, source, .{ .name = "eval" }) catch return null;
        const v = js.interp.runScript(vm, code, vm.global.asValue(), null, null, Value.undefined_) catch |e| switch (e) {
            error.OutOfMemory => return null,
            error.Exception => {
                var buf: [512]u8 = undefined;
                const text = p.exceptionText(&buf);
                p.vm.exception = Value.undefined_;
                return std.fmt.allocPrint(a, "error: {s}", .{text}) catch null;
            },
        };
        p.runJobs();
        return strArg(vm, v, a) catch null;
    }

    /// A module specifier through the page's import map: the entry
    /// whose key equals it, else the longest key ending in `/` that
    /// prefixes it (the rest appended to the value); else unchanged.
    fn mapImport(p: *Page, spec: []const u8, a: std.mem.Allocator) Error![]const u8 {
        if (p.import_map == null) try p.readImportMap();
        const m = p.import_map.?;
        var best: ?usize = null;
        for (m.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.key, spec)) return e.value;
            if (e.key.len > 0 and e.key[e.key.len - 1] == '/' and std.mem.startsWith(u8, spec, e.key)) {
                if (best == null or e.key.len > m.items[best.?].key.len) best = i;
            }
        }
        if (best) |i| return try std.mem.concat(a, u8, &.{ m.items[i].value, spec[m.items[i].key.len..] });
        return spec;
    }

    /// `<script type="importmap">`'s `imports`, parsed once (every such
    /// script in the document counts; `scopes` are not read).
    fn readImportMap(p: *Page) Error!void {
        var list: std.ArrayList(ImportEntry) = .empty;
        errdefer list.deinit(p.a);
        var scratch = std.heap.ArenaAllocator.init(p.a);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const doc = p.docs.items[0].doc;
        var w = doc.walk(dom.document_id);
        while (w.next()) |id| {
            if (!doc.isHtml(id, "script")) continue;
            const t = doc.getAttr(id, "type") orelse continue;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, t, " "), "importmap")) continue;
            const text = doc.textContent(id, sa) catch continue;
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, sa, text, .{}) catch continue;
            if (parsed != .object) continue;
            const imports = parsed.object.get("imports") orelse continue;
            if (imports != .object) continue;
            var it = imports.object.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* != .string) continue;
                try list.append(p.a, .{ .key = try p.a.dupe(u8, e.key_ptr.*), .value = try p.a.dupe(u8, e.value_ptr.string) });
            }
        }
        p.import_map = list;
    }

    /// The host's scratch for heavy transient work (a compile, a frame's
    /// cascade), else the page's own allocator.
    pub fn scratchBase(p: *Page) std.mem.Allocator {
        return if (p.host.scratch) |f| f(p.host.ctx) else p.a;
    }

    fn runJobs(p: *Page) void {
        p.vm.runJobs() catch |e| p.reportError(e, "a promise job");
    }

    fn reportError(p: *Page, e: Error, where: []const u8) void {
        switch (e) {
            error.OutOfMemory => p.logf(.err, "script: out of memory ({s}; cells {d} KB live of {d})", .{ if (p.vm.heap.exhausted) "the cell heap is full" else "the bookkeeping heap is full", p.vm.heap.live_bytes / 1024, p.vm.heap.region.len / 1024 }),
            error.Exception => {
                p.script_errors += 1;
                var buf: [512]u8 = undefined;
                const text = p.exceptionText(&buf);
                p.vm.exception = Value.undefined_;
                p.logf(.err, "script: uncaught {s} ({s})", .{ text, where });
            },
        }
    }

    fn exceptionText(p: *Page, buf: []u8) []const u8 {
        const vm = p.vm;
        const ex = vm.exception;
        // An Error: "Name: message" and its stack line if present, then
        // the throw site — script:line:col and the source around it —
        // which is what names the missing member on a real site.
        var text: []const u8 = undefined;
        if (ex.isObject()) {
            const o = Vm.asObject(ex);
            const stack = vm.get(o, .{ .atom = vm.atom("stack") catch return "exception" }, ex) catch Value.undefined_;
            if (stack.isString()) {
                text = js.builtins.utf8Buf(vm, Vm.asString(stack), buf) catch return "exception";
            } else {
                const s = vm.toString(ex) catch return "exception";
                text = js.builtins.utf8Buf(vm, s, buf) catch return "exception";
            }
            if (o.class == .error_) if (throwSite(o, buf[text.len..])) |site| return buf[0 .. text.len + site.len];
            return text;
        }
        const s = vm.toString(ex) catch return "exception";
        return js.builtins.utf8Buf(vm, s, buf) catch "exception";
    }

    /// " at NAME:LINE:COL «source»" for an Error made while code ran.
    fn throwSite(o: *Object, buf: []u8) ?[]const u8 {
        const ed = o.internal(js.vm.ErrorData);
        const code = ed.code orelse return null;
        const src = code.data.source orelse return null;
        const pos: usize = @min(ed.pos, src.text.len);
        var line: usize = 1;
        var col: usize = 1;
        for (src.text[0..pos]) |ch| {
            if (ch == '\n') {
                line += 1;
                col = 1;
            } else col += 1;
        }
        const from = pos -| 60;
        const to = @min(src.text.len, pos + 60);
        var snippet_buf: [128]u8 = undefined;
        var n: usize = 0;
        for (src.text[from..to]) |ch| {
            if (n >= snippet_buf.len) break;
            snippet_buf[n] = if (ch == '\n' or ch == '\r' or ch == '\t') ' ' else ch;
            n += 1;
        }
        return std.fmt.bufPrint(buf, " at {s}:{d}:{d} «{s}»", .{ src.name[0..@min(src.name.len, 80)], line, col, snippet_buf[0..n] }) catch null;
    }

    pub fn log(p: *Page, level: Level, text: []const u8) void {
        p.host.log(p.host.ctx, level, text);
    }

    pub fn logf(p: *Page, level: Level, comptime fmt: []const u8, args: anytype) void {
        // A line too long is cut, not replaced by its format string.
        var buf: [1536]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print(fmt, args) catch {};
        p.log(level, w.buffered());
    }

    // -------------------------------------------------------- events

    /// A new event object of `iface` with `type`.
    fn newEvent(p: *Page, iface: usize, type_name: []const u8, bubbles: bool, cancelable: bool, trusted: bool) Error!*Object {
        const vm = p.vm;
        const o = try vm.objects.create(p.protos[iface].asValue(), .dom, @sizeOf(Slot));
        var flags: u32 = 0;
        if (bubbles) flags |= ev_bubbles;
        if (cancelable) flags |= ev_cancelable;
        if (trusted) flags |= ev_trusted;
        o.internal(Slot).* = .{ .kind = slot_event, .id = 0, .flags = flags };
        try p.setEventProp(o, "type", try vm.str(type_name));
        try p.setEventProp(o, "target", Value.null_);
        try p.setEventProp(o, "currentTarget", Value.null_);
        try p.setEventProp(o, "eventPhase", Value.fromInt(0));
        try p.setEventProp(o, "timeStamp", Value.fromF64(p.now()));
        return o;
    }

    fn setEventProp(p: *Page, o: *Object, name: []const u8, v: Value) Error!void {
        _ = try p.vm.objects.defineOwnForce(o, .{ .atom = try p.vm.atom(name) }, v, .{ .writable = false, .enumerable = true, .configurable = true });
    }

    /// Fire a plain event at a target; true when its default was not
    /// prevented.
    pub fn fireSimple(p: *Page, target: Value, type_name: []const u8, bubbles: bool, cancelable: bool) bool {
        const ev = p.newEvent(I.event, type_name, bubbles, cancelable, true) catch return true;
        return p.dispatch(target, ev) catch |e| {
            p.reportError(e, type_name);
            return true;
        };
    }

    /// A user's click on `id` (the page's pointer landed): the `click`
    /// event through the tree; false when a listener prevented the
    /// default (the link should not be followed, the box not toggled).
    pub fn click(p: *Page, id: NodeId) bool {
        p.resetDoc();
        return p.clickHere(id);
    }

    /// `click` on a node of the current document (a script's `el.click()`).
    fn clickHere(p: *Page, id: NodeId) bool {
        const target = p.wrapValue(id) catch return true;
        const ev = p.newEvent(I.mouse_event, "click", true, true, true) catch return true;
        p.setEventProp(ev, "button", Value.fromInt(0)) catch {};
        p.setEventProp(ev, "buttons", Value.fromInt(0)) catch {};
        p.setEventProp(ev, "detail", Value.fromInt(1)) catch {};
        const ok = p.dispatch(target, ev) catch |e| {
            p.reportError(e, "click");
            return true;
        };
        p.runJobs();
        return ok;
    }

    /// The user submitted a form (a button, Enter in a field): the
    /// `submit` event; false when a listener prevented it.
    pub fn fireSubmit(p: *Page, form: NodeId) bool {
        p.resetDoc();
        return p.submitHere(form);
    }

    fn submitHere(p: *Page, form: NodeId) bool {
        const target = p.wrapValue(form) catch return true;
        return p.fireSimple(target, "submit", true, true);
    }

    /// The user typed into a control, or toggled one.
    pub fn fireInput(p: *Page, id: NodeId) void {
        p.resetDoc();
        const target = p.wrapValue(id) catch return;
        _ = p.fireSimple(target, "input", true, false);
        p.runJobs();
    }

    pub fn fireChange(p: *Page, id: NodeId) void {
        p.resetDoc();
        p.changeHere(id);
        p.runJobs();
    }

    /// `input` then `change` at a control in the current document (a
    /// script's click() on a box or radio; no reset, no job run).
    fn changeHere(p: *Page, id: NodeId) void {
        const target = p.wrapValue(id) catch return;
        _ = p.fireSimple(target, "input", true, false);
        _ = p.fireSimple(target, "change", true, false);
    }

    /// The user pressed a key: `keydown` at the focused element (else
    /// the body), `keypress` for a character, `keyup`. False when a
    /// listener prevented the default — the page should then neither
    /// type, move focus nor scroll for it. `keyFromByte` names a plain
    /// byte; the page names its own codes with `keyNamed`.
    pub fn fireKey(p: *Page, focus: ?NodeId, k: KeyInfo) bool {
        p.resetDoc();
        const target_id: NodeId = focus orelse bodyOrDocument(p);
        const target = p.wrapValue(target_id) catch return true;
        var ok = p.fireKeyEvent(target, "keydown", k, true);
        if (ok and k.printable) ok = p.fireKeyEvent(target, "keypress", k, true);
        _ = p.fireKeyEvent(target, "keyup", k, false);
        p.runJobs();
        return ok;
    }

    fn fireKeyEvent(p: *Page, target: Value, name: []const u8, k: KeyInfo, cancelable: bool) bool {
        const vm = p.vm;
        const ev = p.newEvent(I.keyboard_event, name, true, cancelable, true) catch return true;
        const props = [_]struct { n: []const u8, v: Value }{
            .{ .n = "key", .v = vm.str(k.key) catch return true },
            .{ .n = "code", .v = vm.str(k.code) catch return true },
            .{ .n = "keyCode", .v = Value.fromInt(k.key_code) },
            .{ .n = "which", .v = Value.fromInt(k.key_code) },
            .{ .n = "charCode", .v = Value.fromInt(if (std.mem.eql(u8, name, "keypress")) k.char_code else 0) },
            .{ .n = "altKey", .v = Value.false_ },
            .{ .n = "ctrlKey", .v = Value.false_ },
            .{ .n = "metaKey", .v = Value.false_ },
            .{ .n = "shiftKey", .v = Value.fromBool(k.shift) },
            .{ .n = "repeat", .v = Value.false_ },
            .{ .n = "isComposing", .v = Value.false_ },
            .{ .n = "location", .v = Value.fromInt(0) },
        };
        for (props) |pr| p.setEventProp(ev, pr.n, pr.v) catch return true;
        return p.dispatch(target, ev) catch |e| {
            p.reportError(e, name);
            return true;
        };
    }

    /// Whether any listener anywhere could care about a click: the
    /// embedder may skip the dispatch when none does.
    pub fn hasListeners(p: *Page) bool {
        return p.wrappers.count() > 1;
    }

    /// DOM Events dispatch: capture down the path, the target, bubble
    /// up. Returns !defaultPrevented.
    pub fn dispatch(p: *Page, target: Value, ev: *Object) Error!bool {
        const vm = p.vm;
        if (docOfValue(target)) |d| p.switchTo(d);
        const slot = ev.internal(Slot);
        if (slot.flags & ev_dispatching != 0) return vm.throwTypeError("the event is already being dispatched");
        slot.flags |= ev_dispatching;
        slot.flags &= ~(ev_stop | ev_stop_immediate);
        defer {
            slot.flags &= ~ev_dispatching;
            p.setEventProp(ev, "eventPhase", Value.fromInt(0)) catch {};
            p.setEventProp(ev, "currentTarget", Value.null_) catch {};
        }
        const mark = vm.heap.tempMark();
        defer vm.heap.tempRelease(mark);
        vm.heap.tempPush(ev.cell());
        try p.setEventProp(ev, "target", target);
        // The path: the target, its ancestors' wrappers, the window.
        var path: std.ArrayList(Value) = .empty;
        defer path.deinit(p.a);
        try path.append(p.a, target);
        if (p.nodeOfValue(target)) |id| {
            var cur = p.doc.get(id).parent;
            while (cur) |c| : (cur = p.doc.get(c).parent) if (p.wrappers.get(p.key(c))) |o| try path.append(p.a, o.asValue());
            if (p.cur == 0) try path.append(p.a, vm.global.asValue());
        }
        const bubbles = slot.flags & ev_bubbles != 0;
        // Capture: from the window down to the target's parent.
        var i: usize = path.items.len;
        while (i > 1) : (i -= 1) {
            if (slot.flags & ev_stop != 0) break;
            try p.setEventProp(ev, "eventPhase", Value.fromInt(1));
            try p.invokeListeners(path.items[i - 1], ev, true);
        }
        if (slot.flags & ev_stop == 0) {
            try p.setEventProp(ev, "eventPhase", Value.fromInt(2));
            try p.invokeListeners(target, ev, true);
            if (slot.flags & ev_stop == 0) try p.invokeListeners(target, ev, false);
        }
        if (bubbles) {
            i = 1;
            while (i < path.items.len) : (i += 1) {
                if (slot.flags & ev_stop != 0) break;
                try p.setEventProp(ev, "eventPhase", Value.fromInt(3));
                try p.invokeListeners(path.items[i], ev, false);
            }
        }
        return slot.flags & ev_canceled == 0;
    }

    /// The listener list of an object: a flat array of (type, callback,
    /// flags) triples under a symbol, made on first use.
    fn listenerList(p: *Page, o: *Object, create: bool) Error!?*Object {
        const vm = p.vm;
        if (try vm.objects.getOwn(o, .{ .symbol = p.sym_listeners })) |own| {
            if (own.val.isObject()) return Vm.asObject(own.val);
        }
        if (!create) return null;
        const arr = try vm.newArray(0);
        _ = try vm.objects.defineOwn(o, .{ .symbol = p.sym_listeners }, arr.asValue(), .hidden);
        return arr;
    }

    const flag_capture: i32 = 1;
    const flag_once: i32 = 2;
    const flag_passive: i32 = 4;

    /// The `on<type>` handler of a target: a function a script set on
    /// the object (`el.onclick = f`), else the element's `on<type>`
    /// attribute compiled once into a function of `event` (cached on
    /// the wrapper under the attribute's text); the body's `onload`
    /// answers for the window's `load`. A handler returning false
    /// prevents the default.
    fn invokeHandlerAttribute(p: *Page, target: Value, ev: *Object, type_name: []const u8) Error!void {
        const vm = p.vm;
        if (!target.isObject()) return;
        var o = Vm.asObject(target);
        var node_id: ?NodeId = p.nodeOfValue(target);
        if (o == vm.global) {
            // The window's handlers live on the body element in markup.
            if (node_id == null and (std.mem.eql(u8, type_name, "load") or std.mem.eql(u8, type_name, "unload") or std.mem.eql(u8, type_name, "error"))) {
                const b = bodyOrDocument(p);
                if (b != dom.document_id) node_id = b;
            }
        }
        var name_buf: [64]u8 = undefined;
        const prop = std.fmt.bufPrint(&name_buf, "on{s}", .{type_name}) catch return;
        var handler = Value.undefined_;
        if (try vm.objects.getOwn(o, .{ .atom = try vm.atom(prop) })) |own| handler = own.val;
        if (!vm.isCallable(handler)) if (node_id) |id| {
            if (p.doc.get(id).kind == .element) if (p.doc.getAttr(id, prop)) |text| {
                // Compiled once per attribute text, on the element's wrapper.
                const w = try p.wrap(id);
                o = w;
                const cache_key = try std.fmt.allocPrint(vm.meta, "__h_{s}", .{prop});
                defer vm.meta.free(cache_key);
                var cached = Value.undefined_;
                if (try vm.objects.getOwn(w, .{ .atom = try vm.atom(cache_key) })) |own| cached = own.val;
                var stale = true;
                if (cached.isObject()) {
                    const src = try vm.get(Vm.asObject(cached), .{ .atom = try vm.atom("src") }, cached);
                    if (src.isString()) {
                        var buf: [4096]u8 = undefined;
                        const t = js.builtins.utf8Buf(vm, Vm.asString(src), &buf) catch "";
                        stale = !std.mem.eql(u8, t, text);
                    }
                    if (!stale) handler = try vm.get(Vm.asObject(cached), .{ .atom = try vm.atom("fn") }, cached);
                }
                if (stale) {
                    const source = try std.fmt.allocPrint(vm.meta, "(function (event) {{\n{s}\n}})", .{text});
                    defer vm.meta.free(source);
                    handler = p.evalSource(source) catch Value.undefined_;
                    if (vm.isCallable(handler)) {
                        const rec = try vm.newObject();
                        try vm.defineValue(rec, "src", try vm.str(text), .default);
                        try vm.defineValue(rec, "fn", handler, .default);
                        _ = try vm.objects.defineOwn(w, .{ .atom = try vm.atom(cache_key) }, rec.asValue(), .hidden);
                    }
                }
            };
        };
        if (!vm.isCallable(handler)) return;
        const this_v = if (node_id) |id| try p.wrapValue(id) else target;
        const r = vm.call(handler, this_v, &.{ev.asValue()}) catch |e| switch (e) {
            error.OutOfMemory => return e,
            error.Exception => {
                var buf: [512]u8 = undefined;
                const t = p.exceptionText(&buf);
                vm.exception = Value.undefined_;
                p.script_errors += 1;
                p.logf(.err, "script: uncaught {s} (in {s})", .{ t, prop });
                return;
            },
        };
        if (r.isBool() and !r.asBool()) {
            const s = ev.internal(Slot);
            if (s.flags & ev_cancelable != 0) s.flags |= ev_canceled;
        }
    }

    /// Compile and run an expression source, for a handler attribute;
    /// the value of the script (its last expression).
    fn evalSource(p: *Page, source: []const u8) Error!Value {
        const vm = p.vm;
        const code = js.compiler.compile(vm.meta, &vm.heap, &vm.strings, source, .{ .name = "an event handler attribute" }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SyntaxError => {
                p.script_errors += 1;
                p.logf(.err, "script: SyntaxError: {s} (in an event handler attribute)", .{js.compiler.last_error});
                return Value.undefined_;
            },
        };
        return js.interp.runScript(vm, code, vm.global.asValue(), null, null, Value.undefined_);
    }

    fn invokeListeners(p: *Page, target: Value, ev: *Object, capture: bool) Error!void {
        const vm = p.vm;
        if (!target.isObject()) return;
        const o = Vm.asObject(target);
        if (!capture) {
            const slot = ev.internal(Slot);
            if (slot.flags & ev_stop_immediate == 0) {
                var tbuf: [64]u8 = undefined;
                const tv = try vm.get(ev, .{ .atom = try vm.atom("type") }, ev.asValue());
                if (tv.isString()) {
                    if (js.builtins.utf8Buf(vm, Vm.asString(tv), &tbuf)) |tn| {
                        try p.setEventProp(ev, "currentTarget", target);
                        try p.invokeHandlerAttribute(target, ev, tn);
                    } else |_| {}
                }
            }
        }
        const list = (try p.listenerList(o, false)) orelse return;
        // A snapshot: listeners added during dispatch do not run now.
        var snap: std.ArrayList(Value) = .empty;
        defer snap.deinit(p.a);
        try vm.listFromArrayLike(list.asValue(), &snap);
        // The snapshot's cells are rooted for the calls (a listener may
        // remove another, and the collector may run inside a listener).
        const snap_mark = vm.heap.tempMark();
        defer vm.heap.tempRelease(snap_mark);
        for (snap.items) |v| if (v.isCell()) vm.heap.tempPush(v.asCell());
        const type_v = try vm.get(ev, .{ .atom = try vm.atom("type") }, ev.asValue());
        const slot = ev.internal(Slot);
        var k: usize = 0;
        while (k + 2 < snap.items.len) : (k += 3) {
            if (slot.flags & ev_stop_immediate != 0) break;
            const flags: i32 = if (snap.items[k + 2].isNumber()) @intFromFloat(snap.items[k + 2].asNumber()) else 0;
            if (((flags & flag_capture) != 0) != capture) continue;
            if (!vm.isStrictlyEqual(snap.items[k], type_v)) continue;
            const cb = snap.items[k + 1];
            // Still registered? (removed during this dispatch = skipped)
            if (!try p.hasListener(list, snap.items[k], cb, flags)) continue;
            if (flags & flag_once != 0) try p.removeListener(list, snap.items[k], cb, flags);
            try p.setEventProp(ev, "currentTarget", target);
            const r: Error!Value = if (vm.isCallable(cb)) vm.callRooted(cb, target, &.{ev.asValue()}) else blk: {
                if (!cb.isObject()) break :blk Value.undefined_;
                const h = try vm.get(Vm.asObject(cb), .{ .atom = try vm.atom("handleEvent") }, cb);
                if (!vm.isCallable(h)) break :blk Value.undefined_;
                if (h.isCell()) vm.heap.tempPush(h.asCell());
                break :blk vm.callRooted(h, cb, &.{ev.asValue()});
            };
            _ = r catch |e| switch (e) {
                error.OutOfMemory => return e,
                error.Exception => {
                    var buf: [512]u8 = undefined;
                    const text = p.exceptionText(&buf);
                    vm.exception = Value.undefined_;
                    p.script_errors += 1;
                    p.logf(.err, "script: uncaught {s} (in a listener)", .{text});
                },
            };
        }
    }

    fn hasListener(p: *Page, list: *Object, type_v: Value, cb: Value, flags: i32) Error!bool {
        const vm = p.vm;
        const n = Vm.arrayLength(list);
        var k: u32 = 0;
        while (k + 2 < n) : (k += 3) {
            const t = try vm.get(list, .{ .index = k }, list.asValue());
            const c = try vm.get(list, .{ .index = k + 1 }, list.asValue());
            const f = try vm.get(list, .{ .index = k + 2 }, list.asValue());
            const ff: i32 = if (f.isNumber()) @intFromFloat(f.asNumber()) else 0;
            if (vm.isStrictlyEqual(t, type_v) and vm.isStrictlyEqual(c, cb) and (ff & flag_capture) == (flags & flag_capture)) return true;
        }
        return false;
    }

    fn removeListener(p: *Page, list: *Object, type_v: Value, cb: Value, flags: i32) Error!void {
        const vm = p.vm;
        var items: std.ArrayList(Value) = .empty;
        defer items.deinit(p.a);
        try vm.listFromArrayLike(list.asValue(), &items);
        var out: std.ArrayList(Value) = .empty;
        defer out.deinit(p.a);
        var k: usize = 0;
        while (k + 2 < items.items.len) : (k += 3) {
            const ff: i32 = if (items.items[k + 2].isNumber()) @intFromFloat(items.items[k + 2].asNumber()) else 0;
            const same = vm.isStrictlyEqual(items.items[k], type_v) and vm.isStrictlyEqual(items.items[k + 1], cb) and (ff & flag_capture) == (flags & flag_capture);
            if (same) continue;
            try out.appendSlice(p.a, items.items[k .. k + 3]);
        }
        // Rewrite in place.
        _ = try vm.set(list, .{ .atom = vm.atoms.length }, Value.fromInt(0), list.asValue());
        for (out.items) |v| try vm.arrayPush(list, v);
    }

    // -------------------------------------------------------- timers

    /// Run every timer and animation frame due at `now_ms`, in order;
    /// true when any ran. Microtasks run after each.
    pub fn runDue(p: *Page, now_ms: f64) bool {
        p.resetDoc();
        var ran = false;
        // Frames and pictures inserted since: loaded, then their `load`.
        while (p.pending_loads.items.len > 0) {
            const item = p.pending_loads.orderedRemove(0);
            ran = true;
            p.switchTo(item.doc);
            if (p.doc.get(item.id).kind != .element) continue;
            if (p.doc.isHtml(item.id, "iframe") or p.doc.isHtml(item.id, "object") or p.doc.isHtml(item.id, "frame")) {
                _ = p.frameDocument(item.id) catch {};
                p.switchTo(item.doc);
            }
            const target = p.wrapValue(item.id) catch continue;
            _ = p.fireSimple(target, "load", false, false);
            p.runJobs();
            p.resetDoc();
        }
        while (true) {
            // The earliest due timer, by (when, id).
            var best: ?usize = null;
            for (p.timers.items, 0..) |t, k| {
                if (t.when > now_ms) continue;
                if (best == null or t.when < p.timers.items[best.?].when or (t.when == p.timers.items[best.?].when and t.id < p.timers.items[best.?].id)) best = k;
            }
            const k = best orelse break;
            var t = p.timers.items[k];
            if (t.interval) |iv| {
                p.timers.items[k].when = now_ms + iv;
            } else {
                _ = p.timers.orderedRemove(k);
            }
            ran = true;
            const vm = p.vm;
            const mark = vm.heap.tempMark();
            defer vm.heap.tempRelease(mark);
            if (t.func.isCell()) vm.heap.tempPush(t.func.asCell());
            if (t.raf) {
                t.args[0] = Value.fromF64(now_ms);
                t.argc = 1;
            }
            p.resetDoc();
            _ = vm.callRooted(t.func, vm.global.asValue(), t.args[0..t.argc]) catch |e| p.reportError(e, if (t.raf) "an animation frame" else "a timer");
            p.runJobs();
        }
        return ran;
    }

    /// When the next timer is due, or null with none pending.
    pub fn nextDue(p: *Page) ?f64 {
        if (p.pending_loads.items.len > 0) return p.now();
        var best: ?f64 = null;
        for (p.timers.items) |t| if (best == null or t.when < best.?) {
            best = t.when;
        };
        return best;
    }

    pub fn pendingTimers(p: *Page) usize {
        return p.timers.items.len;
    }

    fn addTimer(p: *Page, func: Value, args: []const Value, delay: f64, interval: bool, raf: bool) Error!Value {
        var t: Timer = .{ .id = p.next_timer, .when = p.now() + @max(0, delay), .interval = if (interval) @max(4, delay) else null, .func = func, .args = @splat(Value.undefined_), .argc = 0, .raf = raf };
        p.next_timer += 1;
        for (args, 0..) |a, k| if (k < 4) {
            t.args[k] = a;
            t.argc += 1;
        };
        try p.timers.append(p.a, t);
        return Value.fromInt(@intCast(t.id));
    }

    fn removeTimer(p: *Page, id: u32) void {
        for (p.timers.items, 0..) |t, k| if (t.id == id) {
            _ = p.timers.orderedRemove(k);
            return;
        };
    }

    // ----------------------------------------------------- utilities

    /// The node a wrapper value stands for, or null for anything else.
    /// The node a wrapper stands for, in the current document: a node of
    /// another of the page's documents is adopted — copied over, as the
    /// DOM adopts across documents (identity does not survive the copy).
    fn nodeOfValue(p: *Page, v: Value) ?NodeId {
        if (!v.isObject()) return null;
        const o = Vm.asObject(v);
        if (o.class != .dom) return null;
        const s = o.internal(Slot);
        if (s.kind != slot_node) return null;
        if (s.doc != p.cur) return null;
        return s.id;
    }

    /// A node argument that is going to be inserted: one of another of
    /// the page's documents is adopted — copied over, as the DOM adopts
    /// across documents (identity does not survive the copy).
    fn adoptArg(p: *Page, v: Value) ?NodeId {
        if (!v.isObject()) return null;
        const o = Vm.asObject(v);
        if (o.class != .dom) return null;
        const s = o.internal(Slot);
        if (s.kind != slot_node) return null;
        if (s.doc != p.cur) {
            if (s.doc >= p.docs.items.len) return null;
            const from = p.docs.items[s.doc].doc;
            // Detached from where it was, copied here; the wrapper follows
            // the copy, so the script's reference is the adopted node.
            if (from.get(s.id).parent != null) from.detach(s.id);
            const copy = adopt(p, from, s.id) catch return null;
            const old_key = (@as(u64, s.doc) << 32) | s.id;
            _ = p.wrappers.remove(old_key);
            s.doc = p.cur;
            s.id = copy;
            p.wrappers.put(p.a, p.key(copy), o) catch {};
            return copy;
        }
        return s.id;
    }

    /// A node argument the operation belongs to (a range's point, a
    /// traversal's root): the current document becomes the node's.
    fn nodeSwitching(p: *Page, v: Value) ?NodeId {
        if (!v.isObject()) return null;
        const o = Vm.asObject(v);
        if (o.class != .dom) return null;
        const s = o.internal(Slot);
        if (s.kind != slot_node) return null;
        p.switchTo(s.doc);
        return s.id;
    }

    /// The document index of a node wrapper, or null.
    fn docOfValue(v: Value) ?u32 {
        if (!v.isObject()) return null;
        const o = Vm.asObject(v);
        if (o.class != .dom) return null;
        return o.internal(Slot).doc;
    }

    /// Mark the DOM changed (the page's own document: the others are
    /// not laid out).
    fn touch(p: *Page) void {
        if (p.cur == 0) p.dirty = true;
    }

    fn markSheets(p: *Page) void {
        if (p.cur == 0) p.sheets_dirty = true;
    }

    // ---------------------------------------------- mutation records

    /// A mutation at `node`: every observer watching it (or, with
    /// `subtree`, an ancestor) for this kind gets a record, and the
    /// delivery microtask is queued once.
    fn notify(p: *Page, kind: MutationKind, node: NodeId, attr: ?[]const u8, added: []const NodeId, removed: []const NodeId) void {
        if (p.observers.items.len == 0) return;
        p.notifyInner(kind, node, attr, added, removed) catch {};
    }

    fn notifyInner(p: *Page, kind: MutationKind, node: NodeId, attr: ?[]const u8, added: []const NodeId, removed: []const NodeId) Error!void {
        const vm = p.vm;
        for (p.observers.items) |ob| {
            const wants = switch (kind) {
                .child_list => ob.child_list,
                .attributes => ob.attributes,
                .character_data => ob.character_data,
            };
            if (!wants) continue;
            if (ob.doc != p.cur) continue;
            if (ob.target != node and !(ob.subtree and isAncestor(p.doc, ob.target, node))) continue;
            const rec = try vm.newObject();
            const mark = vm.heap.tempMark();
            defer vm.heap.tempRelease(mark);
            vm.heap.tempPush(rec.cell());
            try vm.defineValue(rec, "type", try vm.str(switch (kind) {
                .child_list => "childList",
                .attributes => "attributes",
                .character_data => "characterData",
            }), .default);
            try vm.defineValue(rec, "target", try p.wrapValue(node), .default);
            try vm.defineValue(rec, "addedNodes", try nodeList(vm, added), .default);
            try vm.defineValue(rec, "removedNodes", try nodeList(vm, removed), .default);
            try vm.defineValue(rec, "attributeName", if (attr) |a| try vm.str(a) else Value.null_, .default);
            try vm.defineValue(rec, "attributeNamespace", Value.null_, .default);
            try vm.defineValue(rec, "oldValue", Value.null_, .default);
            try vm.defineValue(rec, "previousSibling", Value.null_, .default);
            try vm.defineValue(rec, "nextSibling", Value.null_, .default);
            try p.mutation_records.append(p.a, .{ .observer = ob.observer, .record = rec.asValue() });
        }
        if (p.mutation_records.items.len > 0 and !p.delivery_queued and p.deliver_fn.isObject()) {
            p.delivery_queued = true;
            try vm.jobs.append(vm.meta, .{ .func = p.deliver_fn, .args = .{ Value.undefined_, Value.undefined_, Value.undefined_ }, .argc = 0 });
        }
    }

    /// The records queued for `observer` (all of them with null), as an
    /// array, and gone from the queue.
    fn takeRecordsFor(p: *Page, observer: ?Value) Error!Value {
        const vm = p.vm;
        const arr = try vm.newArray(0);
        const mark = vm.heap.tempMark();
        defer vm.heap.tempRelease(mark);
        vm.heap.tempPush(arr.cell());
        var i: usize = 0;
        while (i < p.mutation_records.items.len) {
            const r = p.mutation_records.items[i];
            if (observer == null or vm.isStrictlyEqual(r.observer, observer.?)) {
                try vm.arrayPush(arr, r.record);
                _ = p.mutation_records.orderedRemove(i);
            } else i += 1;
        }
        return arr.asValue();
    }

    // ------------------------------------------- live ranges, iterators

    /// `count` children inserted into `parent` at `index`: boundary
    /// points in the parent past the index move by count.
    fn rangesOnInsert(p: *Page, parent: NodeId, index: usize, count: usize) void {
        const vm = p.vm;
        for (p.ranges.items) |rv| {
            const o = Vm.asObject(rv);
            if (o.internal(Slot).doc != p.cur) continue;
            var st = rangeState(vm, rv) catch continue;
            var changed = false;
            if (st.sc == parent and st.so > index) {
                st.so += count;
                changed = true;
            }
            if (st.ec == parent and st.eo > index) {
                st.eo += count;
                changed = true;
            }
            if (changed) setRangeState(vm, rv, st) catch {};
        }
    }

    /// `id` about to leave `parent`: points inside it go to its place;
    /// points in the parent past it move back by one. Iterators whose
    /// reference is inside it move as the DOM says.
    fn rangesOnRemove(p: *Page, id: NodeId, parent: NodeId) void {
        const vm = p.vm;
        const index = childIndex(p.doc, id);
        for (p.ranges.items) |rv| {
            const o = Vm.asObject(rv);
            if (o.internal(Slot).doc != p.cur) continue;
            var st = rangeState(vm, rv) catch continue;
            var changed = false;
            if (st.sc == id or isAncestor(p.doc, id, st.sc)) {
                st.sc = parent;
                st.so = index;
                changed = true;
            }
            if (st.ec == id or isAncestor(p.doc, id, st.ec)) {
                st.ec = parent;
                st.eo = index;
                changed = true;
            }
            if (st.sc == parent and st.so > index) {
                st.so -= 1;
                changed = true;
            }
            if (st.ec == parent and st.eo > index) {
                st.eo -= 1;
                changed = true;
            }
            if (changed) setRangeState(vm, rv, st) catch {};
        }
        for (p.iterators.items) |iv| {
            const o = Vm.asObject(iv);
            if (o.internal(Slot).doc != p.cur) continue;
            const ref_v = slotGet(vm, o, "__ref") catch continue;
            const ref = p.nodeOfValue(ref_v) orelse continue;
            if (!(ref == id or isAncestor(p.doc, id, ref))) continue;
            const root = o.internal(Slot).id;
            const before = vm.toBoolean(slotGet(vm, o, "__before") catch Value.false_);
            if (before) {
                // The next node after the removed subtree, if any.
                var next: ?NodeId = p.doc.get(id).next;
                var up = id;
                while (next == null) {
                    up = p.doc.get(up).parent orelse break;
                    if (up == root) break;
                    next = p.doc.get(up).next;
                }
                if (next) |n| {
                    slotSet(vm, o, "__ref", p.wrapValue(n) catch continue) catch {};
                    continue;
                }
                slotSet(vm, o, "__before", Value.false_) catch {};
            }
            const target: NodeId = if (p.doc.get(id).prev) |s| lastDescendant(p.doc, s) else parent;
            slotSet(vm, o, "__ref", p.wrapValue(target) catch continue) catch {};
        }
    }

    /// Data replaced in a node: points after the replaced run move.
    fn rangesOnReplaceData(p: *Page, id: NodeId, offset: usize, count: usize, new_len: usize) void {
        const vm = p.vm;
        for (p.ranges.items) |rv| {
            const o = Vm.asObject(rv);
            if (o.internal(Slot).doc != p.cur) continue;
            var st = rangeState(vm, rv) catch continue;
            var changed = false;
            if (st.sc == id) {
                if (st.so > offset and st.so <= offset + count) {
                    st.so = offset;
                    changed = true;
                } else if (st.so > offset + count) {
                    st.so = st.so - count + new_len;
                    changed = true;
                }
            }
            if (st.ec == id) {
                if (st.eo > offset and st.eo <= offset + count) {
                    st.eo = offset;
                    changed = true;
                } else if (st.eo > offset + count) {
                    st.eo = st.eo - count + new_len;
                    changed = true;
                }
            }
            if (changed) setRangeState(vm, rv, st) catch {};
        }
    }

    /// The DOM primitives, with the observers told.
    fn setAttr(p: *Page, id: NodeId, name: []const u8, value: []const u8) Error!void {
        if (p.doc.isHtml(id, "link") or p.doc.isHtml(id, "style")) p.markSheets();
        try p.doc.setAttr(id, name, value);
        p.touch();
        p.notify(.attributes, id, name, &.{}, &.{});
    }

    fn removeAttr(p: *Page, id: NodeId, name: []const u8) void {
        if (!p.doc.hasAttr(id, name)) return;
        if (p.doc.isHtml(id, "link") or p.doc.isHtml(id, "style")) p.markSheets();
        p.doc.removeAttr(id, name);
        p.touch();
        p.notify(.attributes, id, name, &.{}, &.{});
    }

    fn detachNode(p: *Page, id: NodeId) void {
        const parent = p.doc.get(id).parent orelse return;
        if (p.touchesSheets(id)) p.markSheets();
        p.rangesOnRemove(id, parent);
        p.doc.detach(id);
        p.touch();
        p.notify(.child_list, parent, null, &.{}, &.{id});
    }

    fn setText(p: *Page, id: NodeId, text: []const u8) Error!void {
        const n = p.doc.node(id);
        if (n.parent) |par| if (p.doc.isHtml(par, "style")) {
            p.markSheets();
        };
        n.text.clearRetainingCapacity();
        try n.text.appendSlice(p.doc.a, text);
        p.touch();
        p.notify(.character_data, id, null, &.{}, &.{});
    }
};

/// The delivery microtask: every observer with records gets its callback
/// called once with them.
fn deliverMutations(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    p.delivery_queued = false;
    while (p.mutation_records.items.len > 0) {
        const observer = p.mutation_records.items[0].observer;
        const records = try p.takeRecordsFor(observer);
        const mark = vm.heap.tempMark();
        defer vm.heap.tempRelease(mark);
        if (records.isCell()) vm.heap.tempPush(records.asCell());
        const cb = try vm.get(Vm.asObject(observer), .{ .atom = try vm.atom("__callback") }, observer);
        if (cb.isCell()) vm.heap.tempPush(cb.asCell());
        if (vm.isCallable(cb)) _ = vm.callRooted(cb, observer, &.{ records, observer }) catch |e| p.reportError(e, "a MutationObserver callback");
    }
    return Value.undefined_;
}

fn thisObserver(vm: *Vm, this: Value) Error!*Object {
    if (this.isObject()) {
        const o = Vm.asObject(this);
        if ((try vm.objects.getOwn(o, .{ .atom = try vm.atom("__callback") })) != null) return o;
    }
    return vm.throwTypeError("Illegal invocation");
}

fn moObserve(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const o = try thisObserver(vm, this);
    const target = p.nodeSwitching(arg(args, 0)) orelse return vm.throwTypeError("observe needs a node");
    var ob: Observation = .{ .observer = o.asValue(), .doc = p.cur, .target = target, .child_list = false, .attributes = false, .character_data = false, .subtree = false };
    const opts = arg(args, 1);
    if (opts.isObject()) {
        const oo = Vm.asObject(opts);
        ob.child_list = vm.toBoolean(try vm.get(oo, .{ .atom = try vm.atom("childList") }, opts));
        ob.attributes = vm.toBoolean(try vm.get(oo, .{ .atom = try vm.atom("attributes") }, opts)) or !(try vm.get(oo, .{ .atom = try vm.atom("attributeFilter") }, opts)).isUndefined() or !(try vm.get(oo, .{ .atom = try vm.atom("attributeOldValue") }, opts)).isUndefined();
        ob.character_data = vm.toBoolean(try vm.get(oo, .{ .atom = try vm.atom("characterData") }, opts)) or !(try vm.get(oo, .{ .atom = try vm.atom("characterDataOldValue") }, opts)).isUndefined();
        ob.subtree = vm.toBoolean(try vm.get(oo, .{ .atom = try vm.atom("subtree") }, opts));
    }
    if (!ob.child_list and !ob.attributes and !ob.character_data) return vm.throwTypeError("observe needs childList, attributes or characterData");
    // One observation per (observer, target): the newer options win.
    for (p.observers.items) |*x| if (vm.isStrictlyEqual(x.observer, ob.observer) and x.target == target and x.doc == ob.doc) {
        x.* = ob;
        return Value.undefined_;
    };
    try p.observers.append(p.a, ob);
    return Value.undefined_;
}

fn moDisconnect(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const o = try thisObserver(vm, this);
    var i: usize = 0;
    while (i < p.observers.items.len) {
        if (vm.isStrictlyEqual(p.observers.items[i].observer, o.asValue())) _ = p.observers.swapRemove(i) else i += 1;
    }
    _ = try p.takeRecordsFor(o.asValue());
    return Value.undefined_;
}

fn moTakeRecords(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const o = try thisObserver(vm, this);
    return p.takeRecordsFor(o.asValue());
}

// ------------------------------------------------------------ helpers

/// What a key press is to the DOM: its `key`, `code` and `keyCode`.
pub const KeyInfo = struct { key: []const u8, code: []const u8, key_code: i32, char_code: i32 = 0, printable: bool = false, shift: bool = false };

/// A named key (an arrow, Home): `key` and `code` the DOM's names,
/// `key_code` the legacy number.
pub fn keyNamed(name: []const u8, key_code: i32, shift: bool) KeyInfo {
    return .{ .key = name, .code = name, .key_code = key_code, .shift = shift };
}

/// A plain byte as the DOM sees it (Enter, Tab, Backspace, Escape,
/// the printable ASCII; anything else is unidentified).
pub fn keyFromByte(ch: u8) KeyInfo {
    return switch (ch) {
        '\n', '\r' => .{ .key = "Enter", .code = "Enter", .key_code = 13, .char_code = 13, .printable = true },
        '\t' => .{ .key = "Tab", .code = "Tab", .key_code = 9 },
        8, 127 => .{ .key = "Backspace", .code = "Backspace", .key_code = 8 },
        27 => .{ .key = "Escape", .code = "Escape", .key_code = 27 },
        ' ' => .{ .key = " ", .code = "Space", .key_code = 32, .char_code = 32, .printable = true },
        else => if (ch >= 0x20 and ch < 0x7f) printableKey(ch) else .{ .key = "Unidentified", .code = "Unidentified", .key_code = 0 },
    };
}

/// The printable ASCII keys, with the usual `code` names.
fn printableKey(ch: u8) KeyInfo {
    const upper = std.ascii.toUpper(ch);
    if (std.ascii.isAlphabetic(ch)) {
        const i = upper - 'A';
        return .{ .key = key_names[ch], .code = letter_codes[i], .key_code = upper, .char_code = ch, .printable = true, .shift = std.ascii.isUpper(ch) };
    }
    if (std.ascii.isDigit(ch)) {
        const i = ch - '0';
        return .{ .key = key_names[ch], .code = digit_codes[i], .key_code = ch, .char_code = ch, .printable = true };
    }
    return .{ .key = key_names[ch], .code = "Unidentified", .key_code = ch, .char_code = ch, .printable = true };
}

/// One-character strings for every printable byte, so `key` needs no
/// allocation.
const key_names: [128][]const u8 = blk: {
    var names: [128][]const u8 = undefined;
    for (0..128) |i| {
        const s: [1]u8 = .{@intCast(i)};
        const final = s;
        names[i] = &final;
    }
    break :blk names;
};
const letter_codes = [_][]const u8{ "KeyA", "KeyB", "KeyC", "KeyD", "KeyE", "KeyF", "KeyG", "KeyH", "KeyI", "KeyJ", "KeyK", "KeyL", "KeyM", "KeyN", "KeyO", "KeyP", "KeyQ", "KeyR", "KeyS", "KeyT", "KeyU", "KeyV", "KeyW", "KeyX", "KeyY", "KeyZ" };
const digit_codes = [_][]const u8{ "Digit0", "Digit1", "Digit2", "Digit3", "Digit4", "Digit5", "Digit6", "Digit7", "Digit8", "Digit9" };

fn bodyOrDocument(p: *Page) NodeId {
    var c = p.doc.get(dom.document_id).first_child;
    while (c) |cid| : (c = p.doc.get(cid).next) if (p.doc.isHtml(cid, "html")) {
        if (childElementNamed(p, cid, "body")) |b| return b;
    };
    return dom.document_id;
}

inline fn pageOf(vm: *Vm) *Page {
    return @ptrCast(@alignCast(vm.host_data.?));
}

fn arg(args: []const Value, i: usize) Value {
    return if (i < args.len) args[i] else Value.undefined_;
}

/// `this` as a node, or a TypeError.
fn thisNode(vm: *Vm, this: Value) Error!NodeId {
    const p = pageOf(vm);
    if (this.isObject()) {
        const o = Vm.asObject(this);
        if (o.class == .dom and o.internal(Slot).kind == slot_node) {
            p.switchTo(o.internal(Slot).doc);
            return o.internal(Slot).id;
        }
    }
    return vm.throwTypeError("Illegal invocation");
}

/// `this` as its node record (the document switched first: a receiver
/// read before the call would be the old document's).
fn thisNodeRec(vm: *Vm, this: Value) Error!*const dom.Node {
    const id = try thisNode(vm, this);
    return pageOf(vm).doc.get(id);
}

fn thisElement(vm: *Vm, this: Value) Error!NodeId {
    const id = try thisNode(vm, this);
    if (pageOf(vm).doc.get(id).kind != .element) return vm.throwTypeError("Illegal invocation");
    return id;
}

/// An event object, or a TypeError.
fn thisEvent(vm: *Vm, this: Value) Error!*Object {
    if (this.isObject()) {
        const o = Vm.asObject(this);
        if (o.class == .dom and o.internal(Slot).kind == slot_event) return o;
    }
    return vm.throwTypeError("Illegal invocation");
}

/// A string argument as UTF-8 in `a` (the caller's scratch).
fn strArg(vm: *Vm, v: Value, a: std.mem.Allocator) Error![]u8 {
    const s = try vm.toString(v);
    return vm.utf8(s, a);
}

/// A string argument copied into the document's arena (it will be
/// kept by a node).
fn docStr(vm: *Vm, v: Value) Error![]u8 {
    return strArg(vm, v, pageOf(vm).doc.a);
}

fn jsStr(vm: *Vm, text: []const u8) Error!Value {
    return vm.str(text);
}

fn attrKey(vm: *Vm, v: Value, a: std.mem.Allocator) Error![]u8 {
    const s = try strArg(vm, v, a);
    // HTML attribute names are case-insensitive: lowercased, as the
    // parser stores them.
    for (s) |*c| c.* = std.ascii.toLower(c.*);
    return s;
}

const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    fn init(vm: *Vm) Scratch {
        return .{ .arena = std.heap.ArenaAllocator.init(pageOf(vm).a) };
    }
    fn a(s: *Scratch) std.mem.Allocator {
        return s.arena.allocator();
    }
    fn deinit(s: *Scratch) void {
        s.arena.deinit();
    }
};

fn nodeList(vm: *Vm, ids: []const NodeId) Error!Value {
    const p = pageOf(vm);
    const arr = try vm.newArray(0);
    const mark = vm.heap.tempMark();
    defer vm.heap.tempRelease(mark);
    vm.heap.tempPush(arr.cell());
    for (ids) |id| try vm.arrayPush(arr, (try p.wrap(id)).asValue());
    return arr.asValue();
}

/// A collection that answers to names too (`document.forms.login`,
/// `form.elements.q`): the array with each element's `id` and `name`
/// as a property — a name shared by several (a radio group) gives the
/// first, as `HTMLCollection` does.
fn namedCollection(vm: *Vm, ids: []const NodeId) Error!Value {
    const p = pageOf(vm);
    const v = try nodeList(vm, ids);
    const arr = Vm.asObject(v);
    for (ids) |id| {
        const el = try p.wrapValue(id);
        for ([_][]const u8{ "id", "name" }) |attr| if (p.doc.getAttr(id, attr)) |nm| {
            if (nm.len == 0 or std.ascii.isDigit(nm[0])) continue;
            const k: Key = .{ .atom = try vm.atom(nm) };
            if ((try vm.objects.getOwn(arr, k)) == null) _ = try vm.objects.defineOwn(arr, k, el, .hidden);
        };
    }
    return v;
}

/// Element children of `id`, in order.
fn elementChildren(p: *Page, id: NodeId, a: std.mem.Allocator, out: *std.ArrayList(NodeId)) Error!void {
    var c = p.doc.get(id).first_child;
    while (c) |cid| : (c = p.doc.get(cid).next) if (p.doc.get(cid).kind == .element) try out.append(a, cid);
}

fn isAncestor(doc: *const dom.Document, anc: NodeId, id: NodeId) bool {
    var cur: ?NodeId = id;
    while (cur) |c| : (cur = doc.get(c).parent) if (c == anc) return true;
    return false;
}

/// Insert `child` (a node; a fragment's children) before `before` under `parent`.
fn insertNode(p: *Page, parent: NodeId, child: NodeId, before: ?NodeId) Error!void {
    const vm = p.vm;
    const doc = p.doc;
    if (child == parent or isAncestor(doc, child, parent)) return throwDom(vm, .HierarchyRequestError, "the new child is an ancestor of the parent");
    const pk = doc.get(parent).kind;
    if (pk != .element and pk != .document and pk != .fragment) return throwDom(vm, .HierarchyRequestError, "this node cannot have children");
    if (doc.get(child).kind == .document) return throwDom(vm, .HierarchyRequestError, "a document cannot be a child");
    if (pk == .document) {
        // A document holds one element, one doctype, no text.
        const ck = doc.get(child).kind;
        if (ck == .text) return throwDom(vm, .HierarchyRequestError, "a document cannot hold text");
        var elements: usize = 0;
        var c = doc.get(parent).first_child;
        while (c) |cid| : (c = doc.get(cid).next) if (cid != child) {
            if (doc.get(cid).kind == .element) elements += 1;
            if (ck == .doctype and doc.get(cid).kind == .doctype) return throwDom(vm, .HierarchyRequestError, "a document holds one doctype");
        };
        if (ck == .element and elements > 0) return throwDom(vm, .HierarchyRequestError, "a document holds one element");
        if (ck == .fragment) {
            var fe: usize = 0;
            var fc = doc.get(child).first_child;
            while (fc) |fid| : (fc = doc.get(fid).next) {
                if (doc.get(fid).kind == .text) return throwDom(vm, .HierarchyRequestError, "a document cannot hold text");
                if (doc.get(fid).kind == .element) fe += 1;
            }
            if (fe > 1 or (fe == 1 and elements > 0)) return throwDom(vm, .HierarchyRequestError, "a document holds one element");
        }
    }
    if (before) |b| if (doc.get(b).parent != parent) return throwDom(vm, .NotFoundError, "the reference node is not a child");
    // The live ranges and iterators move with the insertion.
    const at_index: usize = if (before) |b| childIndex(doc, b) else doc.childCount(parent);
    const count: usize = if (doc.get(child).kind == .fragment) doc.childCount(child) else 1;
    p.rangesOnInsert(parent, at_index, count);
    if (p.touchesSheets(child) or doc.isHtml(parent, "style")) p.markSheets();
    p.scheduleLoads(child);
    if (doc.get(child).kind == .fragment) {
        var added: std.ArrayList(NodeId) = .empty;
        defer added.deinit(p.a);
        var c = doc.get(child).first_child;
        while (c) |cid| {
            const next = doc.get(cid).next;
            doc.detach(cid);
            doc.insertBefore(parent, cid, before);
            try added.append(p.a, cid);
            c = next;
        }
        p.touch();
        p.notify(.child_list, parent, null, added.items, &.{});
    } else {
        p.detachNode(child);
        doc.insertBefore(parent, child, before);
        p.touch();
        p.notify(.child_list, parent, null, &.{child}, &.{});
    }
}

/// A node argument for `append`-style methods: a node, or a string
/// that becomes a text node.
fn nodeOrText(vm: *Vm, v: Value) Error!NodeId {
    const p = pageOf(vm);
    if (p.adoptArg(v)) |id| return id;
    const text = try docStr(vm, v);
    return p.doc.createText(text);
}

/// Deep copy of the subtree at `id` into the same document.
fn cloneSubtree(p: *Page, id: NodeId, deep: bool) Error!NodeId {
    const doc = p.doc;
    const n = doc.get(id);
    const copy: NodeId = switch (n.kind) {
        .element => blk: {
            const e = try doc.createElement(n.namespace, n.name);
            for (n.attrs.items) |at| try doc.setAttr(e, at.name, at.value);
            break :blk e;
        },
        .text => try doc.createText(n.text.items),
        .comment => try doc.createComment(n.text.items),
        .fragment => try doc.createFragment(),
        .doctype => try doc.createDoctype(n.name, n.public_id, n.system_id),
        .document => try doc.createFragment(),
    };
    if (deep) {
        var c = doc.get(id).first_child;
        while (c) |cid| : (c = doc.get(cid).next) {
            const cc = try cloneSubtree(p, cid, true);
            doc.appendChild(copy, cc);
        }
    }
    return copy;
}

/// Parse markup as a fragment in the context of `ctx` and adopt its
/// nodes into the page's document; returns a fragment node.
fn parseInto(p: *Page, markup: []const u8, ctx: NodeId) Error!NodeId {
    const doc = p.doc;
    const cn = doc.get(ctx);
    const name: []const u8 = if (cn.kind == .element) cn.name else "body";
    const ns: dom.Namespace = if (cn.kind == .element) cn.namespace else .html;
    // Parsed in scratch that goes with the call (a parse costs a node
    // store and a tokenizer beyond the nodes; a page that sets innerHTML
    // a thousand times must not keep a thousand of them), then adopted
    // by copy into the document's arena.
    var scratch = std.heap.ArenaAllocator.init(p.a);
    defer scratch.deinit();
    const frag_doc = try html.parseFragment(scratch.allocator(), markup, name, ns, .{ .scripting = true });
    const frag = try doc.createFragment();
    // The fragment parser's output: the children of its root (the
    // synthetic `html` element's context child), adopted by copy.
    var root: NodeId = dom.document_id;
    var w = frag_doc.walk(dom.document_id);
    while (w.next()) |id| {
        const n = frag_doc.get(id);
        if (n.kind == .element and std.mem.eql(u8, n.name, "html")) {
            root = id;
            break;
        }
    }
    var c = frag_doc.get(root).first_child;
    while (c) |cid| : (c = frag_doc.get(cid).next) {
        const copy = try adopt(p, frag_doc, cid);
        doc.appendChild(frag, copy);
    }
    return frag;
}

fn adopt(p: *Page, from: *const dom.Document, id: NodeId) Error!NodeId {
    const doc = p.doc;
    const n = from.get(id);
    const copy: NodeId = switch (n.kind) {
        .element => blk: {
            // The names and values are the source's: copied, since it may go.
            const e = try doc.createElement(n.namespace, try doc.a.dupe(u8, n.name));
            for (n.attrs.items) |at| try doc.setAttr(e, try doc.a.dupe(u8, at.name), try doc.a.dupe(u8, at.value));
            if (n.ns_uri) |u| doc.node(e).ns_uri = try doc.a.dupe(u8, u);
            doc.node(e).flags = n.flags;
            break :blk e;
        },
        .text => try doc.createText(n.text.items),
        .comment => try doc.createComment(n.text.items),
        .doctype => try doc.createDoctype(try doc.a.dupe(u8, n.name), if (n.public_id) |x| try doc.a.dupe(u8, x) else null, if (n.system_id) |x| try doc.a.dupe(u8, x) else null),
        else => try doc.createFragment(),
    };
    var c = n.first_child;
    while (c) |cid| : (c = from.get(cid).next) {
        const cc = try adopt(p, from, cid);
        doc.appendChild(copy, cc);
    }
    if (n.template_contents) |tc| {
        const tcopy = try adopt(p, from, tc);
        doc.node(copy).template_contents = tcopy;
    }
    return copy;
}

fn serializeInner(p: *Page, id: NodeId, a: std.mem.Allocator) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try html.serialize(a, p.doc, id, &out);
    return out.items;
}

fn upperName(name: []const u8, a: std.mem.Allocator) Error![]u8 {
    const s = try a.dupe(u8, name);
    for (s) |*c| c.* = std.ascii.toUpper(c.*);
    return s;
}

// --------------------------------------------------------- constructors

fn construct(vm: *Vm, this: Value, args: []const Value, new_target: Value) Error!Value {
    _ = this;
    const p = pageOf(vm);
    const fo = vm.current_native orelse return vm.throwTypeError("Illegal constructor");
    const idx: usize = @intFromFloat(Vm.functionData(fo).data.asNumber());
    if (new_target.isUndefined()) return vm.throwTypeError("a constructor needs new");
    if (!interfaces[idx].constructible) return vm.throwTypeError("Illegal constructor");
    if (idx == I.event_target) {
        const o = try vm.objects.create(p.protos[idx].asValue(), .ordinary, 0);
        return o.asValue();
    }
    if (idx == I.range) return newRange(vm);
    if (idx == I.mutation_observer) {
        const cb = arg(args, 0);
        if (!vm.isCallable(cb)) return vm.throwTypeError("MutationObserver needs a callback");
        const o = try vm.objects.create(p.protos[idx].asValue(), .ordinary, 0);
        try vm.defineValue(o, "__callback", cb, .hidden);
        return o.asValue();
    }
    if (idx == I.xhr) {
        const o = try vm.objects.create(p.protos[idx].asValue(), .ordinary, 0);
        try xhrReset(vm, o, 0);
        try vm.defineValue(o, "responseType", try vm.str(""), .default);
        try vm.defineValue(o, "timeout", Value.fromInt(0), .default);
        try vm.defineValue(o, "withCredentials", Value.false_, .default);
        try vm.defineValue(o, "onreadystatechange", Value.null_, .default);
        try vm.defineValue(o, "onload", Value.null_, .default);
        try vm.defineValue(o, "onloadend", Value.null_, .default);
        try vm.defineValue(o, "onerror", Value.null_, .default);
        return o.asValue();
    }
    // An event: new Event(type, { bubbles, cancelable, detail }).
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const type_name = try strArg(vm, arg(args, 0), sc.a());
    var bubbles = false;
    var cancelable = false;
    var detail = Value.null_;
    const init = arg(args, 1);
    if (init.isObject()) {
        const io = Vm.asObject(init);
        bubbles = vm.toBoolean(try vm.get(io, .{ .atom = try vm.atom("bubbles") }, init));
        cancelable = vm.toBoolean(try vm.get(io, .{ .atom = try vm.atom("cancelable") }, init));
        detail = try vm.get(io, .{ .atom = try vm.atom("detail") }, init);
    }
    const ev = try p.newEvent(idx, type_name, bubbles, cancelable, false);
    if (idx == I.custom_event) try p.setEventProp(ev, "detail", detail);
    // The prototype a subclass asked for.
    if (new_target.isObject() and Vm.asObject(new_target) != p.ctors[idx]) {
        const proto = try vm.get(Vm.asObject(new_target), .{ .atom = try vm.atom("prototype") }, new_target);
        if (proto.isObject()) _ = try vm.setPrototypeOf(ev, proto);
    }
    return ev.asValue();
}

// ---------------------------------------------------------- EventTarget

/// The listener target: a node wrapper, the window, or a plain
/// EventTarget instance.
fn thisTarget(vm: *Vm, this: Value) Error!*Object {
    if (!this.isObject()) return vm.throwTypeError("Illegal invocation");
    return Vm.asObject(this);
}

fn listenerFlags(vm: *Vm, opts: Value) Error!i32 {
    if (opts.isObject()) {
        const o = Vm.asObject(opts);
        var f: i32 = 0;
        if (vm.toBoolean(try vm.get(o, .{ .atom = try vm.atom("capture") }, opts))) f |= Page.flag_capture;
        if (vm.toBoolean(try vm.get(o, .{ .atom = try vm.atom("once") }, opts))) f |= Page.flag_once;
        if (vm.toBoolean(try vm.get(o, .{ .atom = try vm.atom("passive") }, opts))) f |= Page.flag_passive;
        return f;
    }
    return if (vm.toBoolean(opts)) Page.flag_capture else 0;
}

fn addEventListener(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const o = try thisTarget(vm, this);
    const cb = arg(args, 1);
    if (cb.isNullish()) return Value.undefined_;
    const type_v = try vm.toStringValue(arg(args, 0));
    const flags = try listenerFlags(vm, arg(args, 2));
    const list = (try p.listenerList(o, true)).?;
    if (try p.hasListener(list, type_v, cb, flags)) return Value.undefined_;
    try vm.arrayPush(list, type_v);
    try vm.arrayPush(list, cb);
    try vm.arrayPush(list, Value.fromInt(flags));
    return Value.undefined_;
}

fn removeEventListener(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const o = try thisTarget(vm, this);
    const list = (try p.listenerList(o, false)) orelse return Value.undefined_;
    const type_v = try vm.toStringValue(arg(args, 0));
    try p.removeListener(list, type_v, arg(args, 1), try listenerFlags(vm, arg(args, 2)));
    return Value.undefined_;
}

fn dispatchEventNative(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    _ = try thisTarget(vm, this);
    const ev = try thisEvent(vm, arg(args, 0));
    if (ev.internal(Slot).flags & ev_dispatching != 0) return vm.throwError(.TypeError, "InvalidStateError: the event is being dispatched");
    ev.internal(Slot).flags &= ~ev_trusted;
    return Value.fromBool(try p.dispatch(this, ev));
}

// ----------------------------------------------------------------- Node

fn getNodeType(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const id = try thisNode(vm, this);
    return Value.fromInt(switch (pageOf(vm).doc.get(id).kind) {
        .element => 1,
        .text => 3,
        .comment => 8,
        .document => 9,
        .doctype => 10,
        .fragment => 11,
    });
}

fn getNodeName(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const id = try thisNode(vm, this);
    const p = pageOf(vm);
    const n = p.doc.get(id);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    return switch (n.kind) {
        .element => jsStr(vm, if (n.namespace == .html and p.isHtmlDoc()) try upperName(n.name, sc.a()) else n.name),
        .text => jsStr(vm, "#text"),
        .comment => jsStr(vm, "#comment"),
        .document => jsStr(vm, "#document"),
        .doctype => jsStr(vm, n.name),
        .fragment => jsStr(vm, "#document-fragment"),
    };
}

fn getNodeValue(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const id = try thisNode(vm, this);
    const n = pageOf(vm).doc.get(id);
    return switch (n.kind) {
        .text, .comment => jsStr(vm, n.text.items),
        else => Value.null_,
    };
}

fn setNodeValue(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    const n = p.doc.node(id);
    if (n.kind != .text and n.kind != .comment) return Value.undefined_;
    const v = arg(args, 0);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const text = if (v.isNullish()) "" else try strArg(vm, v, sc.a());
    try p.setText(id, text);
    return Value.undefined_;
}

fn getDataLength(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const id = try thisNode(vm, this);
    const n = pageOf(vm).doc.get(id);
    // UTF-16 length, as the DOM counts.
    var count: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(n.text.items).iterator();
    while (it.nextCodepoint()) |c| count += if (c >= 0x10000) 2 else 1;
    return Value.fromInt(@intCast(count));
}

fn getTextContent(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    const n = p.doc.get(id);
    if (n.kind == .document or n.kind == .doctype) return Value.null_;
    var sc = Scratch.init(vm);
    defer sc.deinit();
    return jsStr(vm, try p.doc.textContent(id, sc.a()));
}

fn setTextContent(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    const n = p.doc.node(id);
    switch (n.kind) {
        .text, .comment => return setNodeValue(vm, this, args, Value.undefined_),
        .element, .fragment => {
            while (n.first_child) |c| p.detachNode(c);
            const v = arg(args, 0);
            if (!v.isNullish()) {
                const text = try docStr(vm, v);
                if (text.len > 0) try insertNode(p, id, try p.doc.createText(text), null);
            }
            p.touch();
        },
        else => {},
    }
    return Value.undefined_;
}

fn getParentNode(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    return p.wrapValue(p.doc.get(id).parent);
}

fn getParentElement(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    const par = p.doc.get(id).parent orelse return Value.null_;
    if (p.doc.get(par).kind != .element) return Value.null_;
    return p.wrapValue(par);
}

fn getChildNodes(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    var ids: std.ArrayList(NodeId) = .empty;
    var c = p.doc.get(id).first_child;
    while (c) |cid| : (c = p.doc.get(cid).next) try ids.append(sc.a(), cid);
    return nodeList(vm, ids.items);
}

fn getFirstChild(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    return p.wrapValue((try thisNodeRec(vm, this)).first_child);
}

fn getLastChild(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    return p.wrapValue((try thisNodeRec(vm, this)).last_child);
}

fn getPreviousSibling(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    return p.wrapValue((try thisNodeRec(vm, this)).prev);
}

fn getNextSibling(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    return p.wrapValue((try thisNodeRec(vm, this)).next);
}

fn getOwnerDocument(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    if (id == dom.document_id) return Value.null_;
    return p.wrapValue(dom.document_id);
}

fn getIsConnected(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    return Value.fromBool(isAncestor(p.doc, dom.document_id, id));
}

fn getBaseURI(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    _ = try thisNode(vm, this);
    return jsStr(vm, pageOf(vm).url);
}

fn appendChild(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const parent = try thisNode(vm, this);
    const child = p.adoptArg(arg(args, 0)) orelse return vm.throwTypeError("appendChild: not a node");
    try insertNode(p, parent, child, null);
    return arg(args, 0);
}

fn insertBefore(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const parent = try thisNode(vm, this);
    const child = p.adoptArg(arg(args, 0)) orelse return vm.throwTypeError("insertBefore: not a node");
    const ref = arg(args, 1);
    const before: ?NodeId = if (ref.isNullish()) null else (p.nodeOfValue(ref) orelse return vm.throwTypeError("insertBefore: the reference is not a node"));
    try insertNode(p, parent, child, before);
    return arg(args, 0);
}

fn removeChild(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const parent = try thisNode(vm, this);
    const child = p.nodeOfValue(arg(args, 0)) orelse return vm.throwTypeError("removeChild: not a node");
    if (p.doc.get(child).parent != parent) return throwDom(vm, .NotFoundError, "the node is not a child");
    p.detachNode(child);
    return arg(args, 0);
}

fn replaceChild(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const parent = try thisNode(vm, this);
    const new_child = p.adoptArg(arg(args, 0)) orelse return vm.throwTypeError("replaceChild: not a node");
    const old = p.nodeOfValue(arg(args, 1)) orelse return vm.throwTypeError("replaceChild: not a node");
    if (p.doc.get(old).parent != parent) return throwDom(vm, .NotFoundError, "the node is not a child");
    const next = p.doc.get(old).next;
    p.detachNode(old);
    try insertNode(p, parent, new_child, if (next == new_child) null else next);
    return arg(args, 1);
}

fn cloneNode(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    const copy = try cloneSubtree(p, id, vm.toBoolean(arg(args, 0)));
    return p.wrapValue(copy);
}

fn containsNode(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    const other = p.nodeOfValue(arg(args, 0)) orelse return Value.false_;
    return Value.fromBool(isAncestor(p.doc, id, other));
}

fn hasChildNodes(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return Value.fromBool((try thisNodeRec(vm, this)).first_child != null);
}

fn compareDocumentPosition(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    const other = p.nodeOfValue(arg(args, 0)) orelse return vm.throwTypeError("not a node");
    if (id == other) return Value.fromInt(0);
    if (isAncestor(p.doc, id, other)) return Value.fromInt(16 | 4); // contained by, following
    if (isAncestor(p.doc, other, id)) return Value.fromInt(8 | 2); // contains, preceding
    var w = p.doc.walk(dom.document_id);
    while (w.next()) |n| {
        if (n == id) return Value.fromInt(4);
        if (n == other) return Value.fromInt(2);
    }
    return Value.fromInt(1 | 32);
}

fn getRootNode(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    var cur = try thisNode(vm, this);
    while (p.doc.get(cur).parent) |par| cur = par;
    return p.wrapValue(cur);
}

// ------------------------------------------------------------- Document

fn getDocumentElement(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    _ = try thisNode(vm, this);
    var c = p.doc.get(dom.document_id).first_child;
    while (c) |cid| : (c = p.doc.get(cid).next) if (p.doc.get(cid).kind == .element) return p.wrapValue(cid);
    return Value.null_;
}

fn childElementNamed(p: *Page, parent: NodeId, name: []const u8) ?NodeId {
    var c = p.doc.get(parent).first_child;
    while (c) |cid| : (c = p.doc.get(cid).next) if (p.doc.isHtml(cid, name)) return cid;
    return null;
}

fn getHead(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    _ = try thisNode(vm, this);
    var c = p.doc.get(dom.document_id).first_child;
    while (c) |cid| : (c = p.doc.get(cid).next) if (p.doc.isHtml(cid, "html")) return p.wrapValue(childElementNamed(p, cid, "head"));
    return Value.null_;
}

fn getBody(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    _ = try thisNode(vm, this);
    var c = p.doc.get(dom.document_id).first_child;
    while (c) |cid| : (c = p.doc.get(cid).next) if (p.doc.isHtml(cid, "html")) return p.wrapValue(childElementNamed(p, cid, "body") orelse childElementNamed(p, cid, "frameset"));
    return Value.null_;
}

fn titleElement(p: *Page) ?NodeId {
    var w = p.doc.walk(dom.document_id);
    while (w.next()) |id| if (p.doc.isHtml(id, "title")) return id;
    return null;
}

fn getTitle(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    _ = try thisNode(vm, this);
    const t = titleElement(p) orelse return jsStr(vm, "");
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const text = try p.doc.textContent(t, sc.a());
    // Whitespace collapsed and trimmed, as the getter says.
    var out: std.ArrayList(u8) = .empty;
    var space = true;
    for (text) |ch| {
        if (std.ascii.isWhitespace(ch)) {
            if (!space) try out.append(sc.a(), ' ');
            space = true;
        } else {
            try out.append(sc.a(), ch);
            space = false;
        }
    }
    return jsStr(vm, std.mem.trimEnd(u8, out.items, " "));
}

fn setTitle(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    _ = try thisNode(vm, this);
    const text = try docStr(vm, arg(args, 0));
    const t = titleElement(p) orelse blk: {
        // No title yet: one in the head, if there is a head.
        var c = p.doc.get(dom.document_id).first_child;
        while (c) |cid| : (c = p.doc.get(cid).next) if (p.doc.isHtml(cid, "html")) {
            const head = childElementNamed(p, cid, "head") orelse return Value.undefined_;
            const t = try p.doc.createElement(.html, "title");
            p.doc.appendChild(head, t);
            break :blk t;
        };
        return Value.undefined_;
    };
    while (p.doc.get(t).first_child) |c| p.doc.detach(c);
    p.doc.appendChild(t, try p.doc.createText(text));
    p.touch();
    if (p.host.changed) |f| f(p.host.ctx, .title, std.mem.trim(u8, text, " \t\r\n"));
    return Value.undefined_;
}

/// `document.write(...)`: while a parser-inserted script runs, its
/// markup goes right after the script element, parsed as the parser
/// would have parsed it there; from anywhere else it is refused with a
/// log line (a document is never blown away here).
fn documentWriteText(vm: *Vm, args: []const Value, newline: bool) Error!Value {
    const p = pageOf(vm);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    var text: std.ArrayList(u8) = .empty;
    for (args) |a| try text.appendSlice(sc.a(), try strArg(vm, a, sc.a()));
    if (newline) try text.append(sc.a(), '\n');
    // A document opened by script gathers what is written until close.
    if (p.docs.items[p.cur].open) {
        try p.docs.items[p.cur].write_buf.appendSlice(p.a, text.items);
        return Value.undefined_;
    }
    const script = p.current_script orelse {
        p.log(.warn, "script: document.write outside a parser-inserted script is ignored");
        return Value.undefined_;
    };
    const parent = p.doc.get(script).parent orelse return Value.undefined_;
    const frag = try parseInto(p, text.items, parent);
    try insertNode(p, parent, frag, p.doc.get(script).next);
    return Value.undefined_;
}

/// `document.open()`: the document emptied, what `write` adds gathered
/// until `close()` parses it whole and adopts the tree — a document's
/// nodes cannot be replaced in place, so they are copied in.
fn documentOpen(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    _ = try thisNode(vm, this);
    if (p.cur == 0) {
        p.log(.warn, "script: document.open() on the page's own document is ignored");
        return this;
    }
    while (p.doc.get(dom.document_id).first_child) |c| p.detachNode(c);
    p.docs.items[p.cur].open = true;
    p.docs.items[p.cur].write_buf.clearRetainingCapacity();
    return this;
}

fn documentClose(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    _ = try thisNode(vm, this);
    const entry = &p.docs.items[p.cur];
    if (!entry.open) return Value.undefined_;
    entry.open = false;
    var scratch = std.heap.ArenaAllocator.init(p.a);
    defer scratch.deinit();
    const parsed = try html.parse(scratch.allocator(), entry.write_buf.items, .{ .scripting = true });
    entry.write_buf.clearRetainingCapacity();
    var c = parsed.get(dom.document_id).first_child;
    while (c) |cid| : (c = parsed.get(cid).next) {
        const copy = try adopt(p, parsed, cid);
        p.doc.appendChild(dom.document_id, copy);
    }
    p.doc.quirks = parsed.quirks;
    p.touch();
    return Value.undefined_;
}

fn getPublicId(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const id = try thisNode(vm, this);
    return jsStr(vm, pageOf(vm).doc.get(id).public_id orelse "");
}

fn getSystemId(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const id = try thisNode(vm, this);
    return jsStr(vm, pageOf(vm).doc.get(id).system_id orelse "");
}

fn documentWrite(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    _ = try thisNode(vm, this);
    return documentWriteText(vm, args, false);
}

fn documentWriteln(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    _ = try thisNode(vm, this);
    return documentWriteText(vm, args, true);
}

/// `iframe.contentDocument` (an object's, a frame's): the document the
/// element holds, loaded on first touch; null for any other element.
fn getContentDocument(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    if (!(p.doc.isHtml(id, "iframe") or p.doc.isHtml(id, "object") or p.doc.isHtml(id, "frame") or p.doc.isHtml(id, "embed"))) return Value.null_;
    const di = try p.frameDocument(id);
    p.switchTo(di);
    return p.wrapValue(dom.document_id);
}

fn getContentWindow(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    if (!(p.doc.isHtml(id, "iframe") or p.doc.isHtml(id, "object") or p.doc.isHtml(id, "frame"))) return Value.null_;
    const di = try p.frameDocument(id);
    return p.viewOf(di);
}

fn getDoctype(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    _ = try thisNode(vm, this);
    var c = p.doc.get(dom.document_id).first_child;
    while (c) |cid| : (c = p.doc.get(cid).next) if (p.doc.get(cid).kind == .doctype) return p.wrapValue(cid);
    return Value.null_;
}

/// `document.implementation`, one object per document.
fn getImplementation(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    _ = try thisNode(vm, this);
    const w = try p.wrap(dom.document_id);
    if (try vm.objects.getOwn(w, .{ .atom = try vm.atom("__impl") })) |own| return own.val;
    const o = try vm.newObject();
    _ = try vm.defineNative(o, "createDocument", 2, implCreateDocument);
    _ = try vm.defineNative(o, "createHTMLDocument", 0, implCreateHTMLDocument);
    _ = try vm.defineNative(o, "createDocumentType", 3, implCreateDocumentType);
    _ = try vm.defineNative(o, "hasFeature", 0, implHasFeature);
    _ = try vm.objects.defineOwn(w, .{ .atom = try vm.atom("__impl") }, o.asValue(), .hidden);
    return o.asValue();
}

fn namespaceOf(text: []const u8) dom.Namespace {
    if (std.mem.eql(u8, text, "http://www.w3.org/2000/svg")) return .svg;
    if (std.mem.eql(u8, text, "http://www.w3.org/1998/Math/MathML")) return .mathml;
    return .html;
}

/// A new, XML-flavoured document (names keep their case), with a root
/// element when a name is given and the doctype adopted when given.
fn implCreateDocument(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const di = try p.newDocument(null, false, null, "about:blank");
    const saved = p.cur;
    p.switchTo(di);
    defer p.switchTo(saved);
    const dt = arg(args, 2);
    if (!dt.isNullish()) if (p.adoptArg(dt)) |d| if (p.doc.get(d).kind == .doctype) p.doc.appendChild(dom.document_id, d);
    const qn = arg(args, 1);
    if (!qn.isNullish()) {
        const qname = try strArg(vm, qn, sc.a());
        if (qname.len > 0) {
            try checkName(vm, qname, true);
            const nsv = arg(args, 0);
            const ns: dom.Namespace = if (nsv.isNullish()) .html else namespaceOf(try strArg(vm, nsv, sc.a()));
            const root = try p.doc.createElement(ns, try p.doc.a.dupe(u8, qname));
            p.doc.appendChild(dom.document_id, root);
        }
    }
    return p.wrapValue(dom.document_id);
}

fn implCreateHTMLDocument(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const t = arg(args, 0);
    const title = if (t.isUndefined()) "" else try strArg(vm, t, sc.a());
    const markup = if (t.isUndefined()) "<!DOCTYPE html><html><head></head><body></body></html>" else try std.fmt.allocPrint(sc.a(), "<!DOCTYPE html><html><head><title></title></head><body></body></html>", .{});
    const di = try p.newDocument(markup, true, null, "about:blank");
    const saved = p.cur;
    p.switchTo(di);
    defer p.switchTo(saved);
    if (title.len > 0) if (titleElement(p)) |te| p.doc.appendChild(te, try p.doc.createText(try p.doc.a.dupe(u8, title)));
    return p.wrapValue(dom.document_id);
}

/// A doctype node, in a document of its own until adopted.
fn implCreateDocumentType(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const name = try strArg(vm, arg(args, 0), sc.a());
    try checkName(vm, name, true);
    const pub_id = try strArg(vm, arg(args, 1), sc.a());
    const sys_id = try strArg(vm, arg(args, 2), sc.a());
    const di = try p.newDocument(null, false, null, "about:blank");
    const saved = p.cur;
    p.switchTo(di);
    defer p.switchTo(saved);
    const dt = try p.doc.createDoctype(try p.doc.a.dupe(u8, name), try p.doc.a.dupe(u8, pub_id), try p.doc.a.dupe(u8, sys_id));
    return p.wrapValue(dt);
}

fn implHasFeature(_: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    return Value.true_;
}

/// An XML Name check, as createElement/createDocumentType want it: a
/// letter, '_' or ':' first, then letters, digits, '-', '.', '_', ':';
/// with `qualified`, at most one ':' and not at either end.
fn checkName(vm: *Vm, name: []const u8, qualified: bool) Error!void {
    if (name.len == 0) return throwDom(vm, .InvalidCharacterError, "an empty name");
    var colons: usize = 0;
    for (name, 0..) |c, i| {
        const start_ok = std.ascii.isAlphabetic(c) or c == '_' or c == ':' or c >= 0x80;
        const rest_ok = start_ok or std.ascii.isDigit(c) or c == '-' or c == '.';
        if (i == 0 and !start_ok) return throwDom(vm, .InvalidCharacterError, "not a name");
        if (!rest_ok) return throwDom(vm, .InvalidCharacterError, "not a name");
        if (c == ':') colons += 1;
    }
    if (qualified) {
        if (colons > 1 or name[0] == ':' or name[name.len - 1] == ':') return throwDom(vm, .NamespaceError, "not a qualified name");
    }
}

fn getLocation(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    _ = try thisNode(vm, this);
    return pageOf(vm).location_obj.asValue();
}

fn collectByTag(vm: *Vm, this: Value, names: []const []const u8) Error!Value {
    const p = pageOf(vm);
    const root = try thisNode(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    var ids: std.ArrayList(NodeId) = .empty;
    var w = p.doc.walk(root);
    while (w.next()) |id| for (names) |nm| if (p.doc.isHtml(id, nm)) {
        try ids.append(sc.a(), id);
        break;
    };
    return nodeList(vm, ids.items);
}

fn getForms(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const root = try thisNode(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    var ids: std.ArrayList(NodeId) = .empty;
    var w = p.doc.walk(root);
    while (w.next()) |id| if (p.doc.isHtml(id, "form")) try ids.append(sc.a(), id);
    return namedCollection(vm, ids.items);
}
fn getImages(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return collectByTag(vm, this, &.{"img"});
}
fn getScripts(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return collectByTag(vm, this, &.{"script"});
}
fn getLinks(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const root = try thisNode(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    var ids: std.ArrayList(NodeId) = .empty;
    var w = p.doc.walk(root);
    while (w.next()) |id| if ((p.doc.isHtml(id, "a") or p.doc.isHtml(id, "area")) and p.doc.hasAttr(id, "href")) try ids.append(sc.a(), id);
    return nodeList(vm, ids.items);
}

fn getDocumentURL(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    _ = try thisNode(vm, this);
    return jsStr(vm, pageOf(vm).url);
}

fn getReadyState(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    _ = try thisNode(vm, this);
    return jsStr(vm, @tagName(pageOf(vm).ready_state));
}

fn getDefaultView(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    _ = try thisNode(vm, this);
    return p.viewOf(p.cur);
}

fn getCharacterSet(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    _ = try thisNode(vm, this);
    return jsStr(vm, "UTF-8");
}

fn getCompatMode(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    _ = try thisNode(vm, this);
    return jsStr(vm, if (pageOf(vm).doc.quirks == .quirks) "BackCompat" else "CSS1Compat");
}

fn getActiveElement(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return getBody(vm, this, &.{}, Value.undefined_);
}

fn hasFocus(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    _ = try thisNode(vm, this);
    return Value.true_;
}

fn getElementById(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const root = try thisNode(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const want = try strArg(vm, arg(args, 0), sc.a());
    var w = p.doc.walk(root);
    while (w.next()) |id| {
        if (p.doc.get(id).kind != .element) continue;
        if (p.doc.getAttr(id, "id")) |v| if (std.mem.eql(u8, v, want)) return p.wrapValue(id);
    }
    return Value.null_;
}

fn createElement(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    _ = try thisNode(vm, this);
    const name = try docStr(vm, arg(args, 0));
    try checkName(vm, name, false);
    if (p.isHtmlDoc()) for (name) |*c| {
        c.* = std.ascii.toLower(c.*);
    };
    const id = try p.doc.createElement(.html, name);
    return p.wrapValue(id);
}

fn createElementNS(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    _ = try thisNode(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const nsv = arg(args, 0);
    const ns_text = if (nsv.isNullish()) "" else try strArg(vm, nsv, sc.a());
    const name = try docStr(vm, arg(args, 1));
    try checkName(vm, name, true);
    // The standard's namespace rules: a prefix needs a namespace, `xml:`
    // its own, `xmlns` (as name or prefix) the xmlns namespace and the
    // xmlns namespace nothing else.
    const eq = std.mem.eql;
    const prefix: ?[]const u8 = if (std.mem.indexOfScalar(u8, name, ':')) |c| name[0..c] else null;
    const xmlns_ns = "http://www.w3.org/2000/xmlns/";
    if (prefix != null and ns_text.len == 0) return throwDom(vm, .NamespaceError, "a prefix needs a namespace");
    if (prefix != null and eq(u8, prefix.?, "xml") and !eq(u8, ns_text, "http://www.w3.org/XML/1998/namespace")) return throwDom(vm, .NamespaceError, "the xml prefix has its own namespace");
    const is_xmlns = eq(u8, name, "xmlns") or (prefix != null and eq(u8, prefix.?, "xmlns"));
    if (is_xmlns != eq(u8, ns_text, xmlns_ns)) return throwDom(vm, .NamespaceError, "xmlns and its namespace go together");
    const ns: dom.Namespace = if (eq(u8, ns_text, "http://www.w3.org/2000/svg")) .svg else if (eq(u8, ns_text, "http://www.w3.org/1998/Math/MathML")) .mathml else if (ns_text.len == 0 or eq(u8, ns_text, "http://www.w3.org/1999/xhtml")) .html else .other;
    // The qualified name stays as given (`prefix:local` is the tagName).
    const id = try p.doc.createElement(ns, name);
    if (ns == .other) p.doc.node(id).ns_uri = try p.doc.a.dupe(u8, ns_text);
    return p.wrapValue(id);
}

fn createTextNode(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    _ = try thisNode(vm, this);
    const text = try docStr(vm, arg(args, 0));
    return p.wrapValue(try p.doc.createText(text));
}

fn createComment(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    _ = try thisNode(vm, this);
    const text = try docStr(vm, arg(args, 0));
    return p.wrapValue(try p.doc.createComment(text));
}

fn createDocumentFragment(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    _ = try thisNode(vm, this);
    return p.wrapValue(try p.doc.createFragment());
}

fn createEvent(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    _ = try thisNode(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const kind = try strArg(vm, arg(args, 0), sc.a());
    const eq = std.ascii.eqlIgnoreCase;
    const iface: usize = if (eq(kind, "CustomEvent")) I.custom_event else if (eq(kind, "MouseEvent") or eq(kind, "MouseEvents")) I.mouse_event else if (eq(kind, "UIEvent") or eq(kind, "UIEvents")) ifaceIndex("UIEvent") else if (eq(kind, "KeyboardEvent") or eq(kind, "KeyEvents")) ifaceIndex("KeyboardEvent") else if (eq(kind, "Event") or eq(kind, "Events") or eq(kind, "HTMLEvents") or eq(kind, "MutationEvents") or eq(kind, "SVGEvents")) I.event else return throwDom(vm, .NotSupportedError, "not an event interface");
    const ev = try p.newEvent(iface, "", false, false, false);
    _ = try vm.defineNative(ev, "initEvent", 1, initEvent);
    _ = try vm.defineNative(ev, "initUIEvent", 1, initUIEvent);
    _ = try vm.defineNative(ev, "initCustomEvent", 1, initCustomEvent);
    _ = try vm.defineNative(ev, "initMouseEvent", 1, initUIEvent);
    _ = try vm.defineNative(ev, "initKeyboardEvent", 1, initUIEvent);
    return ev.asValue();
}

fn initUIEvent(vm: *Vm, this: Value, args: []const Value, nt: Value) Error!Value {
    const p = pageOf(vm);
    const ev = try thisEvent(vm, this);
    _ = try initEvent(vm, this, args, nt);
    try p.setEventProp(ev, "view", if (arg(args, 3).isNullish()) Value.null_ else arg(args, 3));
    try p.setEventProp(ev, "detail", if (arg(args, 4).isUndefined()) Value.fromInt(0) else arg(args, 4));
    return Value.undefined_;
}

fn initCustomEvent(vm: *Vm, this: Value, args: []const Value, nt: Value) Error!Value {
    const p = pageOf(vm);
    const ev = try thisEvent(vm, this);
    _ = try initEvent(vm, this, args, nt);
    try p.setEventProp(ev, "detail", if (arg(args, 3).isUndefined()) Value.null_ else arg(args, 3));
    return Value.undefined_;
}

fn initEvent(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const ev = try thisEvent(vm, this);
    try p.setEventProp(ev, "type", try vm.toStringValue(arg(args, 0)));
    const s = ev.internal(Slot);
    s.flags &= ~(ev_bubbles | ev_cancelable);
    if (vm.toBoolean(arg(args, 1))) s.flags |= ev_bubbles;
    if (vm.toBoolean(arg(args, 2))) s.flags |= ev_cancelable;
    return Value.undefined_;
}

// ----------------------------------------------------- parent queries

fn querySelector(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const root = try thisNode(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const text = try strArg(vm, arg(args, 0), sc.a());
    const sel = selectors.Selector.parse(sc.a(), text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return vm.throwError(.SyntaxError, "SyntaxError: not a valid selector"),
    };
    return p.wrapValue(sel.queryFirst(p.doc, root));
}

fn querySelectorAll(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const root = try thisNode(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const text = try strArg(vm, arg(args, 0), sc.a());
    const sel = selectors.Selector.parse(sc.a(), text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return vm.throwError(.SyntaxError, "SyntaxError: not a valid selector"),
    };
    var ids: std.ArrayList(NodeId) = .empty;
    sel.queryAll(p.doc, root, sc.a(), &ids) catch return error.OutOfMemory;
    return nodeList(vm, ids.items);
}

fn getElementsByTagName(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const root = try thisNode(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const want = try attrKey(vm, arg(args, 0), sc.a());
    const all = std.mem.eql(u8, want, "*");
    var ids: std.ArrayList(NodeId) = .empty;
    var w = p.doc.walk(root);
    while (w.next()) |id| {
        const n = p.doc.get(id);
        if (n.kind != .element) continue;
        if (all or std.ascii.eqlIgnoreCase(n.name, want)) try ids.append(sc.a(), id);
    }
    return nodeList(vm, ids.items);
}

fn hasClass(classes: []const u8, want: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, classes, " \t\r\n\x0c");
    while (it.next()) |c| if (std.mem.eql(u8, c, want)) return true;
    return false;
}

fn getElementsByClassName(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const root = try thisNode(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const want = try strArg(vm, arg(args, 0), sc.a());
    var ids: std.ArrayList(NodeId) = .empty;
    var w = p.doc.walk(root);
    while (w.next()) |id| {
        if (p.doc.get(id).kind != .element) continue;
        const cls = p.doc.getAttr(id, "class") orelse continue;
        // Every wanted class must be present.
        var all = true;
        var wit = std.mem.tokenizeAny(u8, want, " \t\r\n\x0c");
        var any = false;
        while (wit.next()) |wc| {
            any = true;
            if (!hasClass(cls, wc)) all = false;
        }
        if (any and all) try ids.append(sc.a(), id);
    }
    return nodeList(vm, ids.items);
}

fn getChildren(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    var ids: std.ArrayList(NodeId) = .empty;
    try elementChildren(p, id, sc.a(), &ids);
    return nodeList(vm, ids.items);
}

fn getFirstElementChild(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    var c = p.doc.get(id).first_child;
    while (c) |cid| : (c = p.doc.get(cid).next) if (p.doc.get(cid).kind == .element) return p.wrapValue(cid);
    return Value.null_;
}

fn getLastElementChild(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    var c = p.doc.get(id).last_child;
    while (c) |cid| : (c = p.doc.get(cid).prev) if (p.doc.get(cid).kind == .element) return p.wrapValue(cid);
    return Value.null_;
}

fn getChildElementCount(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    var n: i32 = 0;
    var c = p.doc.get(id).first_child;
    while (c) |cid| : (c = p.doc.get(cid).next) if (p.doc.get(cid).kind == .element) {
        n += 1;
    };
    return Value.fromInt(n);
}

fn appendNodes(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const parent = try thisNode(vm, this);
    for (args) |a| try insertNode(p, parent, try nodeOrText(vm, a), null);
    return Value.undefined_;
}

fn prependNodes(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const parent = try thisNode(vm, this);
    const first = p.doc.get(parent).first_child;
    for (args) |a| try insertNode(p, parent, try nodeOrText(vm, a), first);
    return Value.undefined_;
}

fn replaceChildren(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const parent = try thisNode(vm, this);
    // The new nodes first (a string becomes a text node), then the old go.
    var sc = Scratch.init(vm);
    defer sc.deinit();
    var ids: std.ArrayList(NodeId) = .empty;
    for (args) |a| try ids.append(sc.a(), try nodeOrText(vm, a));
    while (p.doc.get(parent).first_child) |c| p.detachNode(c);
    for (ids.items) |id| try insertNode(p, parent, id, null);
    p.touch();
    return Value.undefined_;
}

// -------------------------------------------------------- ChildNode

fn removeSelf(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    p.detachNode(id);
    return Value.undefined_;
}

fn insertBeforeSelf(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    const parent = p.doc.get(id).parent orelse return Value.undefined_;
    for (args) |a| try insertNode(p, parent, try nodeOrText(vm, a), id);
    return Value.undefined_;
}

fn insertAfterSelf(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    const parent = p.doc.get(id).parent orelse return Value.undefined_;
    const next = p.doc.get(id).next;
    for (args) |a| try insertNode(p, parent, try nodeOrText(vm, a), next);
    return Value.undefined_;
}

fn replaceWith(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    const parent = p.doc.get(id).parent orelse return Value.undefined_;
    const next = p.doc.get(id).next;
    p.detachNode(id);
    for (args) |a| {
        const n = try nodeOrText(vm, a);
        try insertNode(p, parent, n, if (next == n) null else next);
    }
    p.touch();
    return Value.undefined_;
}

// ------------------------------------------------------------- Element

fn getTagName(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return getNodeName(vm, this, &.{}, Value.undefined_);
}

fn getLocalName(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const id = try thisElement(vm, this);
    const n = pageOf(vm).doc.get(id);
    // An element made in another namespace keeps `prefix:local` as its
    // name; the parser's elements have no prefix.
    if (n.namespace == .other) if (std.mem.indexOfScalar(u8, n.name, ':')) |c| return jsStr(vm, n.name[c + 1 ..]);
    return jsStr(vm, n.name);
}

fn getPrefix(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const id = try thisElement(vm, this);
    const n = pageOf(vm).doc.get(id);
    if (n.namespace == .other) if (std.mem.indexOfScalar(u8, n.name, ':')) |c| return jsStr(vm, n.name[0..c]);
    return Value.null_;
}

fn getNamespaceURI(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const id = try thisElement(vm, this);
    const n = pageOf(vm).doc.get(id);
    return jsStr(vm, switch (n.namespace) {
        .html => "http://www.w3.org/1999/xhtml",
        .svg => "http://www.w3.org/2000/svg",
        .mathml => "http://www.w3.org/1998/Math/MathML",
        .other => n.ns_uri orelse "",
    });
}

/// A reflected attribute: the getter gives "" when absent.
fn attrGetter(vm: *Vm, this: Value, name: []const u8) Error!Value {
    const id = try thisElement(vm, this);
    return jsStr(vm, pageOf(vm).doc.getAttr(id, name) orelse "");
}

fn attrSetter(vm: *Vm, this: Value, name: []const u8, v: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    try p.setAttr(id, name, try docStr(vm, v));
    return Value.undefined_;
}

fn boolAttrGetter(vm: *Vm, this: Value, name: []const u8) Error!Value {
    const id = try thisElement(vm, this);
    return Value.fromBool(pageOf(vm).doc.hasAttr(id, name));
}

fn boolAttrSetter(vm: *Vm, this: Value, name: []const u8, v: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    if (vm.toBoolean(v)) try p.setAttr(id, name, "") else p.removeAttr(id, name);
    return Value.undefined_;
}

fn getId(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return attrGetter(vm, this, "id");
}
fn setId(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "id", arg(args, 0));
}
fn getClassName(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return attrGetter(vm, this, "class");
}
fn setClassName(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "class", arg(args, 0));
}
fn getTitleAttr(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return attrGetter(vm, this, "title");
}
fn setTitleAttr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "title", arg(args, 0));
}
fn getLang(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return attrGetter(vm, this, "lang");
}
fn setLang(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "lang", arg(args, 0));
}
fn getDir(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return attrGetter(vm, this, "dir");
}
fn setDir(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "dir", arg(args, 0));
}
fn getHidden(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return boolAttrGetter(vm, this, "hidden");
}
fn setHidden(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return boolAttrSetter(vm, this, "hidden", arg(args, 0));
}
fn getHrefAttrResolved(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return urlAttrGetter(vm, this, "href");
}
fn setHrefAttrRaw(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "href", arg(args, 0));
}
fn getRelAttr(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return attrGetter(vm, this, "rel");
}
fn setRelAttr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "rel", arg(args, 0));
}
fn getAsAttr(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return attrGetter(vm, this, "as");
}
fn setAsAttr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "as", arg(args, 0));
}
fn getTypeAttrRaw(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return attrGetter(vm, this, "type");
}
fn getAsyncAttr(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return boolAttrGetter(vm, this, "async");
}
fn setAsyncAttr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return boolAttrSetter(vm, this, "async", arg(args, 0));
}
fn getDeferAttr(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return boolAttrGetter(vm, this, "defer");
}
fn setDeferAttr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return boolAttrSetter(vm, this, "defer", arg(args, 0));
}
fn getNoModuleAttr(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return boolAttrGetter(vm, this, "nomodule");
}
fn setNoModuleAttr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return boolAttrSetter(vm, this, "nomodule", arg(args, 0));
}
fn getCrossOriginAttr(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const id = try thisElement(vm, this);
    const v = pageOf(vm).doc.getAttr(id, "crossorigin") orelse return Value.null_;
    return jsStr(vm, v);
}
fn setCrossOriginAttr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "crossorigin", arg(args, 0));
}
fn getIntegrityAttr(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return attrGetter(vm, this, "integrity");
}
fn setIntegrityAttr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "integrity", arg(args, 0));
}
/// A template's contents: the fragment the parser filled (made on
/// first touch for a template a script created).
fn templateContent(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    if (p.doc.get(id).template_contents == null) p.doc.node(id).template_contents = try p.doc.createFragment();
    return p.wrapValue(p.doc.get(id).template_contents.?);
}
fn getMediaAttr(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return attrGetter(vm, this, "media");
}
fn setMediaAttr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "media", arg(args, 0));
}
fn getHttpEquiv(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return attrGetter(vm, this, "http-equiv");
}
fn setHttpEquiv(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "http-equiv", arg(args, 0));
}
fn getContentAttr(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return attrGetter(vm, this, "content");
}
fn setContentAttr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "content", arg(args, 0));
}
fn getAltAttr(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return attrGetter(vm, this, "alt");
}
fn setAltAttr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "alt", arg(args, 0));
}

/// A URL attribute resolved against the document, as the IDL wants.
fn urlAttrGetter(vm: *Vm, this: Value, name: []const u8) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const raw = p.doc.getAttr(id, name) orelse return jsStr(vm, "");
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const base = url.parse(sc.a(), p.url, null) catch null;
    const u = url.parse(sc.a(), raw, if (base) |*b| b else null) catch return jsStr(vm, raw);
    return jsStr(vm, try u.href(sc.a()));
}
fn getDataAttr(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return urlAttrGetter(vm, this, "data");
}
fn setDataAttr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "data", arg(args, 0));
}
fn getSrcAttr(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return urlAttrGetter(vm, this, "src");
}
fn setSrcAttr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const r = try attrSetter(vm, this, "src", arg(args, 0));
    if (p.doc.get(id).parent != null) p.pending_loads.append(p.a, .{ .doc = p.cur, .id = id }) catch {};
    return r;
}
fn getHtmlFor(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return attrGetter(vm, this, "for");
}
fn setHtmlFor(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "for", arg(args, 0));
}
fn getTabIndex(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const id = try thisElement(vm, this);
    const t = pageOf(vm).doc.getAttr(id, "tabindex") orelse return Value.fromInt(-1);
    return Value.fromInt(std.fmt.parseInt(i32, std.mem.trim(u8, t, " "), 10) catch -1);
}
fn setTabIndex(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "tabindex", try vm.toStringValue(arg(args, 0)));
}
/// A control's value as a script sees it: what the script set (the
/// "dirty" value, kept on the wrapper and never an attribute) over the
/// `value` attribute; the page's own typing writes the attribute.
pub fn controlValue(p: *Page, id: NodeId, buf: []u8) ?[]const u8 {
    const vm = p.vm;
    if (p.wrappers.get(p.key(id))) |w| {
        const dirty = vm.objects.getOwn(w, .{ .atom = vm.atom("__value") catch return null }) catch return null;
        if (dirty) |own| if (own.val.isString()) return js.builtins.utf8Buf(vm, Vm.asString(own.val), buf) catch null;
    }
    return p.doc.getAttr(id, "value");
}

fn getValueAttr(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    // A textarea's value is its text; a select's is its selected option's.
    if (p.doc.isHtml(id, "textarea")) return getTextContent(vm, this, &.{}, Value.undefined_);
    if (p.doc.isHtml(id, "input")) {
        const w = Vm.asObject(this);
        if (try vm.objects.getOwn(w, .{ .atom = try vm.atom("__value") })) |own| return own.val;
    }
    if (p.doc.isHtml(id, "select")) {
        var first: ?NodeId = null;
        var w = p.doc.walk(id);
        while (w.next()) |c| if (p.doc.isHtml(c, "option")) {
            if (first == null) first = c;
            if (p.doc.hasAttr(c, "selected")) return optionValue(vm, c);
        };
        return if (first) |f| optionValue(vm, f) else jsStr(vm, "");
    }
    return attrGetter(vm, this, "value");
}

fn optionValue(vm: *Vm, id: NodeId) Error!Value {
    const p = pageOf(vm);
    if (p.doc.getAttr(id, "value")) |v| return jsStr(vm, v);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    return jsStr(vm, std.mem.trim(u8, try p.doc.textContent(id, sc.a()), " \t\r\n"));
}
fn setValueAttr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    if (p.doc.isHtml(id, "textarea")) return setTextContent(vm, this, args, Value.undefined_);
    if (p.doc.isHtml(id, "input")) {
        // The dirty value: on the wrapper, not in the markup.
        const w = Vm.asObject(this);
        _ = try vm.objects.defineOwn(w, .{ .atom = try vm.atom("__value") }, try vm.toStringValue(arg(args, 0)), .hidden);
        return Value.undefined_;
    }
    return attrSetter(vm, this, "value", arg(args, 0));
}

/// The `value` attribute itself (`defaultValue`).
fn getValueAttrRaw(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return attrGetter(vm, this, "value");
}
fn setValueAttrRaw(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "value", arg(args, 0));
}
fn getMaxLength(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const id = try thisElement(vm, this);
    const t = pageOf(vm).doc.getAttr(id, "maxlength") orelse return Value.fromInt(-1);
    return Value.fromInt(std.fmt.parseInt(i32, std.mem.trim(u8, t, " "), 10) catch -1);
}
fn setMaxLength(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "maxlength", try vm.toStringValue(arg(args, 0)));
}
fn trueNative(_: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    return Value.true_;
}

fn getSelectedAttr(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return boolAttrGetter(vm, this, "selected");
}
fn setSelectedAttr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    // One option selected per select: the others let go.
    if (vm.toBoolean(arg(args, 0))) if (p.doc.get(id).parent) |par| {
        var sel: ?NodeId = par;
        while (sel) |s| : (sel = p.doc.get(s).parent) if (p.doc.isHtml(s, "select")) break;
        if (sel) |s| {
            var w = p.doc.walk(s);
            while (w.next()) |o| if (o != id and p.doc.isHtml(o, "option")) p.removeAttr(o, "selected");
        }
    };
    return boolAttrSetter(vm, this, "selected", arg(args, 0));
}
fn optionValueAttr(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const id = try thisElement(vm, this);
    return optionValue(vm, id);
}
fn optionIndex(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var sel: ?NodeId = p.doc.get(id).parent;
    while (sel) |s| : (sel = p.doc.get(s).parent) if (p.doc.isHtml(s, "select")) break;
    const s = sel orelse return Value.fromInt(0);
    var i: i32 = 0;
    var w = p.doc.walk(s);
    while (w.next()) |o| if (p.doc.isHtml(o, "option")) {
        if (o == id) return Value.fromInt(i);
        i += 1;
    };
    return Value.fromInt(0);
}
fn setSelectedIndex(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const want = try vm.toIntegerOrInfinity(arg(args, 0));
    var i: f64 = 0;
    var w = p.doc.walk(id);
    while (w.next()) |o| if (p.doc.isHtml(o, "option")) {
        if (i == want) try p.setAttr(o, "selected", "") else p.removeAttr(o, "selected");
        i += 1;
    };
    return Value.undefined_;
}
/// `select.add(option, before)`: before an option, an index, or at the end.
fn selectAdd(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const opt = p.adoptArg(arg(args, 0)) orelse return vm.throwTypeError("add needs an option");
    const before_v = arg(args, 1);
    var before: ?NodeId = null;
    if (before_v.isNumber()) {
        const n = before_v.asNumber();
        var i: f64 = 0;
        var w = p.doc.walk(id);
        while (w.next()) |o| if (p.doc.isHtml(o, "option")) {
            if (i == n) before = o;
            i += 1;
        };
    } else if (!before_v.isNullish()) before = p.nodeOfValue(before_v);
    const parent = if (before) |b| (p.doc.get(b).parent orelse id) else id;
    try insertNode(p, parent, opt, before);
    return Value.undefined_;
}
fn selectRemove(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    if (arg(args, 0).isUndefined()) {
        p.detachNode(id);
        return Value.undefined_;
    }
    const n = try vm.toIntegerOrInfinity(arg(args, 0));
    var i: f64 = 0;
    var w = p.doc.walk(id);
    while (w.next()) |o| if (p.doc.isHtml(o, "option")) {
        if (i == n) {
            p.detachNode(o);
            break;
        }
        i += 1;
    };
    return Value.undefined_;
}
/// `checked` is the control's state (what the user or a script set),
/// `defaultChecked` the attribute; `:checked` and the form's submission
/// follow the state.
fn getChecked(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const id = try thisElement(vm, this);
    return Value.fromBool(pageOf(vm).doc.isChecked(id));
}
fn getDefaultChecked(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return boolAttrGetter(vm, this, "checked");
}
fn setDefaultChecked(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return boolAttrSetter(vm, this, "checked", arg(args, 0));
}
fn setChecked(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    // A radio checked unchecks the rest of its group (same name, same
    // form, or the same document without one).
    if (vm.toBoolean(arg(args, 0))) if (p.doc.getAttr(id, "type")) |t| if (std.ascii.eqlIgnoreCase(t, "radio")) if (p.doc.getAttr(id, "name")) |name| {
        var scope: NodeId = dom.document_id;
        var up = p.doc.get(id).parent;
        while (up) |u| : (up = p.doc.get(u).parent) if (p.doc.isHtml(u, "form")) {
            scope = u;
            break;
        };
        var w = p.doc.walk(scope);
        while (w.next()) |o| if (o != id and p.doc.isHtml(o, "input")) {
            const ot = p.doc.getAttr(o, "type") orelse continue;
            if (!std.ascii.eqlIgnoreCase(ot, "radio")) continue;
            if (std.mem.eql(u8, p.doc.getAttr(o, "name") orelse "", name)) p.doc.setChecked(o, false);
        };
    };
    p.doc.setChecked(id, vm.toBoolean(arg(args, 0)));
    p.touch();
    return Value.undefined_;
}
fn getDisabled(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return boolAttrGetter(vm, this, "disabled");
}
fn setDisabled(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return boolAttrSetter(vm, this, "disabled", arg(args, 0));
}
fn getTypeAttr(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const id = try thisElement(vm, this);
    const p = pageOf(vm);
    const t = p.doc.getAttr(id, "type") orelse (if (p.doc.isHtml(id, "button")) "submit" else if (p.doc.isHtml(id, "input")) "text" else "");
    var sc = Scratch.init(vm);
    defer sc.deinit();
    return jsStr(vm, try std.ascii.allocLowerString(sc.a(), t));
}
fn setTypeAttr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "type", arg(args, 0));
}
fn getNameAttr(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return attrGetter(vm, this, "name");
}
fn setNameAttr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "name", arg(args, 0));
}
fn getPlaceholder(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return attrGetter(vm, this, "placeholder");
}
fn setPlaceholder(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "placeholder", arg(args, 0));
}
fn getHref(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const raw = p.doc.getAttr(id, "href") orelse return jsStr(vm, "");
    // Resolved against the document, as the IDL attribute is.
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const base = url.parse(sc.a(), p.url, null) catch null;
    const u = url.parse(sc.a(), raw, if (base) |*b| b else null) catch return jsStr(vm, raw);
    return jsStr(vm, try u.href(sc.a()));
}
fn setHref(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "href", arg(args, 0));
}

fn getAttribute(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const name = try attrKey(vm, arg(args, 0), sc.a());
    const v = p.doc.getAttr(id, name) orelse return Value.null_;
    return jsStr(vm, v);
}

fn setAttribute(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const name = try attrKey(vm, arg(args, 0), p.doc.a);
    if (name.len == 0) return vm.throwError(.TypeError, "InvalidCharacterError: an empty attribute name");
    const value = try docStr(vm, arg(args, 1));
    try p.setAttr(id, name, value);
    return Value.undefined_;
}

fn removeAttribute(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const name = try attrKey(vm, arg(args, 0), sc.a());
    p.removeAttr(id, name);
    return Value.undefined_;
}

fn hasAttribute(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const name = try attrKey(vm, arg(args, 0), sc.a());
    return Value.fromBool(p.doc.hasAttr(id, name));
}

fn hasAttributes(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const id = try thisElement(vm, this);
    return Value.fromBool(pageOf(vm).doc.get(id).attrs.items.len > 0);
}

fn toggleAttribute(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const name = try attrKey(vm, arg(args, 0), p.doc.a);
    const has = p.doc.hasAttr(id, name);
    const force = arg(args, 1);
    const want = if (force.isUndefined()) !has else vm.toBoolean(force);
    if (want and !has) try p.setAttr(id, name, "");
    if (!want and has) p.removeAttr(id, name);
    return Value.fromBool(want);
}

fn getAttributeNames(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const arr = try vm.newArray(0);
    const mark = vm.heap.tempMark();
    defer vm.heap.tempRelease(mark);
    vm.heap.tempPush(arr.cell());
    for (p.doc.get(id).attrs.items) |at| try vm.arrayPush(arr, try jsStr(vm, at.name));
    return arr.asValue();
}

fn getAttributes(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const arr = try vm.newArray(0);
    const mark = vm.heap.tempMark();
    defer vm.heap.tempRelease(mark);
    vm.heap.tempPush(arr.cell());
    for (p.doc.get(id).attrs.items) |at| {
        const o = try vm.newObject();
        try vm.defineValue(o, "name", try jsStr(vm, at.name), .default);
        try vm.defineValue(o, "localName", try jsStr(vm, at.name), .default);
        try vm.defineValue(o, "value", try jsStr(vm, at.value), .default);
        try vm.arrayPush(arr, o.asValue());
    }
    return arr.asValue();
}

fn matchesSelector(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const text = try strArg(vm, arg(args, 0), sc.a());
    const sel = selectors.Selector.parse(sc.a(), text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return vm.throwError(.SyntaxError, "SyntaxError: not a valid selector"),
    };
    return Value.fromBool(sel.matches(p.doc, id));
}

fn closest(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const text = try strArg(vm, arg(args, 0), sc.a());
    const sel = selectors.Selector.parse(sc.a(), text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return vm.throwError(.SyntaxError, "SyntaxError: not a valid selector"),
    };
    var cur: ?NodeId = id;
    while (cur) |c| : (cur = p.doc.get(c).parent) if (sel.matches(p.doc, c)) return p.wrapValue(c);
    return Value.null_;
}

fn getInnerHTML(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    return jsStr(vm, try serializeInner(p, id, sc.a()));
}

fn setInnerHTML(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const v = arg(args, 0);
    const markup = if (v.isNullish()) "" else try strArg(vm, v, sc.a());
    const frag = try parseInto(p, markup, id);
    while (p.doc.get(id).first_child) |c| p.detachNode(c);
    try insertNode(p, id, frag, null);
    return Value.undefined_;
}

fn getOuterHTML(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    var out: std.ArrayList(u8) = .empty;
    try html.serializeOuter(sc.a(), p.doc, id, &out);
    return jsStr(vm, out.items);
}

fn setOuterHTML(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const parent = p.doc.get(id).parent orelse return Value.undefined_;
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const markup = try strArg(vm, arg(args, 0), sc.a());
    const frag = try parseInto(p, markup, parent);
    const next = p.doc.get(id).next;
    p.detachNode(id);
    try insertNode(p, parent, frag, next);
    return Value.undefined_;
}

fn getNextElementSibling(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    var c = (try thisNodeRec(vm, this)).next;
    while (c) |cid| : (c = p.doc.get(cid).next) if (p.doc.get(cid).kind == .element) return p.wrapValue(cid);
    return Value.null_;
}

fn getPreviousElementSibling(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    var c = (try thisNodeRec(vm, this)).prev;
    while (c) |cid| : (c = p.doc.get(cid).prev) if (p.doc.get(cid).kind == .element) return p.wrapValue(cid);
    return Value.null_;
}

const Adjacent = enum { beforebegin, afterbegin, beforeend, afterend };

fn adjacentPlace(vm: *Vm, id: NodeId, where_v: Value) Error!struct { parent: NodeId, before: ?NodeId } {
    const p = pageOf(vm);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const where = try strArg(vm, where_v, sc.a());
    for (where) |*c| c.* = std.ascii.toLower(c.*);
    const w = std.meta.stringToEnum(Adjacent, where) orelse return vm.throwError(.SyntaxError, "SyntaxError: not a position");
    const n = p.doc.get(id);
    return switch (w) {
        .beforebegin => .{ .parent = n.parent orelse return vm.throwError(.TypeError, "NoModificationAllowedError: no parent"), .before = id },
        .afterbegin => .{ .parent = id, .before = n.first_child },
        .beforeend => .{ .parent = id, .before = null },
        .afterend => .{ .parent = n.parent orelse return vm.throwError(.TypeError, "NoModificationAllowedError: no parent"), .before = n.next },
    };
}

fn insertAdjacentHTML(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const place = try adjacentPlace(vm, id, arg(args, 0));
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const markup = try strArg(vm, arg(args, 1), sc.a());
    const frag = try parseInto(p, markup, place.parent);
    try insertNode(p, place.parent, frag, place.before);
    return Value.undefined_;
}

fn insertAdjacentElement(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const place = try adjacentPlace(vm, id, arg(args, 0));
    const el = p.adoptArg(arg(args, 1)) orelse return vm.throwTypeError("not an element");
    try insertNode(p, place.parent, el, place.before);
    return arg(args, 1);
}

fn insertAdjacentText(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const place = try adjacentPlace(vm, id, arg(args, 0));
    const t = try p.doc.createText(try docStr(vm, arg(args, 1)));
    try insertNode(p, place.parent, t, place.before);
    return Value.undefined_;
}

fn clickNative(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    if (!p.clickHere(id)) return Value.undefined_;
    // The activation behaviour a script's click() has here: a box
    // toggles, a radio checks, a submit button submits its form (the
    // `submit` event, then the host); a link is the host's to follow.
    if (p.doc.isHtml(id, "input") or p.doc.isHtml(id, "button")) {
        const t = p.doc.getAttr(id, "type") orelse (if (p.doc.isHtml(id, "button")) "submit" else "text");
        if (std.ascii.eqlIgnoreCase(t, "checkbox")) {
            _ = try setChecked(vm, this, &.{Value.fromBool(!p.doc.isChecked(id))}, Value.undefined_);
            p.changeHere(id);
            return Value.undefined_;
        }
        if (std.ascii.eqlIgnoreCase(t, "radio")) {
            _ = try setChecked(vm, this, &.{Value.true_}, Value.undefined_);
            p.changeHere(id);
            return Value.undefined_;
        }
        if (std.ascii.eqlIgnoreCase(t, "submit")) {
            var up = p.doc.get(id).parent;
            while (up) |u| : (up = p.doc.get(u).parent) if (p.doc.isHtml(u, "form")) {
                if (p.submitHere(u)) if (p.cur == 0) if (p.host.submit) |f| f(p.host.ctx, u);
                return Value.undefined_;
            };
            return Value.undefined_;
        }
    }
    if (p.cur == 0) if (p.host.activate) |f| f(p.host.ctx, id);
    return Value.undefined_;
}

fn noopNative(_: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    return Value.undefined_;
}

// --------------------------------------------------------- DOMTokenList

fn getClassList(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const o = try vm.objects.create(p.protos[I.tokens].asValue(), .dom, @sizeOf(Slot));
    o.internal(Slot).* = .{ .kind = slot_tokens, .id = id, .doc = p.cur };
    return o.asValue();
}

fn thisTokens(vm: *Vm, this: Value) Error!NodeId {
    if (this.isObject()) {
        const o = Vm.asObject(this);
        if (o.class == .dom and o.internal(Slot).kind == slot_tokens) {
            pageOf(vm).switchTo(o.internal(Slot).doc);
            return o.internal(Slot).id;
        }
    }
    return vm.throwTypeError("Illegal invocation");
}

fn tokensOf(p: *Page, id: NodeId, a: std.mem.Allocator) Error!std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    const cls = p.doc.getAttr(id, "class") orelse return list;
    var it = std.mem.tokenizeAny(u8, cls, " \t\r\n\x0c");
    while (it.next()) |t| {
        var dup = false;
        for (list.items) |x| if (std.mem.eql(u8, x, t)) {
            dup = true;
        };
        if (!dup) try list.append(a, t);
    }
    return list;
}

fn writeTokens(p: *Page, id: NodeId, list: []const []const u8) Error!void {
    var out: std.ArrayList(u8) = .empty;
    for (list, 0..) |t, i| {
        if (i > 0) try out.append(p.doc.a, ' ');
        try out.appendSlice(p.doc.a, t);
    }
    try p.setAttr(id, "class", out.items);
}

fn tokensLength(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisTokens(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const list = try tokensOf(p, id, sc.a());
    return Value.fromInt(@intCast(list.items.len));
}

fn tokensValue(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisTokens(vm, this);
    return jsStr(vm, p.doc.getAttr(id, "class") orelse "");
}

fn tokensSetValue(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisTokens(vm, this);
    try p.setAttr(id, "class", try docStr(vm, arg(args, 0)));
    return Value.undefined_;
}

fn tokensItem(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisTokens(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const list = try tokensOf(p, id, sc.a());
    const i = try vm.toIntegerOrInfinity(arg(args, 0));
    if (i < 0 or i >= @as(f64, @floatFromInt(list.items.len))) return Value.null_;
    return jsStr(vm, list.items[@intFromFloat(i)]);
}

fn tokensContains(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisTokens(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const want = try strArg(vm, arg(args, 0), sc.a());
    return Value.fromBool(hasClass(p.doc.getAttr(id, "class") orelse "", want));
}

fn checkToken(vm: *Vm, t: []const u8) Error!void {
    if (t.len == 0) return vm.throwError(.SyntaxError, "SyntaxError: an empty token");
    for (t) |c| if (std.ascii.isWhitespace(c)) return vm.throwError(.TypeError, "InvalidCharacterError: a token with whitespace");
}

fn tokensAdd(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisTokens(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    var list = try tokensOf(p, id, sc.a());
    for (args) |a| {
        const t = try strArg(vm, a, sc.a());
        try checkToken(vm, t);
        if (!hasClass(p.doc.getAttr(id, "class") orelse "", t)) {
            var dup = false;
            for (list.items) |x| if (std.mem.eql(u8, x, t)) {
                dup = true;
            };
            if (!dup) try list.append(sc.a(), t);
        }
    }
    try writeTokens(p, id, list.items);
    return Value.undefined_;
}

fn tokensRemove(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisTokens(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    var list = try tokensOf(p, id, sc.a());
    for (args) |a| {
        const t = try strArg(vm, a, sc.a());
        try checkToken(vm, t);
        var i: usize = 0;
        while (i < list.items.len) {
            if (std.mem.eql(u8, list.items[i], t)) _ = list.orderedRemove(i) else i += 1;
        }
    }
    try writeTokens(p, id, list.items);
    return Value.undefined_;
}

fn tokensToggle(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisTokens(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const t = try strArg(vm, arg(args, 0), sc.a());
    try checkToken(vm, t);
    var list = try tokensOf(p, id, sc.a());
    var has = false;
    for (list.items) |x| if (std.mem.eql(u8, x, t)) {
        has = true;
    };
    const force = arg(args, 1);
    const want = if (force.isUndefined()) !has else vm.toBoolean(force);
    if (want and !has) try list.append(sc.a(), t);
    if (!want and has) {
        var i: usize = 0;
        while (i < list.items.len) {
            if (std.mem.eql(u8, list.items[i], t)) _ = list.orderedRemove(i) else i += 1;
        }
    }
    if (want != has) try writeTokens(p, id, list.items);
    return Value.fromBool(want);
}

fn tokensReplace(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisTokens(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const old = try strArg(vm, arg(args, 0), sc.a());
    const new = try strArg(vm, arg(args, 1), sc.a());
    try checkToken(vm, old);
    try checkToken(vm, new);
    const list = try tokensOf(p, id, sc.a());
    var found = false;
    for (list.items) |*x| if (std.mem.eql(u8, x.*, old)) {
        x.* = new;
        found = true;
    };
    if (found) try writeTokens(p, id, list.items);
    return Value.fromBool(found);
}

// ---------------------------------------------------------------- Event

fn eventBubbles(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const ev = try thisEvent(vm, this);
    return Value.fromBool(ev.internal(Slot).flags & ev_bubbles != 0);
}
fn eventCancelable(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const ev = try thisEvent(vm, this);
    return Value.fromBool(ev.internal(Slot).flags & ev_cancelable != 0);
}
fn eventDefaultPrevented(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const ev = try thisEvent(vm, this);
    return Value.fromBool(ev.internal(Slot).flags & ev_canceled != 0);
}
fn eventIsTrusted(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const ev = try thisEvent(vm, this);
    return Value.fromBool(ev.internal(Slot).flags & ev_trusted != 0);
}
fn eventComposed(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    _ = try thisEvent(vm, this);
    return Value.false_;
}
fn eventPreventDefault(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const ev = try thisEvent(vm, this);
    const s = ev.internal(Slot);
    if (s.flags & ev_cancelable != 0) s.flags |= ev_canceled;
    return Value.undefined_;
}
fn eventStopPropagation(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const ev = try thisEvent(vm, this);
    ev.internal(Slot).flags |= ev_stop;
    return Value.undefined_;
}
fn eventStopImmediate(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const ev = try thisEvent(vm, this);
    ev.internal(Slot).flags |= ev_stop | ev_stop_immediate;
    return Value.undefined_;
}
fn eventComposedPath(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const ev = try thisEvent(vm, this);
    const arr = try vm.newArray(0);
    if (ev.internal(Slot).flags & ev_dispatching == 0) return arr.asValue();
    const mark = vm.heap.tempMark();
    defer vm.heap.tempRelease(mark);
    vm.heap.tempPush(arr.cell());
    const target = try vm.get(ev, .{ .atom = try vm.atom("target") }, ev.asValue());
    try vm.arrayPush(arr, target);
    if (p.nodeOfValue(target)) |id| {
        var cur = p.doc.get(id).parent;
        while (cur) |c| : (cur = p.doc.get(c).parent) try vm.arrayPush(arr, (try p.wrap(c)).asValue());
        try vm.arrayPush(arr, vm.global.asValue());
    }
    return arr.asValue();
}

// --------------------------------------------------------------- Window

fn consoleLine(vm: *Vm, level: Level, args: []const Value) Error!Value {
    const p = pageOf(vm);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    var line: std.ArrayList(u8) = .empty;
    for (args, 0..) |a, i| {
        if (i > 0) try line.append(sc.a(), ' ');
        try line.appendSlice(sc.a(), try strArg(vm, a, sc.a()));
    }
    p.log(level, line.items);
    return Value.undefined_;
}

fn consoleLog(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return consoleLine(vm, .log, args);
}
fn consoleWarn(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return consoleLine(vm, .warn, args);
}
fn consoleError(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return consoleLine(vm, .err, args);
}
fn consoleAssert(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    if (vm.toBoolean(arg(args, 0))) return Value.undefined_;
    return consoleLine(vm, .err, if (args.len > 1) args[1..] else &.{});
}

fn alert(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const text = try strArg(vm, arg(args, 0), sc.a());
    p.logf(.warn, "alert: {s}", .{text});
    return Value.undefined_;
}

/// `window.open(url)`: a popup is a navigation here (there is one
/// window); null comes back, as for a blocked popup.
fn windowOpen(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const u = arg(args, 0);
    if (!u.isNullish()) {
        var sc = Scratch.init(vm);
        defer sc.deinit();
        const raw = try strArg(vm, u, sc.a());
        if (raw.len > 0) try p.navigateTo(raw);
    }
    return Value.null_;
}

fn confirmNative(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    _ = vm;
    return Value.false_;
}

fn promptNative(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    _ = vm;
    return Value.null_;
}

fn getComputedStyle(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, arg(args, 0));
    if (p.doc.get(id).kind != .element) return vm.throwTypeError("getComputedStyle needs an element");
    const o = try vm.objects.create(p.protos[I.style].asValue(), .dom, @sizeOf(Slot));
    o.internal(Slot).* = .{ .kind = slot_style, .id = id, .flags = style_computed, .doc = p.cur };
    return o.asValue();
}

fn scrollToNative(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    var x: f64 = 0;
    var y: f64 = 0;
    const a0 = arg(args, 0);
    if (a0.isObject()) {
        const o = Vm.asObject(a0);
        x = vm.toNumber(try vm.get(o, .{ .atom = try vm.atom("left") }, a0)) catch 0;
        y = vm.toNumber(try vm.get(o, .{ .atom = try vm.atom("top") }, a0)) catch 0;
    } else {
        x = vm.toNumber(a0) catch 0;
        y = vm.toNumber(arg(args, 1)) catch 0;
    }
    if (std.math.isNan(x)) x = 0;
    if (std.math.isNan(y)) y = 0;
    if (p.host.scroll) |f| f(p.host.ctx, x, y);
    return Value.undefined_;
}

fn scrollByNative(vm: *Vm, this: Value, args: []const Value, nt: Value) Error!Value {
    const p = pageOf(vm);
    var dx: f64 = 0;
    var dy: f64 = 0;
    const a0 = arg(args, 0);
    if (a0.isObject()) {
        const o = Vm.asObject(a0);
        dx = vm.toNumber(try vm.get(o, .{ .atom = try vm.atom("left") }, a0)) catch 0;
        dy = vm.toNumber(try vm.get(o, .{ .atom = try vm.atom("top") }, a0)) catch 0;
    } else {
        dx = vm.toNumber(a0) catch 0;
        dy = vm.toNumber(arg(args, 1)) catch 0;
    }
    _ = this;
    _ = nt;
    if (std.math.isNan(dx)) dx = 0;
    if (std.math.isNan(dy)) dy = 0;
    if (p.host.scroll) |f| f(p.host.ctx, p.scroll_x + dx, p.scroll_y + dy);
    return Value.undefined_;
}

fn matchMedia(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.newObject();
    try vm.defineValue(o, "matches", Value.false_, .default);
    try vm.defineValue(o, "media", try vm.toStringValue(arg(args, 0)), .default);
    _ = try vm.defineNative(o, "addListener", 1, noopNative);
    _ = try vm.defineNative(o, "removeListener", 1, noopNative);
    _ = try vm.defineNative(o, "addEventListener", 2, noopNative);
    _ = try vm.defineNative(o, "removeEventListener", 2, noopNative);
    return o.asValue();
}

fn locationToString(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    return jsStr(vm, pageOf(vm).url);
}

fn locationGetHref(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    return jsStr(vm, pageOf(vm).url);
}

fn locationSetHref(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    try p.navigateTo(try strArg(vm, arg(args, 0), sc.a()));
    return Value.undefined_;
}

fn locationAssign(vm: *Vm, this: Value, args: []const Value, nt: Value) Error!Value {
    return locationSetHref(vm, this, args, nt);
}

fn locationReload(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    if (p.host.navigate) |f| f(p.host.ctx, p.url);
    return Value.undefined_;
}

fn locationGetHash(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    if (std.mem.indexOfScalar(u8, p.url, '#')) |i| {
        if (i + 1 < p.url.len) return jsStr(vm, p.url[i..]);
    }
    return jsStr(vm, "");
}

fn locationSetHash(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    var frag = try strArg(vm, arg(args, 0), sc.a());
    if (frag.len > 0 and frag[0] == '#') frag = frag[1..];
    const base = if (std.mem.indexOfScalar(u8, p.url, '#')) |i| p.url[0..i] else p.url;
    const next = try std.fmt.allocPrint(sc.a(), "{s}#{s}", .{ base, frag });
    if (std.mem.eql(u8, next, p.url)) return Value.undefined_;
    try p.urlChanged(next);
    _ = p.fireSimple(vm.global.asValue(), "hashchange", false, false);
    return Value.undefined_;
}

fn historyPush(vm: *Vm, args: []const Value, replace: bool) Error!Value {
    const p = pageOf(vm);
    try p.historySeed();
    var sc = Scratch.init(vm);
    defer sc.deinit();
    var next_url: []const u8 = p.url;
    const u = arg(args, 2);
    if (!u.isNullish()) {
        const raw = try strArg(vm, u, sc.a());
        next_url = sameOriginUrl(p, raw, sc.a()) orelse return vm.throwError(.TypeError, "SecurityError: a history entry must be same-origin");
    }
    const kept = try p.a.dupe(u8, next_url);
    errdefer p.a.free(kept);
    const entry: HistoryEntry = .{ .url = kept, .state = arg(args, 0) };
    if (replace) {
        p.a.free(p.history.items[p.history_index].url);
        p.history.items[p.history_index] = entry;
    } else {
        // Entries after the current one go, as in every browser.
        while (p.history.items.len > p.history_index + 1) {
            const last = p.history.pop().?;
            p.a.free(last.url);
        }
        try p.history.append(p.a, entry);
        p.history_index = p.history.items.len - 1;
    }
    if (!std.mem.eql(u8, next_url, p.url)) try p.urlChanged(next_url);
    return Value.undefined_;
}

fn historyPushState(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return historyPush(vm, args, false);
}

fn historyReplaceState(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return historyPush(vm, args, true);
}

fn historyBack(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    try pageOf(vm).historyGo(-1);
    return Value.undefined_;
}

fn historyForward(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    try pageOf(vm).historyGo(1);
    return Value.undefined_;
}

fn historyGoNative(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const d = try vm.toIntegerOrInfinity(arg(args, 0));
    if (d == 0) {
        const p = pageOf(vm);
        if (p.host.navigate) |f| f(p.host.ctx, p.url);
        return Value.undefined_;
    }
    if (d < -1000 or d > 1000) return Value.undefined_;
    try pageOf(vm).historyGo(@intFromFloat(d));
    return Value.undefined_;
}

fn historyLength(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    try p.historySeed();
    return Value.fromInt(@intCast(p.history.items.len));
}

fn historyState(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    try p.historySeed();
    return p.history.items[p.history_index].state;
}

// ------------------------------------------------------------ modules

/// The module loader: a specifier resolved against the importing
/// module's URL (or the document's), fetched through the host like a
/// classic `src`; bare specifiers are not modules here.
/// `import.meta.url`: the module's own URL.
fn hostImportMeta(vm: *Vm, name: []const u8, meta: *Object) Error!void {
    try vm.defineValue(meta, "url", try jsStr(vm, name), .default);
}

fn hostLoad(vm: *Vm, referrer: ?[]const u8, specifier_in: []const u8) Error!?js.module.Loaded {
    const p = pageOf(vm);
    var scratch = std.heap.ArenaAllocator.init(p.a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    // The page's import map (`<script type="importmap">`), read once:
    // a bare specifier maps by its entry or its longest prefix entry.
    const specifier = try p.mapImport(specifier_in, sa);
    const relative = std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../") or std.mem.startsWith(u8, specifier, "/");
    const absolute = std.mem.indexOf(u8, specifier, "://") != null;
    if (!relative and !absolute) return null;
    const base = url.parse(sa, referrer orelse p.url, null) catch null;
    const u = url.parse(sa, specifier, if (base) |*b| b else null) catch return null;
    // The canonical name has no fragment: one module per resource.
    const abs = u.serialize(sa, true) catch return null;
    const fetch = p.host.fetch orelse return null;
    const text = fetch(p.host.ctx, abs) orelse return null;
    return .{ .name = try vm.meta.dupe(u8, abs), .source = try vm.meta.dupe(u8, text) };
}

// ------------------------------------------------------------- tables

fn childNamed(p: *Page, parent: NodeId, name: []const u8) ?NodeId {
    var c = p.doc.get(parent).first_child;
    while (c) |cid| : (c = p.doc.get(cid).next) if (p.doc.isHtml(cid, name)) return cid;
    return null;
}

fn tableCaption(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    return p.wrapValue(childNamed(p, id, "caption"));
}
fn tableTHead(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    return p.wrapValue(childNamed(p, id, "thead"));
}
fn tableTFoot(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    return p.wrapValue(childNamed(p, id, "tfoot"));
}

/// Setting caption/tHead/tFoot: the old one goes, the new one takes
/// its place (a caption first; a head after captions and colgroups; a
/// foot at the end).
fn tableSetPart(vm: *Vm, this: Value, v: Value, name: []const u8) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const new_part: ?NodeId = if (v.isNullish()) null else (p.adoptArg(v) orelse return vm.throwTypeError("not an element"));
    if (new_part) |np| if (!p.doc.isHtml(np, name)) return throwDom(vm, .HierarchyRequestError, "not the right element");
    if (childNamed(p, id, name)) |old| if (new_part == null or old != new_part.?) p.detachNode(old);
    if (new_part) |np| {
        if (p.doc.get(np).parent == id) return Value.undefined_;
        try insertNode(p, id, np, tablePartPlace(p, id, name));
    }
    return Value.undefined_;
}

/// Where a caption, head or foot goes among a table's children.
fn tablePartPlace(p: *Page, table: NodeId, name: []const u8) ?NodeId {
    if (std.mem.eql(u8, name, "caption")) return p.doc.get(table).first_child;
    if (std.mem.eql(u8, name, "thead")) {
        var c = p.doc.get(table).first_child;
        while (c) |cid| : (c = p.doc.get(cid).next) if (!(p.doc.isHtml(cid, "caption") or p.doc.isHtml(cid, "colgroup"))) return cid;
        return null;
    }
    return null;
}

fn tableSetCaption(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return tableSetPart(vm, this, arg(args, 0), "caption");
}
fn tableSetTHead(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return tableSetPart(vm, this, arg(args, 0), "thead");
}
fn tableSetTFoot(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return tableSetPart(vm, this, arg(args, 0), "tfoot");
}

fn tableCreatePart(vm: *Vm, this: Value, name: []const u8) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    if (childNamed(p, id, name)) |old| return p.wrapValue(old);
    const part = try p.doc.createElement(.html, name);
    try insertNode(p, id, part, tablePartPlace(p, id, name));
    return p.wrapValue(part);
}
fn tableDeletePart(vm: *Vm, this: Value, name: []const u8) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    if (childNamed(p, id, name)) |old| p.detachNode(old);
    return Value.undefined_;
}
fn tableCreateCaption(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return tableCreatePart(vm, this, "caption");
}
fn tableDeleteCaption(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return tableDeletePart(vm, this, "caption");
}
fn tableCreateTHead(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return tableCreatePart(vm, this, "thead");
}
fn tableDeleteTHead(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return tableDeletePart(vm, this, "thead");
}
fn tableCreateTFoot(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return tableCreatePart(vm, this, "tfoot");
}
fn tableDeleteTFoot(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return tableDeletePart(vm, this, "tfoot");
}
fn tableCreateTBody(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const body = try p.doc.createElement(.html, "tbody");
    // After the last tbody, else at the end.
    var last: ?NodeId = null;
    var c = p.doc.get(id).first_child;
    while (c) |cid| : (c = p.doc.get(cid).next) if (p.doc.isHtml(cid, "tbody")) {
        last = cid;
    };
    try insertNode(p, id, body, if (last) |l| p.doc.get(l).next else null);
    return p.wrapValue(body);
}

fn tableTBodies(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    var ids: std.ArrayList(NodeId) = .empty;
    var c = p.doc.get(id).first_child;
    while (c) |cid| : (c = p.doc.get(cid).next) if (p.doc.isHtml(cid, "tbody")) try ids.append(sc.a(), cid);
    return nodeList(vm, ids.items);
}

/// A table's rows: the head's, then the bodies' and the table's own in
/// tree order, then the foot's.
fn tableRowIds(p: *Page, table: NodeId, a: std.mem.Allocator) Error![]NodeId {
    var ids: std.ArrayList(NodeId) = .empty;
    var c = p.doc.get(table).first_child;
    while (c) |cid| : (c = p.doc.get(cid).next) if (p.doc.isHtml(cid, "thead")) {
        var r = p.doc.get(cid).first_child;
        while (r) |rid| : (r = p.doc.get(rid).next) if (p.doc.isHtml(rid, "tr")) try ids.append(a, rid);
    };
    c = p.doc.get(table).first_child;
    while (c) |cid| : (c = p.doc.get(cid).next) {
        if (p.doc.isHtml(cid, "tr")) try ids.append(a, cid);
        if (p.doc.isHtml(cid, "tbody")) {
            var r = p.doc.get(cid).first_child;
            while (r) |rid| : (r = p.doc.get(rid).next) if (p.doc.isHtml(rid, "tr")) try ids.append(a, rid);
        }
    }
    c = p.doc.get(table).first_child;
    while (c) |cid| : (c = p.doc.get(cid).next) if (p.doc.isHtml(cid, "tfoot")) {
        var r = p.doc.get(cid).first_child;
        while (r) |rid| : (r = p.doc.get(rid).next) if (p.doc.isHtml(rid, "tr")) try ids.append(a, rid);
    };
    return ids.items;
}

fn tableRows(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    return nodeList(vm, try tableRowIds(p, id, sc.a()));
}

fn indexArg(vm: *Vm, v: Value, len: usize) Error!?usize {
    const n = if (v.isUndefined()) -1 else try vm.toIntegerOrInfinity(v);
    if (n < -1 or n > @as(f64, @floatFromInt(len))) return throwDom(vm, .IndexSizeError, "the index is past the rows");
    if (n == -1 or n == @as(f64, @floatFromInt(len))) return null;
    return @intFromFloat(n);
}

fn tableInsertRow(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const rows = try tableRowIds(p, id, sc.a());
    const at = try indexArg(vm, arg(args, 0), rows.len);
    const row = try p.doc.createElement(.html, "tr");
    if (at) |i| {
        try insertNode(p, p.doc.get(rows[i]).parent.?, row, rows[i]);
    } else {
        // At the end: into the last tbody, made if the table has none.
        var last_body: ?NodeId = null;
        var c = p.doc.get(id).first_child;
        while (c) |cid| : (c = p.doc.get(cid).next) if (p.doc.isHtml(cid, "tbody")) {
            last_body = cid;
        };
        if (last_body == null and rows.len == 0) {
            const body = try p.doc.createElement(.html, "tbody");
            try insertNode(p, id, body, null);
            last_body = body;
        }
        if (last_body) |b| try insertNode(p, b, row, null) else try insertNode(p, id, row, null);
    }
    return p.wrapValue(row);
}

fn tableDeleteRow(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const rows = try tableRowIds(p, id, sc.a());
    const n = try vm.toIntegerOrInfinity(arg(args, 0));
    if (n == -1) {
        if (rows.len > 0) p.detachNode(rows[rows.len - 1]);
        return Value.undefined_;
    }
    if (n < 0 or n >= @as(f64, @floatFromInt(rows.len))) return throwDom(vm, .IndexSizeError, "no row at the index");
    p.detachNode(rows[@intFromFloat(n)]);
    return Value.undefined_;
}

fn sectionRowIds(p: *Page, section: NodeId, a: std.mem.Allocator) Error![]NodeId {
    var ids: std.ArrayList(NodeId) = .empty;
    var r = p.doc.get(section).first_child;
    while (r) |rid| : (r = p.doc.get(rid).next) if (p.doc.isHtml(rid, "tr")) try ids.append(a, rid);
    return ids.items;
}

fn sectionRows(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    return nodeList(vm, try sectionRowIds(p, id, sc.a()));
}

fn sectionInsertRow(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const rows = try sectionRowIds(p, id, sc.a());
    const at = try indexArg(vm, arg(args, 0), rows.len);
    const row = try p.doc.createElement(.html, "tr");
    try insertNode(p, id, row, if (at) |i| rows[i] else null);
    return p.wrapValue(row);
}

fn sectionDeleteRow(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const rows = try sectionRowIds(p, id, sc.a());
    const n = try vm.toIntegerOrInfinity(arg(args, 0));
    if (n == -1) {
        if (rows.len > 0) p.detachNode(rows[rows.len - 1]);
        return Value.undefined_;
    }
    if (n < 0 or n >= @as(f64, @floatFromInt(rows.len))) return throwDom(vm, .IndexSizeError, "no row at the index");
    p.detachNode(rows[@intFromFloat(n)]);
    return Value.undefined_;
}

fn rowTable(p: *Page, row: NodeId) ?NodeId {
    var up = p.doc.get(row).parent;
    while (up) |u| : (up = p.doc.get(u).parent) if (p.doc.isHtml(u, "table")) return u;
    return null;
}

fn rowIndex(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const table = rowTable(p, id) orelse return Value.fromInt(-1);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    for (try tableRowIds(p, table, sc.a()), 0..) |r, i| if (r == id) return Value.fromInt(@intCast(i));
    return Value.fromInt(-1);
}

fn sectionRowIndex(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const parent = p.doc.get(id).parent orelse return Value.fromInt(-1);
    var i: i32 = 0;
    var r = p.doc.get(parent).first_child;
    while (r) |rid| : (r = p.doc.get(rid).next) if (p.doc.isHtml(rid, "tr")) {
        if (rid == id) return Value.fromInt(i);
        i += 1;
    };
    return Value.fromInt(-1);
}

fn rowCellIds(p: *Page, row: NodeId, a: std.mem.Allocator) Error![]NodeId {
    var ids: std.ArrayList(NodeId) = .empty;
    var c = p.doc.get(row).first_child;
    while (c) |cid| : (c = p.doc.get(cid).next) if (p.doc.isHtml(cid, "td") or p.doc.isHtml(cid, "th")) try ids.append(a, cid);
    return ids.items;
}

fn rowCells(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    return nodeList(vm, try rowCellIds(p, id, sc.a()));
}

fn rowInsertCell(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const cells = try rowCellIds(p, id, sc.a());
    const at = try indexArg(vm, arg(args, 0), cells.len);
    const cell = try p.doc.createElement(.html, "td");
    try insertNode(p, id, cell, if (at) |i| cells[i] else null);
    return p.wrapValue(cell);
}

fn rowDeleteCell(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const cells = try rowCellIds(p, id, sc.a());
    const n = try vm.toIntegerOrInfinity(arg(args, 0));
    if (n == -1) {
        if (cells.len > 0) p.detachNode(cells[cells.len - 1]);
        return Value.undefined_;
    }
    if (n < 0 or n >= @as(f64, @floatFromInt(cells.len))) return throwDom(vm, .IndexSizeError, "no cell at the index");
    p.detachNode(cells[@intFromFloat(n)]);
    return Value.undefined_;
}

fn cellIndex(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const parent = p.doc.get(id).parent orelse return Value.fromInt(-1);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    for (try rowCellIds(p, parent, sc.a()), 0..) |c, i| if (c == id) return Value.fromInt(@intCast(i));
    return Value.fromInt(-1);
}

// ---------------------------------------------------------------- SVG

fn svgOwner(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var up = p.doc.get(id).parent;
    while (up) |u| : (up = p.doc.get(u).parent) if (p.doc.isElement(u, .svg, "svg")) return p.wrapValue(u);
    return Value.null_;
}

/// An SVGAnimatedLength: `baseVal` and `animVal` (no animation runs
/// here, so the same), each an SVGLength read from the attribute as a
/// user-unit number.
fn svgLength(vm: *Vm, this: Value, name: []const u8) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const raw = std.mem.trim(u8, p.doc.getAttr(id, name) orelse "0", " \t\r\n");
    var end: usize = 0;
    while (end < raw.len and (std.ascii.isDigit(raw[end]) or raw[end] == '.' or raw[end] == '-' or raw[end] == '+' or raw[end] == 'e' or raw[end] == 'E')) end += 1;
    const value = std.fmt.parseFloat(f64, raw[0..end]) catch 0;
    const unit_type: i32 = if (end == raw.len) 1 else if (std.mem.eql(u8, raw[end..], "px")) 5 else if (std.mem.eql(u8, raw[end..], "%")) 2 else 0;
    const animated = try vm.newObject();
    const mark = vm.heap.tempMark();
    defer vm.heap.tempRelease(mark);
    vm.heap.tempPush(animated.cell());
    for ([_][]const u8{ "baseVal", "animVal" }) |k| {
        const len = try vm.newObject();
        vm.heap.tempPush(len.cell());
        try vm.defineValue(len, "value", Value.fromF64(value), .default);
        try vm.defineValue(len, "valueInSpecifiedUnits", Value.fromF64(value), .default);
        try vm.defineValue(len, "unitType", Value.fromInt(unit_type), .default);
        try vm.defineValue(len, "valueAsString", try jsStr(vm, raw), .default);
        try vm.defineValue(animated, k, len.asValue(), .default);
    }
    return animated.asValue();
}
fn svgLengthX(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return svgLength(vm, this, "x");
}
fn svgLengthY(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return svgLength(vm, this, "y");
}
fn svgLengthWidth(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return svgLength(vm, this, "width");
}
fn svgLengthHeight(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return svgLength(vm, this, "height");
}

/// The characters of a text element (UTF-16 units, as the DOM counts).
fn svgNumberOfChars(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const text = p.doc.textContent(id, sc.a()) catch return error.OutOfMemory;
    return Value.fromInt(@intCast(utf16Len(text)));
}

/// No SVG text is laid out here: the length is the characters' count at
/// the font size, the plainest estimate.
fn svgComputedTextLength(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const text = p.doc.textContent(id, sc.a()) catch return error.OutOfMemory;
    const size = std.fmt.parseFloat(f64, std.mem.trim(u8, p.doc.getAttr(id, "font-size") orelse "16", " ")) catch 16;
    return Value.fromF64(@as(f64, @floatFromInt(utf16Len(text))) * size * 0.5);
}

// ------------------------------------------------------------- images

/// An image's rendered size: its box in the page; in a frame, which is
/// not laid out, the cascade's `width`/`height` when they are lengths,
/// else the attributes.
fn imageSize(vm: *Vm, this: Value, axis: u8) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const name: []const u8 = if (axis == 0) "width" else "height";
    if (p.cur == 0) {
        if (p.host.rect) |f| if (f(p.host.ctx, id)) |r| return Value.fromF64(@round(r[2 + axis]));
    } else {
        var buf: [64]u8 = undefined;
        if (try frameComputed(p, id, name, &buf)) |text| if (std.mem.endsWith(u8, text, "px")) {
            if (std.fmt.parseFloat(f64, text[0 .. text.len - 2])) |px| return Value.fromF64(@round(px)) else |_| {}
        };
    }
    const attr = p.doc.getAttr(id, name) orelse return Value.fromInt(0);
    return Value.fromInt(std.fmt.parseInt(i32, std.mem.trim(u8, attr, " "), 10) catch 0);
}
fn imageWidth(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return imageSize(vm, this, 0);
}
fn imageHeight(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return imageSize(vm, this, 1);
}
fn setWidthAttr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "width", try vm.toStringValue(arg(args, 0)));
}
fn setHeightAttr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "height", try vm.toStringValue(arg(args, 0)));
}

// -------------------------------------------------------------- forms

fn getActionAttr(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return attrGetter(vm, this, "action");
}
fn setActionAttr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "action", arg(args, 0));
}
fn getMethodAttr(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const id = try thisElement(vm, this);
    const m = pageOf(vm).doc.getAttr(id, "method") orelse "get";
    return jsStr(vm, if (std.ascii.eqlIgnoreCase(m, "post")) "post" else "get");
}
fn setMethodAttr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "method", arg(args, 0));
}

fn isControl(p: *Page, id: NodeId) bool {
    return p.doc.isHtml(id, "input") or p.doc.isHtml(id, "select") or p.doc.isHtml(id, "textarea") or p.doc.isHtml(id, "button");
}

fn getFormElements(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    var ids: std.ArrayList(NodeId) = .empty;
    var w = p.doc.walk(id);
    while (w.next()) |c| if (isControl(p, c)) try ids.append(sc.a(), c);
    return namedCollection(vm, ids.items);
}

fn getFormLength(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var n: i32 = 0;
    var w = p.doc.walk(id);
    while (w.next()) |c| if (isControl(p, c)) {
        n += 1;
    };
    return Value.fromInt(n);
}

fn formSubmit(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    if (p.host.submit) |f| f(p.host.ctx, id) else p.log(.warn, "script: form.submit() has no host");
    return Value.undefined_;
}

fn formRequestSubmit(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    if (!p.submitHere(id)) return Value.undefined_;
    if (p.cur == 0) if (p.host.submit) |f| f(p.host.ctx, id);
    return Value.undefined_;
}

fn formReset(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const target = try p.wrapValue(id);
    if (!p.fireSimple(target, "reset", true, true)) return Value.undefined_;
    var w = p.doc.walk(id);
    while (w.next()) |c| if (isControl(p, c)) {
        // Back to the markup's values: what the user typed or toggled goes.
        if (p.doc.isHtml(c, "textarea")) continue;
        if (p.doc.getAttr(c, "type")) |t| if (std.ascii.eqlIgnoreCase(t, "checkbox") or std.ascii.eqlIgnoreCase(t, "radio")) continue;
        if (p.doc.isHtml(c, "input")) p.doc.removeAttr(c, "value");
    };
    p.touch();
    return Value.undefined_;
}

fn getOwnerForm(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var cur = p.doc.get(id).parent;
    while (cur) |c| : (cur = p.doc.get(c).parent) if (p.doc.isHtml(c, "form")) return p.wrapValue(c);
    return Value.null_;
}

fn getSelectedIndex(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var i: i32 = 0;
    var w = p.doc.walk(id);
    while (w.next()) |c| if (p.doc.isHtml(c, "option")) {
        if (p.doc.hasAttr(c, "selected")) return Value.fromInt(i);
        i += 1;
    };
    return Value.fromInt(if (i > 0) 0 else -1);
}

fn getOptions(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return collectByTag(vm, this, &.{"option"});
}

fn timerArgs(vm: *Vm, args: []const Value, interval: bool) Error!Value {
    const p = pageOf(vm);
    const func = arg(args, 0);
    if (!vm.isCallable(func)) return Value.fromInt(0); // a string handler: not run
    const delay = if (args.len > 1) (vm.toNumber(args[1]) catch 0) else 0;
    const d = if (std.math.isNan(delay)) 0 else delay;
    return p.addTimer(func, if (args.len > 2) args[2..] else &.{}, d, interval, false);
}

fn setTimeout(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return timerArgs(vm, args, false);
}

fn setInterval(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return timerArgs(vm, args, true);
}

fn clearTimer(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const v = arg(args, 0);
    if (!v.isNumber()) return Value.undefined_;
    const id = v.asNumber();
    if (id < 1 or id > 4294967295.0) return Value.undefined_;
    p.removeTimer(@intFromFloat(id));
    return Value.undefined_;
}

fn requestAnimationFrame(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const func = arg(args, 0);
    if (!vm.isCallable(func)) return vm.throwTypeError("requestAnimationFrame needs a function");
    return p.addTimer(func, &.{}, 0, false, true);
}

fn queueMicrotask(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const func = arg(args, 0);
    if (!vm.isCallable(func)) return vm.throwTypeError("queueMicrotask needs a function");
    try vm.jobs.append(vm.meta, .{ .func = func, .args = .{ Value.undefined_, Value.undefined_, Value.undefined_ }, .argc = 0 });
    return Value.undefined_;
}

// ---------------------------------------------------- CSSStyleDeclaration

fn getNull(_: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    return Value.null_;
}
fn getZero(_: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    return Value.fromInt(0);
}
fn setIgnored(_: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    return Value.undefined_;
}

/// `el.style`: one object per element, kept on the wrapper.
fn getStyle(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const w = Vm.asObject(this);
    if (try vm.objects.getOwn(w, .{ .symbol = p.sym_style })) |own| return own.val;
    const o = try vm.objects.create(p.protos[I.style].asValue(), .dom, @sizeOf(Slot));
    o.internal(Slot).* = .{ .kind = slot_style, .id = id, .flags = 0, .doc = p.cur };
    _ = try vm.objects.defineOwn(w, .{ .symbol = p.sym_style }, o.asValue(), .hidden);
    return o.asValue();
}

const StyleRef = struct { id: NodeId, computed: bool, doc: u32 };

fn thisStyle(vm: *Vm, this: Value) Error!StyleRef {
    if (this.isObject()) {
        const o = Vm.asObject(this);
        if (o.class == .dom and o.internal(Slot).kind == slot_style) {
            pageOf(vm).switchTo(o.internal(Slot).doc);
            return .{ .id = o.internal(Slot).id, .computed = o.internal(Slot).flags & style_computed != 0, .doc = o.internal(Slot).doc };
        }
    }
    return vm.throwTypeError("Illegal invocation");
}

const Decl = struct { name: []const u8, value: []const u8, important: bool };

/// The element's `style` attribute as declarations (in `a`).
fn declarationsOf(p: *Page, id: NodeId, a: std.mem.Allocator) Error![]Decl {
    var list: std.ArrayList(Decl) = .empty;
    const text = p.doc.getAttr(id, "style") orelse return list.items;
    var parser = css.Parser.init(a, text, false) catch return error.OutOfMemory;
    const items = parser.parseBlockContents() catch return error.OutOfMemory;
    for (items) |item| if (item == .declaration) {
        const d = item.declaration;
        const name = try a.dupe(u8, d.name);
        for (name) |*c| c.* = std.ascii.toLower(c.*);
        const value = css.valuesText(a, d.value) catch return error.OutOfMemory;
        // A later declaration of the same name replaces the earlier.
        var replaced = false;
        for (list.items) |*x| if (std.mem.eql(u8, x.name, name)) {
            x.* = .{ .name = name, .value = value, .important = d.important };
            replaced = true;
        };
        if (!replaced) try list.append(a, .{ .name = name, .value = value, .important = d.important });
    };
    return list.items;
}

/// Write declarations back as the `style` attribute.
fn writeDeclarations(p: *Page, id: NodeId, decls: []const Decl) Error!void {
    var out: std.ArrayList(u8) = .empty;
    for (decls, 0..) |d, i| {
        if (i > 0) try out.append(p.doc.a, ' ');
        try out.appendSlice(p.doc.a, d.name);
        try out.appendSlice(p.doc.a, ": ");
        try out.appendSlice(p.doc.a, d.value);
        if (d.important) try out.appendSlice(p.doc.a, " !important");
        try out.append(p.doc.a, ';');
    }
    if (out.items.len == 0) p.removeAttr(id, "style") else try p.setAttr(id, "style", out.items);
}

fn stylePropertyGet(vm: *Vm, this: Value, name: []const u8) Error!Value {
    const p = pageOf(vm);
    const ref = try thisStyle(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    if (ref.computed) {
        if (ref.doc != 0) {
            var buf: [256]u8 = undefined;
            if (try frameComputed(p, ref.id, name, &buf)) |text| return jsStr(vm, text);
        } else if (p.host.computed) |f| {
            var buf: [256]u8 = undefined;
            if (f(p.host.ctx, ref.id, name, &buf)) |text| return jsStr(vm, text);
        }
    }
    const decls = try declarationsOf(p, ref.id, sc.a());
    for (decls) |d| if (std.mem.eql(u8, d.name, name)) return jsStr(vm, d.value);
    return jsStr(vm, "");
}

/// A computed property in the current document when it is not the
/// page's: the cascade run here, in scratch, with the host's user-agent
/// sheet, for the frame's viewport — the box its owner has in the page
/// (none: 0×0, as a frame the page hides), or a nominal one.
fn frameComputed(p: *Page, id: NodeId, name: []const u8, buf: []u8) Error!?[]const u8 {
    const ua = p.host.ua_sheet orelse return null;
    var arena = std.heap.ArenaAllocator.init(p.scratchBase());
    defer arena.deinit();
    const a = arena.allocator();
    const env = frameEnv(p);
    const sheets = stylelib.collectDocumentSheetsWith(a, p.doc, env, ua.*) catch return error.OutOfMemory;
    const styles = stylelib.compute(a, p.doc, sheets, env) catch return error.OutOfMemory;
    if (id >= styles.computed.len) return null;
    return stylelib.propertyText(styles.get(id), name, buf);
}

fn frameEnv(p: *Page) stylelib.Env {
    const owner = p.docs.items[p.cur].owner orelse return .{ .width = 1024, .height = 768 };
    if (owner.doc != 0) return .{ .width = 1024, .height = 768 };
    const rect = p.host.rect orelse return .{ .width = 1024, .height = 768 };
    const r = rect(p.host.ctx, owner.id) orelse return .{ .width = 0, .height = 0 };
    return .{ .width = r[2], .height = r[3] };
}

fn stylePropertySet(vm: *Vm, this: Value, name: []const u8, v: Value, important: bool) Error!Value {
    const p = pageOf(vm);
    const ref = try thisStyle(vm, this);
    if (ref.computed) return vm.throwError(.TypeError, "NoModificationAllowedError: a computed style is read-only");
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const raw = if (v.isNullish()) "" else try strArg(vm, v, sc.a());
    const value = std.mem.trim(u8, raw, " \t\r\n");
    var decls = std.ArrayList(Decl).fromOwnedSlice(try declarationsOf(p, ref.id, sc.a()));
    var i: usize = 0;
    var found = false;
    while (i < decls.items.len) {
        if (std.mem.eql(u8, decls.items[i].name, name)) {
            if (value.len == 0) {
                _ = decls.orderedRemove(i);
                continue;
            }
            decls.items[i].value = try p.doc.a.dupe(u8, value);
            decls.items[i].important = important;
            found = true;
        }
        i += 1;
    }
    if (!found and value.len > 0) try decls.append(sc.a(), .{ .name = try p.doc.a.dupe(u8, name), .value = try p.doc.a.dupe(u8, value), .important = important });
    try writeDeclarations(p, ref.id, decls.items);
    return Value.undefined_;
}

fn propertyNameArg(vm: *Vm, v: Value, a: std.mem.Allocator) Error![]u8 {
    const s = try strArg(vm, v, a);
    for (s) |*c| c.* = std.ascii.toLower(c.*);
    return @constCast(std.mem.trim(u8, s, " \t\r\n"));
}

fn styleGetPropertyValue(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const name = try propertyNameArg(vm, arg(args, 0), sc.a());
    return stylePropertyGet(vm, this, name);
}

fn styleGetPropertyPriority(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const ref = try thisStyle(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const name = try propertyNameArg(vm, arg(args, 0), sc.a());
    const decls = try declarationsOf(p, ref.id, sc.a());
    for (decls) |d| if (std.mem.eql(u8, d.name, name)) return jsStr(vm, if (d.important) "important" else "");
    return jsStr(vm, "");
}

fn styleSetProperty(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const name = try propertyNameArg(vm, arg(args, 0), sc.a());
    if (name.len == 0) return Value.undefined_;
    const prio = arg(args, 2);
    const important = !prio.isNullish() and std.ascii.eqlIgnoreCase(try strArg(vm, prio, sc.a()), "important");
    return stylePropertySet(vm, this, name, arg(args, 1), important);
}

fn styleRemoveProperty(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const name = try propertyNameArg(vm, arg(args, 0), sc.a());
    const old = try stylePropertyGet(vm, this, name);
    _ = try stylePropertySet(vm, this, name, Value.undefined_, false);
    return old;
}

fn styleItem(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const ref = try thisStyle(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const decls = try declarationsOf(p, ref.id, sc.a());
    const i = try vm.toIntegerOrInfinity(arg(args, 0));
    if (i < 0 or i >= @as(f64, @floatFromInt(decls.len))) return jsStr(vm, "");
    return jsStr(vm, decls[@intFromFloat(i)].name);
}

fn styleLength(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const ref = try thisStyle(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const decls = try declarationsOf(p, ref.id, sc.a());
    return Value.fromInt(@intCast(decls.len));
}

fn styleCssText(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const ref = try thisStyle(vm, this);
    if (ref.computed) return jsStr(vm, "");
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const decls = try declarationsOf(p, ref.id, sc.a());
    var out: std.ArrayList(u8) = .empty;
    for (decls, 0..) |d, i| {
        if (i > 0) try out.append(sc.a(), ' ');
        try out.appendSlice(sc.a(), d.name);
        try out.appendSlice(sc.a(), ": ");
        try out.appendSlice(sc.a(), d.value);
        if (d.important) try out.appendSlice(sc.a(), " !important");
        try out.append(sc.a(), ';');
    }
    return jsStr(vm, out.items);
}

fn styleSetCssText(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const ref = try thisStyle(vm, this);
    if (ref.computed) return vm.throwError(.TypeError, "NoModificationAllowedError: a computed style is read-only");
    const v = arg(args, 0);
    const text = if (v.isNullish()) "" else try docStr(vm, v);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) p.removeAttr(ref.id, "style") else try p.setAttr(ref.id, "style", text);
    return Value.undefined_;
}

// ------------------------------------------------------------- geometry

fn rectOf(p: *Page, id: NodeId) ?[4]f64 {
    const f = p.host.rect orelse return null;
    return f(p.host.ctx, id);
}

fn getClientWidth(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const r = rectOf(p, id) orelse return Value.fromInt(0);
    return Value.fromF64(@round(r[2]));
}

fn getClientHeight(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const r = rectOf(p, id) orelse return Value.fromInt(0);
    return Value.fromF64(@round(r[3]));
}

fn getOffsetTop(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const r = rectOf(p, id) orelse return Value.fromInt(0);
    return Value.fromF64(@round(r[1] + p.scroll_y));
}

fn getOffsetLeft(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const r = rectOf(p, id) orelse return Value.fromInt(0);
    return Value.fromF64(@round(r[0] + p.scroll_x));
}

fn rectObject(vm: *Vm, r: [4]f64) Error!Value {
    const o = try vm.newObject();
    const mark = vm.heap.tempMark();
    defer vm.heap.tempRelease(mark);
    vm.heap.tempPush(o.cell());
    try vm.defineValue(o, "x", Value.fromF64(r[0]), .default);
    try vm.defineValue(o, "y", Value.fromF64(r[1]), .default);
    try vm.defineValue(o, "width", Value.fromF64(r[2]), .default);
    try vm.defineValue(o, "height", Value.fromF64(r[3]), .default);
    try vm.defineValue(o, "top", Value.fromF64(r[1]), .default);
    try vm.defineValue(o, "left", Value.fromF64(r[0]), .default);
    try vm.defineValue(o, "right", Value.fromF64(r[0] + r[2]), .default);
    try vm.defineValue(o, "bottom", Value.fromF64(r[1] + r[3]), .default);
    return o.asValue();
}

fn getBoundingClientRect(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    return rectObject(vm, rectOf(p, id) orelse .{ 0, 0, 0, 0 });
}

fn getClientRects(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const arr = try vm.newArray(0);
    if (rectOf(p, id)) |r| {
        const mark = vm.heap.tempMark();
        defer vm.heap.tempRelease(mark);
        vm.heap.tempPush(arr.cell());
        try vm.arrayPush(arr, try rectObject(vm, r));
    }
    return arr.asValue();
}

fn scrollIntoView(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    const r = rectOf(p, id) orelse return Value.undefined_;
    if (p.host.scroll) |f| f(p.host.ctx, p.scroll_x, p.scroll_y + r[1]);
    return Value.undefined_;
}

// ------------------------------------------------------------ requests

/// A request's URL resolved against the document, and the document's
/// origin when the request crosses it ("" when same-origin).
const Resolved = struct { url: []const u8, origin: []const u8 };

fn resolveRequest(p: *Page, raw: []const u8, a: std.mem.Allocator) ?Resolved {
    const base = url.parse(a, p.url, null) catch return null;
    const u = url.parse(a, raw, &base) catch return null;
    const o1 = base.origin(a) catch return null;
    const o2 = u.origin(a) catch return null;
    if (std.mem.eql(u8, o1, "null")) return null;
    return .{ .url = u.href(a) catch return null, .origin = if (std.mem.eql(u8, o1, o2)) "" else o1 };
}

/// The absolute URL of a request, resolved against the document, when
/// it is same-origin; null otherwise.
fn sameOriginUrl(p: *Page, raw: []const u8, a: std.mem.Allocator) ?[]const u8 {
    const base = url.parse(a, p.url, null) catch return null;
    const u = url.parse(a, raw, &base) catch return null;
    const o1 = base.origin(a) catch return null;
    const o2 = u.origin(a) catch return null;
    if (std.mem.eql(u8, o1, "null") or !std.mem.eql(u8, o1, o2)) return null;
    return u.href(a) catch null;
}

fn rejectedPromise(vm: *Vm, kind: js.vm.ErrorKind, msg: []const u8) Error!Value {
    const cap = try js.builtins.promise.newCapability(vm, vm.intrinsics.promise_ctor.asValue());
    const err = try vm.newError(kind, msg);
    _ = try vm.call(cap.reject, Value.undefined_, &.{err.asValue()});
    return cap.promise;
}

const Request = struct { url: []const u8, post: bool, body: []const u8, origin: []const u8 = "" };

/// `fetch`'s and XHR's arguments read: the URL (resolved, same-origin),
/// the method, the body.
fn readRequest(vm: *Vm, url_v: Value, method_v: Value, body_v: Value, a: std.mem.Allocator) Error!union(enum) { ok: Request, bad: []const u8 } {
    const p = pageOf(vm);
    var raw_url: []const u8 = "";
    if (url_v.isObject()) {
        const uo = Vm.asObject(url_v);
        const inner = try vm.get(uo, .{ .atom = try vm.atom("url") }, url_v);
        raw_url = try strArg(vm, if (inner.isUndefined()) url_v else inner, a);
    } else raw_url = try strArg(vm, url_v, a);
    const r = resolveRequest(p, raw_url, a) orelse return .{ .bad = "not a URL a page can request" };
    var post = false;
    if (!method_v.isNullish()) {
        const m = try strArg(vm, method_v, a);
        if (std.ascii.eqlIgnoreCase(m, "POST")) post = true else if (!std.ascii.eqlIgnoreCase(m, "GET") and !std.ascii.eqlIgnoreCase(m, "HEAD")) return .{ .bad = "only GET and POST are allowed from a page yet" };
    }
    var body: []const u8 = "";
    if (!body_v.isNullish()) body = try strArg(vm, body_v, a);
    return .{ .ok = .{ .url = r.url, .post = post, .body = body, .origin = r.origin } };
}

fn doRequest(p: *Page, req: Request, a: std.mem.Allocator, out: *Response) bool {
    const f = p.host.request orelse {
        out.refused = "this page has no network";
        return false;
    };
    return f(p.host.ctx, a, req.url, req.post, req.body, req.origin, out);
}

/// A native that closes over a string: `text()` and `json()` on a
/// Response read their body from the function's data slot.
fn nativeData(vm: *Vm) Value {
    const fo = vm.current_native orelse return Value.undefined_;
    return Vm.functionData(fo).data;
}

fn responseText(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    return js.realm.promiseResolve(vm, nativeData(vm));
}

fn responseJson(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    const json = try vm.get(vm.global, .{ .atom = try vm.atom("JSON") }, vm.global.asValue());
    if (!json.isObject()) return rejectedPromise(vm, .TypeError, "no JSON");
    const parse = try vm.get(Vm.asObject(json), .{ .atom = try vm.atom("parse") }, json);
    const v = vm.call(parse, json, &.{nativeData(vm)}) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.Exception => {
            const ex = vm.exception;
            vm.exception = Value.undefined_;
            const cap = try js.builtins.promise.newCapability(vm, vm.intrinsics.promise_ctor.asValue());
            _ = try vm.call(cap.reject, Value.undefined_, &.{ex});
            return cap.promise;
        },
    };
    return js.realm.promiseResolve(vm, v);
}

fn headersGet(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const name = try strArg(vm, arg(args, 0), sc.a());
    if (std.ascii.eqlIgnoreCase(name, "content-type")) {
        const ct = nativeData(vm);
        return if (ct.isString() and Vm.asString(ct).len > 0) ct else Value.null_;
    }
    return Value.null_;
}

fn headersHas(vm: *Vm, this: Value, args: []const Value, nt: Value) Error!Value {
    const v = try headersGet(vm, this, args, nt);
    return Value.fromBool(!v.isNull());
}

fn statusText(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        500 => "Internal Server Error",
        else => "",
    };
}

/// A Response object over what came back.
fn responseObject(vm: *Vm, r: *const Response) Error!Value {
    const o = try vm.newObject();
    const mark = vm.heap.tempMark();
    defer vm.heap.tempRelease(mark);
    vm.heap.tempPush(o.cell());
    const body = try vm.str(r.body);
    const ctype = try vm.str(r.content_type);
    try vm.defineValue(o, "ok", Value.fromBool(r.status >= 200 and r.status < 300), .default);
    try vm.defineValue(o, "status", Value.fromInt(r.status), .default);
    try vm.defineValue(o, "statusText", try vm.str(statusText(r.status)), .default);
    try vm.defineValue(o, "url", try vm.str(r.url), .default);
    try vm.defineValue(o, "redirected", Value.false_, .default);
    try vm.defineValue(o, "type", try vm.str("basic"), .default);
    try vm.defineValue(o, "bodyUsed", Value.false_, .default);
    const headers = try vm.newObject();
    const hget = try vm.newNative("get", 1, headersGet, ctype);
    _ = try vm.objects.defineOwn(headers, .{ .atom = try vm.atom("get") }, hget.asValue(), .hidden);
    const hhas = try vm.newNative("has", 1, headersHas, ctype);
    _ = try vm.objects.defineOwn(headers, .{ .atom = try vm.atom("has") }, hhas.asValue(), .hidden);
    try vm.defineValue(o, "headers", headers.asValue(), .default);
    const text = try vm.newNative("text", 0, responseText, body);
    _ = try vm.objects.defineOwn(o, .{ .atom = try vm.atom("text") }, text.asValue(), .hidden);
    const json = try vm.newNative("json", 0, responseJson, body);
    _ = try vm.objects.defineOwn(o, .{ .atom = try vm.atom("json") }, json.asValue(), .hidden);
    return o.asValue();
}

/// `fetch(url, { method, body })`: the whole resource through the host,
/// same-origin, as a promise of a Response. The page waits on the
/// host while it comes (one resource at a time is what the page's
/// channel carries), so a slow server is a slow script — the price of
/// a page with one capability, paid once per request.
fn fetchNative(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    var method = Value.undefined_;
    var body = Value.undefined_;
    const init = arg(args, 1);
    if (init.isObject()) {
        const io = Vm.asObject(init);
        method = try vm.get(io, .{ .atom = try vm.atom("method") }, init);
        body = try vm.get(io, .{ .atom = try vm.atom("body") }, init);
    }
    const req = switch (try readRequest(vm, arg(args, 0), method, body, sc.a())) {
        .ok => |r| r,
        .bad => |why| return rejectedPromise(vm, .TypeError, why),
    };
    var out: Response = .{};
    if (!doRequest(p, req, sc.a(), &out)) {
        var msg: [256]u8 = undefined;
        return rejectedPromise(vm, .TypeError, std.fmt.bufPrint(&msg, "fetch: {s}", .{out.refused}) catch "fetch refused");
    }
    return js.realm.promiseResolve(vm, try responseObject(vm, &out));
}

// ------------------------------------------------------- CSSStyleSheet

fn isSheetElement(p: *Page, id: NodeId) bool {
    if (p.doc.isHtml(id, "style")) return true;
    if (!p.doc.isHtml(id, "link")) return false;
    const rel = p.doc.getAttr(id, "rel") orelse return false;
    var it = std.mem.tokenizeAny(u8, rel, " \t\r\n");
    while (it.next()) |tok| if (std.ascii.eqlIgnoreCase(tok, "stylesheet")) return true;
    return false;
}

fn sheetObject(p: *Page, id: NodeId) Error!Value {
    const vm = p.vm;
    const o = try vm.objects.create(p.protos[I.sheet].asValue(), .dom, @sizeOf(Slot));
    o.internal(Slot).* = .{ .kind = slot_sheet, .id = id, .doc = p.cur };
    return o.asValue();
}

/// `document.styleSheets`: the `<style>` and `<link rel=stylesheet>`
/// elements, in document order (a snapshot, as the other lists are).
fn getStyleSheets(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    _ = try thisNode(vm, this);
    const arr = try vm.newArray(0);
    const mark = vm.heap.tempMark();
    defer vm.heap.tempRelease(mark);
    vm.heap.tempPush(arr.cell());
    var w = p.doc.walk(dom.document_id);
    while (w.next()) |id| if (p.doc.get(id).kind == .element and isSheetElement(p, id)) try vm.arrayPush(arr, try sheetObject(p, id));
    return arr.asValue();
}

fn thisSheet(vm: *Vm, this: Value) Error!NodeId {
    if (this.isObject()) {
        const o = Vm.asObject(this);
        if (o.class == .dom and o.internal(Slot).kind == slot_sheet) {
            pageOf(vm).switchTo(o.internal(Slot).doc);
            return o.internal(Slot).id;
        }
    }
    return vm.throwTypeError("Illegal invocation");
}

fn sheetHref(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisSheet(vm, this);
    if (!p.doc.isHtml(id, "link")) return Value.null_;
    const raw = p.doc.getAttr(id, "href") orelse return Value.null_;
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const base = url.parse(sc.a(), p.url, null) catch null;
    const u = url.parse(sc.a(), raw, if (base) |*b| b else null) catch return jsStr(vm, raw);
    return jsStr(vm, try u.href(sc.a()));
}

fn sheetOwnerNode(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    return p.wrapValue(try thisSheet(vm, this));
}

fn sheetType(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    _ = try thisSheet(vm, this);
    return jsStr(vm, "text/css");
}

fn sheetMedia(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisSheet(vm, this);
    return jsStr(vm, p.doc.getAttr(id, "media") orelse "");
}

fn sheetTitle(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisSheet(vm, this);
    if (p.doc.getAttr(id, "title")) |t| return jsStr(vm, t);
    return Value.null_;
}

fn sheetDisabled(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisSheet(vm, this);
    return Value.fromBool(p.doc.hasAttr(id, "disabled"));
}

fn sheetSetDisabled(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisSheet(vm, this);
    if (vm.toBoolean(arg(args, 0))) try p.setAttr(id, "disabled", "") else p.removeAttr(id, "disabled");
    return Value.undefined_;
}

/// A `<style>`'s text (a `<link>`'s is the page's, not here).
fn sheetText(p: *Page, id: NodeId, a: std.mem.Allocator) Error![]const u8 {
    if (!p.doc.isHtml(id, "style")) return "";
    return p.doc.textContent(id, a);
}

/// The rules of a sheet's text, as plain rule objects (a snapshot).
fn rulesOf(vm: *Vm, text: []const u8, a: std.mem.Allocator) Error!Value {
    const arr = try vm.newArray(0);
    const mark = vm.heap.tempMark();
    defer vm.heap.tempRelease(mark);
    vm.heap.tempPush(arr.cell());
    var parser = css.Parser.init(a, text, false) catch return error.OutOfMemory;
    const rules = parser.parseStylesheet() catch return error.OutOfMemory;
    for (rules) |r| {
        const o = try vm.newObject();
        try vm.arrayPush(arr, o.asValue());
        switch (r) {
            .err => continue,
            .qualified => |q| {
                const sel = css.valuesText(a, q.prelude) catch return error.OutOfMemory;
                const block = css.valuesText(a, q.block) catch return error.OutOfMemory;
                try vm.defineValue(o, "type", Value.fromInt(1), .default);
                try vm.defineValue(o, "selectorText", try vm.str(sel), .default);
                try vm.defineValue(o, "cssText", try vm.str(try std.fmt.allocPrint(a, "{s} {{ {s} }}", .{ sel, block })), .default);
                const style = try vm.newObject();
                try vm.defineValue(style, "cssText", try vm.str(block), .default);
                try vm.defineValue(o, "style", style.asValue(), .default);
            },
            .at => |at| {
                const prelude = css.valuesText(a, at.prelude) catch return error.OutOfMemory;
                const kind: i32 = if (std.ascii.eqlIgnoreCase(at.name, "media")) 4 else if (std.ascii.eqlIgnoreCase(at.name, "import")) 3 else if (std.ascii.eqlIgnoreCase(at.name, "font-face")) 5 else if (std.ascii.eqlIgnoreCase(at.name, "keyframes")) 7 else if (std.ascii.eqlIgnoreCase(at.name, "supports")) 12 else 0;
                try vm.defineValue(o, "type", Value.fromInt(kind), .default);
                const body = if (at.block) |b| (css.valuesText(a, b) catch return error.OutOfMemory) else null;
                const rule_text = if (body) |b| try std.fmt.allocPrint(a, "@{s} {s} {{ {s} }}", .{ at.name, prelude, b }) else try std.fmt.allocPrint(a, "@{s} {s};", .{ at.name, prelude });
                try vm.defineValue(o, "cssText", try vm.str(rule_text), .default);
                try vm.defineValue(o, "conditionText", try vm.str(prelude), .default);
            },
        }
    }
    return arr.asValue();
}

fn sheetRules(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisSheet(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    return rulesOf(vm, try sheetText(p, id, sc.a()), sc.a());
}

/// The sheet's rules as text again, one per line, with `text` put in at
/// `index` (or a rule taken out): a `<style>`'s content rewritten.
fn rewriteSheet(vm: *Vm, id: NodeId, insert: ?[]const u8, index: usize, remove: bool) Error!void {
    const p = pageOf(vm);
    if (!p.doc.isHtml(id, "style")) return vm.throwError(.TypeError, "NotAllowedError: only a <style> sheet can be changed here");
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const a = sc.a();
    const text = try sheetText(p, id, a);
    var parser = css.Parser.init(a, text, false) catch return error.OutOfMemory;
    const rules = parser.parseStylesheet() catch return error.OutOfMemory;
    var texts: std.ArrayList([]const u8) = .empty;
    for (rules) |r| switch (r) {
        .err => {},
        .qualified => |q| try texts.append(a, try std.fmt.allocPrint(a, "{s} {{ {s} }}", .{ css.valuesText(a, q.prelude) catch return error.OutOfMemory, css.valuesText(a, q.block) catch return error.OutOfMemory })),
        .at => |at| {
            const prelude = css.valuesText(a, at.prelude) catch return error.OutOfMemory;
            if (at.block) |b| try texts.append(a, try std.fmt.allocPrint(a, "@{s} {s} {{ {s} }}", .{ at.name, prelude, css.valuesText(a, b) catch return error.OutOfMemory })) else try texts.append(a, try std.fmt.allocPrint(a, "@{s} {s};", .{ at.name, prelude }));
        },
    };
    if (index > texts.items.len) return vm.throwError(.RangeError, "IndexSizeError: the index is past the rules");
    if (remove) {
        if (index == texts.items.len) return vm.throwError(.RangeError, "IndexSizeError: no rule at the index");
        _ = texts.orderedRemove(index);
    }
    if (insert) |t| try texts.insert(a, index, t);
    var out: std.ArrayList(u8) = .empty;
    for (texts.items) |t| {
        try out.appendSlice(a, t);
        try out.append(a, '\n');
    }
    while (p.doc.get(id).first_child) |c| p.doc.detach(c);
    p.doc.appendChild(id, try p.doc.createText(try p.doc.a.dupe(u8, out.items)));
    p.touch();
    p.markSheets();
}

fn sheetInsertRule(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const id = try thisSheet(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const text = try strArg(vm, arg(args, 0), sc.a());
    const idx = if (arg(args, 1).isUndefined()) 0 else try vm.toIntegerOrInfinity(arg(args, 1));
    if (idx < 0 or idx > 1e6) return vm.throwError(.RangeError, "IndexSizeError: the index is past the rules");
    try rewriteSheet(vm, id, text, @intFromFloat(idx), false);
    return Value.fromF64(idx);
}

fn sheetDeleteRule(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const id = try thisSheet(vm, this);
    const idx = try vm.toIntegerOrInfinity(arg(args, 0));
    if (idx < 0 or idx > 1e6) return vm.throwError(.RangeError, "IndexSizeError: the index is past the rules");
    try rewriteSheet(vm, id, null, @intFromFloat(idx), true);
    return Value.undefined_;
}

/// Wraps `localStorage` and `sessionStorage` in Proxies so a name is
/// an item: `s.foo`, `s.foo = 1`, `delete s.foo`, `'foo' in s`,
/// `Object.keys(s)`. The interface's own members still win.
const named_storage_source =
    \\(function () {
    \\  function wrap(store) {
    \\    var own = function (k) { return typeof k === 'symbol' || k in Storage.prototype; };
    \\    return new Proxy(store, {
    \\      get: function (t, k) { if (own(k)) { var v = t[k]; return typeof v === 'function' ? v.bind(t) : v; } var r = t.getItem(String(k)); return r === null ? undefined : r; },
    \\      set: function (t, k, v) { if (own(k)) { t[k] = v; return true; } t.setItem(String(k), String(v)); return true; },
    \\      has: function (t, k) { return own(k) || t.getItem(String(k)) !== null; },
    \\      deleteProperty: function (t, k) { if (!own(k)) t.removeItem(String(k)); return true; },
    \\      ownKeys: function (t) { var ks = []; for (var i = 0; i < t.length; i++) ks.push(t.key(i)); return ks; },
    \\      getOwnPropertyDescriptor: function (t, k) { if (own(k)) return undefined; var v = t.getItem(String(k)); return v === null ? undefined : { value: v, writable: true, enumerable: true, configurable: true }; }
    \\    });
    \\  }
    \\  Object.defineProperty(window, 'localStorage', { value: wrap(window.localStorage), configurable: true, writable: true, enumerable: false });
    \\  Object.defineProperty(window, 'sessionStorage', { value: wrap(window.sessionStorage), configurable: true, writable: true, enumerable: false });
    \\})();
;

/// `sheet.cssRules` is live: a list held across an `insertRule` shows
/// the new rule. The bindings hand back a fresh array per read, so the
/// list a script keeps is a Proxy that re-reads the sheet on every access.
const live_rules_source =
    \\(function () {
    \\  var d = Object.getOwnPropertyDescriptor(CSSStyleSheet.prototype, 'cssRules');
    \\  if (!d || !d.get) return;
    \\  var raw = d.get;
    \\  Object.defineProperty(CSSStyleSheet.prototype, 'cssRules', { configurable: true, enumerable: true, get: function () {
    \\    var sheet = this;
    \\    return new Proxy({}, {
    \\      get: function (t, k) { var r = raw.call(sheet); if (k === 'item') return function (i) { var v = r[i]; return v === undefined ? null : v; }; var v = r[k]; return typeof v === 'function' ? v.bind(r) : v; },
    \\      has: function (t, k) { return k in raw.call(sheet); },
    \\      ownKeys: function () { return Reflect.ownKeys(raw.call(sheet)); },
    \\      getOwnPropertyDescriptor: function (t, k) { var dd = Object.getOwnPropertyDescriptor(raw.call(sheet), k); if (dd) dd.configurable = true; return dd; }
    \\    });
    \\  } });
    \\})();
;

// ------------------------------------------------- the prelude's natives

/// `__urlParse(input, base?)`: the URL's components as the `URL`
/// interface names them, or null when it does not parse. The base is
/// the document's when none is given.
fn urlParseNative(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const a = sc.a();
    const input = try strArg(vm, arg(args, 0), a);
    const base_v = arg(args, 1);
    // The base: the one given, else the document's (a relative `new
    // URL('x')` throws in browsers; here it resolves, which serves pages
    // better than an error would).
    const base_text = if (base_v.isUndefined()) p.url else try strArg(vm, base_v, a);
    var base = url.parse(a, base_text, null) catch return Value.null_;
    const u = url.parse(a, input, &base) catch return Value.null_;
    const o = try vm.newObject();
    const mark = vm.heap.tempMark();
    defer vm.heap.tempRelease(mark);
    vm.heap.tempPush(o.cell());
    const protocol = try std.fmt.allocPrint(a, "{s}:", .{u.scheme});
    var hostport: []const u8 = "";
    var hostname: []const u8 = "";
    var port: []const u8 = "";
    if (u.host != null) {
        hostport = try u.hostString(a);
        hostname = hostport;
        if (u.port) |pt| {
            port = try std.fmt.allocPrint(a, "{d}", .{pt});
            if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |i| hostname = hostport[0..i];
        }
    }
    var copy = u;
    copy.query = null;
    copy.fragment = null;
    const no_qf = try copy.serialize(a, true);
    const prefix_len = protocol.len + (if (u.host != null) 2 + hostport.len + (if (u.username.len > 0) u.username.len + 1 + (if (u.password.len > 0) u.password.len + 1 else 0) else 0) else 0);
    const pathname = if (no_qf.len >= prefix_len) no_qf[prefix_len..] else "";
    const search = if (u.query) |q| (if (q.len > 0) try std.fmt.allocPrint(a, "?{s}", .{q}) else "") else "";
    const hash = if (u.fragment) |f| (if (f.len > 0) try std.fmt.allocPrint(a, "#{s}", .{f}) else "") else "";
    try vm.defineValue(o, "href", try jsStr(vm, try u.href(a)), .default);
    try vm.defineValue(o, "protocol", try jsStr(vm, protocol), .default);
    try vm.defineValue(o, "username", try jsStr(vm, u.username), .default);
    try vm.defineValue(o, "password", try jsStr(vm, u.password), .default);
    try vm.defineValue(o, "host", try jsStr(vm, hostport), .default);
    try vm.defineValue(o, "hostname", try jsStr(vm, hostname), .default);
    try vm.defineValue(o, "port", try jsStr(vm, port), .default);
    try vm.defineValue(o, "pathname", try jsStr(vm, pathname), .default);
    try vm.defineValue(o, "search", try jsStr(vm, search), .default);
    try vm.defineValue(o, "hash", try jsStr(vm, hash), .default);
    try vm.defineValue(o, "origin", try jsStr(vm, try u.origin(a)), .default);
    return o.asValue();
}

fn perfNowNative(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    return Value.fromF64(pageOf(vm).now());
}

fn currentScriptNative(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    return p.wrapValue(p.current_script);
}

// ---------------------------------------------------------- DOMException

/// The DOM's exception names and their legacy codes.
const DomError = enum { IndexSizeError, HierarchyRequestError, WrongDocumentError, InvalidCharacterError, NotFoundError, NotSupportedError, InvalidStateError, SyntaxError, InvalidModificationError, NamespaceError, InvalidAccessError, TypeMismatchError, SecurityError, NetworkError, AbortError, InvalidNodeTypeError, DataCloneError, NotAllowedError, QuotaExceededError };

const DomCode = struct { name: []const u8, legacy: []const u8, code: i32 };
const dom_codes = [_]DomCode{
    .{ .name = "IndexSizeError", .legacy = "INDEX_SIZE_ERR", .code = 1 },
    .{ .name = "DOMStringSizeError", .legacy = "DOMSTRING_SIZE_ERR", .code = 2 },
    .{ .name = "HierarchyRequestError", .legacy = "HIERARCHY_REQUEST_ERR", .code = 3 },
    .{ .name = "WrongDocumentError", .legacy = "WRONG_DOCUMENT_ERR", .code = 4 },
    .{ .name = "InvalidCharacterError", .legacy = "INVALID_CHARACTER_ERR", .code = 5 },
    .{ .name = "NoDataAllowedError", .legacy = "NO_DATA_ALLOWED_ERR", .code = 6 },
    .{ .name = "NoModificationAllowedError", .legacy = "NO_MODIFICATION_ALLOWED_ERR", .code = 7 },
    .{ .name = "NotFoundError", .legacy = "NOT_FOUND_ERR", .code = 8 },
    .{ .name = "NotSupportedError", .legacy = "NOT_SUPPORTED_ERR", .code = 9 },
    .{ .name = "InUseAttributeError", .legacy = "INUSE_ATTRIBUTE_ERR", .code = 10 },
    .{ .name = "InvalidStateError", .legacy = "INVALID_STATE_ERR", .code = 11 },
    .{ .name = "SyntaxError", .legacy = "SYNTAX_ERR", .code = 12 },
    .{ .name = "InvalidModificationError", .legacy = "INVALID_MODIFICATION_ERR", .code = 13 },
    .{ .name = "NamespaceError", .legacy = "NAMESPACE_ERR", .code = 14 },
    .{ .name = "InvalidAccessError", .legacy = "INVALID_ACCESS_ERR", .code = 15 },
    .{ .name = "ValidationError", .legacy = "VALIDATION_ERR", .code = 16 },
    .{ .name = "TypeMismatchError", .legacy = "TYPE_MISMATCH_ERR", .code = 17 },
    .{ .name = "SecurityError", .legacy = "SECURITY_ERR", .code = 18 },
    .{ .name = "NetworkError", .legacy = "NETWORK_ERR", .code = 19 },
    .{ .name = "AbortError", .legacy = "ABORT_ERR", .code = 20 },
    .{ .name = "URLMismatchError", .legacy = "URL_MISMATCH_ERR", .code = 21 },
    .{ .name = "QuotaExceededError", .legacy = "QUOTA_EXCEEDED_ERR", .code = 22 },
    .{ .name = "TimeoutError", .legacy = "TIMEOUT_ERR", .code = 23 },
    .{ .name = "InvalidNodeTypeError", .legacy = "INVALID_NODE_TYPE_ERR", .code = 24 },
    .{ .name = "DataCloneError", .legacy = "DATA_CLONE_ERR", .code = 25 },
};

fn domCodeOf(name: []const u8) i32 {
    for (dom_codes) |c| if (std.mem.eql(u8, c.name, name)) return c.code;
    return 0;
}

const node_filter_consts = [_]struct { name: []const u8, value: f64 }{
    .{ .name = "FILTER_ACCEPT", .value = 1 },     .{ .name = "FILTER_REJECT", .value = 2 },                .{ .name = "FILTER_SKIP", .value = 3 },
    .{ .name = "SHOW_ALL", .value = 4294967295 }, .{ .name = "SHOW_ELEMENT", .value = 1 },                 .{ .name = "SHOW_ATTRIBUTE", .value = 2 },
    .{ .name = "SHOW_TEXT", .value = 4 },         .{ .name = "SHOW_CDATA_SECTION", .value = 8 },           .{ .name = "SHOW_ENTITY_REFERENCE", .value = 16 },
    .{ .name = "SHOW_ENTITY", .value = 32 },      .{ .name = "SHOW_PROCESSING_INSTRUCTION", .value = 64 }, .{ .name = "SHOW_COMMENT", .value = 128 },
    .{ .name = "SHOW_DOCUMENT", .value = 256 },   .{ .name = "SHOW_DOCUMENT_TYPE", .value = 512 },         .{ .name = "SHOW_DOCUMENT_FRAGMENT", .value = 1024 },
    .{ .name = "SHOW_NOTATION", .value = 2048 },
};

/// A DOMException instance: name, message and the legacy code, own.
fn domException(vm: *Vm, name: []const u8, msg: []const u8) Error!Value {
    const p = pageOf(vm);
    const proto = if (p.dom_exception_proto.isObject()) p.dom_exception_proto else vm.intrinsics.error_prototype.asValue();
    const o = try vm.objects.create(proto, .error_, 0);
    try vm.defineValue(o, "name", try vm.str(name), .hidden);
    try vm.defineValue(o, "message", try vm.str(msg), .hidden);
    try vm.defineValue(o, "code", Value.fromInt(domCodeOf(name)), .hidden);
    return o.asValue();
}

fn throwDom(vm: *Vm, err: DomError, msg: []const u8) Error {
    const v = domException(vm, @tagName(err), msg) catch |e| return e;
    return vm.throwValue(v);
}

fn domExceptionCtor(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const msg = if (arg(args, 0).isUndefined()) "" else try strArg(vm, arg(args, 0), sc.a());
    const name = if (arg(args, 1).isUndefined()) "Error" else try strArg(vm, arg(args, 1), sc.a());
    return domException(vm, name, msg);
}

// ------------------------------------------------------- CharacterData

/// UTF-16 length of UTF-8 text, and the byte offset of a UTF-16 offset.
fn utf16Len(text: []const u8) usize {
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |c| n += if (c >= 0x10000) 2 else 1;
    return n;
}

fn byteOffsetOfUtf16(text: []const u8, off: usize) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n < off) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const c = std.unicode.utf8Decode(text[i .. i + @min(len, text.len - i)]) catch 0;
        n += if (c >= 0x10000) 2 else 1;
        i += len;
    }
    return @min(i, text.len);
}

fn thisCharacterData(vm: *Vm, this: Value) Error!NodeId {
    const id = try thisNode(vm, this);
    const k = pageOf(vm).doc.get(id).kind;
    if (k != .text and k != .comment) return vm.throwTypeError("Illegal invocation");
    return id;
}

/// The `replace data` algorithm: `count` units at `offset` replaced by
/// `data`, the live ranges in the node moved as the DOM says.
fn replaceData(vm: *Vm, id: NodeId, offset_in: usize, count_in: usize, data: []const u8) Error!void {
    const p = pageOf(vm);
    const n = p.doc.node(id);
    const length = utf16Len(n.text.items);
    if (offset_in > length) return throwDom(vm, .IndexSizeError, "the offset is past the data");
    const count = @min(count_in, length - offset_in);
    const b0 = byteOffsetOfUtf16(n.text.items, offset_in);
    const b1 = byteOffsetOfUtf16(n.text.items, offset_in + count);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(sc.a(), n.text.items[0..b0]);
    try out.appendSlice(sc.a(), data);
    try out.appendSlice(sc.a(), n.text.items[b1..]);
    try p.setText(id, out.items);
    p.rangesOnReplaceData(id, offset_in, count, utf16Len(data));
}

fn cdSubstringData(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisCharacterData(vm, this);
    const text = p.doc.get(id).text.items;
    const length = utf16Len(text);
    const offset: usize = @intFromFloat(@max(0, try vm.toIntegerOrInfinity(arg(args, 0))));
    if (offset > length) return throwDom(vm, .IndexSizeError, "the offset is past the data");
    const count: usize = @intFromFloat(@max(0, @min(1e9, try vm.toIntegerOrInfinity(arg(args, 1)))));
    const end = @min(length, offset + count);
    return jsStr(vm, text[byteOffsetOfUtf16(text, offset)..byteOffsetOfUtf16(text, end)]);
}

fn cdAppendData(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisCharacterData(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const data = try strArg(vm, arg(args, 0), sc.a());
    try replaceData(vm, id, utf16Len(p.doc.get(id).text.items), 0, data);
    return Value.undefined_;
}

fn cdInsertData(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const id = try thisCharacterData(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const offset: usize = @intFromFloat(@max(0, try vm.toIntegerOrInfinity(arg(args, 0))));
    const data = try strArg(vm, arg(args, 1), sc.a());
    try replaceData(vm, id, offset, 0, data);
    return Value.undefined_;
}

fn cdDeleteData(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const id = try thisCharacterData(vm, this);
    const offset: usize = @intFromFloat(@max(0, try vm.toIntegerOrInfinity(arg(args, 0))));
    const count: usize = @intFromFloat(@max(0, @min(1e9, try vm.toIntegerOrInfinity(arg(args, 1)))));
    try replaceData(vm, id, offset, count, "");
    return Value.undefined_;
}

fn cdReplaceData(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const id = try thisCharacterData(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const offset: usize = @intFromFloat(@max(0, try vm.toIntegerOrInfinity(arg(args, 0))));
    const count: usize = @intFromFloat(@max(0, @min(1e9, try vm.toIntegerOrInfinity(arg(args, 1)))));
    const data = try strArg(vm, arg(args, 2), sc.a());
    try replaceData(vm, id, offset, count, data);
    return Value.undefined_;
}

/// `splitText(offset)`: the tail into a new text node after this one;
/// live ranges in the tail move to it.
fn splitText(vm: *Vm, id: NodeId, offset: usize) Error!NodeId {
    const p = pageOf(vm);
    const n = p.doc.node(id);
    const length = utf16Len(n.text.items);
    if (offset > length) return throwDom(vm, .IndexSizeError, "the offset is past the data");
    const b = byteOffsetOfUtf16(n.text.items, offset);
    const tail = try p.doc.createText(try p.doc.a.dupe(u8, n.text.items[b..]));
    const parent = n.parent;
    if (parent) |par| {
        try insertNode(p, par, tail, n.next);
        // Ranges: a point in the old node past the split goes to the new
        // node; a point in the parent just after the old node moves past
        // the new one.
        for (p.ranges.items) |rv| {
            const r = try rangeState(vm, rv);
            var st = r;
            var changed = false;
            if (st.sc == id and st.so > offset) {
                st.sc = tail;
                st.so -= offset;
                changed = true;
            }
            if (st.ec == id and st.eo > offset) {
                st.ec = tail;
                st.eo -= offset;
                changed = true;
            }
            const idx = childIndex(p.doc, id);
            if (st.sc == par and st.so == idx + 1) {
                st.so += 1;
                changed = true;
            }
            if (st.ec == par and st.eo == idx + 1) {
                st.eo += 1;
                changed = true;
            }
            if (changed) try setRangeState(vm, rv, st);
        }
    }
    try replaceData(vm, id, offset, length - offset, "");
    return tail;
}

fn textSplit(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisCharacterData(vm, this);
    const offset: usize = @intFromFloat(@max(0, try vm.toIntegerOrInfinity(arg(args, 0))));
    return p.wrapValue(try splitText(vm, id, offset));
}

fn isSameNode(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const id = try thisNode(vm, this);
    const p = pageOf(vm);
    const other = arg(args, 0);
    if (Page.docOfValue(other)) |d| if (d == p.cur) if (p.nodeOfValue(other)) |o| return Value.fromBool(o == id);
    return Value.false_;
}

fn isEqualNode(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const id = try thisNode(vm, this);
    const p = pageOf(vm);
    const other = p.nodeOfValue(arg(args, 0)) orelse return Value.false_;
    var sc = Scratch.init(vm);
    defer sc.deinit();
    var a: std.ArrayList(u8) = .empty;
    var b: std.ArrayList(u8) = .empty;
    try html.serializeOuter(sc.a(), p.doc, id, &a);
    try html.serializeOuter(sc.a(), p.doc, other, &b);
    return Value.fromBool(std.mem.eql(u8, a.items, b.items));
}

/// `normalize()`: adjacent text nodes merged, empty ones removed.
fn normalizeNode(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const root = try thisNode(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    var ids: std.ArrayList(NodeId) = .empty;
    var w = p.doc.walk(root);
    while (w.step()) |id| if (p.doc.get(id).kind == .text) try ids.append(sc.a(), id);
    for (ids.items) |id| {
        if (p.doc.get(id).parent == null) continue;
        if (p.doc.get(id).text.items.len == 0) {
            p.detachNode(id);
            continue;
        }
        while (p.doc.get(id).next) |nx| {
            if (p.doc.get(nx).kind != .text) break;
            const tail = try sc.a().dupe(u8, p.doc.get(nx).text.items);
            try replaceData(vm, id, utf16Len(p.doc.get(id).text.items), 0, tail);
            p.detachNode(nx);
        }
    }
    return Value.undefined_;
}

// ------------------------------------------------------------ traversal

fn nodeTypeBit(kind: dom.Kind) u32 {
    return switch (kind) {
        .element => 1,
        .text => 4,
        .comment => 128,
        .document => 256,
        .doctype => 512,
        .fragment => 1024,
    };
}

const TravKind = enum { iterator, walker };

fn newTraversal(vm: *Vm, kind: TravKind, args: []const Value) Error!Value {
    const p = pageOf(vm);
    const root = p.nodeSwitching(arg(args, 0)) orelse return vm.throwTypeError("a root node is needed");
    const what: f64 = if (arg(args, 1).isUndefined()) 4294967295 else (vm.toNumber(arg(args, 1)) catch 4294967295);
    const filter = arg(args, 2);
    const o = try vm.objects.create(p.protos[if (kind == .iterator) I.node_iterator else I.tree_walker].asValue(), .dom, @sizeOf(Slot));
    o.internal(Slot).* = .{ .kind = slot_traversal, .id = root, .flags = if (kind == .iterator) 0 else 1, .doc = p.cur };
    try vm.defineValue(o, "__what", Value.fromF64(what), .hidden);
    try vm.defineValue(o, "__filter", if (filter.isNullish()) Value.null_ else filter, .hidden);
    try vm.defineValue(o, "__ref", try p.wrapValue(root), .hidden);
    try vm.defineValue(o, "__before", Value.true_, .hidden);
    try vm.defineValue(o, "__active", Value.false_, .hidden);
    if (kind == .iterator) try p.iterators.append(p.a, o.asValue());
    return o.asValue();
}

fn createNodeIterator(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    _ = try thisNode(vm, this);
    return newTraversal(vm, .iterator, args);
}

fn createTreeWalker(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    _ = try thisNode(vm, this);
    return newTraversal(vm, .walker, args);
}

fn thisTraversal(vm: *Vm, this: Value) Error!*Object {
    if (this.isObject()) {
        const o = Vm.asObject(this);
        if (o.class == .dom and o.internal(Slot).kind == slot_traversal) {
            pageOf(vm).switchTo(o.internal(Slot).doc);
            return o;
        }
    }
    return vm.throwTypeError("Illegal invocation");
}

fn slotGet(vm: *Vm, o: *Object, name: []const u8) Error!Value {
    return vm.get(o, .{ .atom = try vm.atom(name) }, o.asValue());
}

fn slotSet(vm: *Vm, o: *Object, name: []const u8, v: Value) Error!void {
    try vm.defineValue(o, name, v, .hidden);
}

/// The filter's verdict on a node: 1 accept, 2 reject, 3 skip.
fn filterNode(vm: *Vm, o: *Object, id: NodeId) Error!u32 {
    const p = pageOf(vm);
    if (vm.toBoolean(try slotGet(vm, o, "__active"))) return throwDom(vm, .InvalidStateError, "the filter is already running");
    const what: u64 = @intFromFloat(@max(0, try vm.toNumber(try slotGet(vm, o, "__what"))));
    if (what & nodeTypeBit(p.doc.get(id).kind) == 0) return 3;
    const filter = try slotGet(vm, o, "__filter");
    if (filter.isNullish()) return 1;
    var callee = filter;
    if (!vm.isCallable(filter)) {
        if (!filter.isObject()) return 1;
        callee = try vm.get(Vm.asObject(filter), .{ .atom = try vm.atom("acceptNode") }, filter);
        if (!vm.isCallable(callee)) return vm.throwTypeError("the filter has no acceptNode");
    }
    try slotSet(vm, o, "__active", Value.true_);
    const saved = p.cur;
    const r = vm.call(callee, filter, &.{try p.wrapValue(id)});
    p.switchTo(saved);
    slotSet(vm, o, "__active", Value.false_) catch {};
    const v = try r;
    const n = try vm.toNumber(v);
    if (std.math.isNan(n)) return 0;
    return @intFromFloat(@max(0, @min(3, @floor(n))));
}

fn travRoot(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try thisTraversal(vm, this);
    return pageOf(vm).wrapValue(o.internal(Slot).id);
}
fn travWhatToShow(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return slotGet(vm, try thisTraversal(vm, this), "__what");
}
fn travFilter(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return slotGet(vm, try thisTraversal(vm, this), "__filter");
}
fn iterReferenceNode(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return slotGet(vm, try thisTraversal(vm, this), "__ref");
}
fn iterPointerBefore(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return slotGet(vm, try thisTraversal(vm, this), "__before");
}

/// The node after `id` in tree order, within `root`, or null.
fn followingIn(doc: *const dom.Document, id: NodeId, root: NodeId) ?NodeId {
    if (doc.get(id).first_child) |c| return c;
    var cur = id;
    while (cur != root) {
        if (doc.get(cur).next) |n| return n;
        cur = doc.get(cur).parent orelse return null;
    }
    return null;
}

fn lastDescendant(doc: *const dom.Document, id: NodeId) NodeId {
    var cur = id;
    while (doc.get(cur).last_child) |c| cur = c;
    return cur;
}

/// The node before `id` in tree order, within `root`, or null.
fn precedingIn(doc: *const dom.Document, id: NodeId, root: NodeId) ?NodeId {
    if (id == root) return null;
    if (doc.get(id).prev) |s| return lastDescendant(doc, s);
    return doc.get(id).parent;
}

fn iterTraverse(vm: *Vm, this: Value, forward: bool) Error!Value {
    const p = pageOf(vm);
    const o = try thisTraversal(vm, this);
    const root = o.internal(Slot).id;
    var node = p.nodeOfValue(try slotGet(vm, o, "__ref")) orelse root;
    var before = vm.toBoolean(try slotGet(vm, o, "__before"));
    while (true) {
        if (forward) {
            if (!before) node = followingIn(p.doc, node, root) orelse return Value.null_;
            before = false;
        } else {
            if (before) node = precedingIn(p.doc, node, root) orelse return Value.null_;
            before = true;
        }
        const ref_was = try slotGet(vm, o, "__ref");
        const result = try filterNode(vm, o, node);
        // The filter removed nodes: the pre-removing steps moved the
        // iterator's reference, and the traversal goes on from there.
        const ref_now = try slotGet(vm, o, "__ref");
        const moved = !vm.isStrictlyEqual(ref_was, ref_now);
        if (result == 1) {
            // A node removed by its own filter is still returned, but the
            // iterator stays where the removal left it.
            if (rootOf(p.doc, node) == rootOf(p.doc, root)) {
                try slotSet(vm, o, "__ref", try p.wrapValue(node));
                try slotSet(vm, o, "__before", Value.fromBool(before));
            }
            return p.wrapValue(node);
        }
        if (moved) {
            node = p.nodeOfValue(ref_now) orelse root;
            before = vm.toBoolean(try slotGet(vm, o, "__before"));
        }
    }
}

fn iterNextNode(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return iterTraverse(vm, this, true);
}
fn iterPreviousNode(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return iterTraverse(vm, this, false);
}

fn walkerCurrent(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return slotGet(vm, try thisTraversal(vm, this), "__ref");
}
fn walkerSetCurrent(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try thisTraversal(vm, this);
    if (Page.docOfValue(arg(args, 0)) == null) return vm.throwTypeError("currentNode must be a node");
    try slotSet(vm, o, "__ref", arg(args, 0));
    return Value.undefined_;
}

fn walkerSet(vm: *Vm, o: *Object, id: NodeId) Error!Value {
    const v = try pageOf(vm).wrapValue(id);
    try slotSet(vm, o, "__ref", v);
    return v;
}

fn walkerParentNode(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const o = try thisTraversal(vm, this);
    const root = o.internal(Slot).id;
    var node: ?NodeId = p.nodeOfValue(try slotGet(vm, o, "__ref"));
    while (node) |n| {
        if (n == root) return Value.null_;
        node = p.doc.get(n).parent;
        if (node) |pn| if (try filterNode(vm, o, pn) == 1) return walkerSet(vm, o, pn);
    }
    return Value.null_;
}

/// TreeWalker's "traverse children".
fn walkerChildren(vm: *Vm, this: Value, first: bool) Error!Value {
    const p = pageOf(vm);
    const o = try thisTraversal(vm, this);
    const root = o.internal(Slot).id;
    const current = p.nodeOfValue(try slotGet(vm, o, "__ref")) orelse root;
    var node: ?NodeId = if (first) p.doc.get(current).first_child else p.doc.get(current).last_child;
    while (node) |n| {
        const result = try filterNode(vm, o, n);
        if (result == 1) return walkerSet(vm, o, n);
        if (result == 3) {
            const child = if (first) p.doc.get(n).first_child else p.doc.get(n).last_child;
            if (child) |c| {
                node = c;
                continue;
            }
        }
        var cur = n;
        while (true) {
            const sibling = if (first) p.doc.get(cur).next else p.doc.get(cur).prev;
            if (sibling) |sib| {
                node = sib;
                break;
            }
            const parent = p.doc.get(cur).parent orelse return Value.null_;
            if (parent == root or parent == current) return Value.null_;
            cur = parent;
        }
    }
    return Value.null_;
}

fn walkerFirstChild(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return walkerChildren(vm, this, true);
}
fn walkerLastChild(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return walkerChildren(vm, this, false);
}

/// TreeWalker's "traverse siblings".
fn walkerSiblings(vm: *Vm, this: Value, next: bool) Error!Value {
    const p = pageOf(vm);
    const o = try thisTraversal(vm, this);
    const root = o.internal(Slot).id;
    var node = p.nodeOfValue(try slotGet(vm, o, "__ref")) orelse root;
    if (node == root) return Value.null_;
    while (true) {
        var sibling: ?NodeId = if (next) p.doc.get(node).next else p.doc.get(node).prev;
        while (sibling) |sib| {
            node = sib;
            const result = try filterNode(vm, o, node);
            if (result == 1) return walkerSet(vm, o, node);
            sibling = if (next) p.doc.get(node).first_child else p.doc.get(node).last_child;
            if (result == 2 or sibling == null) sibling = if (next) p.doc.get(node).next else p.doc.get(node).prev;
        }
        node = p.doc.get(node).parent orelse return Value.null_;
        if (node == root) return Value.null_;
        if (try filterNode(vm, o, node) == 1) return Value.null_;
    }
}

fn walkerNextSibling(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return walkerSiblings(vm, this, true);
}
fn walkerPreviousSibling(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return walkerSiblings(vm, this, false);
}

fn walkerNextNode(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const o = try thisTraversal(vm, this);
    const root = o.internal(Slot).id;
    var node = p.nodeOfValue(try slotGet(vm, o, "__ref")) orelse root;
    var result: u32 = 1;
    while (true) {
        while (result != 2 and p.doc.get(node).first_child != null) {
            node = p.doc.get(node).first_child.?;
            result = try filterNode(vm, o, node);
            if (result == 1) return walkerSet(vm, o, node);
        }
        var sibling: ?NodeId = null;
        var temp: ?NodeId = node;
        while (temp) |t| {
            if (t == root) return Value.null_;
            sibling = p.doc.get(t).next;
            if (sibling != null) break;
            temp = p.doc.get(t).parent;
        }
        node = sibling orelse return Value.null_;
        result = try filterNode(vm, o, node);
        if (result == 1) return walkerSet(vm, o, node);
    }
}

fn walkerPreviousNode(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const o = try thisTraversal(vm, this);
    const root = o.internal(Slot).id;
    var node = p.nodeOfValue(try slotGet(vm, o, "__ref")) orelse root;
    while (node != root) {
        var sibling = p.doc.get(node).prev;
        while (sibling) |sib| {
            node = sib;
            var result = try filterNode(vm, o, node);
            while (result != 2 and p.doc.get(node).last_child != null) {
                node = p.doc.get(node).last_child.?;
                result = try filterNode(vm, o, node);
            }
            if (result == 1) return walkerSet(vm, o, node);
            sibling = p.doc.get(node).prev;
        }
        if (node == root) return Value.null_;
        node = p.doc.get(node).parent orelse return Value.null_;
        if (try filterNode(vm, o, node) == 1) return walkerSet(vm, o, node);
    }
    return Value.null_;
}

// ---------------------------------------------------------------- Range

const RangeState = struct { sc: NodeId, so: usize, ec: NodeId, eo: usize };

fn thisRange(vm: *Vm, this: Value) Error!*Object {
    if (this.isObject()) {
        const o = Vm.asObject(this);
        if (o.class == .dom and o.internal(Slot).kind == slot_range) {
            pageOf(vm).switchTo(o.internal(Slot).doc);
            return o;
        }
    }
    return vm.throwTypeError("Illegal invocation");
}

fn rangeState(vm: *Vm, rv: Value) Error!RangeState {
    const o = Vm.asObject(rv);
    const p = pageOf(vm);
    const sc = p.nodeOfValue(try slotGet(vm, o, "__sc")) orelse dom.document_id;
    const ec = p.nodeOfValue(try slotGet(vm, o, "__ec")) orelse dom.document_id;
    const so: usize = @intFromFloat(@max(0, try vm.toNumber(try slotGet(vm, o, "__so"))));
    const eo: usize = @intFromFloat(@max(0, try vm.toNumber(try slotGet(vm, o, "__eo"))));
    return .{ .sc = sc, .so = so, .ec = ec, .eo = eo };
}

fn setRangeState(vm: *Vm, rv: Value, st: RangeState) Error!void {
    const o = Vm.asObject(rv);
    const p = pageOf(vm);
    try slotSet(vm, o, "__sc", try p.wrapValue(st.sc));
    try slotSet(vm, o, "__so", Value.fromF64(@floatFromInt(st.so)));
    try slotSet(vm, o, "__ec", try p.wrapValue(st.ec));
    try slotSet(vm, o, "__eo", Value.fromF64(@floatFromInt(st.eo)));
}

fn newRange(vm: *Vm) Error!Value {
    const p = pageOf(vm);
    const o = try vm.objects.create(p.protos[I.range].asValue(), .dom, @sizeOf(Slot));
    o.internal(Slot).* = .{ .kind = slot_range, .id = 0, .doc = p.cur };
    try setRangeState(vm, o.asValue(), .{ .sc = dom.document_id, .so = 0, .ec = dom.document_id, .eo = 0 });
    try p.ranges.append(p.a, o.asValue());
    return o.asValue();
}

fn createRange(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    _ = try thisNode(vm, this);
    return newRange(vm);
}

/// A node's length: its data in UTF-16 units, or its child count.
fn nodeLength(doc: *const dom.Document, id: NodeId) usize {
    const n = doc.get(id);
    return switch (n.kind) {
        .text, .comment => utf16Len(n.text.items),
        .doctype => 0,
        else => doc.childCount(id),
    };
}

fn childIndex(doc: *const dom.Document, id: NodeId) usize {
    var i: usize = 0;
    var cur = doc.get(id).prev;
    while (cur) |c| : (cur = doc.get(c).prev) i += 1;
    return i;
}

fn childAt(doc: *const dom.Document, parent: NodeId, index: usize) ?NodeId {
    var i: usize = 0;
    var c = doc.get(parent).first_child;
    while (c) |cid| : (c = doc.get(cid).next) {
        if (i == index) return cid;
        i += 1;
    }
    return null;
}

fn rootOf(doc: *const dom.Document, id: NodeId) NodeId {
    var cur = id;
    while (doc.get(cur).parent) |par| cur = par;
    return cur;
}

/// Tree order: -1 when `a` comes before `b`, 1 after, 0 the same.
fn treeOrder(doc: *const dom.Document, a: NodeId, b: NodeId) i8 {
    if (a == b) return 0;
    if (isAncestor(doc, a, b)) return -1;
    if (isAncestor(doc, b, a)) return 1;
    var w = doc.walk(rootOf(doc, a));
    while (w.step()) |n| {
        if (n == a) return -1;
        if (n == b) return 1;
    }
    return 0;
}

/// The position of boundary point (a, ao) relative to (b, bo): -1
/// before, 0 equal, 1 after — the DOM's algorithm.
fn bpCompare(doc: *const dom.Document, a: NodeId, ao: usize, b: NodeId, bo: usize) i8 {
    if (a == b) return if (ao == bo) 0 else if (ao < bo) -1 else 1;
    if (isAncestor(doc, a, b)) {
        // The child of a that holds b.
        var child = b;
        while (doc.get(child).parent) |par| {
            if (par == a) break;
            child = par;
        }
        return if (childIndex(doc, child) < ao) 1 else -1;
    }
    if (isAncestor(doc, b, a)) return -@as(i8, bpCompare(doc, b, bo, a, ao));
    return treeOrder(doc, a, b);
}

fn rangeStartContainer(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return slotGet(vm, try thisRange(vm, this), "__sc");
}
fn rangeStartOffset(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return slotGet(vm, try thisRange(vm, this), "__so");
}
fn rangeEndContainer(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return slotGet(vm, try thisRange(vm, this), "__ec");
}
fn rangeEndOffset(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return slotGet(vm, try thisRange(vm, this), "__eo");
}
fn rangeCollapsed(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try thisRange(vm, this);
    const st = try rangeState(vm, o.asValue());
    return Value.fromBool(st.sc == st.ec and st.so == st.eo);
}
fn rangeCommonAncestor(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const o = try thisRange(vm, this);
    const st = try rangeState(vm, o.asValue());
    return p.wrapValue(commonAncestor(p.doc, st.sc, st.ec));
}

fn commonAncestor(doc: *const dom.Document, a: NodeId, b: NodeId) NodeId {
    var cur: ?NodeId = a;
    while (cur) |c| : (cur = doc.get(c).parent) if (isAncestor(doc, c, b)) return c;
    return rootOf(doc, a);
}

/// A boundary point argument: the node and offset checked.
fn rangePoint(vm: *Vm, node_v: Value, offset_v: Value) Error!struct { node: NodeId, offset: usize } {
    const p = pageOf(vm);
    const node = p.nodeSwitching(node_v) orelse return vm.throwTypeError("a node is needed");
    if (p.doc.get(node).kind == .doctype) return throwDom(vm, .InvalidNodeTypeError, "a doctype cannot be a boundary point");
    const offset: usize = @intFromFloat(@max(0, try vm.toIntegerOrInfinity(offset_v)));
    if (offset > nodeLength(p.doc, node)) return throwDom(vm, .IndexSizeError, "the offset is past the node's length");
    return .{ .node = node, .offset = offset };
}

/// Set the start (or end) of a range: the other end collapses to it
/// when it would come before (after), or lie in another tree.
fn rangeSetPoint(vm: *Vm, rv: Value, node: NodeId, offset: usize, start: bool) Error!void {
    const p = pageOf(vm);
    const ro = Vm.asObject(rv);
    // A point in another of the page's documents moves the range there.
    const same_doc = ro.internal(Slot).doc == p.cur;
    if (!same_doc) {
        ro.internal(Slot).doc = p.cur;
        try setRangeState(vm, rv, .{ .sc = node, .so = offset, .ec = node, .eo = offset });
        return;
    }
    var st = try rangeState(vm, rv);
    const same_root = rootOf(p.doc, node) == rootOf(p.doc, st.sc);
    if (start) {
        st.sc = node;
        st.so = offset;
        if (!same_root or bpCompare(p.doc, node, offset, st.ec, st.eo) > 0) {
            st.ec = node;
            st.eo = offset;
        }
    } else {
        st.ec = node;
        st.eo = offset;
        if (!same_root or bpCompare(p.doc, node, offset, st.sc, st.so) < 0) {
            st.sc = node;
            st.so = offset;
        }
    }
    try setRangeState(vm, rv, st);
}

fn rangeSetStart(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try thisRange(vm, this);
    const pt = try rangePoint(vm, arg(args, 0), arg(args, 1));
    try rangeSetPoint(vm, o.asValue(), pt.node, pt.offset, true);
    return Value.undefined_;
}
fn rangeSetEnd(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try thisRange(vm, this);
    const pt = try rangePoint(vm, arg(args, 0), arg(args, 1));
    try rangeSetPoint(vm, o.asValue(), pt.node, pt.offset, false);
    return Value.undefined_;
}

fn rangeBeside(vm: *Vm, this: Value, args: []const Value, start: bool, after: bool) Error!Value {
    const p = pageOf(vm);
    const o = try thisRange(vm, this);
    const node = p.nodeSwitching(arg(args, 0)) orelse return vm.throwTypeError("a node is needed");
    const parent = p.doc.get(node).parent orelse return throwDom(vm, .InvalidNodeTypeError, "the node has no parent");
    const idx = childIndex(p.doc, node) + @as(usize, if (after) 1 else 0);
    try rangeSetPoint(vm, o.asValue(), parent, idx, start);
    return Value.undefined_;
}
fn rangeSetStartBefore(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return rangeBeside(vm, this, args, true, false);
}
fn rangeSetStartAfter(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return rangeBeside(vm, this, args, true, true);
}
fn rangeSetEndBefore(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return rangeBeside(vm, this, args, false, false);
}
fn rangeSetEndAfter(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return rangeBeside(vm, this, args, false, true);
}

fn rangeCollapse(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try thisRange(vm, this);
    var st = try rangeState(vm, o.asValue());
    if (vm.toBoolean(arg(args, 0))) {
        st.ec = st.sc;
        st.eo = st.so;
    } else {
        st.sc = st.ec;
        st.so = st.eo;
    }
    try setRangeState(vm, o.asValue(), st);
    return Value.undefined_;
}

fn rangeSelectNode(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const o = try thisRange(vm, this);
    const node = p.nodeSwitching(arg(args, 0)) orelse return vm.throwTypeError("a node is needed");
    const parent = p.doc.get(node).parent orelse return throwDom(vm, .InvalidNodeTypeError, "the node has no parent");
    const idx = childIndex(p.doc, node);
    o.internal(Slot).doc = p.cur;
    try setRangeState(vm, o.asValue(), .{ .sc = parent, .so = idx, .ec = parent, .eo = idx + 1 });
    return Value.undefined_;
}

fn rangeSelectNodeContents(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const o = try thisRange(vm, this);
    const node = p.nodeSwitching(arg(args, 0)) orelse return vm.throwTypeError("a node is needed");
    if (p.doc.get(node).kind == .doctype) return throwDom(vm, .InvalidNodeTypeError, "a doctype has no contents");
    o.internal(Slot).doc = p.cur;
    try setRangeState(vm, o.asValue(), .{ .sc = node, .so = 0, .ec = node, .eo = nodeLength(p.doc, node) });
    return Value.undefined_;
}

fn rangeCompareBoundaryPoints(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const o = try thisRange(vm, this);
    const how = try vm.toIntegerOrInfinity(arg(args, 0));
    const other_v = arg(args, 1);
    if (!other_v.isObject() or Vm.asObject(other_v).class != .dom or Vm.asObject(other_v).internal(Slot).kind != slot_range) return vm.throwTypeError("a Range is needed");
    if (how < 0 or how > 3) return throwDom(vm, .NotSupportedError, "not a comparison");
    const a = try rangeState(vm, o.asValue());
    const b = try rangeState(vm, other_v);
    if (rootOf(p.doc, a.sc) != rootOf(p.doc, b.sc)) return throwDom(vm, .WrongDocumentError, "the ranges are in different trees");
    const r: i8 = switch (@as(u8, @intFromFloat(how))) {
        0 => bpCompare(p.doc, a.sc, a.so, b.sc, b.so),
        1 => bpCompare(p.doc, a.ec, a.eo, b.sc, b.so),
        2 => bpCompare(p.doc, a.ec, a.eo, b.ec, b.eo),
        else => bpCompare(p.doc, a.sc, a.so, b.ec, b.eo),
    };
    return Value.fromInt(r);
}

/// Whether `node` is contained (wholly) or partially contained by the range.
fn rangeContains(doc: *const dom.Document, st: RangeState, node: NodeId) bool {
    if (rootOf(doc, node) != rootOf(doc, st.sc)) return false;
    return bpCompare(doc, node, 0, st.sc, st.so) > 0 and bpCompare(doc, node, nodeLength(doc, node), st.ec, st.eo) < 0;
}

fn partiallyContains(doc: *const dom.Document, st: RangeState, node: NodeId) bool {
    const a = isAncestor(doc, node, st.sc) and node != st.sc or node == st.sc;
    const b = isAncestor(doc, node, st.ec) and node != st.ec or node == st.ec;
    return (a and !b) or (b and !a);
}

const ContentsOp = enum { delete, extract, clone };

/// The heart of deleteContents, extractContents and cloneContents: the
/// DOM's algorithm with `op` deciding what becomes of the nodes.
fn rangeContents(vm: *Vm, rv: Value, op: ContentsOp) Error!?NodeId {
    const p = pageOf(vm);
    const doc = p.doc;
    const st = try rangeState(vm, rv);
    const frag: ?NodeId = if (op == .delete) null else try doc.createFragment();
    if (st.sc == st.ec and st.so == st.eo) return frag;
    const kind_s = doc.get(st.sc).kind;
    // One character data node: a substring.
    if (st.sc == st.ec and (kind_s == .text or kind_s == .comment)) {
        if (frag) |f| {
            const text = doc.get(st.sc).text.items;
            const b0 = byteOffsetOfUtf16(text, st.so);
            const b1 = byteOffsetOfUtf16(text, st.eo);
            const c = if (kind_s == .text) try doc.createText(try doc.a.dupe(u8, text[b0..b1])) else try doc.createComment(try doc.a.dupe(u8, text[b0..b1]));
            doc.appendChild(f, c);
        }
        if (op != .clone) try replaceData(vm, st.sc, st.so, st.eo - st.so, "");
        return frag;
    }
    const common = commonAncestor(doc, st.sc, st.ec);
    // First and last partially contained children of the common ancestor.
    var first_partial: ?NodeId = null;
    var last_partial: ?NodeId = null;
    if (!(isAncestor(doc, st.sc, st.ec))) {
        var c = doc.get(common).first_child;
        while (c) |cid| : (c = doc.get(cid).next) if (partiallyContains(doc, st, cid)) {
            first_partial = cid;
            break;
        };
    }
    if (!(isAncestor(doc, st.ec, st.sc))) {
        var c = doc.get(common).last_child;
        while (c) |cid| : (c = doc.get(cid).prev) if (partiallyContains(doc, st, cid)) {
            last_partial = cid;
            break;
        };
    }
    // The contained children, gathered before anything moves.
    var sc_list = Scratch.init(vm);
    defer sc_list.deinit();
    var contained: std.ArrayList(NodeId) = .empty;
    {
        var c = doc.get(common).first_child;
        while (c) |cid| : (c = doc.get(cid).next) if (rangeContains(doc, st, cid)) try contained.append(sc_list.a(), cid);
    }
    for (contained.items) |cid| if (doc.get(cid).kind == .doctype) return throwDom(vm, .HierarchyRequestError, "a doctype cannot be moved");
    // Where the range ends up (delete/extract): the start, or just after
    // the start's ancestor under the common ancestor.
    var new_node = st.sc;
    var new_offset = st.so;
    if (!isAncestor(doc, st.sc, st.ec) and st.sc != st.ec) {
        var ref = st.sc;
        while (doc.get(ref).parent) |par| {
            if (par == common) break;
            ref = par;
        }
        if (doc.get(ref).parent) |par| {
            new_node = par;
            new_offset = childIndex(doc, ref) + 1;
        }
    }
    // The first partially contained child.
    if (first_partial) |fp| {
        const fk = doc.get(fp).kind;
        if (fk == .text or fk == .comment) {
            if (frag) |f| {
                const text = doc.get(fp).text.items;
                const b0 = byteOffsetOfUtf16(text, st.so);
                const c = if (fk == .text) try doc.createText(try doc.a.dupe(u8, text[b0..])) else try doc.createComment(try doc.a.dupe(u8, text[b0..]));
                doc.appendChild(f, c);
            }
            if (op != .clone) try replaceData(vm, fp, st.so, nodeLength(doc, fp) - st.so, "");
        } else {
            const clone: ?NodeId = if (frag != null) try cloneSubtree(p, fp, false) else null;
            if (frag) |f| doc.appendChild(f, clone.?);
            const sub = try newRange(vm);
            try setRangeState(vm, sub, .{ .sc = st.sc, .so = st.so, .ec = fp, .eo = nodeLength(doc, fp) });
            const sub_frag = try rangeContents(vm, sub, op);
            if (clone) |cl| if (sub_frag) |sf| {
                while (doc.get(sf).first_child) |c| {
                    doc.detach(c);
                    doc.appendChild(cl, c);
                }
            };
        }
    }
    // The contained children.
    for (contained.items) |cid| {
        switch (op) {
            .clone => if (frag) |f| doc.appendChild(f, try cloneSubtree(p, cid, true)),
            .extract => {
                p.detachNode(cid);
                if (frag) |f| doc.appendChild(f, cid);
            },
            .delete => p.detachNode(cid),
        }
    }
    // The last partially contained child.
    if (last_partial) |lp| {
        const lk = doc.get(lp).kind;
        if (lk == .text or lk == .comment) {
            if (frag) |f| {
                const text = doc.get(lp).text.items;
                const b1 = byteOffsetOfUtf16(text, st.eo);
                const c = if (lk == .text) try doc.createText(try doc.a.dupe(u8, text[0..b1])) else try doc.createComment(try doc.a.dupe(u8, text[0..b1]));
                doc.appendChild(f, c);
            }
            if (op != .clone) try replaceData(vm, lp, 0, st.eo, "");
        } else {
            const clone: ?NodeId = if (frag != null) try cloneSubtree(p, lp, false) else null;
            if (frag) |f| doc.appendChild(f, clone.?);
            const sub = try newRange(vm);
            try setRangeState(vm, sub, .{ .sc = lp, .so = 0, .ec = st.ec, .eo = st.eo });
            const sub_frag = try rangeContents(vm, sub, op);
            if (clone) |cl| if (sub_frag) |sf| {
                while (doc.get(sf).first_child) |c| {
                    doc.detach(c);
                    doc.appendChild(cl, c);
                }
            };
        }
    }
    if (op != .clone) try setRangeState(vm, rv, .{ .sc = new_node, .so = new_offset, .ec = new_node, .eo = new_offset });
    return frag;
}

fn rangeDeleteContents(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try thisRange(vm, this);
    _ = try rangeContents(vm, o.asValue(), .delete);
    return Value.undefined_;
}
fn rangeExtractContents(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const o = try thisRange(vm, this);
    const f = (try rangeContents(vm, o.asValue(), .extract)).?;
    return p.wrapValue(f);
}
fn rangeCloneContents(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const o = try thisRange(vm, this);
    const f = (try rangeContents(vm, o.asValue(), .clone)).?;
    return p.wrapValue(f);
}

fn rangeInsertNode(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const o = try thisRange(vm, this);
    const node = p.adoptArg(arg(args, 0)) orelse return vm.throwTypeError("a node is needed");
    const st = try rangeState(vm, o.asValue());
    const sk = p.doc.get(st.sc).kind;
    if (sk == .comment or (sk == .text and p.doc.get(st.sc).parent == null)) return throwDom(vm, .HierarchyRequestError, "cannot insert here");
    if (sk == .text and st.sc == node) return throwDom(vm, .HierarchyRequestError, "cannot insert a node into itself");
    var reference: ?NodeId = null;
    var parent: NodeId = st.sc;
    if (sk == .text) {
        parent = p.doc.get(st.sc).parent.?;
        reference = try splitText(vm, st.sc, st.so);
    } else {
        reference = childAt(p.doc, st.sc, st.so);
    }
    if (reference == node) reference = p.doc.get(node).next;
    const collapsed = st.sc == st.ec and st.so == st.eo;
    if (p.doc.get(node).parent != null) p.detachNode(node);
    var new_offset = if (reference) |r| childIndex(p.doc, r) else p.doc.childCount(parent);
    new_offset += if (p.doc.get(node).kind == .fragment) p.doc.childCount(node) else 1;
    try insertNode(p, parent, node, reference);
    if (collapsed) {
        var st2 = try rangeState(vm, o.asValue());
        st2.ec = parent;
        st2.eo = new_offset;
        try setRangeState(vm, o.asValue(), st2);
    }
    return Value.undefined_;
}

fn rangeSurroundContents(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const o = try thisRange(vm, this);
    const new_parent = p.adoptArg(arg(args, 0)) orelse return vm.throwTypeError("a node is needed");
    const npk = p.doc.get(new_parent).kind;
    if (npk == .document or npk == .doctype or npk == .fragment) return throwDom(vm, .InvalidNodeTypeError, "cannot surround with that");
    const st = try rangeState(vm, o.asValue());
    // A partially contained non-text node cannot be surrounded.
    var w = p.doc.walk(commonAncestor(p.doc, st.sc, st.ec));
    while (w.step()) |n| if (partiallyContains(p.doc, st, n) and p.doc.get(n).kind != .text) return throwDom(vm, .InvalidStateError, "the range partially selects a node");
    const frag = (try rangeContents(vm, o.asValue(), .extract)).?;
    while (p.doc.get(new_parent).first_child) |c| p.detachNode(c);
    _ = try rangeInsertNode(vm, this, &.{try p.wrapValue(new_parent)}, Value.undefined_);
    try insertNode(p, new_parent, frag, null);
    return rangeSelectNode(vm, this, &.{try p.wrapValue(new_parent)}, Value.undefined_);
}

fn rangeCloneRange(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try thisRange(vm, this);
    const st = try rangeState(vm, o.asValue());
    const r = try newRange(vm);
    try setRangeState(vm, r, st);
    return r;
}

fn rangeToString(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const o = try thisRange(vm, this);
    const st = try rangeState(vm, o.asValue());
    var sc = Scratch.init(vm);
    defer sc.deinit();
    var out: std.ArrayList(u8) = .empty;
    const sk = p.doc.get(st.sc).kind;
    if (st.sc == st.ec and sk == .text) {
        const text = p.doc.get(st.sc).text.items;
        return jsStr(vm, text[byteOffsetOfUtf16(text, st.so)..byteOffsetOfUtf16(text, st.eo)]);
    }
    if (sk == .text) {
        const text = p.doc.get(st.sc).text.items;
        try out.appendSlice(sc.a(), text[byteOffsetOfUtf16(text, st.so)..]);
    }
    var w = p.doc.walk(rootOf(p.doc, st.sc));
    while (w.step()) |n| if (p.doc.get(n).kind == .text and rangeContains(p.doc, st, n)) try out.appendSlice(sc.a(), p.doc.get(n).text.items);
    if (p.doc.get(st.ec).kind == .text and st.ec != st.sc) {
        const text = p.doc.get(st.ec).text.items;
        try out.appendSlice(sc.a(), text[0..byteOffsetOfUtf16(text, st.eo)]);
    }
    return jsStr(vm, out.items);
}

fn rangeComparePointInner(vm: *Vm, this: Value, args: []const Value) Error!i8 {
    const p = pageOf(vm);
    const o = try thisRange(vm, this);
    const pt = try rangePoint(vm, arg(args, 0), arg(args, 1));
    const st = try rangeState(vm, o.asValue());
    if (rootOf(p.doc, pt.node) != rootOf(p.doc, st.sc)) return throwDom(vm, .WrongDocumentError, "the node is in another tree");
    if (bpCompare(p.doc, pt.node, pt.offset, st.sc, st.so) < 0) return -1;
    if (bpCompare(p.doc, pt.node, pt.offset, st.ec, st.eo) > 0) return 1;
    return 0;
}

fn rangeIsPointInRange(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const r = rangeComparePointInner(vm, this, args) catch |e| switch (e) {
        error.Exception => {
            vm.exception = Value.undefined_;
            return Value.false_;
        },
        else => return e,
    };
    return Value.fromBool(r == 0);
}

fn rangeComparePoint(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return Value.fromInt(try rangeComparePointInner(vm, this, args));
}

fn rangeIntersectsNode(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const o = try thisRange(vm, this);
    const node = p.nodeOfValue(arg(args, 0)) orelse return vm.throwTypeError("a node is needed");
    const st = try rangeState(vm, o.asValue());
    if (rootOf(p.doc, node) != rootOf(p.doc, st.sc)) return Value.false_;
    const parent = p.doc.get(node).parent orelse return Value.true_;
    const idx = childIndex(p.doc, node);
    return Value.fromBool(bpCompare(p.doc, parent, idx, st.ec, st.eo) < 0 and bpCompare(p.doc, parent, idx + 1, st.sc, st.so) > 0);
}

// ------------------------------------------------------------- Storage

fn thisStorage(vm: *Vm, this: Value) Error!bool {
    if (this.isObject()) {
        const o = Vm.asObject(this);
        if (o.class == .dom and o.internal(Slot).kind == slot_storage) return o.internal(Slot).flags & storage_session != 0;
    }
    return vm.throwTypeError("Illegal invocation");
}

fn sessionFind(p: *Page, key: []const u8) ?usize {
    for (p.session_items.items, 0..) |it, i| if (std.mem.eql(u8, it.key, key)) return i;
    return null;
}

fn sessionUsed(p: *Page) usize {
    var n: usize = 0;
    for (p.session_items.items) |it| n += it.key.len + it.value.len;
    return n;
}

/// One storage operation on either store; the host's answer for the
/// local one, the page's list for the session one.
fn storageOp(vm: *Vm, session: bool, op: StorageOp, key: []const u8, value: []const u8, buf: []u8) Error!StorageResult {
    const p = pageOf(vm);
    if (!session) {
        const f = p.host.storage orelse return .none;
        return f(p.host.ctx, op, key, value, buf);
    }
    switch (op) {
        .get => {
            const i = sessionFind(p, key) orelse return .none;
            return .{ .text = p.session_items.items[i].value };
        },
        .set => {
            // The bytes the old entry for this key holds, freed by the write.
            const old: usize = if (sessionFind(p, key)) |i| p.session_items.items[i].key.len + p.session_items.items[i].value.len else 0;
            if (sessionUsed(p) - old + key.len + value.len > session_quota) return .quota;
            const v = try p.a.dupe(u8, value);
            if (sessionFind(p, key)) |i| {
                p.a.free(p.session_items.items[i].value);
                p.session_items.items[i].value = v;
            } else {
                const k = try p.a.dupe(u8, key);
                try p.session_items.append(p.a, .{ .key = k, .value = v });
            }
            return .ok;
        },
        .remove => {
            if (sessionFind(p, key)) |i| {
                const it = p.session_items.orderedRemove(i);
                p.a.free(it.key);
                p.a.free(it.value);
            }
            return .ok;
        },
        .clear => {
            for (p.session_items.items) |it| {
                p.a.free(it.key);
                p.a.free(it.value);
            }
            p.session_items.clearRetainingCapacity();
            return .ok;
        },
        .key_at => {
            const n = std.fmt.parseInt(usize, key, 10) catch return .none;
            if (n >= p.session_items.items.len) return .none;
            return .{ .text = p.session_items.items[n].key };
        },
        .length => return .{ .count = @intCast(p.session_items.items.len) },
    }
}

fn storageGetItem(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const session = try thisStorage(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const key = try strArg(vm, arg(args, 0), sc.a());
    var buf: [4096]u8 = undefined;
    return switch (try storageOp(vm, session, .get, key, "", &buf)) {
        .text => |t| jsStr(vm, t),
        else => Value.null_,
    };
}

fn storageSetItem(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const session = try thisStorage(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const key = try strArg(vm, arg(args, 0), sc.a());
    const value = try strArg(vm, arg(args, 1), sc.a());
    var buf: [16]u8 = undefined;
    return switch (try storageOp(vm, session, .set, key, value, &buf)) {
        .quota => vm.throwError(.Error, "QuotaExceededError: the origin's storage is full"),
        else => Value.undefined_,
    };
}

fn storageRemoveItem(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const session = try thisStorage(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const key = try strArg(vm, arg(args, 0), sc.a());
    var buf: [16]u8 = undefined;
    _ = try storageOp(vm, session, .remove, key, "", &buf);
    return Value.undefined_;
}

fn storageClear(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const session = try thisStorage(vm, this);
    var buf: [16]u8 = undefined;
    _ = try storageOp(vm, session, .clear, "", "", &buf);
    return Value.undefined_;
}

fn storageKey(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const session = try thisStorage(vm, this);
    const n = try vm.toIntegerOrInfinity(arg(args, 0));
    if (n < 0 or n > 1e9) return Value.null_;
    var nbuf: [24]u8 = undefined;
    const ntext = std.fmt.bufPrint(&nbuf, "{d}", .{@as(u64, @intFromFloat(n))}) catch return Value.null_;
    var buf: [4096]u8 = undefined;
    return switch (try storageOp(vm, session, .key_at, ntext, "", &buf)) {
        .text => |t| jsStr(vm, t),
        else => Value.null_,
    };
}

fn storageLength(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const session = try thisStorage(vm, this);
    var buf: [16]u8 = undefined;
    return switch (try storageOp(vm, session, .length, "", "", &buf)) {
        .count => |n| Value.fromInt(@intCast(n)),
        else => Value.fromInt(0),
    };
}

// ------------------------------------------------------- XMLHttpRequest

fn xhrReset(vm: *Vm, o: *Object, ready: i32) Error!void {
    try vm.defineValue(o, "readyState", Value.fromInt(ready), .default);
    try vm.defineValue(o, "status", Value.fromInt(0), .default);
    try vm.defineValue(o, "statusText", try vm.str(""), .default);
    try vm.defineValue(o, "responseText", try vm.str(""), .default);
    try vm.defineValue(o, "response", try vm.str(""), .default);
    try vm.defineValue(o, "responseURL", try vm.str(""), .default);
}

fn thisXhr(vm: *Vm, this: Value) Error!*Object {
    if (!this.isObject()) return vm.throwTypeError("Illegal invocation");
    return Vm.asObject(this);
}

fn xhrOpen(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const o = try thisXhr(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const method = try strArg(vm, arg(args, 0), sc.a());
    const raw = try strArg(vm, arg(args, 1), sc.a());
    if (!std.ascii.eqlIgnoreCase(method, "GET") and !std.ascii.eqlIgnoreCase(method, "POST") and !std.ascii.eqlIgnoreCase(method, "HEAD")) return vm.throwError(.SyntaxError, "XMLHttpRequest: only GET and POST are allowed from a page yet");
    const r = resolveRequest(p, raw, sc.a()) orelse return vm.throwError(.SyntaxError, "XMLHttpRequest: not a URL a page can request");
    try vm.defineValue(o, "__method", try vm.str(method), .hidden);
    try vm.defineValue(o, "__url", try vm.str(r.url), .hidden);
    try vm.defineValue(o, "__origin", try vm.str(r.origin), .hidden);
    try vm.defineValue(o, "__ctype", try vm.str(""), .hidden);
    try xhrReset(vm, o, 1);
    try xhrHandler(vm, o, "onreadystatechange", "readystatechange");
    return Value.undefined_;
}

/// An XHR event fired at the request object (its `on…` property is
/// called by the dispatch, like any handler property).
fn xhrHandler(vm: *Vm, o: *Object, attr: []const u8, event_name: []const u8) Error!void {
    _ = attr;
    const p = pageOf(vm);
    const ev = try p.newEvent(I.event, event_name, false, false, true);
    _ = p.dispatch(o.asValue(), ev) catch |e| p.reportError(e, event_name);
}

fn xhrSend(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const o = try thisXhr(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const method_v = try vm.get(o, .{ .atom = try vm.atom("__method") }, this);
    const url_v = try vm.get(o, .{ .atom = try vm.atom("__url") }, this);
    if (!url_v.isString()) return vm.throwError(.TypeError, "InvalidStateError: send() before open()");
    const origin_v = try vm.get(o, .{ .atom = try vm.atom("__origin") }, this);
    const req: Request = .{ .url = try strArg(vm, url_v, sc.a()), .post = std.ascii.eqlIgnoreCase(try strArg(vm, method_v, sc.a()), "POST"), .body = if (arg(args, 0).isNullish()) "" else try strArg(vm, arg(args, 0), sc.a()), .origin = if (origin_v.isString()) try strArg(vm, origin_v, sc.a()) else "" };
    var out: Response = .{};
    const ok = doRequest(p, req, sc.a(), &out);
    try vm.defineValue(o, "readyState", Value.fromInt(4), .default);
    if (ok) {
        try vm.defineValue(o, "status", Value.fromInt(out.status), .default);
        try vm.defineValue(o, "statusText", try vm.str(statusText(out.status)), .default);
        try vm.defineValue(o, "responseText", try vm.str(out.body), .default);
        try vm.defineValue(o, "responseURL", try vm.str(out.url), .default);
        try vm.defineValue(o, "__ctype", try vm.str(out.content_type), .hidden);
        // `responseType` "json" parses; anything else is the text.
        const rt = try vm.get(o, .{ .atom = try vm.atom("responseType") }, this);
        var response = try vm.str(out.body);
        if (rt.isString() and std.mem.eql(u8, try strArg(vm, rt, sc.a()), "json")) {
            const json = try vm.get(vm.global, .{ .atom = try vm.atom("JSON") }, vm.global.asValue());
            const parse = try vm.get(Vm.asObject(json), .{ .atom = try vm.atom("parse") }, json);
            response = vm.call(parse, json, &.{response}) catch |e| switch (e) {
                error.OutOfMemory => return e,
                error.Exception => blk: {
                    vm.exception = Value.undefined_;
                    break :blk Value.null_;
                },
            };
        }
        try vm.defineValue(o, "response", response, .default);
        try xhrHandler(vm, o, "onreadystatechange", "readystatechange");
        try xhrHandler(vm, o, "onload", "load");
    } else {
        p.logf(.err, "script: XMLHttpRequest {s}: {s}", .{ req.url, out.refused });
        try xhrHandler(vm, o, "onreadystatechange", "readystatechange");
        try xhrHandler(vm, o, "onerror", "error");
    }
    try xhrHandler(vm, o, "onloadend", "loadend");
    return Value.undefined_;
}

fn xhrGetResponseHeader(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try thisXhr(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const name = try strArg(vm, arg(args, 0), sc.a());
    if (!std.ascii.eqlIgnoreCase(name, "content-type")) return Value.null_;
    const ct = try vm.get(o, .{ .atom = try vm.atom("__ctype") }, this);
    return if (ct.isString() and Vm.asString(ct).len > 0) ct else Value.null_;
}

fn xhrGetAllResponseHeaders(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try thisXhr(vm, this);
    const ct = try vm.get(o, .{ .atom = try vm.atom("__ctype") }, this);
    if (!ct.isString() or Vm.asString(ct).len == 0) return jsStr(vm, "");
    var sc = Scratch.init(vm);
    defer sc.deinit();
    return jsStr(vm, try std.fmt.allocPrint(sc.a(), "content-type: {s}\r\n", .{try strArg(vm, ct, sc.a())}));
}

// ----------------------------------------------------------------- tests

const TestHost = struct {
    lines: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,
    scrolled_to: [2]f64 = .{ 0, 0 },
    navigated: std.ArrayList(u8) = .empty,
    changes: std.ArrayList(u8) = .empty,
    submitted: ?NodeId = null,
    activated: ?NodeId = null,
    /// A tiny in-memory store: key/value pairs per test host.
    store: std.ArrayList([2][]u8) = .empty,
    /// A directory whose files answer fetches and requests by the URL's
    /// last segment (the Acid3 support files), and what was read.
    dir: ?[]const u8 = null,
    served: std.ArrayList([]u8) = .empty,
    /// The page's document and the user-agent sheet: `computed` runs
    /// the cascade over them, as the page's layout would.
    doc: ?*dom.Document = null,
    ua: ?*const stylelib.Sheet = null,
    fn serveFile(h: *TestHost, abs_url: []const u8) ?[]const u8 {
        const dir = h.dir orelse return null;
        const path_end = std.mem.indexOfAny(u8, abs_url, "?#") orelse abs_url.len;
        const path = abs_url[0..path_end];
        const name = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse return null) + 1 ..];
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '.') == null) return null;
        var pbuf: [512]u8 = undefined;
        const full = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, name }) catch return null;
        const text = std.Io.Dir.cwd().readFileAlloc(std.testing.io, full, h.a, .limited(4 << 20)) catch return null;
        h.served.append(h.a, text) catch {
            h.a.free(text);
            return null;
        };
        return text;
    }
    fn log(ctx: *anyopaque, level: Level, text: []const u8) void {
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        h.lines.appendSlice(h.a, @tagName(level)) catch {};
        h.lines.append(h.a, ':') catch {};
        h.lines.appendSlice(h.a, text) catch {};
        h.lines.append(h.a, '\n') catch {};
    }
    /// Every element is a 100×20 box at (8, 8 + 30·id).
    fn rect(ctx: *anyopaque, id: NodeId) ?[4]f64 {
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        // A frame is as big as its style attribute says, else 0×0 (the
        // page hides its frames); anything else a nominal box.
        if (h.doc) |doc| if (doc.isHtml(id, "iframe")) {
            var w: f64 = 0;
            var ht: f64 = 0;
            if (doc.getAttr(id, "style")) |st| {
                var it = std.mem.splitScalar(u8, st, ';');
                while (it.next()) |decl| {
                    const colon = std.mem.indexOfScalar(u8, decl, ':') orelse continue;
                    const k = std.mem.trim(u8, decl[0..colon], " ");
                    const v = std.mem.trim(u8, decl[colon + 1 ..], " ");
                    const px = if (std.mem.endsWith(u8, v, "px")) std.fmt.parseFloat(f64, v[0 .. v.len - 2]) catch 0 else 0;
                    if (std.mem.eql(u8, k, "width")) w = px else if (std.mem.eql(u8, k, "height")) ht = px;
                }
            }
            return .{ 0, 0, w, ht };
        };
        return .{ 8, 8 + 30 * @as(f64, @floatFromInt(id)), 100, 20 };
    }
    fn computed(ctx: *anyopaque, id: NodeId, name: []const u8, buf: []u8) ?[]const u8 {
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        if (h.doc) |doc| if (h.ua) |ua| {
            var arena = std.heap.ArenaAllocator.init(h.a);
            defer arena.deinit();
            const a = arena.allocator();
            const env: stylelib.Env = .{ .width = 1024, .height = 768 };
            const sheets = stylelib.collectDocumentSheetsWith(a, doc, env, ua.*) catch return null;
            const styles = stylelib.compute(a, doc, sheets, env) catch return null;
            if (id < styles.computed.len) if (stylelib.propertyText(styles.get(id), name, buf)) |t| return t;
        };
        if (std.mem.eql(u8, name, "display")) return std.fmt.bufPrint(buf, "block", .{}) catch null;
        if (std.mem.eql(u8, name, "color")) return std.fmt.bufPrint(buf, "rgb(0, 0, 0)", .{}) catch null;
        return null;
    }
    fn scroll(ctx: *anyopaque, x: f64, y: f64) void {
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        h.scrolled_to = .{ x, y };
    }
    fn fetch(ctx: *anyopaque, abs_url: []const u8) ?[]const u8 {
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        if (h.dir != null) return h.serveFile(abs_url);
        if (std.mem.endsWith(u8, abs_url, "/lib/greet.js")) return "import { name } from './name.js'; export function greet() { return 'hi ' + name; } export default 42;";
        if (std.mem.endsWith(u8, abs_url, "/lib/name.js")) return "export const name = 'moss';";
        if (std.mem.endsWith(u8, abs_url, "/late.js")) return "export const late = 'late';";
        if (std.mem.endsWith(u8, abs_url, "/classic.js")) return "var fromClassic = 'classic';";
        return null;
    }
    fn navigate(ctx: *anyopaque, abs_url: []const u8) void {
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        h.navigated.appendSlice(h.a, abs_url) catch {};
        h.navigated.append(h.a, ';') catch {};
    }
    fn changed(ctx: *anyopaque, what: Changed, text: []const u8) void {
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        h.changes.appendSlice(h.a, @tagName(what)) catch {};
        h.changes.append(h.a, '=') catch {};
        h.changes.appendSlice(h.a, text) catch {};
        h.changes.append(h.a, ';') catch {};
    }
    fn submit(ctx: *anyopaque, form: NodeId) void {
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        h.submitted = form;
    }
    fn activate(ctx: *anyopaque, id: NodeId) void {
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        h.activated = id;
    }
    /// Canned answers: /data.json is JSON, /missing is a 404, /refuse is
    /// refused by policy, anything else echoes its URL and body.
    fn storage(ctx: *anyopaque, op: StorageOp, key: []const u8, value: []const u8, buf: []u8) StorageResult {
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        var found: ?usize = null;
        for (h.store.items, 0..) |kv, i| if (std.mem.eql(u8, kv[0], key)) {
            found = i;
        };
        switch (op) {
            .get => {
                const i = found orelse return .none;
                const v = h.store.items[i][1];
                const n = @min(v.len, buf.len);
                @memcpy(buf[0..n], v[0..n]);
                return .{ .text = buf[0..n] };
            },
            .set => {
                if (key.len + value.len > 64) return .quota;
                const v = h.a.dupe(u8, value) catch return .quota;
                if (found) |i| {
                    h.a.free(h.store.items[i][1]);
                    h.store.items[i][1] = v;
                } else {
                    const k = h.a.dupe(u8, key) catch return .quota;
                    h.store.append(h.a, .{ k, v }) catch return .quota;
                }
                return .ok;
            },
            .remove => {
                if (found) |i| {
                    const kv = h.store.orderedRemove(i);
                    h.a.free(kv[0]);
                    h.a.free(kv[1]);
                }
                return .ok;
            },
            .clear => {
                for (h.store.items) |kv| {
                    h.a.free(kv[0]);
                    h.a.free(kv[1]);
                }
                h.store.clearRetainingCapacity();
                return .ok;
            },
            .key_at => {
                const n = std.fmt.parseInt(usize, key, 10) catch return .none;
                if (n >= h.store.items.len) return .none;
                const k = h.store.items[n][0];
                @memcpy(buf[0..k.len], k);
                return .{ .text = buf[0..k.len] };
            },
            .length => return .{ .count = @intCast(h.store.items.len) },
        }
    }
    fn request(ctx: *anyopaque, a: std.mem.Allocator, abs_url: []const u8, post: bool, body: []const u8, origin: []const u8, out: *Response) bool {
        out.url = abs_url;
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        if (h.dir != null) {
            const text = h.serveFile(abs_url) orelse {
                out.status = 404;
                out.content_type = "text/plain";
                out.body = "no such file";
                return true;
            };
            out.status = 200;
            out.content_type = if (std.mem.endsWith(u8, abs_url, ".xml")) "text/xml" else if (std.mem.endsWith(u8, abs_url, ".css")) "text/css" else if (std.mem.endsWith(u8, abs_url, ".html")) "text/html" else if (std.mem.endsWith(u8, abs_url, ".png")) "image/png" else "application/octet-stream";
            out.body = text;
            return true;
        }
        // Another origin: allowed only with the origin sent (the broker
        // would check the answer's header); this one answers by echo.
        if (std.mem.indexOf(u8, abs_url, "elsewhere.test") != null) {
            if (origin.len == 0) {
                out.refused = "no origin";
                return false;
            }
            out.status = 200;
            out.content_type = "text/plain";
            out.body = std.fmt.allocPrint(a, "cors from {s}", .{origin}) catch return false;
            return true;
        }
        if (std.mem.endsWith(u8, abs_url, "/data.json")) {
            out.status = 200;
            out.content_type = "application/json";
            out.body = "{\"n\": 7}";
            return true;
        }
        if (std.mem.endsWith(u8, abs_url, "/missing")) {
            out.status = 404;
            out.content_type = "text/plain";
            out.body = "no such page";
            return true;
        }
        if (std.mem.endsWith(u8, abs_url, "/refuse")) {
            out.refused = "policy";
            return false;
        }
        out.status = 200;
        out.content_type = "text/plain; charset=utf-8";
        out.body = std.fmt.allocPrint(a, "{s} {s} {s}", .{ if (post) "POST" else "GET", abs_url, body }) catch return false;
        return true;
    }
};

const TestPage = struct {
    arena: std.heap.ArenaAllocator,
    region: []u8,
    vm: *Vm,
    doc: *dom.Document,
    page: Page,
    host: *TestHost,
    ua: stylelib.Sheet,

    fn open(markup: []const u8) !*TestPage {
        const ta = std.testing.allocator;
        const tp = try ta.create(TestPage);
        tp.arena = std.heap.ArenaAllocator.init(ta);
        tp.region = try ta.alloc(u8, 8 << 20);
        tp.vm = try ta.create(Vm);
        try tp.vm.init(tp.region, ta);
        tp.doc = try html.parse(tp.arena.allocator(), markup, .{ .scripting = true });
        tp.host = try ta.create(TestHost);
        tp.host.* = .{ .a = ta };
        tp.ua = try stylelib.parseSheet(tp.arena.allocator(), stylelib.ua_sheet, .user_agent, .{ .width = 1024, .height = 768 });
        tp.host.doc = tp.doc;
        tp.host.ua = &tp.ua;
        try tp.page.init(tp.vm, tp.doc, ta, .{ .ctx = tp.host, .log = TestHost.log, .rect = TestHost.rect, .computed = TestHost.computed, .scroll = TestHost.scroll, .request = TestHost.request, .fetch = TestHost.fetch, .navigate = TestHost.navigate, .changed = TestHost.changed, .submit = TestHost.submit, .activate = TestHost.activate, .storage = TestHost.storage, .ua_sheet = &tp.ua });
        try tp.page.setUrl("http://example.test:8080/dir/page.html?q=1#top");
        return tp;
    }

    fn close(tp: *TestPage) void {
        const ta = std.testing.allocator;
        tp.page.deinit();
        tp.vm.deinit();
        ta.destroy(tp.vm);
        ta.free(tp.region);
        tp.host.lines.deinit(ta);
        tp.host.navigated.deinit(ta);
        tp.host.changes.deinit(ta);
        for (tp.host.store.items) |kv| {
            ta.free(kv[0]);
            ta.free(kv[1]);
        }
        tp.host.store.deinit(ta);
        for (tp.host.served.items) |t| ta.free(t);
        tp.host.served.deinit(ta);
        ta.destroy(tp.host);
        tp.arena.deinit();
        ta.destroy(tp);
    }

    fn body(tp: *TestPage) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        var w = tp.doc.walk(dom.document_id);
        while (w.next()) |id| if (tp.doc.isHtml(id, "body")) {
            try html.serialize(tp.arena.allocator(), tp.doc, id, &out);
            break;
        };
        return out.items;
    }
};

test "script: inline scripts run in order and change the document" {
    const tp = try TestPage.open(
        \\<!DOCTYPE html><html><head><title>  A   page </title></head><body>
        \\<div id="root" class="a b"><p>one</p></div>
        \\<script>
        \\  var root = document.getElementById('root');
        \\  var p = document.createElement('p');
        \\  p.textContent = 'two';
        \\  p.setAttribute('data-n', 2);
        \\  root.appendChild(p);
        \\  root.classList.add('c');
        \\  root.classList.remove('a');
        \\  console.log(document.title, root.children.length, root.className, root.classList.contains('c'));
        \\</script>
        \\<script>
        \\  console.log(document.querySelectorAll('#root p').length, document.querySelector('p[data-n]').textContent);
        \\  document.body.insertAdjacentHTML('beforeend', '<ul><li>x</li><li>y</li></ul>');
        \\  console.log(document.body.lastElementChild.tagName, document.body.lastElementChild.children[1].innerHTML);
        \\  document.title = 'Changed';
        \\  console.log(location.hostname, location.port, location.pathname, location.search, location.hash, document.URL === location.href);
        \\  console.log(root === document.getElementById('root'), root.parentNode === document.body, root instanceof HTMLElement, root instanceof Node, document instanceof Document);
        \\  console.log(Object.prototype.toString.call(root), root.nodeType, root.nodeName, root.firstChild.nodeName, Node.ELEMENT_NODE);
        \\</script>
        \\</body></html>
    );
    defer tp.close();
    tp.page.runScripts();
    try std.testing.expectEqualStrings(
        \\log:A page 2 b c true
        \\log:2 two
        \\log:UL y
        \\log:example.test 8080 /dir/page.html ?q=1 #top true
        \\log:true true true true true
        \\log:[object HTMLElement] 1 DIV P 1
        \\
    , tp.host.lines.items);
    try std.testing.expect(tp.page.takeDirty());
    try std.testing.expect(!tp.page.takeDirty());
    const b = try tp.body();
    try std.testing.expect(std.mem.indexOf(u8, b, "<p data-n=\"2\">two</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "class=\"b c\"") != null);
    try std.testing.expectEqual(@as(u32, 2), tp.page.scripts_run);
    try std.testing.expectEqual(@as(u32, 0), tp.page.script_errors);
    try std.testing.expectEqual(ReadyState.complete, tp.page.ready_state);
}

test "script: events dispatch in phases, bubble, cancel, and a click reaches the page" {
    const tp = try TestPage.open(
        \\<body><div id="outer"><button id="b">Go</button></div><a id="l" href="/x">link</a>
        \\<script>
        \\  var seq = [];
        \\  var outer = document.getElementById('outer'), b = document.getElementById('b');
        \\  window.addEventListener('click', function (e) { seq.push('w-cap:' + e.eventPhase); }, true);
        \\  document.addEventListener('click', function (e) { seq.push('d:' + e.eventPhase); });
        \\  outer.addEventListener('click', function (e) { seq.push('outer:' + (e.target === b) + ':' + (e.currentTarget === outer)); });
        \\  b.addEventListener('click', function (e) { seq.push('b1'); }, { once: true });
        \\  b.addEventListener('click', function (e) { seq.push('b2:' + e.isTrusted + ':' + e.type); });
        \\  document.getElementById('l').addEventListener('click', function (e) { e.preventDefault(); });
        \\  document.addEventListener('DOMContentLoaded', function () { seq.push('dcl:' + document.readyState); });
        \\  window.addEventListener('load', function () { seq.push('load:' + document.readyState); });
        \\  var custom = 0;
        \\  outer.addEventListener('ping', function (e) { custom = e.detail.n; e.stopPropagation(); });
        \\  document.addEventListener('ping', function () { custom = -1; });
        \\  var r = b.dispatchEvent(new CustomEvent('ping', { bubbles: true, detail: { n: 7 } }));
        \\  seq.push('ping:' + custom + ':' + r);
        \\  var ev = new Event('x', { cancelable: true });
        \\  var target = new EventTarget();
        \\  target.addEventListener('x', function (e) { e.preventDefault(); });
        \\  seq.push('et:' + target.dispatchEvent(ev) + ':' + ev.defaultPrevented);
        \\</script></body>
    );
    defer tp.close();
    tp.page.runScripts();
    // The page's click on the button, then a second (the once listener gone).
    var w = tp.doc.walk(dom.document_id);
    var button: NodeId = 0;
    var link: NodeId = 0;
    while (w.next()) |id| {
        if (tp.doc.isHtml(id, "button")) button = id;
        if (tp.doc.isHtml(id, "a")) link = id;
    }
    try std.testing.expect(tp.page.click(button));
    try std.testing.expect(tp.page.click(button));
    try std.testing.expect(!tp.page.click(link));
    tp.page.runSource("console.log(seq.join(' '))", "check");
    try std.testing.expectEqualStrings(
        \\log:ping:7:true et:false:true dcl:interactive load:complete w-cap:1 b1 b2:true:click outer:true:true d:3 w-cap:1 b2:true:click outer:true:true d:3 w-cap:1 d:3
        \\
    , tp.host.lines.items);
}

test "script: errors are reported and do not stop the next script, timers run when due" {
    const tp = try TestPage.open(
        \\<body><script>throw new TypeError('boom');</script>
        \\<script>this is not js</script>
        \\<script>
        \\  var order = [];
        \\  setTimeout(function (a, b) { order.push('t2:' + a + b); }, 20, 'x', 'y');
        \\  var t = setTimeout(function () { order.push('never'); }, 5);
        \\  clearTimeout(t);
        \\  setTimeout(function () { order.push('t1'); Promise.resolve().then(function () { order.push('micro'); }); }, 10);
        \\  var n = 0; var iv = setInterval(function () { order.push('iv' + (++n)); if (n === 2) clearInterval(iv); }, 15);
        \\  requestAnimationFrame(function (ts) { order.push('raf:' + (ts >= 0)); });
        \\  queueMicrotask(function () { order.push('qm'); });
        \\  console.log('ready');
        \\</script></body>
    );
    defer tp.close();
    tp.page.runScripts();
    try std.testing.expectEqual(@as(u32, 2), tp.page.script_errors);
    try std.testing.expect(std.mem.indexOf(u8, tp.host.lines.items, "err:script: uncaught TypeError: boom") != null);
    try std.testing.expect(std.mem.indexOf(u8, tp.host.lines.items, "err:script: SyntaxError:") != null);
    try std.testing.expect(std.mem.indexOf(u8, tp.host.lines.items, "log:ready") != null);
    try std.testing.expectEqual(@as(usize, 4), tp.page.pendingTimers());
    try std.testing.expectEqual(@as(f64, 0), tp.page.nextDue().?);
    tp.page.fake_now = 12;
    try std.testing.expect(tp.page.runDue(12));
    tp.page.fake_now = 40;
    try std.testing.expect(tp.page.runDue(40));
    // The interval fired once at 40 and rescheduled from then: due at 55.
    try std.testing.expectEqual(@as(usize, 1), tp.page.pendingTimers());
    try std.testing.expect(!tp.page.runDue(50));
    tp.page.fake_now = 60;
    try std.testing.expect(tp.page.runDue(60));
    try std.testing.expectEqual(@as(usize, 0), tp.page.pendingTimers());
    tp.page.runSource("console.log(order.join(' '))", "check");
    try std.testing.expect(std.mem.endsWith(u8, tp.host.lines.items, "log:qm raf:true t1 micro iv1 t2:xy iv2\n"));
}

test "script: the style object reads and writes the attribute, computed style and geometry come from the host" {
    const tp = try TestPage.open(
        \\<body><div id="d" style="color: blue; Background-Color : rgb(1, 2, 3)">x</div><p id="q">y</p>
        \\<script>
        \\  var d = document.getElementById('d'), q = document.getElementById('q');
        \\  var out = [];
        \\  out.push(d.style.color, d.style.backgroundColor, d.style.getPropertyValue('background-color'), d.style.length, d.style.item(1), d.style === d.style);
        \\  d.style.color = 'red';
        \\  d.style.setProperty('margin-top', '4px', 'important');
        \\  d.style.cssFloat = 'left';
        \\  out.push(d.getAttribute('style'), d.style.getPropertyPriority('margin-top'), d.style.cssText);
        \\  out.push(d.style.removeProperty('color'), d.style.color, d.style.length);
        \\  d.style.cssText = '';
        \\  out.push(d.hasAttribute('style'));
        \\  q.style.display = 'none';
        \\  out.push(q.outerHTML);
        \\  var cs = getComputedStyle(q);
        \\  out.push(cs.display, cs.color, cs.getPropertyValue('display'), cs.width);
        \\  var r = q.getBoundingClientRect();
        \\  out.push(r.x, r.y, r.width, r.height, r.right, r.bottom, q.offsetWidth, q.clientHeight, q.offsetTop, q.getClientRects().length);
        \\  var threw = false; try { cs.display = 'block'; } catch (e) { threw = e instanceof TypeError; }
        \\  out.push(threw);
        \\  window.scrollTo(0, 120); q.scrollIntoView();
        \\  console.log(out.join('|'));
        \\</script></body>
    );
    defer tp.close();
    tp.page.runScripts();
    try std.testing.expectEqualStrings(
        \\log:blue|rgb(1, 2, 3)|rgb(1, 2, 3)|2|background-color|true|color: red; background-color: rgb(1, 2, 3); margin-top: 4px !important; float: left;|important|color: red; background-color: rgb(1, 2, 3); margin-top: 4px !important; float: left;|red||3|false|<p id="q" style="display: none;">y</p>|none|rgb(0, 0, 0)|none|auto|8|188|100|20|108|208|100|20|188|1|true
        \\
    , tp.host.lines.items);
    // The last scroll asked was scrollIntoView's: the element's top.
    try std.testing.expectEqual(@as(f64, 188), tp.host.scrolled_to[1]);
}

test "script: fetch and XMLHttpRequest go through the host, same-origin only" {
    const tp = try TestPage.open(
        \\<body><script>
        \\  var out = [], ps = [];
        \\  ps.push(fetch('/api/data.json').then(function (r) { out.push('f1:' + r.ok + ':' + r.status + ':' + r.url + ':' + r.headers.get('Content-Type')); return r.json(); }).then(function (j) { out.push('json:' + j.n); }));
        \\  ps.push(fetch('missing').then(function (r) { out.push('f2:' + r.ok + ':' + r.status + ':' + r.statusText); return r.text(); }).then(function (t) { out.push('text:' + t); }));
        \\  ps.push(fetch('/post', { method: 'POST', body: 'a=1' }).then(function (r) { return r.text(); }).then(function (t) { out.push('post:' + t); }));
        \\  ps.push(fetch('http://elsewhere.test/x').then(function (r) { return r.text(); }).then(function (t) { out.push('cors:' + t); }));
        \\  ps.push(fetch('/refuse').catch(function (e) { out.push('refused:' + e.message); }));
        \\  var x = new XMLHttpRequest();
        \\  var states = [];
        \\  x.onreadystatechange = function () { states.push(x.readyState); };
        \\  x.addEventListener('load', function (e) { out.push('xhr:' + x.status + ':' + x.responseText + ':' + x.getResponseHeader('content-type') + ':' + (e.target === x)); });
        \\  x.onloadend = function () { out.push('end:' + states.join(',')); };
        \\  x.open('GET', '/thing?q=1');
        \\  x.send();
        \\  var y = new XMLHttpRequest(); y.responseType = 'json'; y.open('GET', '/data.json'); y.send(); out.push('yjson:' + y.response.n);
        \\  var z = new XMLHttpRequest(); var zerr = false; z.onerror = function () { zerr = true; }; z.open('GET', '/refuse'); z.send(); out.push('zerr:' + zerr + ':' + z.status);
        \\  var threw = false; try { new XMLHttpRequest().open('GET', 'http://a b/'); } catch (e) { threw = e.name === 'SyntaxError'; } out.push('xcors:' + threw);
        \\  Promise.all(ps).then(function () { console.log(out.sort().join(' ')); });
        \\</script></body>
    );
    defer tp.close();
    tp.page.runScripts();
    try std.testing.expect(std.mem.indexOf(u8, tp.host.lines.items, "err:script: XMLHttpRequest http://example.test:8080/refuse: policy") != null);
    const last = std.mem.lastIndexOf(u8, tp.host.lines.items, "log:").?;
    try std.testing.expectEqualStrings(
        \\log:cors:cors from http://example.test:8080 end:1,4 f1:true:200:http://example.test:8080/api/data.json:application/json f2:false:404:Not Found json:7 post:POST http://example.test:8080/post a=1 refused:fetch: policy text:no such page xcors:true xhr:200:GET http://example.test:8080/thing?q=1 :text/plain; charset=utf-8:true yjson:7 zerr:true:0
        \\
    , tp.host.lines.items[last..]);
}

test "script: module scripts run deferred through the loader, location and history move the page" {
    const tp = try TestPage.open(
        \\<head><title>t</title></head><body>
        \\<script type="module">import { greet } from './lib/greet.js'; import d from '/lib/greet.js'; window.m1 = greet() + ':' + d + ':' + (typeof fromClassic); import('/late.js').then(function (m) { window.late = m.late; });</script>
        \\<script src="/classic.js"></script>
        \\<script type="module">window.m2 = 'second:' + window.m1;</script>
        \\<script type="module">import { nothing } from './lib/greet.js';</script>
        \\<script>
        \\  var out = [];
        \\  out.push('classic-first:' + (typeof window.m1));
        \\  window.addEventListener('hashchange', function () { out.push('hash:' + location.hash); });
        \\  window.addEventListener('popstate', function (e) { out.push('pop:' + JSON.stringify(e.state) + ':' + location.pathname + location.search); });
        \\  location.hash = 'sec';
        \\  history.pushState({ n: 1 }, '', '/one?a=1');
        \\  history.pushState({ n: 2 }, '', '/two');
        \\  out.push('len:' + history.length + ':' + history.state.n + ':' + location.pathname);
        \\  history.back();
        \\  history.back();
        \\  history.forward();
        \\  history.replaceState({ n: 9 }, '', '/nine');
        \\  out.push('state:' + history.state.n + ':' + location.pathname);
        \\  document.title = ' New  Title ';
        \\  var threw = false; try { history.pushState({}, '', 'http://other.test/x'); } catch (e) { threw = true; }
        \\  out.push('xo:' + threw);
        \\  location.href = 'next.html?q';
        \\  location.assign('/abs');
        \\  window.addEventListener('load', function () { out.push('modules:' + window.m1 + '|' + window.m2 + '|' + window.late); console.log(out.join(' ')); });
        \\</script></body>
    );
    defer tp.close();
    tp.page.runScripts();
    try std.testing.expect(std.mem.indexOf(u8, tp.host.lines.items, "does not provide an export named 'nothing'") != null);
    const last = std.mem.lastIndexOf(u8, tp.host.lines.items, "log:").?;
    try std.testing.expectEqualStrings(
        \\log:classic-first:undefined hash:#sec len:3:2:/two pop:{"n":1}:/one?a=1 pop:null:/dir/page.html?q=1 pop:{"n":1}:/one?a=1 state:9:/nine xo:true modules:hi moss:42:string|second:hi moss:42:string|late
        \\
    , tp.host.lines.items[last..]);
    // Relative to the document's URL as pushState left it (/nine).
    try std.testing.expectEqualStrings("http://example.test:8080/next.html?q;http://example.test:8080/abs;", tp.host.navigated.items);
    try std.testing.expectEqualStrings("url=http://example.test:8080/dir/page.html?q=1#sec;url=http://example.test:8080/one?a=1;url=http://example.test:8080/two;url=http://example.test:8080/one?a=1;url=http://example.test:8080/dir/page.html?q=1#sec;url=http://example.test:8080/one?a=1;url=http://example.test:8080/nine;title=New  Title;", tp.host.changes.items);
}

test "script: forms fire submit, input and change, and a script can submit or reset one" {
    const tp = try TestPage.open(
        \\<body><form id="f" action="/go" method="POST"><input id="q" name="q" value="v"><select id="s"><option value="a">A</option><option value="b" selected>B</option></select><textarea id="t">tt</textarea><button id="b">Go</button></form><a id="l" href="/x">x</a>
        \\<script>
        \\  var out = [];
        \\  var f = document.getElementById('f'), q = document.getElementById('q');
        \\  out.push(f.method, f.action, f.elements.length, f.length, q.form === f, document.forms.length, document.getElementById('s').value, document.getElementById('s').selectedIndex, document.getElementById('t').value, f instanceof HTMLFormElement);
        \\  var prevent = true;
        \\  f.addEventListener('submit', function (e) { out.push('submit:' + (e.target === f)); if (prevent) e.preventDefault(); });
        \\  q.addEventListener('input', function (e) { out.push('input:' + q.value); });
        \\  q.addEventListener('change', function (e) { out.push('change:' + q.value); });
        \\  f.requestSubmit();
        \\  prevent = false;
        \\  f.requestSubmit();
        \\  document.getElementById('l').addEventListener('click', function (e) { out.push('lclick'); });
        \\  document.getElementById('l').click();
        \\  window.report = function () { console.log(out.join(' ')); };
        \\</script></body>
    );
    defer tp.close();
    tp.page.runScripts();
    try std.testing.expect(tp.host.submitted != null);
    var w = tp.doc.walk(dom.document_id);
    var form: NodeId = 0;
    var input: NodeId = 0;
    var link: NodeId = 0;
    while (w.next()) |id| {
        if (tp.doc.isHtml(id, "form")) form = id;
        if (tp.doc.isHtml(id, "input")) input = id;
        if (tp.doc.isHtml(id, "a")) link = id;
    }
    try std.testing.expectEqual(form, tp.host.submitted.?);
    try std.testing.expectEqual(link, tp.host.activated.?);
    // The user types: the page reports input, then commits the change.
    try tp.doc.setAttr(input, "value", "vw");
    tp.page.fireInput(input);
    tp.page.fireChange(input);
    // The user presses Enter in the form: submit fires (not prevented now).
    try std.testing.expect(tp.page.fireSubmit(form));
    tp.page.runSource("report()", "check");
    try std.testing.expectEqualStrings("log:post /go 4 4 true 1 b 1 tt true submit:true submit:true lclick input:vw input:vw change:vw submit:true\n", tp.host.lines.items);
}

test "script: localStorage goes through the host, sessionStorage stays in the page" {
    const tp = try TestPage.open(
        \\<body><script>
        \\  var out = [];
        \\  localStorage.setItem('a', '1'); localStorage.setItem('b', 'two'); localStorage.setItem('a', 'one');
        \\  out.push(localStorage.length, localStorage.getItem('a'), localStorage.getItem('b'), localStorage.getItem('zz'), localStorage.key(0), localStorage.key(1), localStorage.key(2));
        \\  localStorage.removeItem('a');
        \\  out.push(localStorage.length, localStorage.getItem('a'));
        \\  var q = false; try { localStorage.setItem('big', 'x'.repeat(100)); } catch (e) { q = /QuotaExceededError/.test(e.message); }
        \\  out.push('quota:' + q);
        \\  sessionStorage.setItem('s', 'v'); sessionStorage.setItem('t', 'w');
        \\  out.push(sessionStorage.length, sessionStorage.getItem('s'), sessionStorage.key(1), localStorage.getItem('s'));
        \\  sessionStorage.clear();
        \\  out.push(sessionStorage.length, localStorage.length, localStorage instanceof Storage);
        \\  console.log(out.join(' '));
        \\</script></body>
    );
    defer tp.close();
    tp.page.runScripts();
    // (`join` renders a null as nothing.)
    try std.testing.expectEqualStrings("log:2 one two  a b  1  quota:true 2 v t  0 1 true\n", tp.host.lines.items);
    try std.testing.expectEqual(@as(usize, 1), tp.host.store.items.len);
}

test "script: keys reach the focused element as keyboard events, and stylesheets read and change" {
    const tp = try TestPage.open(
        \\<head><style id="s">h1 { color: red; }
        \\@media (min-width: 10px) { p { margin: 0 } }</style><link rel="stylesheet" href="/x.css" media="print"></head>
        \\<body><input id="i"><script>
        \\  var out = [];
        \\  var i = document.getElementById('i');
        \\  i.addEventListener('keydown', function (e) { out.push('down:' + e.key + ':' + e.code + ':' + e.keyCode + ':' + e.shiftKey + ':' + (e.target === i) + ':' + (e instanceof KeyboardEvent)); if (e.key === 'x') e.preventDefault(); });
        \\  i.addEventListener('keypress', function (e) { out.push('press:' + e.key + ':' + e.charCode); });
        \\  document.body.addEventListener('keyup', function (e) { out.push('up:' + e.key); });
        \\  var sheets = document.styleSheets;
        \\  var s = sheets[0], l = sheets[1];
        \\  out.push('sheets:' + sheets.length + ':' + (s instanceof CSSStyleSheet) + ':' + (s.ownerNode === document.getElementById('s')) + ':' + s.href + ':' + l.href + ':' + l.media + ':' + l.cssRules.length);
        \\  out.push('rules:' + s.cssRules.length + ':' + s.cssRules[0].selectorText + ':' + s.cssRules[0].style.cssText + ':' + s.cssRules[1].type + ':' + s.cssRules[1].conditionText);
        \\  s.insertRule('body { margin: 0 }', 0);
        \\  s.deleteRule(2);
        \\  out.push('after:' + s.cssRules.length + ':' + s.cssRules[0].cssText + ':' + s.cssRules[1].selectorText);
        \\  window.report = function () { console.log(out.join(' ')); };
        \\</script></body>
    );
    defer tp.close();
    tp.page.runScripts();
    var w = tp.doc.walk(dom.document_id);
    var input: NodeId = 0;
    var style: NodeId = 0;
    while (w.next()) |id| {
        if (tp.doc.isHtml(id, "input")) input = id;
        if (tp.doc.isHtml(id, "style")) style = id;
    }
    try std.testing.expect(tp.page.fireKey(input, keyFromByte('a')));
    try std.testing.expect(!tp.page.fireKey(input, keyFromByte('x')));
    try std.testing.expect(tp.page.fireKey(input, keyFromByte('\n')));
    try std.testing.expect(tp.page.fireKey(null, keyNamed("ArrowUp", 38, false)));
    tp.page.runSource("report()", "check");
    try std.testing.expectEqualStrings(
        \\log:sheets:2:true:true:null:http://example.test:8080/x.css:print:0 rules:2:h1:color: red;:4:(min-width: 10px) after:2:body { margin: 0 }:h1 down:a:KeyA:65:false:true:true press:a:97 up:a down:x:KeyX:88:false:true:true up:x down:Enter:Enter:13:false:true:true press:Enter:13 up:Enter up:ArrowUp
        \\
    , tp.host.lines.items);
    try std.testing.expect(std.mem.indexOf(u8, tp.doc.textContent(style, tp.arena.allocator()) catch "", "body { margin: 0 }") != null);
}

test "script: mutation observers see the tree, attributes and text change, delivered as a microtask" {
    const tp = try TestPage.open(
        \\<body><div id="d"><p id="p">text</p></div><script>
        \\  var out = [];
        \\  var d = document.getElementById('d'), p = document.getElementById('p');
        \\  var mo = new MutationObserver(function (records, observer) {
        \\    out.push(records.map(function (r) { return r.type + ':' + (r.target.id || r.target.nodeName) + ':' + r.addedNodes.length + ':' + r.removedNodes.length + ':' + r.attributeName; }).join(',') + '|' + (observer === mo));
        \\  });
        \\  mo.observe(d, { childList: true, attributes: true, characterData: true, subtree: true });
        \\  var e = document.createElement('span'); e.id = 'e'; d.appendChild(e);
        \\  p.setAttribute('title', 't'); p.classList.add('c'); p.style.color = 'red';
        \\  p.firstChild.data = 'changed';
        \\  p.remove();
        \\  out.push('sync:' + out.length);
        \\  Promise.resolve().then(function () { out.push('after:' + out.length); });
        \\  var other = new MutationObserver(function () { out.push('other'); });
        \\  other.observe(document.body, { childList: true });
        \\  d.appendChild(document.createElement('i'));
        \\  out.push('taken:' + other.takeRecords().length);
        \\  other.disconnect();
        \\  document.body.appendChild(document.createElement('b'));
        \\  window.report = function () { console.log(out.join(' ')); };
        \\</script></body>
    );
    defer tp.close();
    tp.page.runScripts();
    tp.page.runSource("report()", "check");
    try std.testing.expectEqualStrings("log:sync:0 taken:0 childList:d:1:0:null,attributes:p:0:0:title,attributes:p:0:0:class,attributes:p:0:0:style,characterData:#text:0:0:null,childList:d:0:1:null,childList:d:1:0:null|true after:3\n", tp.host.lines.items);
}

test "script: a storage answers to names through its proxy" {
    const tp = try TestPage.open(
        \\<body><script>
        \\  var out = [];
        \\  localStorage.color = 'blue'; localStorage['n'] = 3;
        \\  out.push(localStorage.color, localStorage.n, typeof localStorage.n, localStorage.getItem('color'), localStorage.length, 'color' in localStorage, 'zz' in localStorage, localStorage.zz);
        \\  delete localStorage.color;
        \\  out.push(localStorage.length, Object.keys(localStorage).join('+'), localStorage instanceof Storage, typeof localStorage.setItem);
        \\  sessionStorage.x = 'y'; out.push(sessionStorage.getItem('x'), localStorage.getItem('x'));
        \\  console.log(out.join(' '));
        \\</script></body>
    );
    defer tp.close();
    tp.page.runScripts();
    // (`join` renders undefined and null as nothing.)
    try std.testing.expectEqualStrings("log:blue 3 string blue 2 true false  1 n true function y \n", tp.host.lines.items);
}

test "script: handler attributes and properties run, and document.write inserts after its script" {
    const tp = try TestPage.open(
        \\<body onload="window.loaded = 'body:' + (this === document.body) + ':' + event.type">
        \\<button id="b" onclick="out.push('attr:' + event.type + ':' + (this === document.getElementById('b'))); return false">B</button>
        \\<a id="l" href="/x" onclick="return false">x</a>
        \\<p id="before">before</p><script>var out = []; document.write('<i id="w">w</i>'); out.push('written:' + (document.getElementById('w').previousSibling.tagName));</script><p id="after">after</p>
        \\<script>
        \\  var b = document.getElementById('b');
        \\  b.addEventListener('click', function (e) { out.push('listener:' + e.defaultPrevented); });
        \\  b.onclick = function (e) { out.push('prop'); };
        \\  document.getElementById('w').onmouseover = null;
        \\  window.addEventListener('load', function () { out.push(window.loaded); document.write('late'); console.log(out.join(' ')); });
        \\</script></body>
    );
    defer tp.close();
    tp.page.runScripts();
    var w = tp.doc.walk(dom.document_id);
    var button: NodeId = 0;
    var link: NodeId = 0;
    while (w.next()) |id| {
        if (tp.doc.isHtml(id, "button")) button = id;
        if (tp.doc.isHtml(id, "a")) link = id;
    }
    // The property set by script replaced the attribute's handler: no
    // 'return false' now, so the click goes on; the link's attribute
    // still prevents.
    try std.testing.expect(tp.page.click(button));
    try std.testing.expect(!tp.page.click(link));
    tp.page.runSource("console.log(out.join(' '))", "check");
    // (The load listener's document.write is refused first, then it logs.)
    try std.testing.expectEqualStrings("warn:script: document.write outside a parser-inserted script is ignored\nlog:written:SCRIPT body:true:load\nlog:written:SCRIPT body:true:load prop listener:false\n", tp.host.lines.items);
}

// Acid3 on the host, when fetched (tools/fetch-acid3.sh): the page's
// scripts run, its timer chain is driven to the end on a fake clock,
// and the score is printed with the document arena's growth — the
// stage's exit criterion measured in the fast loop, never asserted.
test "script: acid3 on the host (when fetched): the score, printed" {
    const ta = std.testing.allocator;
    const dir = "tools/testdata/acid3";
    const markup = std.Io.Dir.cwd().readFileAlloc(std.testing.io, dir ++ "/test.html", ta, .limited(4 << 20)) catch return error.SkipZigTest;
    defer ta.free(markup);
    const tp = try TestPage.open(markup);
    defer tp.close();
    tp.host.dir = dir;
    try tp.page.setUrl("http://acid3.test/acid3/test.html");
    const arena_before = tp.arena.queryCapacity();
    tp.page.runScripts();
    var now: f64 = 0;
    var ticks: usize = 0;
    while (tp.page.nextDue()) |due| : (ticks += 1) {
        now = @max(now + 1, due);
        tp.page.fake_now = now;
        _ = tp.page.runDue(now);
        if (now > 300_000 or ticks > 100_000) break;
    }
    var score: []const u8 = "?";
    var w = tp.doc.walk(dom.document_id);
    while (w.next()) |id| if (tp.doc.get(id).kind == .element) if (tp.doc.getAttr(id, "id")) |i| if (std.mem.eql(u8, i, "score")) {
        score = try tp.doc.textContent(id, tp.arena.allocator());
    };
    std.debug.print("acid3 (host): {s}/100 after {d} timer ticks and {d} ms of page time; document arena +{d} KB; {d} script errors\n", .{ score, ticks, @as(u64, @intFromFloat(now)), (tp.arena.queryCapacity() - arena_before) / 1024, tp.page.script_errors });
    // The harness's log names each failing test: printed for the next round.
    tp.page.runSource("console.log(typeof log === 'string' ? log : '(no log)')", "acid3 log");
    const at = std.mem.lastIndexOf(u8, tp.host.lines.items, "log:") orelse 0;
    std.debug.print("{s}\n", .{tp.host.lines.items[at..]});
}

test "script: the wrappers survive a collection at every safe point" {
    const tp = try TestPage.open(
        \\<body><div id="d"><span>a</span><span>b</span></div>
        \\<script>
        \\  var d = document.getElementById('d');
        \\  d.addEventListener('click', function () { d.setAttribute('clicked', 'yes'); });
        \\  for (var i = 0; i < 200; i++) { var s = document.createElement('span'); s.textContent = 'n' + i; d.appendChild(s); }
        \\  var kept = d.children[3];
        \\  for (var j = 0; j < 2000; j++) { var junk = { a: [j, j + 1], b: 'x' + j }; }
        \\  console.log(d.children.length, kept === d.children[3], kept.textContent);
        \\</script></body>
    );
    defer tp.close();
    tp.vm.heap.stress = true;
    tp.page.runScripts();
    var w = tp.doc.walk(dom.document_id);
    var div: NodeId = 0;
    while (w.next()) |id| if (tp.doc.isHtml(id, "div")) {
        div = id;
    };
    try std.testing.expect(tp.page.click(div));
    try std.testing.expectEqualStrings("yes", tp.doc.getAttr(div, "clicked").?);
    try std.testing.expectEqualStrings("log:202 true n1\n", tp.host.lines.items);
    try std.testing.expect(tp.vm.heap.collections > 0);
}
