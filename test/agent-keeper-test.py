"""Tests of agent-keeper.py with a fake agent.  Run: python3 test/agent-keeper-test.py"""
import os, signal, subprocess, sys, time, uuid, glob

K = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'lisp', 'agent', 'agent-keeper.py')
DIR = os.path.expanduser('~/.cache/emacs-agent/keeper')
FAKE = r'''
import sys, threading, time, os
def ticks():
    for i in range(int(sys.argv[1])):
        print('{"tick":%d}' % i, flush=True); time.sleep(0.1)
    if sys.argv[2] == 'exit':
        sys.stderr.write('bye from agent\n'); sys.stderr.flush(); os._exit(7)
threading.Thread(target=ticks, daemon=True).start()
for line in sys.stdin:
    print('{"echo":%s}' % line.strip(), flush=True)
time.sleep(0.2)
'''

def start(kid, n, how='stay'):
    return subprocess.Popen([sys.executable, K, 'start', kid, '--', sys.executable, '-c', FAKE, str(n), how],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE)

def attach(kid, off):
    return subprocess.Popen([sys.executable, K, 'attach', kid, str(off)],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE)

def frames(p, until=None, timeout=10):
    out = []
    os.set_blocking(p.stdout.fileno(), False)
    buf = b''
    t = time.time()
    while time.time() - t < timeout:
        try:
            d = os.read(p.stdout.fileno(), 65536)
        except BlockingIOError:
            time.sleep(0.05); continue
        if not d:
            break
        buf += d
        *lines, buf = buf.split(b'\n')
        out += [l.decode() for l in lines]
        if until and any(until(l) for l in out):
            break
    return out

def parse(out):
    off, payload = 0, []
    for l in out:
        if l[0].isdigit():
            o, rest = l.split(' ', 1); off = int(o); payload.append(rest)
    return off, payload

def alive(kid):
    return os.path.exists(os.path.join(DIR, kid + '.sock'))

def check(cond, msg):
    print(('ok   ' if cond else 'FAIL ') + msg)
    if not cond: sys.exit(1)

# 1+2: echo, detach on stdin EOF, exactly-once replay
kid = 't' + uuid.uuid4().hex[:8]
p = start(kid, 40)
p.stdin.write(b'"hello"\n'); p.stdin.flush()
out = frames(p, until=lambda l: '"tick":5' in l)
off, pay = parse(out)
check('{"echo":"hello"}' in pay, 'echo through keeper')
p.stdin.close()            # connection lost
p.wait(timeout=5)
time.sleep(2)
check(alive(kid), 'agent kept after detach')
q = attach(kid, off)
out2 = frames(q, until=lambda l: '"tick":39' in l)
_, pay2 = parse(out2)
ticks = [int(x.split(':')[1].rstrip('}')) for x in pay + pay2 if 'tick' in x]
check(ticks == list(range(40)), 'ticks exactly once across reattach: %s' % (ticks[:3] + ['...'] + ticks[-3:]))
q.stdin.write(b'"again"\n'); q.stdin.flush()
out3 = frames(q, until=lambda l: 'again' in l, timeout=3)
check(any('again' in l for l in out3), 'input after reattach')
# 2b: SIGTERM (tramp-rpc's server closing) detaches too
q.terminate(); q.wait(); time.sleep(1.5)
check(alive(kid), 'SIGTERMed client detaches, agent kept')
check(oct(os.stat(os.path.join(DIR, kid + '.out')).st_mode & 0o777) == '0o600', 'spool is private')
q = attach(kid, 0)
frames(q, until=lambda l: 'again' in l, timeout=3)
# 3: SIGKILL client stops agent
q.kill(); q.wait()
time.sleep(1.5)
check(not alive(kid), 'SIGKILLed client stops the agent and cleans up')
check(not glob.glob(os.path.join(DIR, kid + '*')), 'no files left')

# 4: agent exits while detached; reattach gets rest + E frame
kid = 't' + uuid.uuid4().hex[:8]
p = start(kid, 10, 'exit')
out = frames(p, until=lambda l: '"tick":2' in l)
off, pay = parse(out)
p.stdin.close(); p.wait(timeout=5)
time.sleep(3)
check(alive(kid), 'exited agent waits for a client')
q = attach(kid, off)
out2 = frames(q, timeout=5)
_, pay2 = parse(out2)
ticks = [int(x.split(':')[1].rstrip('}')) for x in pay + pay2 if 'tick' in x]
check(ticks == list(range(10)), 'all output after detached exit')
e = [l for l in out2 if l.startswith('E ')]
import base64
check(e and e[0].split()[1] == '7' and b'bye from agent' in base64.b64decode(e[0].split()[2]), 'exit frame %s' % e)
q.wait(timeout=5)
time.sleep(0.5)
check(not glob.glob(os.path.join(DIR, kid + '*')), 'cleaned after exit delivered')

# 5: unknown id
q = attach('tnone', 0); out = frames(q, timeout=3); q.wait()
check(out == ['G'] and q.returncode == 3, 'unknown id gives G')

# 6: kill mode
kid = 't' + uuid.uuid4().hex[:8]
p = start(kid, 1000)
frames(p, until=lambda l: '"tick":1' in l)
p.stdin.close(); p.wait()
subprocess.run([sys.executable, K, 'kill', kid], timeout=10)
time.sleep(1.5)
check(not alive(kid), 'kill mode stops a detached agent')

# 7: a second attach replaces the first without stopping the agent
kid = 't' + uuid.uuid4().hex[:8]
p = start(kid, 1000)
out = frames(p, until=lambda l: '"tick":1' in l)
off, _ = parse(out)
q = attach(kid, off)
frames(q, until=lambda l: '"tick":3' in l)
time.sleep(0.5)
check(p.poll() is not None and alive(kid), 'old client dropped, agent alive')
q.kill(); q.wait(); time.sleep(1.5)
check(not alive(kid), 'killing the new client stops it')
print('all passed')
