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
    _pad: u32 = 0,
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
        .{ .name = "location", .get = getLocation },
        .{ .name = "forms", .get = getForms },
        .{ .name = "images", .get = getImages },
        .{ .name = "links", .get = getLinks },
        .{ .name = "scripts", .get = getScripts },
    }, .methods = &parent_methods ++ [_]Method{
        .{ .name = "getElementById", .len = 1, .f = getElementById },
        .{ .name = "createElement", .len = 1, .f = createElement },
        .{ .name = "createElementNS", .len = 2, .f = createElementNS },
        .{ .name = "createTextNode", .len = 1, .f = createTextNode },
        .{ .name = "createComment", .len = 1, .f = createComment },
        .{ .name = "createDocumentFragment", .f = createDocumentFragment },
        .{ .name = "createEvent", .len = 1, .f = createEvent },
        .{ .name = "hasFocus", .f = hasFocus },
    } },
    .{ .name = "DocumentFragment", .parent = "Node", .attrs = &parent_attrs, .methods = &parent_methods ++ [_]Method{
        .{ .name = "getElementById", .len = 1, .f = getElementById },
    } },
    .{ .name = "DocumentType", .parent = "Node", .attrs = &.{
        .{ .name = "name", .get = getNodeName },
    } },
    .{ .name = "CharacterData", .parent = "Node", .attrs = &.{
        .{ .name = "data", .get = getNodeValue, .set = setNodeValue },
        .{ .name = "length", .get = getDataLength },
    }, .methods = &.{
        .{ .name = "remove", .f = removeSelf },
        .{ .name = "before", .f = insertBeforeSelf },
        .{ .name = "after", .f = insertAfterSelf },
        .{ .name = "replaceWith", .f = replaceWith },
    } },
    .{ .name = "Text", .parent = "CharacterData", .attrs = &.{
        .{ .name = "wholeText", .get = getNodeValue },
    } },
    .{ .name = "Comment", .parent = "CharacterData" },
    .{ .name = "Element", .parent = "Node", .attrs = &parent_attrs ++ [_]Attr{
        .{ .name = "tagName", .get = getTagName },
        .{ .name = "localName", .get = getLocalName },
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
        .{ .name = "offsetWidth", .get = getClientWidth },
        .{ .name = "offsetHeight", .get = getClientHeight },
        .{ .name = "offsetTop", .get = getOffsetTop },
        .{ .name = "offsetLeft", .get = getOffsetLeft },
        .{ .name = "offsetParent", .get = getParentElement },
    }, .methods = &.{
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
        .{ .name = "selectedIndex", .get = getSelectedIndex },
        .{ .name = "options", .get = getOptions },
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
    const tokens = ifaceIndex("DOMTokenList");
    const style = ifaceIndex("CSSStyleDeclaration");
    const event = ifaceIndex("Event");
    const custom_event = ifaceIndex("CustomEvent");
    const xhr = ifaceIndex("XMLHttpRequest");
    const storage = ifaceIndex("Storage");
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
const session_quota: usize = 256 << 10;

pub const Page = struct {
    vm: *Vm,
    doc: *dom.Document,
    /// Bookkeeping memory (the wrapper table, timers).
    a: std.mem.Allocator,
    host: Host,
    url: []const u8 = "about:blank",
    viewport_w: u32 = 800,
    viewport_h: u32 = 600,
    scroll_x: f64 = 0,
    scroll_y: f64 = 0,
    wrappers: std.AutoHashMapUnmanaged(NodeId, *Object) = .empty,
    protos: [interfaces.len]*Object = undefined,
    ctors: [interfaces.len]*Object = undefined,
    sym_listeners: *Symbol = undefined,
    sym_slot: *Symbol = undefined,
    sym_style: *Symbol = undefined,
    document_obj: *Object = undefined,
    location_obj: *Object = undefined,
    timers: std.ArrayList(Timer) = .empty,
    next_timer: u32 = 1,
    /// Every script's text, kept: the engine holds slices of it.
    sources: std.ArrayList([]u8) = .empty,
    url_owned: bool = false,
    /// The DOM changed since the embedder last asked.
    dirty: bool = false,
    ready_state: ReadyState = .loading,
    /// When no host clock is set: the time the tests advance by hand.
    fake_now: f64 = 0,
    scripts_run: u32 = 0,
    script_errors: u32 = 0,
    /// The session history the page's scripts made: `pushState` entries
    /// and where the page is in them (the host keeps the real history).
    history: std.ArrayList(HistoryEntry) = .empty,
    history_index: usize = 0,
    modules_run: u32 = 0,
    /// `sessionStorage`: the page's own, gone with the document.
    session_items: std.ArrayList(SessionItem) = .empty,

    /// Install the bindings into `vm` for `doc`. The VM's `host_data`
    /// becomes this page and its embedder roots this page's tables.
    pub fn init(p: *Page, vm: *Vm, doc: *dom.Document, a: std.mem.Allocator, host: Host) Error!void {
        p.* = .{ .vm = vm, .doc = doc, .a = a, .host = host };
        vm.host_data = p;
        vm.embedder_roots = .{ .ctx = p, .trace = trace };
        p.sym_listeners = try vm.newSymbol(try vm.strings.fromUtf8("listeners"));
        p.sym_slot = try vm.newSymbol(try vm.strings.fromUtf8("slot"));
        p.sym_style = try vm.newSymbol(try vm.strings.fromUtf8("style"));
        try p.installInterfaces();
        try p.installWindow();
        vm.host_load = hostLoad;
    }

    pub fn deinit(p: *Page) void {
        p.wrappers.deinit(p.a);
        p.timers.deinit(p.a);
        for (p.sources.items) |src| p.a.free(src);
        p.sources.deinit(p.a);
        for (p.history.items) |h| p.a.free(h.url);
        p.history.deinit(p.a);
        for (p.session_items.items) |it| {
            p.a.free(it.key);
            p.a.free(it.value);
        }
        p.session_items.deinit(p.a);
        if (p.url_owned) p.a.free(p.url);
        p.vm.embedder_roots = null;
        p.vm.host_data = null;
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
        for (p.timers.items) |t| {
            m.markValue(t.func);
            for (t.args[0..t.argc]) |v| m.markValue(v);
        }
        for (p.history.items) |h| m.markValue(h.state);
    }

    /// Whether the DOM changed since the last call (and forget it).
    pub fn takeDirty(p: *Page) bool {
        const d = p.dirty;
        p.dirty = false;
        return d;
    }

    pub fn now(p: *Page) f64 {
        return if (p.vm.host_now) |f| f() else p.fake_now;
    }

    // ------------------------------------------------------- install

    fn installInterfaces(p: *Page) Error!void {
        const vm = p.vm;
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
        _ = try vm.defineNative(g, "matchMedia", 1, matchMedia);
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
        if (p.wrappers.get(id)) |o| return o;
        const n = p.doc.get(id);
        const k: usize = switch (n.kind) {
            .document => I.document,
            .fragment => I.fragment,
            .doctype => I.doctype,
            .text => I.text,
            .comment => I.comment,
            .element => if (n.namespace != .html) I.element else if (std.mem.eql(u8, n.name, "input") or std.mem.eql(u8, n.name, "textarea") or std.mem.eql(u8, n.name, "select") or std.mem.eql(u8, n.name, "button")) I.input else if (std.mem.eql(u8, n.name, "a") or std.mem.eql(u8, n.name, "area")) I.anchor else if (std.mem.eql(u8, n.name, "form")) I.form else I.html_element,
        };
        const o = try p.vm.objects.create(p.protos[k].asValue(), .dom, @sizeOf(Slot));
        o.internal(Slot).* = .{ .kind = slot_node, .id = id };
        try p.wrappers.put(p.a, id, o);
        return o;
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
        var list: std.ArrayList(NodeId) = .empty;
        defer list.deinit(p.a);
        var w = p.doc.walk(dom.document_id);
        while (w.next()) |id| if (p.doc.isHtml(id, "script")) list.append(p.a, id) catch return;
        // Classic scripts as the parser meets them; module scripts are
        // deferred, so they run after, in document order.
        for (list.items) |id| if (!isModuleScript(p, id)) p.runScriptElement(id);
        for (list.items) |id| if (isModuleScript(p, id)) p.runScriptElement(id);
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
        const doc = p.doc;
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
            const text = fetch(p.host.ctx, abs) orelse {
                p.logf(.err, "script: could not load {s}", .{abs});
                return;
            };
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
        const vm = p.vm;
        // The engine keeps slices of the source (a function's text).
        const src = p.a.dupe(u8, source) catch return;
        p.sources.append(p.a, src) catch {
            p.a.free(src);
            return;
        };
        const code = js.compiler.compile(vm.meta, &vm.heap, &vm.strings, src, .{ .name = name }) catch |e| switch (e) {
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
        _ = js.interp.runScript(vm, code, vm.global.asValue(), null, null, Value.undefined_) catch |e| p.reportError(e, name);
        p.runJobs();
    }

    fn runJobs(p: *Page) void {
        p.vm.runJobs() catch |e| p.reportError(e, "a promise job");
    }

    fn reportError(p: *Page, e: Error, where: []const u8) void {
        switch (e) {
            error.OutOfMemory => p.log(.err, "script: out of memory"),
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
        // An Error: "Name: message" and its stack line if present.
        if (ex.isObject()) {
            const o = Vm.asObject(ex);
            const stack = vm.get(o, .{ .atom = vm.atom("stack") catch return "exception" }, ex) catch Value.undefined_;
            if (stack.isString()) return js.builtins.utf8Buf(vm, Vm.asString(stack), buf) catch "exception";
        }
        const s = vm.toString(ex) catch return "exception";
        return js.builtins.utf8Buf(vm, s, buf) catch "exception";
    }

    pub fn log(p: *Page, level: Level, text: []const u8) void {
        p.host.log(p.host.ctx, level, text);
    }

    pub fn logf(p: *Page, level: Level, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        p.log(level, std.fmt.bufPrint(&buf, fmt, args) catch fmt);
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
        const target = p.wrapValue(form) catch return true;
        return p.fireSimple(target, "submit", true, true);
    }

    /// The user typed into a control, or toggled one.
    pub fn fireInput(p: *Page, id: NodeId) void {
        const target = p.wrapValue(id) catch return;
        _ = p.fireSimple(target, "input", true, false);
        p.runJobs();
    }

    pub fn fireChange(p: *Page, id: NodeId) void {
        const target = p.wrapValue(id) catch return;
        _ = p.fireSimple(target, "input", true, false);
        _ = p.fireSimple(target, "change", true, false);
        p.runJobs();
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
            while (cur) |c| : (cur = p.doc.get(c).parent) if (p.wrappers.get(c)) |o| try path.append(p.a, o.asValue());
            try path.append(p.a, vm.global.asValue());
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

    fn invokeListeners(p: *Page, target: Value, ev: *Object, capture: bool) Error!void {
        const vm = p.vm;
        if (!target.isObject()) return;
        const o = Vm.asObject(target);
        const list = (try p.listenerList(o, false)) orelse return;
        // A snapshot: listeners added during dispatch do not run now.
        var snap: std.ArrayList(Value) = .empty;
        defer snap.deinit(p.a);
        try vm.listFromArrayLike(list.asValue(), &snap);
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
            const r: Error!Value = if (vm.isCallable(cb)) vm.call(cb, target, &.{ev.asValue()}) else blk: {
                if (!cb.isObject()) break :blk Value.undefined_;
                const h = try vm.get(Vm.asObject(cb), .{ .atom = try vm.atom("handleEvent") }, cb);
                if (!vm.isCallable(h)) break :blk Value.undefined_;
                break :blk vm.call(h, cb, &.{ev.asValue()});
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
        var ran = false;
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
            _ = vm.call(t.func, vm.global.asValue(), t.args[0..t.argc]) catch |e| p.reportError(e, if (t.raf) "an animation frame" else "a timer");
            p.runJobs();
        }
        return ran;
    }

    /// When the next timer is due, or null with none pending.
    pub fn nextDue(p: *Page) ?f64 {
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
    fn nodeOfValue(p: *Page, v: Value) ?NodeId {
        _ = p;
        if (!v.isObject()) return null;
        const o = Vm.asObject(v);
        if (o.class != .dom) return null;
        const s = o.internal(Slot);
        if (s.kind != slot_node) return null;
        return s.id;
    }

    /// Mark the DOM changed.
    fn touch(p: *Page) void {
        p.dirty = true;
    }
};

// ------------------------------------------------------------ helpers

inline fn pageOf(vm: *Vm) *Page {
    return @ptrCast(@alignCast(vm.host_data.?));
}

fn arg(args: []const Value, i: usize) Value {
    return if (i < args.len) args[i] else Value.undefined_;
}

/// `this` as a node, or a TypeError.
fn thisNode(vm: *Vm, this: Value) Error!NodeId {
    return pageOf(vm).nodeOfValue(this) orelse vm.throwTypeError("Illegal invocation");
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
    if (child == parent or isAncestor(doc, child, parent)) return vm.throwError(.TypeError, "HierarchyRequestError: the new child is an ancestor of the parent");
    const pk = doc.get(parent).kind;
    if (pk != .element and pk != .document and pk != .fragment) return vm.throwError(.TypeError, "HierarchyRequestError: this node cannot have children");
    if (before) |b| if (doc.get(b).parent != parent) return vm.throwError(.TypeError, "NotFoundError: the reference node is not a child");
    if (doc.get(child).kind == .fragment) {
        var c = doc.get(child).first_child;
        while (c) |cid| {
            const next = doc.get(cid).next;
            doc.detach(cid);
            doc.insertBefore(parent, cid, before);
            c = next;
        }
    } else {
        doc.detach(child);
        doc.insertBefore(parent, child, before);
    }
    p.touch();
}

/// A node argument for `append`-style methods: a node, or a string
/// that becomes a text node.
fn nodeOrText(vm: *Vm, v: Value) Error!NodeId {
    const p = pageOf(vm);
    if (p.nodeOfValue(v)) |id| return id;
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
    // Parsed into the document's own arena so the strings can be shared.
    const frag_doc = try html.parseFragment(doc.a, markup, name, ns, .{ .scripting = true });
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
            const e = try doc.createElement(n.namespace, n.name);
            for (n.attrs.items) |at| try doc.setAttr(e, at.name, at.value);
            break :blk e;
        },
        .text => try doc.createText(n.text.items),
        .comment => try doc.createComment(n.text.items),
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
    const n = pageOf(vm).doc.get(id);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    return switch (n.kind) {
        .element => jsStr(vm, if (n.namespace == .html) try upperName(n.name, sc.a()) else n.name),
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
    n.text.clearRetainingCapacity();
    try n.text.appendSlice(p.doc.a, text);
    p.touch();
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
            while (n.first_child) |c| p.doc.detach(c);
            const v = arg(args, 0);
            if (!v.isNullish()) {
                const text = try docStr(vm, v);
                if (text.len > 0) p.doc.appendChild(id, try p.doc.createText(text));
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
    return p.wrapValue(p.doc.get(try thisNode(vm, this)).first_child);
}

fn getLastChild(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    return p.wrapValue(p.doc.get(try thisNode(vm, this)).last_child);
}

fn getPreviousSibling(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    return p.wrapValue(p.doc.get(try thisNode(vm, this)).prev);
}

fn getNextSibling(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    return p.wrapValue(p.doc.get(try thisNode(vm, this)).next);
}

fn getOwnerDocument(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    if (id == dom.document_id) return Value.null_;
    return p.document_obj.asValue();
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
    const child = p.nodeOfValue(arg(args, 0)) orelse return vm.throwTypeError("appendChild: not a node");
    try insertNode(p, parent, child, null);
    return arg(args, 0);
}

fn insertBefore(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const parent = try thisNode(vm, this);
    const child = p.nodeOfValue(arg(args, 0)) orelse return vm.throwTypeError("insertBefore: not a node");
    const ref = arg(args, 1);
    const before: ?NodeId = if (ref.isNullish()) null else (p.nodeOfValue(ref) orelse return vm.throwTypeError("insertBefore: the reference is not a node"));
    try insertNode(p, parent, child, before);
    return arg(args, 0);
}

fn removeChild(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const parent = try thisNode(vm, this);
    const child = p.nodeOfValue(arg(args, 0)) orelse return vm.throwTypeError("removeChild: not a node");
    if (p.doc.get(child).parent != parent) return vm.throwError(.TypeError, "NotFoundError: the node is not a child");
    p.doc.detach(child);
    p.touch();
    return arg(args, 0);
}

fn replaceChild(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const parent = try thisNode(vm, this);
    const new_child = p.nodeOfValue(arg(args, 0)) orelse return vm.throwTypeError("replaceChild: not a node");
    const old = p.nodeOfValue(arg(args, 1)) orelse return vm.throwTypeError("replaceChild: not a node");
    if (p.doc.get(old).parent != parent) return vm.throwError(.TypeError, "NotFoundError: the node is not a child");
    const next = p.doc.get(old).next;
    p.doc.detach(old);
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
    const p = pageOf(vm);
    return Value.fromBool(p.doc.get(try thisNode(vm, this)).first_child != null);
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
    return collectByTag(vm, this, &.{"form"});
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
    _ = try thisNode(vm, this);
    return vm.global.asValue();
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
    if (name.len == 0) return vm.throwError(.TypeError, "InvalidCharacterError: an empty tag name");
    for (name) |*c| c.* = std.ascii.toLower(c.*);
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
    const ns: dom.Namespace = if (std.mem.eql(u8, ns_text, "http://www.w3.org/2000/svg")) .svg else if (std.mem.eql(u8, ns_text, "http://www.w3.org/1998/Math/MathML")) .mathml else .html;
    var name = try docStr(vm, arg(args, 1));
    if (std.mem.indexOfScalar(u8, name, ':')) |i| name = name[i + 1 ..];
    if (ns == .html) for (name) |*c| {
        c.* = std.ascii.toLower(c.*);
    };
    return p.wrapValue(try p.doc.createElement(ns, name));
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
    const iface: usize = if (std.ascii.eqlIgnoreCase(kind, "CustomEvent")) I.custom_event else if (std.ascii.eqlIgnoreCase(kind, "MouseEvent") or std.ascii.eqlIgnoreCase(kind, "MouseEvents")) I.mouse_event else I.event;
    const ev = try p.newEvent(iface, "", false, false, false);
    _ = try vm.defineNative(ev, "initEvent", 1, initEvent);
    return ev.asValue();
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
    while (p.doc.get(parent).first_child) |c| p.doc.detach(c);
    for (ids.items) |id| try insertNode(p, parent, id, null);
    p.touch();
    return Value.undefined_;
}

// -------------------------------------------------------- ChildNode

fn removeSelf(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisNode(vm, this);
    if (p.doc.get(id).parent != null) {
        p.doc.detach(id);
        p.touch();
    }
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
    p.doc.detach(id);
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
    return jsStr(vm, pageOf(vm).doc.get(id).name);
}

fn getNamespaceURI(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const id = try thisElement(vm, this);
    return jsStr(vm, switch (pageOf(vm).doc.get(id).namespace) {
        .html => "http://www.w3.org/1999/xhtml",
        .svg => "http://www.w3.org/2000/svg",
        .mathml => "http://www.w3.org/1998/Math/MathML",
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
    try p.doc.setAttr(id, name, try docStr(vm, v));
    p.touch();
    return Value.undefined_;
}

fn boolAttrGetter(vm: *Vm, this: Value, name: []const u8) Error!Value {
    const id = try thisElement(vm, this);
    return Value.fromBool(pageOf(vm).doc.hasAttr(id, name));
}

fn boolAttrSetter(vm: *Vm, this: Value, name: []const u8, v: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    if (vm.toBoolean(v)) try p.doc.setAttr(id, name, "") else p.doc.removeAttr(id, name);
    p.touch();
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
fn getTabIndex(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const id = try thisElement(vm, this);
    const t = pageOf(vm).doc.getAttr(id, "tabindex") orelse return Value.fromInt(-1);
    return Value.fromInt(std.fmt.parseInt(i32, std.mem.trim(u8, t, " "), 10) catch -1);
}
fn setTabIndex(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return attrSetter(vm, this, "tabindex", try vm.toStringValue(arg(args, 0)));
}
fn getValueAttr(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    // A textarea's value is its text; a select's is its selected option's.
    if (p.doc.isHtml(id, "textarea")) return getTextContent(vm, this, &.{}, Value.undefined_);
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
    return attrSetter(vm, this, "value", arg(args, 0));
}
fn getChecked(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return boolAttrGetter(vm, this, "checked");
}
fn setChecked(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return boolAttrSetter(vm, this, "checked", arg(args, 0));
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
    return jsStr(vm, p.doc.getAttr(id, "type") orelse (if (p.doc.isHtml(id, "button")) "submit" else if (p.doc.isHtml(id, "input")) "text" else ""));
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
    try p.doc.setAttr(id, name, value);
    p.touch();
    return Value.undefined_;
}

fn removeAttribute(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    const id = try thisElement(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    const name = try attrKey(vm, arg(args, 0), sc.a());
    if (p.doc.hasAttr(id, name)) {
        p.doc.removeAttr(id, name);
        p.touch();
    }
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
    if (want and !has) try p.doc.setAttr(id, name, "");
    if (!want and has) p.doc.removeAttr(id, name);
    if (want != has) p.touch();
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
    while (p.doc.get(id).first_child) |c| p.doc.detach(c);
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
    p.doc.detach(id);
    try insertNode(p, parent, frag, next);
    return Value.undefined_;
}

fn getNextElementSibling(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    var c = p.doc.get(try thisNode(vm, this)).next;
    while (c) |cid| : (c = p.doc.get(cid).next) if (p.doc.get(cid).kind == .element) return p.wrapValue(cid);
    return Value.null_;
}

fn getPreviousElementSibling(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const p = pageOf(vm);
    var c = p.doc.get(try thisNode(vm, this)).prev;
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
    const el = p.nodeOfValue(arg(args, 1)) orelse return vm.throwTypeError("not an element");
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
    if (p.click(id)) if (p.host.activate) |f| f(p.host.ctx, id);
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
    o.internal(Slot).* = .{ .kind = slot_tokens, .id = id };
    return o.asValue();
}

fn thisTokens(vm: *Vm, this: Value) Error!NodeId {
    if (this.isObject()) {
        const o = Vm.asObject(this);
        if (o.class == .dom and o.internal(Slot).kind == slot_tokens) return o.internal(Slot).id;
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
    try p.doc.setAttr(id, "class", out.items);
    p.touch();
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
    try p.doc.setAttr(id, "class", try docStr(vm, arg(args, 0)));
    p.touch();
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
    const id = p.nodeOfValue(arg(args, 0)) orelse return vm.throwTypeError("getComputedStyle needs an element");
    if (p.doc.get(id).kind != .element) return vm.throwTypeError("getComputedStyle needs an element");
    const o = try vm.objects.create(p.protos[I.style].asValue(), .dom, @sizeOf(Slot));
    o.internal(Slot).* = .{ .kind = slot_style, .id = id, .flags = style_computed };
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
fn hostLoad(vm: *Vm, referrer: ?[]const u8, specifier: []const u8) Error!?js.module.Loaded {
    const p = pageOf(vm);
    const relative = std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../") or std.mem.startsWith(u8, specifier, "/");
    const absolute = std.mem.indexOf(u8, specifier, "://") != null;
    if (!relative and !absolute) return null;
    var scratch = std.heap.ArenaAllocator.init(p.a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const base = url.parse(sa, referrer orelse p.url, null) catch null;
    const u = url.parse(sa, specifier, if (base) |*b| b else null) catch return null;
    // The canonical name has no fragment: one module per resource.
    const abs = u.serialize(sa, true) catch return null;
    const fetch = p.host.fetch orelse return null;
    const text = fetch(p.host.ctx, abs) orelse return null;
    return .{ .name = try vm.meta.dupe(u8, abs), .source = try vm.meta.dupe(u8, text) };
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
    return nodeList(vm, ids.items);
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
    if (!p.fireSubmit(id)) return Value.undefined_;
    if (p.host.submit) |f| f(p.host.ctx, id);
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
    o.internal(Slot).* = .{ .kind = slot_style, .id = id, .flags = 0 };
    _ = try vm.objects.defineOwn(w, .{ .symbol = p.sym_style }, o.asValue(), .hidden);
    return o.asValue();
}

const StyleRef = struct { id: NodeId, computed: bool };

fn thisStyle(vm: *Vm, this: Value) Error!StyleRef {
    if (this.isObject()) {
        const o = Vm.asObject(this);
        if (o.class == .dom and o.internal(Slot).kind == slot_style) return .{ .id = o.internal(Slot).id, .computed = o.internal(Slot).flags & style_computed != 0 };
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
    if (out.items.len == 0) p.doc.removeAttr(id, "style") else try p.doc.setAttr(id, "style", out.items);
    p.touch();
}

fn stylePropertyGet(vm: *Vm, this: Value, name: []const u8) Error!Value {
    const p = pageOf(vm);
    const ref = try thisStyle(vm, this);
    var sc = Scratch.init(vm);
    defer sc.deinit();
    if (ref.computed) {
        if (p.host.computed) |f| {
            var buf: [256]u8 = undefined;
            if (f(p.host.ctx, ref.id, name, &buf)) |text| return jsStr(vm, text);
        }
    }
    const decls = try declarationsOf(p, ref.id, sc.a());
    for (decls) |d| if (std.mem.eql(u8, d.name, name)) return jsStr(vm, d.value);
    return jsStr(vm, "");
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
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) p.doc.removeAttr(ref.id, "style") else try p.doc.setAttr(ref.id, "style", text);
    p.touch();
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

/// An event handler IDL attribute (`onload`) called, then the event fired.
fn xhrHandler(vm: *Vm, o: *Object, attr: []const u8, event_name: []const u8) Error!void {
    const p = pageOf(vm);
    const h = try vm.get(o, .{ .atom = try vm.atom(attr) }, o.asValue());
    const ev = try p.newEvent(I.event, event_name, false, false, true);
    if (vm.isCallable(h)) {
        try p.setEventProp(ev, "target", o.asValue());
        try p.setEventProp(ev, "currentTarget", o.asValue());
        _ = vm.call(h, o.asValue(), &.{ev.asValue()}) catch |e| p.reportError(e, attr);
    }
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
    fn log(ctx: *anyopaque, level: Level, text: []const u8) void {
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        h.lines.appendSlice(h.a, @tagName(level)) catch {};
        h.lines.append(h.a, ':') catch {};
        h.lines.appendSlice(h.a, text) catch {};
        h.lines.append(h.a, '\n') catch {};
    }
    /// Every element is a 100×20 box at (8, 8 + 30·id).
    fn rect(_: *anyopaque, id: NodeId) ?[4]f64 {
        return .{ 8, 8 + 30 * @as(f64, @floatFromInt(id)), 100, 20 };
    }
    fn computed(_: *anyopaque, _: NodeId, name: []const u8, buf: []u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "display")) return std.fmt.bufPrint(buf, "block", .{}) catch null;
        if (std.mem.eql(u8, name, "color")) return std.fmt.bufPrint(buf, "rgb(0, 0, 0)", .{}) catch null;
        return null;
    }
    fn scroll(ctx: *anyopaque, x: f64, y: f64) void {
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        h.scrolled_to = .{ x, y };
    }
    fn fetch(_: *anyopaque, abs_url: []const u8) ?[]const u8 {
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
    fn request(_: *anyopaque, a: std.mem.Allocator, abs_url: []const u8, post: bool, body: []const u8, origin: []const u8, out: *Response) bool {
        out.url = abs_url;
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
        try tp.page.init(tp.vm, tp.doc, ta, .{ .ctx = tp.host, .log = TestHost.log, .rect = TestHost.rect, .computed = TestHost.computed, .scroll = TestHost.scroll, .request = TestHost.request, .fetch = TestHost.fetch, .navigate = TestHost.navigate, .changed = TestHost.changed, .submit = TestHost.submit, .activate = TestHost.activate, .storage = TestHost.storage });
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
        \\log:blue|rgb(1, 2, 3)|rgb(1, 2, 3)|2|background-color|true|color: red; background-color: rgb(1, 2, 3); margin-top: 4px !important; float: left;|important|color: red; background-color: rgb(1, 2, 3); margin-top: 4px !important; float: left;|red||3|false|<p id="q" style="display: none;">y</p>|block|rgb(0, 0, 0)|block||8|188|100|20|108|208|100|20|188|1|true
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
