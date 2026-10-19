"""Tests of agent-remote-relay.py against fake emx bridges.
Run: python3 test/agent-remote-relay-test.py"""
import json, os, socket, subprocess, sys, tempfile, threading, time

R = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'lisp', 'agent', 'agent-remote-relay.py')
d = tempfile.mkdtemp(prefix='relay-')

class Emx:
    """A bridge that serves one MCP session per connection and logs what it got."""
    def __init__(self, tag):
        self.path = os.path.join(d, 'emx-999-%s.sock' % tag)
        self.log = []
        self.srv = socket.socket(socket.AF_UNIX); self.srv.bind(self.path); self.srv.listen()
        self.conns = []
        threading.Thread(target=self.serve, daemon=True).start()
    def serve(self):
        while True:
            try: c, _ = self.srv.accept()
            except OSError: return
            self.conns.append(c)
            threading.Thread(target=self.handle, args=(c,), daemon=True).start()
    def handle(self, c):
        f = c.makefile('rb')
        self.log.append(('name', f.readline().strip().decode()))
        for line in f:
            m = json.loads(line); self.log.append(m.get('method') or 'response')
            if 'id' in m and 'method' in m and m['method'] != 'slow':
                c.sendall((json.dumps({'jsonrpc': '2.0', 'id': m['id'], 'result': {'from': self.path[-9:-5], 'method': m['method']}}) + '\n').encode())
    def close(self):
        self.srv.close()
        for c in self.conns:
            try: c.shutdown(socket.SHUT_RDWR)
            except OSError: pass
            c.close()
        os.unlink(self.path)

def check(c, msg):
    print(('ok   ' if c else 'FAIL ') + msg)
    if not c: sys.exit(1)

a = Emx('aaaa')
p = subprocess.Popen([sys.executable, R, a.path, '*claude@x*'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
def send(m): p.stdin.write((json.dumps(m) + '\n').encode()); p.stdin.flush()
def recv(): return json.loads(p.stdout.readline())

send({'jsonrpc': '2.0', 'id': 0, 'method': 'initialize', 'params': {}})
check(recv()['result']['from'] == 'aaaa', 'initialize through bridge a')
send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
send({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call'})
check(recv()['id'] == 1, 'request through bridge a')
check(a.log[0] == ('name', '*claude@x*'), 'first line names the session')

a.close(); time.sleep(0.5)
send({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call'})
r = recv()
check(r['id'] == 2 and 'out of reach' in r['error']['message'], 'request fails at once without a bridge')

b = Emx('bbbb')
time.sleep(4)
send({'jsonrpc': '2.0', 'id': 'x3', 'method': 'tools/call'})
r1 = recv()
check(r1.get('method') == 'notifications/tools/list_changed', 'agent told to list tools again: %s' % r1)
r2 = recv()
check(r2['id'] == 'x3' and r2['result']['from'] == 'bbbb', 'request through new bridge b')
check(b.log == [('name', '*claude@x*'), 'initialize', 'notifications/initialized', 'tools/call'],
      'handshake replayed before the request: %s' % b.log)

# a request in flight when the bridge goes gets an error
send({'jsonrpc': '2.0', 'id': 4, 'method': 'slow'})
time.sleep(0.5)
b.close()
r = recv()
check(r['id'] == 4 and 'out of reach' in r['error']['message'], 'in-flight request fails when the bridge goes')
p.stdin.close(); p.wait(timeout=5)
check(p.returncode == 0, 'relay exits when the agent closes stdin')
print('all passed')
