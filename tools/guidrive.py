# Drive a headless `run-gui` boot over QMP the way the runner does — sign
# in as alice, click the Web pill, type URLs into the address field — and
# print what the log says about each load; a screendump per URL lands
# beside the log. The exact desktop, without a window: how the first
# real sites were opened (2026-09-18).
#
#   qemu-system-aarch64 <the run-gui arguments from build.zig> \
#     -display none -qmp tcp:127.0.0.1:4455,server=on,wait=off \
#     -serial file:LOG -append "profile=guishell interactive" ... &
#   python3 tools/guidrive.py LOG 4455 https://example.com https://…
#
# Widget positions come from the log ("gui: widget ID at X,Y", "dock: item
# N cx=X cy=Y"); the scanout is the run-gui EDID's 1920x1200.
import json, socket, sys, time, re
log_path, port, urls = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
W, H = 1920, 1200
def readlog():
    try: return open(log_path, 'rb').read().decode('utf8', 'replace')
    except FileNotFoundError: return ''
def wait(marker, secs=60):
    t0 = time.time()
    while time.time() - t0 < secs:
        if marker in readlog(): return True
        time.sleep(0.2)
    print('TIMEOUT waiting for', marker); sys.exit(2)
def count(marker): return readlog().count(marker)
def widget(id):
    m = None
    for m in re.finditer(r'gui: widget %s at (\d+),(\d+)' % re.escape(id), readlog()): pass
    return (int(m.group(1)), int(m.group(2))) if m else None
def dock(idx):
    m = None
    for m in re.finditer(r'dock: item %d cx=(\d+) cy=(\d+)' % idx, readlog()): pass
    return (int(m.group(1)), int(m.group(2))) if m else None
s = None
for _ in range(100):
    try:
        s = socket.create_connection(('127.0.0.1', port)); break
    except OSError: time.sleep(0.3)
f = s.makefile('rwb', buffering=0)
def rd():
    return json.loads(f.readline())
rd()  # greeting
def ex(cmd):
    f.write((json.dumps(cmd) + '\n').encode()); r = rd()
    while 'return' not in r and 'error' not in r: r = rd()
    return r
ex({'execute': 'qmp_capabilities'})
def key(q, down): return {'type': 'key', 'data': {'down': down, 'key': {'type': 'qcode', 'data': q}}}
def send(events): ex({'execute': 'input-send-event', 'arguments': {'events': events}})
def tap(q): send([key(q, True)]); send([key(q, False)]); time.sleep(0.005)
def chord(m, q): send([key(m, True)]); send([key(q, True)]); send([key(q, False)]); send([key(m, False)]); time.sleep(0.005)
shifted = {'!':'1','(':'9',')':'0','"':'apostrophe','?':'slash','|':'backslash',':':'semicolon','_':'minus','&':'7'}
plain = {' ':'spc','-':'minus','\n':'ret','/':'slash','.':'dot','=':'equal',';':'semicolon',',':'comma'}
def typetext(t):
    for c in t:
        if 'A' <= c <= 'Z': chord('shift', c.lower())
        elif c in shifted: chord('shift', shifted[c])
        elif c in plain: tap(plain[c])
        else: tap(c)
def click(x, y):
    send([{'type':'abs','data':{'axis':'x','value': x*32768//W}}, {'type':'abs','data':{'axis':'y','value': y*32768//H}}])
    send([{'type':'btn','data':{'button':'left','down':True}}]); send([{'type':'btn','data':{'button':'left','down':False}}])
wait('gui: ready'); time.sleep(0.5)
typetext('alice'); time.sleep(0.1); tap('tab'); time.sleep(0.1); typetext('alice-pass'); time.sleep(0.1); tap('tab'); time.sleep(0.1); tap('ret')
wait('topbar: ready'); wait('dock: ready'); time.sleep(1.0)
p = dock(5); print('pill', p); click(*p)
wait('dock: activate browser'); wait('gui: widget go at', 30); time.sleep(1.5)
for u in urls:
    fld = None
    for m in re.finditer(r'gui: widget (url-t1-\d+) at', readlog()): fld = m.group(1)
    xy = widget(fld); print('field', fld, xy)
    click(*xy); time.sleep(0.3); chord('meta_l', 'a'); typetext(u); time.sleep(0.2)
    before = count('page t1: load failed') + count('page t1: load done')
    g = widget('go'); click(*g)
    t0 = time.time()
    while time.time() - t0 < 40 and count('page t1: load failed') + count('page t1: load done') == before: time.sleep(0.3)
    time.sleep(0.5)
    tail = [l for l in readlog().splitlines()[-400:] if 'webhost' in l or 'page t1' in l or 'netsvc' in l or 'resolv' in l]
    print('---', u); print('\n'.join(tail[-8:])); time.sleep(1.5); ex({'execute': 'screendump', 'arguments': {'filename': log_path.replace('.log', '-%d.ppm' % urls.index(u))}}); time.sleep(0.5)
ex({'execute': 'screendump', 'arguments': {'filename': log_path.replace('.log', '.ppm')}}); time.sleep(1)
ex({'execute': 'quit'})
