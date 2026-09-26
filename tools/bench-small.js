// A small workload of the engine's own — calls, objects, a Map, string
// building, array pipelines — timed the same way on the host (this
// file, `zig build bench-js` runs it after Octane) and on the target
// (the same text inlined in boot/scripts/jsrun-drill.msh, whose log
// carries the line), so the host/target ratio is the number a page's
// script is planned by.
function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
class P { constructor(x, y) { this.x = x; this.y = y; } add(o) { return new P(this.x + o.x, this.y + o.y); } }
const t0 = Date.now();
const f = fib(24);
let p = new P(0, 0);
for (let i = 0; i < 200000; i++) p = p.add(new P(i, -i));
const m = new Map();
for (let i = 0; i < 50000; i++) m.set('k' + (i % 1000), i);
let s = '';
for (let i = 0; i < 20000; i++) s += i % 10;
const a = [];
for (let i = 0; i < 100000; i++) a.push(i * 2);
const sum = a.filter(x => x % 3 === 0).map(x => x / 2).reduce((x, y) => x + y, 0);
print('bench-small', Date.now() - t0, 'ms', f, p.x, m.size, s.length, sum);
