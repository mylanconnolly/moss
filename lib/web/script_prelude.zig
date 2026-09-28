//! The web platform's smaller APIs, written in the language they serve:
//! a prelude the bindings run at a page's start, after the interfaces
//! the table installs. Each is defined only when the table did not
//! define it, so a native version can take over any of them. What is
//! here answers what real sites' scripts reached for first
//! (2026-09-28): `URL` and `URLSearchParams` over the native parser,
//! `performance`, base64, text encoding, `Headers`/`Request`/
//! `Response`, `AbortController`, `Blob`/`File`/`FormData`,
//! `DOMParser`, the observers (an intersection observer reports every
//! target visible once, so lazy pictures load; a resize observer
//! reports the box once), `crypto`, a `WebSocket` and a `Worker` that
//! never come up, `Image`/`Audio`/`Option`, `CSS`, `screen`, the
//! navigator's and the document's remaining members (`cookie` as an
//! in-memory jar, `currentScript`, `fonts`), `Element.animate`, and
//! an `Intl` that formats plainly.
const std = @import("std");

pub const source =
    \\(function () {
    \\  var g = window;
    \\  var def = function (o, k, v) { Object.defineProperty(o, k, { value: v, writable: true, configurable: true, enumerable: false }); };
    \\  var miss = function (k) { return typeof g[k] === 'undefined'; };
    \\  // performance: a monotonic clock from the page's start.
    \\  if (miss('performance')) {
    \\    var t0 = __perfNow();
    \\    var perf = { timeOrigin: t0, now: function () { return __perfNow() - t0; }, mark: function () {}, measure: function () {}, clearMarks: function () {}, clearMeasures: function () {}, clearResourceTimings: function () {}, setResourceTimingBufferSize: function () {}, getEntries: function () { return []; }, getEntriesByType: function () { return []; }, getEntriesByName: function () { return []; }, timing: { navigationStart: t0, domLoading: t0, domInteractive: t0, domContentLoadedEventStart: t0, domContentLoadedEventEnd: t0, domComplete: t0, loadEventStart: t0, loadEventEnd: t0, responseStart: t0, responseEnd: t0, fetchStart: t0, requestStart: t0 }, navigation: { type: 0, redirectCount: 0 }, addEventListener: function () {}, removeEventListener: function () {}, toJSON: function () { return {}; } };
    \\    def(g, 'performance', perf);
    \\  }
    \\  // URL and URLSearchParams over the native parser.
    \\  if (miss('URLSearchParams')) {
    \\    var dec = function (s) { try { return decodeURIComponent(s.replace(/\+/g, ' ')); } catch (e) { return s; } };
    \\    var enc = function (s) { return encodeURIComponent(s).replace(/%20/g, '+'); };
    \\    var USP = function URLSearchParams(init) {
    \\      this._l = []; this._url = null;
    \\      if (init instanceof USP) this._l = init._l.map(function (e) { return [e[0], e[1]]; });
    \\      else if (typeof init === 'string') { if (init[0] === '?') init = init.slice(1); if (init) init.split('&').forEach(function (p) { if (!p) return; var i = p.indexOf('='); this._l.push([dec(i < 0 ? p : p.slice(0, i)), i < 0 ? '' : dec(p.slice(i + 1))]); }, this); }
    \\      else if (init && typeof init === 'object') { if (typeof init[Symbol.iterator] === 'function') { for (var e of init) this._l.push([String(e[0]), String(e[1])]); } else { for (var k in init) this._l.push([k, String(init[k])]); } }
    \\    };
    \\    USP.prototype = {
    \\      constructor: USP,
    \\      append: function (k, v) { this._l.push([String(k), String(v)]); this._u(); },
    \\      'delete': function (k, v) { k = String(k); this._l = this._l.filter(function (e) { return e[0] !== k || (v !== undefined && e[1] !== String(v)); }); this._u(); },
    \\      get: function (k) { k = String(k); for (var i = 0; i < this._l.length; i++) if (this._l[i][0] === k) return this._l[i][1]; return null; },
    \\      getAll: function (k) { k = String(k); return this._l.filter(function (e) { return e[0] === k; }).map(function (e) { return e[1]; }); },
    \\      has: function (k, v) { k = String(k); return this._l.some(function (e) { return e[0] === k && (v === undefined || e[1] === String(v)); }); },
    \\      set: function (k, v) { k = String(k); v = String(v); var i = -1; for (var j = 0; j < this._l.length; j++) if (this._l[j][0] === k) { i = j; break; } if (i < 0) this._l.push([k, v]); else { this._l[i][1] = v; this._l = this._l.filter(function (e, j) { return j <= i || e[0] !== k; }); } this._u(); },
    \\      sort: function () { this._l.sort(function (a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0; }); this._u(); },
    \\      forEach: function (f, t) { this._l.forEach(function (e) { f.call(t, e[1], e[0], this); }, this); },
    \\      keys: function () { return this._l.map(function (e) { return e[0]; })[Symbol.iterator](); },
    \\      values: function () { return this._l.map(function (e) { return e[1]; })[Symbol.iterator](); },
    \\      entries: function () { return this._l.map(function (e) { return [e[0], e[1]]; })[Symbol.iterator](); },
    \\      toString: function () { return this._l.map(function (e) { return enc(e[0]) + '=' + enc(e[1]); }).join('&'); },
    \\      _u: function () { if (this._url) this._url._setSearch(this.toString()); }
    \\    };
    \\    Object.defineProperty(USP.prototype, 'size', { get: function () { return this._l.length; } });
    \\    USP.prototype[Symbol.iterator] = USP.prototype.entries;
    \\    Object.defineProperty(USP.prototype, Symbol.toStringTag, { value: 'URLSearchParams' });
    \\    def(g, 'URLSearchParams', USP);
    \\    var URLC = function URL(input, base) {
    \\      var c = __urlParse(String(input), base === undefined ? undefined : String(base));
    \\      if (!c) throw new TypeError("Failed to construct 'URL': Invalid URL: " + input);
    \\      this._c = c; this._sp = null;
    \\    };
    \\    var parts = ['href', 'protocol', 'username', 'password', 'host', 'hostname', 'port', 'pathname', 'search', 'hash', 'origin'];
    \\    URLC.prototype._rebuild = function (patch) {
    \\      var c = Object.assign({}, this._c, patch);
    \\      if (patch.hostname !== undefined || patch.port !== undefined) c.host = c.hostname + (c.port ? ':' + c.port : '');
    \\      if (patch.host !== undefined) { var i = c.host.lastIndexOf(':'); c.hostname = i < 0 ? c.host : c.host.slice(0, i); c.port = i < 0 ? '' : c.host.slice(i + 1); }
    \\      if (c.search && c.search[0] !== '?') c.search = '?' + c.search;
    \\      if (c.hash && c.hash[0] !== '#') c.hash = '#' + c.hash;
    \\      if (c.pathname && c.pathname[0] !== '/' && c.host) c.pathname = '/' + c.pathname;
    \\      if (c.protocol && c.protocol[c.protocol.length - 1] !== ':') c.protocol = c.protocol + ':';
    \\      var auth = c.username ? c.username + (c.password ? ':' + c.password : '') + '@' : '';
    \\      var href = c.protocol + (c.host || c.protocol === 'file:' ? '//' + auth + c.host : '') + c.pathname + c.search + c.hash;
    \\      var n = __urlParse(href, undefined);
    \\      if (n) this._c = n;
    \\    };
    \\    parts.forEach(function (k) {
    \\      Object.defineProperty(URLC.prototype, k, { enumerable: true, configurable: true, get: function () { return this._c[k]; }, set: function (v) { if (k === 'origin') return; var patch = {}; patch[k] = String(v); if (k === 'href') { var n = __urlParse(String(v), undefined); if (!n) throw new TypeError('Invalid URL'); this._c = n; this._sp = null; return; } this._rebuild(patch); if (k === 'search' && this._sp) { this._sp._url = null; this._sp = null; } } });
    \\    });
    \\    Object.defineProperty(URLC.prototype, 'searchParams', { get: function () { if (!this._sp) { this._sp = new USP(this._c.search); this._sp._url = this; } return this._sp; } });
    \\    URLC.prototype._setSearch = function (q) { this._rebuild({ search: q ? '?' + q : '' }); };
    \\    URLC.prototype.toString = function () { return this._c.href; };
    \\    URLC.prototype.toJSON = function () { return this._c.href; };
    \\    Object.defineProperty(URLC.prototype, Symbol.toStringTag, { value: 'URL' });
    \\    URLC.canParse = function (u, b) { return !!__urlParse(String(u), b === undefined ? undefined : String(b)); };
    \\    URLC.parse = function (u, b) { try { return new URLC(u, b); } catch (e) { return null; } };
    \\    var blobs = 0;
    \\    URLC.createObjectURL = function () { return 'blob:' + location.origin + '/' + (++blobs); };
    \\    URLC.revokeObjectURL = function () {};
    \\    def(g, 'URL', URLC);
    \\    def(g, 'webkitURL', URLC);
    \\  }
    \\  // base64
    \\  if (miss('btoa')) {
    \\    var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    \\    def(g, 'btoa', function (s) { s = String(s); var out = ''; for (var i = 0; i < s.length; i += 3) { var a = s.charCodeAt(i), b = s.charCodeAt(i + 1), c = s.charCodeAt(i + 2); if (a > 255 || b > 255 || c > 255) throw new Error('InvalidCharacterError'); var n = (a << 16) | ((b || 0) << 8) | (c || 0); out += B64[n >> 18] + B64[(n >> 12) & 63] + (isNaN(b) ? '=' : B64[(n >> 6) & 63]) + (isNaN(c) ? '=' : B64[n & 63]); } return out; });
    \\    def(g, 'atob', function (s) { s = String(s).replace(/[\s=]/g, ''); var out = '', bits = 0, acc = 0; for (var i = 0; i < s.length; i++) { var v = B64.indexOf(s[i]); if (v < 0) throw new Error('InvalidCharacterError'); acc = (acc << 6) | v; bits += 6; if (bits >= 8) { bits -= 8; out += String.fromCharCode((acc >> bits) & 255); } } return out; });
    \\  }
    \\  // text encoding (UTF-8)
    \\  if (miss('TextEncoder')) {
    \\    var TE = function TextEncoder() { this.encoding = 'utf-8'; };
    \\    TE.prototype.encode = function (s) { s = String(s === undefined ? '' : s); var out = []; for (var i = 0; i < s.length; i++) { var c = s.charCodeAt(i); if (c >= 0xd800 && c < 0xdc00 && i + 1 < s.length) { var d = s.charCodeAt(i + 1); if (d >= 0xdc00 && d < 0xe000) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); i++; } } if (c < 0x80) out.push(c); else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63)); else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63)); else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63)); } return new Uint8Array(out); };
    \\    TE.prototype.encodeInto = function (s, a) { var b = this.encode(s); var n = Math.min(b.length, a.length); a.set(b.subarray(0, n)); return { read: s.length, written: n }; };
    \\    var TD = function TextDecoder(label, opts) { this.encoding = (label || 'utf-8').toLowerCase(); this.fatal = !!(opts && opts.fatal); this.ignoreBOM = !!(opts && opts.ignoreBOM); };
    \\    TD.prototype.decode = function (buf) { if (buf === undefined) return ''; var b = buf instanceof ArrayBuffer ? new Uint8Array(buf) : (buf.buffer ? new Uint8Array(buf.buffer, buf.byteOffset || 0, buf.byteLength) : new Uint8Array(buf)); var out = '', i = 0; if (!this.ignoreBOM && b.length >= 3 && b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf) i = 3; while (i < b.length) { var c = b[i++]; if (c < 0x80) out += String.fromCharCode(c); else if (c < 0xe0) out += String.fromCharCode(((c & 31) << 6) | (b[i++] & 63)); else if (c < 0xf0) { out += String.fromCharCode(((c & 15) << 12) | ((b[i++] & 63) << 6) | (b[i++] & 63)); } else { var cp = ((c & 7) << 18) | ((b[i++] & 63) << 12) | ((b[i++] & 63) << 6) | (b[i++] & 63); out += String.fromCodePoint(cp); } } return out; };
    \\    def(g, 'TextEncoder', TE); def(g, 'TextDecoder', TD);
    \\  }
    \\  // custom elements: a registry that remembers definitions.
    \\  if (miss('customElements')) {
    \\    var reg = {}, waits = {};
    \\    def(g, 'customElements', { define: function (n, c) { if (reg[n]) throw new Error("NotSupportedError: '" + n + "' has already been defined"); reg[n] = c; if (waits[n]) { waits[n].forEach(function (r) { r(c); }); delete waits[n]; } }, get: function (n) { return reg[n]; }, getName: function (c) { for (var k in reg) if (reg[k] === c) return k; return null; }, whenDefined: function (n) { if (reg[n]) return Promise.resolve(reg[n]); return new Promise(function (r) { (waits[n] = waits[n] || []).push(r); }); }, upgrade: function () {} });
    \\  }
    \\  // Headers, Request, Response for scripts that build them.
    \\  if (miss('Headers')) {
    \\    var H = function Headers(init) { this._m = []; if (init instanceof H) init._m.forEach(function (e) { this.append(e[0], e[1]); }, this); else if (Array.isArray(init)) init.forEach(function (e) { this.append(e[0], e[1]); }, this); else if (init && typeof init === 'object') for (var k in init) this.append(k, init[k]); };
    \\    H.prototype = { constructor: H, append: function (k, v) { k = String(k).toLowerCase(); v = String(v).trim(); for (var i = 0; i < this._m.length; i++) if (this._m[i][0] === k) { this._m[i][1] += ', ' + v; return; } this._m.push([k, v]); }, set: function (k, v) { this['delete'](k); this._m.push([String(k).toLowerCase(), String(v).trim()]); }, get: function (k) { k = String(k).toLowerCase(); for (var i = 0; i < this._m.length; i++) if (this._m[i][0] === k) return this._m[i][1]; return null; }, has: function (k) { return this.get(k) !== null; }, 'delete': function (k) { k = String(k).toLowerCase(); this._m = this._m.filter(function (e) { return e[0] !== k; }); }, forEach: function (f, t) { this._m.forEach(function (e) { f.call(t, e[1], e[0], this); }, this); }, keys: function () { return this._m.map(function (e) { return e[0]; })[Symbol.iterator](); }, values: function () { return this._m.map(function (e) { return e[1]; })[Symbol.iterator](); }, entries: function () { return this._m.map(function (e) { return [e[0], e[1]]; })[Symbol.iterator](); }, getSetCookie: function () { return []; } };
    \\    H.prototype[Symbol.iterator] = H.prototype.entries;
    \\    def(g, 'Headers', H);
    \\    var Rq = function Request(input, init) { init = init || {}; this.url = input instanceof Rq ? input.url : String(input); this.method = (init.method || (input instanceof Rq ? input.method : 'GET')).toUpperCase(); this.headers = new H(init.headers || (input instanceof Rq ? input.headers : undefined)); this.body = init.body === undefined ? null : init.body; this.credentials = init.credentials || 'same-origin'; this.mode = init.mode || 'cors'; this.signal = init.signal || null; this.cache = init.cache || 'default'; this.redirect = init.redirect || 'follow'; this.referrer = 'about:client'; this.bodyUsed = false; };
    \\    Rq.prototype.clone = function () { return new Rq(this); };
    \\    Rq.prototype.text = function () { return Promise.resolve(this.body === null ? '' : String(this.body)); };
    \\    Rq.prototype.json = function () { return this.text().then(JSON.parse); };
    \\    def(g, 'Request', Rq);
    \\    var Rs = function Response(body, init) { init = init || {}; this._b = body === undefined || body === null ? '' : body; this.status = init.status === undefined ? 200 : init.status; this.ok = this.status >= 200 && this.status < 300; this.statusText = init.statusText || ''; this.headers = new H(init.headers); this.type = 'default'; this.url = ''; this.redirected = false; this.bodyUsed = false; this.body = null; };
    \\    Rs.prototype.text = function () { this.bodyUsed = true; var b = this._b; return Promise.resolve(typeof b === 'string' ? b : (b && typeof b.text === 'function') ? b.text() : String(b)); };
    \\    Rs.prototype.json = function () { return this.text().then(function (t) { return JSON.parse(t); }); };
    \\    Rs.prototype.arrayBuffer = function () { return this.text().then(function (t) { return new TextEncoder().encode(t).buffer; }); };
    \\    Rs.prototype.blob = function () { return this.text().then(function (t) { return new Blob([t]); }); };
    \\    Rs.prototype.clone = function () { return new Rs(this._b, { status: this.status, statusText: this.statusText, headers: this.headers }); };
    \\    Rs.error = function () { var r = new Rs(null, { status: 0 }); r.type = 'error'; return r; };
    \\    Rs.json = function (d, init) { return new Rs(JSON.stringify(d), init); };
    \\    Rs.redirect = function (u, s) { return new Rs(null, { status: s || 302, headers: { location: String(u) } }); };
    \\    def(g, 'Response', Rs);
    \\  }
    \\  if (miss('AbortController')) {
    \\    var AS = function AbortSignal() { this.aborted = false; this.reason = undefined; this.onabort = null; this._l = []; };
    \\    AS.prototype = { constructor: AS, addEventListener: function (t, f) { if (t === 'abort') this._l.push(f); }, removeEventListener: function (t, f) { this._l = this._l.filter(function (x) { return x !== f; }); }, dispatchEvent: function () { return true; }, throwIfAborted: function () { if (this.aborted) throw this.reason; } };
    \\    AS.abort = function (r) { var s = new AS(); s.aborted = true; s.reason = r; return s; };
    \\    AS.timeout = function (ms) { var s = new AS(); setTimeout(function () { s._fire(new Error('TimeoutError')); }, ms); return s; };
    \\    AS.prototype._fire = function (r) { if (this.aborted) return; this.aborted = true; this.reason = r === undefined ? new Error('AbortError') : r; var ev = { type: 'abort', target: this }; if (this.onabort) this.onabort(ev); this._l.forEach(function (f) { f.call(this, ev); }, this); };
    \\    var AC = function AbortController() { this.signal = new AS(); };
    \\    AC.prototype.abort = function (r) { this.signal._fire(r); };
    \\    def(g, 'AbortSignal', AS); def(g, 'AbortController', AC);
    \\  }
    \\  if (miss('Blob')) {
    \\    var Bl = function Blob(parts, opts) { this._p = (parts || []).map(function (p) { return typeof p === 'string' ? p : (p instanceof Bl ? p._p.join('') : (p && p.buffer ? new TextDecoder().decode(p) : String(p))); }).join(''); this.size = new TextEncoder().encode(this._p).length; this.type = (opts && opts.type) || ''; };
    \\    Bl.prototype.text = function () { return Promise.resolve(this._p); };
    \\    Bl.prototype.arrayBuffer = function () { return Promise.resolve(new TextEncoder().encode(this._p).buffer); };
    \\    Bl.prototype.slice = function (a, b, t) { return new Bl([this._p.slice(a, b)], { type: t }); };
    \\    Bl.prototype.stream = function () { throw new Error('streams are not built'); };
    \\    def(g, 'Blob', Bl);
    \\    var Fl = function File(parts, name, opts) { Bl.call(this, parts, opts); this.name = String(name); this.lastModified = Date.now(); };
    \\    Fl.prototype = Object.create(Bl.prototype); Fl.prototype.constructor = Fl;
    \\    def(g, 'File', Fl);
    \\  }
    \\  if (miss('FormData')) {
    \\    var FD = function FormData(form) { this._l = []; if (form && form.elements) for (var i = 0; i < form.elements.length; i++) { var el = form.elements[i]; if (el.name && !el.disabled && (el.type !== 'checkbox' && el.type !== 'radio' || el.checked)) this._l.push([el.name, el.value]); } };
    \\    FD.prototype = { constructor: FD, append: function (k, v) { this._l.push([String(k), v]); }, set: function (k, v) { this['delete'](k); this.append(k, v); }, get: function (k) { for (var i = 0; i < this._l.length; i++) if (this._l[i][0] === k) return this._l[i][1]; return null; }, getAll: function (k) { return this._l.filter(function (e) { return e[0] === k; }).map(function (e) { return e[1]; }); }, has: function (k) { return this.get(k) !== null; }, 'delete': function (k) { this._l = this._l.filter(function (e) { return e[0] !== k; }); }, forEach: function (f, t) { this._l.forEach(function (e) { f.call(t, e[1], e[0], this); }, this); }, keys: function () { return this._l.map(function (e) { return e[0]; })[Symbol.iterator](); }, values: function () { return this._l.map(function (e) { return e[1]; })[Symbol.iterator](); }, entries: function () { return this._l.map(function (e) { return [e[0], e[1]]; })[Symbol.iterator](); } };
    \\    FD.prototype[Symbol.iterator] = FD.prototype.entries;
    \\    def(g, 'FormData', FD);
    \\  }
    \\  if (miss('DOMParser')) {
    \\    var DP = function DOMParser() {};
    \\    DP.prototype.parseFromString = function (s, type) { var d = document.implementation.createHTMLDocument(''); if (type && type.indexOf('xml') >= 0) { var r = d.createElement('div'); r.innerHTML = s; return d; } d.documentElement.innerHTML = s; return d; };
    \\    def(g, 'DOMParser', DP);
    \\  }
    \\  if (miss('structuredClone')) def(g, 'structuredClone', function (v) { return v === undefined ? undefined : JSON.parse(JSON.stringify(v)); });
    \\  if (miss('requestIdleCallback')) {
    \\    def(g, 'requestIdleCallback', function (cb, o) { return setTimeout(function () { cb({ didTimeout: false, timeRemaining: function () { return 50; } }); }, (o && o.timeout) ? Math.min(o.timeout, 1) : 1); });
    \\    def(g, 'cancelIdleCallback', function (id) { clearTimeout(id); });
    \\  }
    \\  // Observers: an intersection observer reports everything visible once
    \\  // (lazy pictures load), a resize observer reports the box once.
    \\  if (miss('IntersectionObserver')) {
    \\    var IO = function IntersectionObserver(cb, o) { this._cb = cb; this.root = (o && o.root) || null; this.rootMargin = (o && o.rootMargin) || '0px'; this.thresholds = [0]; this._t = []; };
    \\    IO.prototype = { constructor: IO, observe: function (el) { if (this._t.indexOf(el) >= 0) return; this._t.push(el); var s = this; setTimeout(function () { if (s._t.indexOf(el) < 0) return; var r = el.getBoundingClientRect(); s._cb([{ target: el, isIntersecting: true, intersectionRatio: 1, time: performance.now(), boundingClientRect: r, intersectionRect: r, rootBounds: null }], s); }, 0); }, unobserve: function (el) { this._t = this._t.filter(function (x) { return x !== el; }); }, disconnect: function () { this._t = []; }, takeRecords: function () { return []; } };
    \\    def(g, 'IntersectionObserver', IO);
    \\    def(g, 'IntersectionObserverEntry', function () {});
    \\  }
    \\  if (miss('ResizeObserver')) {
    \\    var RO = function ResizeObserver(cb) { this._cb = cb; this._t = []; };
    \\    RO.prototype = { constructor: RO, observe: function (el) { if (this._t.indexOf(el) >= 0) return; this._t.push(el); var s = this; setTimeout(function () { if (s._t.indexOf(el) < 0) return; var r = el.getBoundingClientRect(); var sz = [{ inlineSize: r.width, blockSize: r.height }]; s._cb([{ target: el, contentRect: r, borderBoxSize: sz, contentBoxSize: sz, devicePixelContentBoxSize: sz }], s); }, 0); }, unobserve: function (el) { this._t = this._t.filter(function (x) { return x !== el; }); }, disconnect: function () { this._t = []; } };
    \\    def(g, 'ResizeObserver', RO);
    \\  }
    \\  if (miss('PerformanceObserver')) { var PO = function PerformanceObserver() {}; PO.prototype = { observe: function () {}, disconnect: function () {}, takeRecords: function () { return []; } }; PO.supportedEntryTypes = []; def(g, 'PerformanceObserver', PO); }
    \\  if (miss('ReportingObserver')) { var RpO = function ReportingObserver() {}; RpO.prototype = { observe: function () {}, disconnect: function () {}, takeRecords: function () { return []; } }; def(g, 'ReportingObserver', RpO); }
    \\  if (miss('crypto')) {
    \\    def(g, 'crypto', { getRandomValues: function (a) { for (var i = 0; i < a.length; i++) a[i] = Math.floor(Math.random() * 4294967296); return a; }, randomUUID: function () { var h = '0123456789abcdef', s = ''; for (var i = 0; i < 36; i++) s += (i === 8 || i === 13 || i === 18 || i === 23) ? '-' : i === 14 ? '4' : i === 19 ? h[8 + Math.floor(Math.random() * 4)] : h[Math.floor(Math.random() * 16)]; return s; }, subtle: { digest: function () { return Promise.reject(new Error('NotSupportedError')); } } });
    \\  }
    \\  // A socket or worker that never comes up: the page goes on without.
    \\  if (miss('WebSocket')) {
    \\    var WS = function WebSocket(url) { this.url = String(url); this.readyState = 0; this.onopen = this.onclose = this.onerror = this.onmessage = null; this._l = {}; var s = this; setTimeout(function () { s.readyState = 3; var ev = { type: 'error', target: s }; if (s.onerror) s.onerror(ev); (s._l.error || []).forEach(function (f) { f(ev); }); ev = { type: 'close', code: 1006, reason: '', wasClean: false, target: s }; if (s.onclose) s.onclose(ev); (s._l.close || []).forEach(function (f) { f(ev); }); }, 0); };
    \\    WS.prototype = { constructor: WS, send: function () {}, close: function () { this.readyState = 3; }, addEventListener: function (t, f) { (this._l[t] = this._l[t] || []).push(f); }, removeEventListener: function (t, f) { if (this._l[t]) this._l[t] = this._l[t].filter(function (x) { return x !== f; }); }, dispatchEvent: function () { return true; } };
    \\    WS.CONNECTING = 0; WS.OPEN = 1; WS.CLOSING = 2; WS.CLOSED = 3;
    \\    def(g, 'WebSocket', WS);
    \\  }
    \\  if (miss('Worker')) { var Wk = function Worker() { this.onmessage = this.onerror = null; }; Wk.prototype = { postMessage: function () {}, terminate: function () {}, addEventListener: function () {}, removeEventListener: function () {} }; def(g, 'Worker', Wk); def(g, 'SharedWorker', Wk); }
    \\  if (miss('BroadcastChannel')) { var BC = function BroadcastChannel(n) { this.name = n; this.onmessage = null; }; BC.prototype = { postMessage: function () {}, close: function () {}, addEventListener: function () {}, removeEventListener: function () {} }; def(g, 'BroadcastChannel', BC); }
    \\  if (miss('MessageChannel')) { var MP = function MessagePort() { this.onmessage = null; }; MP.prototype = { postMessage: function () {}, start: function () {}, close: function () {}, addEventListener: function () {}, removeEventListener: function () {} }; def(g, 'MessageChannel', function MessageChannel() { this.port1 = new MP(); this.port2 = new MP(); }); }
    \\  if (miss('Notification')) { var Nt = function Notification() {}; Nt.permission = 'denied'; Nt.requestPermission = function () { return Promise.resolve('denied'); }; def(g, 'Notification', Nt); }
    \\  if (miss('Image')) def(g, 'Image', function Image(w, h) { var i = document.createElement('img'); if (w !== undefined) i.width = w; if (h !== undefined) i.height = h; return i; });
    \\  if (miss('Audio')) def(g, 'Audio', function Audio(src) { var a = document.createElement('audio'); if (src !== undefined) a.src = src; return a; });
    \\  if (miss('Option')) def(g, 'Option', function Option(text, value, defaultSelected, selected) { var o = document.createElement('option'); if (text !== undefined) o.text = text; if (value !== undefined) o.value = value; if (defaultSelected) o.defaultSelected = true; if (selected) o.selected = true; return o; });
    \\  if (miss('CSS')) def(g, 'CSS', { supports: function () { return false; }, escape: function (s) { return String(s).replace(/([^\w-])/g, '\\$1'); }, px: function (v) { return v + 'px'; } });
    \\  // The viewport is set after this runs: the screen reads it when asked.
    \\  var vw = function () { return g.innerWidth || 1024; }, vh = function () { return g.innerHeight || 768; };
    \\  if (miss('screen')) { var scr = { availLeft: 0, availTop: 0, colorDepth: 24, pixelDepth: 24, orientation: { angle: 0, addEventListener: function () {}, removeEventListener: function () {} } }; Object.defineProperties(scr, { width: { get: vw }, height: { get: vh }, availWidth: { get: vw }, availHeight: { get: vh } }); Object.defineProperty(scr.orientation, 'type', { get: function () { return vw() >= vh() ? 'landscape-primary' : 'portrait-primary'; } }); def(g, 'screen', scr); }
    \\  if (miss('getSelection')) def(g, 'getSelection', function () { return { rangeCount: 0, type: 'None', anchorNode: null, focusNode: null, isCollapsed: true, toString: function () { return ''; }, removeAllRanges: function () {}, addRange: function () {}, getRangeAt: function () { throw new Error('IndexSizeError'); } }; });
    \\  if (miss('print')) def(g, 'print', function () {});
    \\  if (miss('stop')) def(g, 'stop', function () {});
    \\  if (miss('name')) g.name = '';
    \\  if (miss('status')) g.status = '';
    \\  if (miss('origin')) def(g, 'origin', location.origin);
    \\  if (miss('isSecureContext')) def(g, 'isSecureContext', location.protocol === 'https:');
    \\  if (miss('crossOriginIsolated')) def(g, 'crossOriginIsolated', false);
    \\  if (miss('visualViewport')) { var vv = { offsetLeft: 0, offsetTop: 0, pageLeft: 0, pageTop: 0, scale: 1, addEventListener: function () {}, removeEventListener: function () {} }; Object.defineProperties(vv, { width: { get: vw }, height: { get: vh } }); def(g, 'visualViewport', vv); }
    \\  if (miss('speechSynthesis')) def(g, 'speechSynthesis', { speak: function () {}, cancel: function () {}, getVoices: function () { return []; }, addEventListener: function () {} });
    \\  if (miss('scheduler')) def(g, 'scheduler', { postTask: function (f) { return new Promise(function (r) { setTimeout(function () { r(f()); }, 0); }); }, yield: function () { return Promise.resolve(); } });
    \\  // the navigator's remaining members
    \\  var n = navigator;
    \\  var nd = function (k, v) { if (typeof n[k] === 'undefined') def(n, k, v); };
    \\  nd('vendor', ''); nd('vendorSub', ''); nd('product', 'Gecko'); nd('productSub', '20100101'); nd('appName', 'Netscape'); nd('appVersion', '5.0 (moss)'); nd('appCodeName', 'Mozilla');
    \\  nd('hardwareConcurrency', 1); nd('maxTouchPoints', 0); nd('doNotTrack', null); nd('deviceMemory', 1); nd('pdfViewerEnabled', false); nd('webdriver', false);
    \\  nd('plugins', { length: 0, item: function () { return null; }, namedItem: function () { return null; }, refresh: function () {} }); nd('mimeTypes', { length: 0, item: function () { return null; }, namedItem: function () { return null; } });
    \\  nd('sendBeacon', function () { return true; });
    \\  nd('javaEnabled', function () { return false; });
    \\  nd('vibrate', function () { return false; });
    \\  nd('permissions', { query: function () { return Promise.resolve({ state: 'denied', onchange: null, addEventListener: function () {} }); } });
    \\  nd('clipboard', { writeText: function () { return Promise.reject(new Error('NotAllowedError')); }, readText: function () { return Promise.reject(new Error('NotAllowedError')); } });
    \\  nd('mediaDevices', { enumerateDevices: function () { return Promise.resolve([]); }, getUserMedia: function () { return Promise.reject(new Error('NotAllowedError')); } });
    \\  nd('storage', { estimate: function () { return Promise.resolve({ quota: 32768, usage: 0 }); }, persist: function () { return Promise.resolve(false); } });
    \\  nd('locks', { request: function (n, o, f) { return Promise.resolve((typeof o === 'function' ? o : f)({ name: n, mode: 'exclusive' })); } });
    \\  nd('getBattery', function () { return Promise.resolve({ charging: true, level: 1, chargingTime: 0, dischargingTime: Infinity, addEventListener: function () {} }); });
    \\  // the document's remaining members
    \\  var D = Document.prototype;
    \\  var dd = function (k, desc) { if (!(k in D) && !(k in document)) Object.defineProperty(D, k, desc); };
    \\  dd('cookie', { configurable: true, get: function () { var jar = this.__cookies || []; return jar.map(function (c) { return c[0] + '=' + c[1]; }).join('; '); }, set: function (v) { v = String(v); var parts = v.split(';'); var nv = parts[0].trim(); var i = nv.indexOf('='); if (i < 0) return; var name = nv.slice(0, i).trim(), value = nv.slice(i + 1).trim(); var gone = false; for (var j = 1; j < parts.length; j++) { var a = parts[j].trim().toLowerCase(); if (a.indexOf('max-age=') === 0 && parseInt(a.slice(8), 10) <= 0) gone = true; if (a.indexOf('expires=') === 0) { var t = Date.parse(a.slice(8)); if (!isNaN(t) && t < Date.now()) gone = true; } } var jar = this.__cookies || (this.__cookies = []); jar = jar.filter(function (c) { return c[0] !== name; }); if (!gone) jar.push([name, value]); this.__cookies = jar; } });
    \\  dd('currentScript', { configurable: true, get: function () { return __currentScript(); } });
    \\  dd('fonts', { configurable: true, get: function () { return { ready: Promise.resolve(this.fonts), status: 'loaded', size: 0, check: function () { return true; }, load: function () { return Promise.resolve([]); }, add: function () {}, addEventListener: function () {}, removeEventListener: function () {}, forEach: function () {} }; } });
    \\  dd('scrollingElement', { configurable: true, get: function () { return this.documentElement; } });
    \\  dd('timeline', { configurable: true, get: function () { return { currentTime: performance.now() }; } });
    \\  dd('visibilityState', { configurable: true, get: function () { return 'visible'; } });
    \\  dd('hasStorageAccess', { configurable: true, value: function () { return Promise.resolve(true); } });
    \\  dd('requestStorageAccess', { configurable: true, value: function () { return Promise.resolve(); } });
    \\  dd('exitFullscreen', { configurable: true, value: function () { return Promise.resolve(); } });
    \\  dd('elementFromPoint', { configurable: true, value: function () { return null; } });
    \\  dd('elementsFromPoint', { configurable: true, value: function () { return []; } });
    \\  dd('caretPositionFromPoint', { configurable: true, value: function () { return null; } });
    \\  dd('startViewTransition', { configurable: true, value: function (f) { if (f) f(); return { finished: Promise.resolve(), ready: Promise.resolve(), updateCallbackDone: Promise.resolve(), skipTransition: function () {} }; } });
    \\  var E = Element.prototype;
    \\  var ed = function (k, v) { if (!(k in E)) def(E, k, v); };
    \\  ed('animate', function () { var a = { finished: Promise.resolve(), ready: Promise.resolve(), playState: 'finished', currentTime: 0, playbackRate: 1, cancel: function () {}, play: function () {}, pause: function () {}, finish: function () {}, reverse: function () {}, addEventListener: function () {}, removeEventListener: function () {}, oncancel: null, onfinish: null }; return a; });
    \\  ed('getAnimations', function () { return []; });
    \\  ed('requestFullscreen', function () { return Promise.reject(new Error('NotAllowedError')); });
    \\  ed('requestPointerLock', function () {});
    \\  ed('setPointerCapture', function () {});
    \\  ed('releasePointerCapture', function () {});
    \\  ed('hasPointerCapture', function () { return false; });
    \\  ed('attachShadow', function (init) { var host = this; var root = document.createDocumentFragment(); root.host = host; root.mode = (init && init.mode) || 'open'; root.innerHTML = ''; root.adoptedStyleSheets = []; root.getElementById = function (id) { return root.querySelector('#' + id); }; if (root.mode === 'open') def(host, 'shadowRoot', root); return root; });
    \\  ed('checkVisibility', function () { return true; });
    \\  ed('scrollIntoViewIfNeeded', function () { this.scrollIntoView(); });
    \\  var HE = HTMLElement.prototype;
    \\  // dataset: the data-* attributes as a live map, camelCase to kebab.
    \\  if (!('dataset' in HE)) {
    \\    var kebab = function (k) { return String(k).replace(/[A-Z]/g, function (c) { return '-' + c.toLowerCase(); }); };
    \\    var camel = function (n) { return n.replace(/-([a-z])/g, function (m, c) { return c.toUpperCase(); }); };
    \\    var dsKeys = function (el) { return el.getAttributeNames().filter(function (n) { return n.indexOf('data-') === 0; }).map(function (n) { return camel(n.slice(5)); }); };
    \\    Object.defineProperty(HE, 'dataset', { configurable: true, get: function () {
    \\      var el = this;
    \\      if (el.__dataset) return el.__dataset;
    \\      var ds = new Proxy({}, {
    \\        get: function (t, k) { if (typeof k === 'symbol') return undefined; if (k === 'toJSON') return function () { var o = {}; dsKeys(el).forEach(function (n) { o[n] = el.getAttribute('data-' + kebab(n)); }); return o; }; var v = el.getAttribute('data-' + kebab(k)); return v === null ? undefined : v; },
    \\        set: function (t, k, v) { el.setAttribute('data-' + kebab(k), String(v)); return true; },
    \\        has: function (t, k) { return typeof k !== 'symbol' && el.hasAttribute('data-' + kebab(k)); },
    \\        deleteProperty: function (t, k) { el.removeAttribute('data-' + kebab(k)); return true; },
    \\        ownKeys: function () { return dsKeys(el); },
    \\        getOwnPropertyDescriptor: function (t, k) { var v = el.getAttribute('data-' + kebab(k)); return v === null ? undefined : { value: v, writable: true, enumerable: true, configurable: true }; }
    \\      });
    \\      def(el, '__dataset', ds);
    \\      return ds;
    \\    } });
    \\  }
    \\  if (!('dataset' in SVGElement.prototype)) Object.defineProperty(SVGElement.prototype, 'dataset', Object.getOwnPropertyDescriptor(HE, 'dataset'));
    \\  // Collections are arrays here; the names still resolve and match.
    \\  if (miss('NodeList')) { var NL = function NodeList() {}; NL.prototype = Array.prototype; def(g, 'NodeList', NL); }
    \\  if (miss('HTMLCollection')) { var HC = function HTMLCollection() {}; HC.prototype = Array.prototype; def(g, 'HTMLCollection', HC); }
    \\  if (miss('DOMStringMap')) def(g, 'DOMStringMap', function DOMStringMap() {});
    \\  // Element interfaces the table does not name: each an alias of the
    \\  // nearest it does (a button is an input here; the rest HTMLElement),
    \\  // so `instanceof` and `customElements.define(..., { extends })` work.
    \\  var alias = function (name, base) { if (miss(name)) def(g, name, base); };
    \\  ['HTMLButtonElement', 'HTMLSelectElement', 'HTMLTextAreaElement'].forEach(function (n) { alias(n, HTMLInputElement); });
    \\  alias('HTMLAreaElement', HTMLAnchorElement);
    \\  ['HTMLDivElement', 'HTMLSpanElement', 'HTMLParagraphElement', 'HTMLHeadingElement', 'HTMLUListElement', 'HTMLOListElement', 'HTMLLIElement', 'HTMLBodyElement', 'HTMLHeadElement', 'HTMLHtmlElement', 'HTMLLinkElement', 'HTMLStyleElement', 'HTMLTitleElement', 'HTMLBRElement', 'HTMLHRElement', 'HTMLPreElement', 'HTMLQuoteElement', 'HTMLLabelElement', 'HTMLFieldSetElement', 'HTMLLegendElement', 'HTMLDataListElement', 'HTMLOutputElement', 'HTMLProgressElement', 'HTMLMeterElement', 'HTMLDetailsElement', 'HTMLDialogElement', 'HTMLMenuElement', 'HTMLNavElement', 'HTMLIFrameElement', 'HTMLFrameElement', 'HTMLEmbedElement', 'HTMLObjectElement', 'HTMLParamElement', 'HTMLVideoElement', 'HTMLAudioElement', 'HTMLMediaElement', 'HTMLSourceElement', 'HTMLTrackElement', 'HTMLCanvasElement', 'HTMLMapElement', 'HTMLPictureElement', 'HTMLTableCaptionElement', 'HTMLTableColElement', 'HTMLTimeElement', 'HTMLDataElement', 'HTMLSlotElement', 'HTMLModElement', 'HTMLBaseElement', 'HTMLUnknownElement', 'HTMLDListElement', 'HTMLOptGroupElement', 'HTMLMarqueeElement', 'HTMLFontElement', 'HTMLDirectoryElement', 'HTMLFrameSetElement'].forEach(function (n) { alias(n, HTMLElement); });
    \\  ['SVGSVGElement', 'SVGGraphicsElement', 'SVGGElement', 'SVGPathElement', 'SVGCircleElement', 'SVGUseElement', 'SVGImageElement', 'SVGLineElement', 'SVGPolygonElement', 'SVGDefsElement', 'SVGSymbolElement', 'SVGTextElement', 'SVGAnimateElement', 'SVGForeignObjectElement'].forEach(function (n) { alias(n, SVGElement); });
    \\  ['CharacterData', 'ProcessingInstruction', 'CDATASection', 'XMLDocument', 'HTMLDocument'].forEach(function (n) { alias(n, typeof Document !== 'undefined' && n.indexOf('Document') >= 0 ? Document : Node); });
    \\  // A DOMMatrix that carries a 2D transform's six numbers (no geometry
    \\  // is done with it here beyond that).
    \\  if (miss('DOMMatrix')) {
    \\    var DM = function DOMMatrix(init) { var m = [1, 0, 0, 1, 0, 0]; if (typeof init === 'string' && init && init !== 'none') { var mm = init.match(/matrix\(([^)]*)\)/); if (mm) m = mm[1].split(',').map(Number); } else if (Array.isArray(init) && init.length >= 6) m = init.slice(0, 6); this.a = m[0]; this.b = m[1]; this.c = m[2]; this.d = m[3]; this.e = m[4]; this.f = m[5]; this.m11 = this.a; this.m12 = this.b; this.m21 = this.c; this.m22 = this.d; this.m41 = this.e; this.m42 = this.f; this.m13 = 0; this.m14 = 0; this.m23 = 0; this.m24 = 0; this.m31 = 0; this.m32 = 0; this.m33 = 1; this.m34 = 0; this.m43 = 0; this.m44 = 1; this.is2D = true; this.isIdentity = this.a === 1 && this.b === 0 && this.c === 0 && this.d === 1 && this.e === 0 && this.f === 0; };
    \\    DM.prototype = { constructor: DM, translate: function (x, y) { return new DM([this.a, this.b, this.c, this.d, this.e + (x || 0), this.f + (y || 0)]); }, scale: function (x, y) { y = y === undefined ? x : y; return new DM([this.a * x, this.b * x, this.c * y, this.d * y, this.e, this.f]); }, multiply: function (o) { return new DM([this.a * o.a + this.c * o.b, this.b * o.a + this.d * o.b, this.a * o.c + this.c * o.d, this.b * o.c + this.d * o.d, this.a * o.e + this.c * o.f + this.e, this.b * o.e + this.d * o.f + this.f]); }, inverse: function () { var det = this.a * this.d - this.b * this.c; if (!det) return new DM([NaN, NaN, NaN, NaN, NaN, NaN]); return new DM([this.d / det, -this.b / det, -this.c / det, this.a / det, (this.c * this.f - this.d * this.e) / det, (this.b * this.e - this.a * this.f) / det]); }, transformPoint: function (p) { p = p || {}; var x = p.x || 0, y = p.y || 0; return { x: this.a * x + this.c * y + this.e, y: this.b * x + this.d * y + this.f, z: 0, w: 1 }; }, toString: function () { return 'matrix(' + [this.a, this.b, this.c, this.d, this.e, this.f].join(', ') + ')'; }, toJSON: function () { return { a: this.a, b: this.b, c: this.c, d: this.d, e: this.e, f: this.f, is2D: true }; } };
    \\    DM.fromMatrix = function (o) { return new DM(o ? [o.a, o.b, o.c, o.d, o.e, o.f] : undefined); };
    \\    def(g, 'DOMMatrix', DM); def(g, 'DOMMatrixReadOnly', DM); def(g, 'WebKitCSSMatrix', DM);
    \\    def(g, 'DOMPoint', function DOMPoint(x, y, z, w) { this.x = x || 0; this.y = y || 0; this.z = z || 0; this.w = w === undefined ? 1 : w; });
    \\    def(g, 'DOMRect', function DOMRect(x, y, w, h) { this.x = x || 0; this.y = y || 0; this.width = w || 0; this.height = h || 0; this.left = this.x; this.top = this.y; this.right = this.x + this.width; this.bottom = this.y + this.height; });
    \\    def(g, 'DOMRectReadOnly', g.DOMRect);
    \\  }
    \\  var NP = Node.prototype;
    \\  if (!('getRootNode' in NP)) def(NP, 'getRootNode', function () { var n = this; while (n.parentNode) n = n.parentNode; return n; });
    \\  if (!('isConnected' in NP)) Object.defineProperty(NP, 'isConnected', { configurable: true, get: function () { return this.getRootNode() === this.ownerDocument || this === this.ownerDocument; } });
    \\  var EP = Element.prototype;
    \\  if (!('replaceChildren' in EP)) def(EP, 'replaceChildren', function () { while (this.firstChild) this.removeChild(this.firstChild); for (var i = 0; i < arguments.length; i++) this.appendChild(typeof arguments[i] === 'string' ? document.createTextNode(arguments[i]) : arguments[i]); });
    \\  if (!('insertAdjacentHTML' in EP)) def(EP, 'insertAdjacentHTML', function (where, html) { var t = document.createElement('template'); t.innerHTML = html; var frag = t.content || t; var nodes = Array.prototype.slice.call(frag.childNodes); var el = this; where = String(where).toLowerCase(); nodes.forEach(function (n) { if (where === 'beforebegin') el.parentNode.insertBefore(n, el); else if (where === 'afterbegin') el.insertBefore(n, el.firstChild); else if (where === 'beforeend') el.appendChild(n); else if (where === 'afterend') el.parentNode.insertBefore(n, el.nextSibling); }); });
    \\  if (!('insertAdjacentElement' in EP)) def(EP, 'insertAdjacentElement', function (where, n) { where = String(where).toLowerCase(); if (where === 'beforebegin') this.parentNode.insertBefore(n, this); else if (where === 'afterbegin') this.insertBefore(n, this.firstChild); else if (where === 'beforeend') this.appendChild(n); else if (where === 'afterend') this.parentNode.insertBefore(n, this.nextSibling); return n; });
    \\  if (!('insertAdjacentText' in EP)) def(EP, 'insertAdjacentText', function (where, s) { this.insertAdjacentElement(where, document.createTextNode(s)); });
    \\  if (!('inert' in HE)) Object.defineProperty(HE, 'inert', { configurable: true, get: function () { return this.hasAttribute('inert'); }, set: function (v) { if (v) this.setAttribute('inert', ''); else this.removeAttribute('inert'); } });
    \\  if (!('popover' in HE)) { Object.defineProperty(HE, 'popover', { configurable: true, get: function () { return this.getAttribute('popover'); }, set: function (v) { this.setAttribute('popover', v); } }); def(HE, 'showPopover', function () {}); def(HE, 'hidePopover', function () {}); def(HE, 'togglePopover', function () { return false; }); }
    \\  if (miss('reportError')) def(g, 'reportError', function (e) { console.error(String(e)); });
    \\  if (miss('queueMicrotask')) def(g, 'queueMicrotask', function (f) { Promise.resolve().then(f); });
    \\  if (miss('SharedArrayBuffer')) def(g, 'SharedArrayBuffer', ArrayBuffer);
    \\  if (miss('Intl')) def(g, 'Intl', { DateTimeFormat: function () { return { format: function (d) { return String(d); }, resolvedOptions: function () { return { timeZone: 'UTC', locale: 'en' }; }, formatToParts: function () { return []; } }; }, NumberFormat: function () { return { format: function (n) { return String(n); }, resolvedOptions: function () { return { locale: 'en' }; }, formatToParts: function () { return []; } }; }, Collator: function () { return { compare: function (a, b) { return a < b ? -1 : a > b ? 1 : 0; } }; }, PluralRules: function () { return { select: function () { return 'other'; } }; }, RelativeTimeFormat: function () { return { format: function (v, u) { return v + ' ' + u; } }; }, ListFormat: function () { return { format: function (l) { return l.join(', '); } }; }, Segmenter: function () { return { segment: function (s) { return [{ segment: s, index: 0 }]; } }; }, getCanonicalLocales: function (l) { return [].concat(l || []); }, supportedValuesOf: function () { return []; } });
    \\})();
;

test "the prelude is one balanced script" {
    var depth: i32 = 0;
    for (source) |c| {
        if (c == '{') depth += 1;
        if (c == '}') depth -= 1;
    }
    try std.testing.expectEqual(@as(i32, 0), depth);
}
