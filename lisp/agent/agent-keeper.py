"""Keep an agent process alive on its host while the connection to Emacs is lost.

A remote agent normally runs as a child of tramp-rpc's server, so it dies
with the SSH connection.  Started through this script it runs under a
daemon (the keeper) instead, and Emacs talks to it through a client that
can come and go:

  python3 -c KEEPER start ID -- COMMAND...   start COMMAND under keeper ID, attach
  python3 -c KEEPER attach ID OFFSET         attach again, from output byte OFFSET
  python3 -c KEEPER kill ID                  stop the agent of keeper ID; after
                                             its exit, end the keeper

The client passes its stdin to the agent and prints the agent's output,
one frame per line:

  <end> <line>        a line the agent printed; <end> is the byte offset in
                      its output just after the line, for the next attach
  E <code> <base64>   the agent exited with <code>; <base64> is the tail of
                      its stderr
  G                   (attach, kill) there is no keeper with this ID

A client whose connection is gone detaches: the agent keeps running and its
output waits for the next attach.  The client learns of it from its stdin
ending, a broken stdout or SIGTERM, which tramp-rpc's server sends the
processes it started as the connection closes.  A client that disappears
without detaching has been killed on purpose (Emacs deletes a remote process
with SIGKILL), so the keeper stops the agent.  So does a keeper no client has
attached to for IDLE seconds.  The client passes on whole lines only.

After the agent exits the keeper keeps its output until `kill' says Emacs got
the exit frame (or IDLE passes): a connection lost just as the frame was sent
must not lose it.
"""

import base64
import os
import selectors
import signal
import socket
import subprocess
import sys
import threading
import time
import traceback

DIR = os.path.expanduser('~/.cache/emacs-agent/keeper')
IDLE = 24 * 3600
STOP_GRACE = 5
CHUNK = 1 << 16
ERR_TAIL = 4096


def paths(kid):
    return [os.path.join(DIR, kid + ext) for ext in ('.sock', '.out', '.err')]


class Keeper:
    def __init__(self, kid, listener, command):
        self.sock_path, self.out_path, self.err_path = paths(kid)
        self.listener = listener
        self.err = open(self.err_path, 'wb')
        self.child = subprocess.Popen(command, stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=self.err,
                                      start_new_session=True)
        os.set_blocking(self.child.stdin.fileno(), False)
        os.set_blocking(self.child.stdout.fileno(), False)
        self.spool = open(self.out_path, 'w+b')
        self.size = 0          # bytes in the spool
        self.complete = 0      # offset just after its last newline
        self.client = None
        self.to_child = bytearray()
        self.code = None       # the agent's exit status, once it has exited
        self.stop_at = None    # when the agent was asked to stop
        self.alone_since = time.monotonic()
        self.sel = selectors.DefaultSelector()
        self.sel.register(listener, selectors.EVENT_READ, self.accept)
        self.sel.register(self.child.stdout, selectors.EVENT_READ, self.read_child)

    # The agent

    def read_child(self, _mask):
        data = os.read(self.child.stdout.fileno(), CHUNK)
        if not data:
            self.sel.unregister(self.child.stdout)
            self.child.stdout.close()
            if self.size > self.complete:
                data = b'\n'
            else:
                return
        self.spool.seek(self.size)
        self.spool.write(data)
        self.size += len(data)
        newline = data.rfind(b'\n')
        if newline >= 0:
            self.complete = self.size - len(data) + newline + 1
        self.update_client()

    def write_child(self, _mask):
        try:
            n = os.write(self.child.stdin.fileno(), self.to_child)
            del self.to_child[:n]
        except BlockingIOError:
            pass
        except OSError:
            self.to_child.clear()
        if not self.to_child:
            self.sel.unregister(self.child.stdin)

    def send_child(self, line):
        if self.code is not None or self.child.stdin.closed:
            return
        if not self.to_child:
            self.sel.register(self.child.stdin, selectors.EVENT_WRITE, self.write_child)
        self.to_child += line

    def stop(self):
        if self.stop_at is None and self.code is None:
            self.stop_at = time.monotonic()
            try:
                self.child.terminate()
            except OSError:
                pass

    def finish(self):
        for path in (self.sock_path, self.out_path, self.err_path):
            try:
                os.unlink(path)
            except OSError:
                pass
        sys.exit(0)

    def exit_frame(self):
        self.err.flush()
        with open(self.err_path, 'rb') as f:
            f.seek(max(0, os.fstat(f.fileno()).st_size - ERR_TAIL))
            tail = f.read()
        code = self.code if self.code >= 0 else 128 - self.code
        return b'E %d %s\n' % (code, base64.b64encode(tail))

    # The client

    def accept(self, _mask):
        conn, _ = self.listener.accept()
        conn.setblocking(False)
        state = {'sock': conn, 'header': True, 'inbuf': bytearray(), 'outbuf': bytearray(),
                 'pos': 0, 'detached': False, 'done': False, 'closed': False}
        self.sel.register(conn, selectors.EVENT_READ, lambda mask: self.client_io(state, mask))

    def close(self, state):
        if state['closed']:
            return
        # What the client sent before it went may say it detached: read it
        # before taking its going as a kill.
        self.receive(state, drain=True)
        state['closed'] = True
        self.sel.unregister(state['sock'])
        state['sock'].close()
        if state is self.client:
            self.client = None
            self.alone_since = time.monotonic()
            if not state['detached'] and not state['done']:
                self.stop()

    def receive(self, state, drain=False):
        """Read and handle what the client sent; return False once it is gone.
With DRAIN, read all that is buffered and handle only what concerns a closing
connection."""
        while True:
            try:
                data = state['sock'].recv(CHUNK)
            except BlockingIOError:
                return True
            except OSError:
                data = b''
            if not data:
                if not drain:
                    self.close(state)
                return False
            state['inbuf'] += data
            while not state['closed']:
                newline = state['inbuf'].find(b'\n')
                if newline < 0:
                    break
                line = bytes(state['inbuf'][:newline + 1])
                del state['inbuf'][:newline + 1]
                if not drain:
                    self.client_line(state, line)
                elif line == b'\0detach\n':
                    state['detached'] = True
                elif not state['header'] and not line.startswith(b'\0') and state is self.client:
                    self.send_child(line)
            if not drain:
                return not state['closed']

    def client_io(self, state, mask):
        if state['closed']:
            # Closed by an earlier event of the same select.
            return
        if mask & selectors.EVENT_WRITE:
            try:
                n = state['sock'].send(state['outbuf'])
                del state['outbuf'][:n]
            except BlockingIOError:
                pass
            except OSError:
                return self.close(state)
            self.update_client()
            if state['closed']:
                return
        if mask & selectors.EVENT_READ:
            self.receive(state)

    def client_line(self, state, line):
        if state['header']:
            state['header'] = False
            words = line.split()
            if words[:1] == [b'kill']:
                if self.code is not None:
                    # The agent has exited and Emacs got its exit: done.
                    self.finish()
                self.stop()
                return self.close(state)
            try:
                state['pos'] = min(int(words[1]), self.complete)
            except (IndexError, ValueError):
                state['detached'] = True
                return self.close(state)
            if self.client:
                # A newer client replaces the old one, which must not stop the agent.
                self.client['detached'] = True
                self.close(self.client)
            self.client = state
            self.update_client()
        elif line.startswith(b'\0'):
            words = line[1:].split()
            if words == [b'detach']:
                state['detached'] = True
            elif words[:1] == [b'sig'] and self.code is None:
                try:
                    os.kill(self.child.pid, int(words[1]))
                except OSError:
                    pass
        elif state is self.client:
            self.send_child(line)

    def update_client(self):
        """Fill the client's output buffer from the spool."""
        state = self.client
        if state is None:
            return
        out = state['outbuf']
        if len(out) < CHUNK and state['pos'] < self.complete:
            self.spool.seek(state['pos'])
            data = self.spool.read(min(self.complete - state['pos'], 4 * CHUNK))
            end = data.rfind(b'\n') + 1
            if end == 0:
                # A line longer than the read: take it whole.
                data = data + self.spool.readline()
                end = len(data)
            for line in data[:end].splitlines(keepends=True):
                state['pos'] += len(line)
                out += b'%d ' % state['pos']
                out += line
        if (self.code is not None and state['pos'] == self.complete
                and self.child.stdout.closed and not state['done']):
            state['done'] = True
            out += self.exit_frame()
        events = selectors.EVENT_READ | (selectors.EVENT_WRITE if out else 0)
        self.sel.modify(state['sock'], events, self.sel.get_key(state['sock']).data)
        if state['done'] and not out:
            # Sent, but Emacs may not get it if the connection drops now: keep
            # the spool until Emacs says it has (`kill'), for a reattach.
            self.close(state)

    def run(self):
        while True:
            for key, mask in self.sel.select(timeout=1):
                key.data(mask)
            now = time.monotonic()
            if self.code is None:
                self.code = self.child.poll()
                self.exited_at = now
            if self.code is not None and not self.child.stdout.closed and now - self.exited_at > 2:
                # A process the agent left behind holds its stdout open.
                self.sel.unregister(self.child.stdout)
                self.child.stdout.close()
            if self.code is not None:
                self.update_client()
            if self.code is None and self.stop_at is not None and now - self.stop_at > STOP_GRACE:
                try:
                    self.child.kill()
                except OSError:
                    pass
            if self.client is None and now - self.alone_since > IDLE:
                if self.code is not None:
                    self.finish()
                self.stop()
            if self.stop_at is not None and self.code is not None and self.client is None:
                self.finish()


def daemonize(kid, command):
    """Start the keeper of COMMAND in the background.
Return None once it runs the agent, else why it couldn't."""
    os.makedirs(DIR, mode=0o700, exist_ok=True)
    sock_path = paths(kid)[0]
    log_path = os.path.join(DIR, kid + '.log')
    old = os.umask(0o077)
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(sock_path)
    os.umask(old)
    listener.listen()
    ready_r, ready_w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(ready_r)
        try:
            os.setsid()
            os.umask(0o077)
            if os.fork():
                os._exit(0)
            null = os.open(os.devnull, os.O_RDWR)
            for fd in (0, 1):
                os.dup2(null, fd)
            log = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            os.dup2(log, 2)
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            signal.signal(signal.SIGPIPE, signal.SIG_IGN)
            try:
                keeper = Keeper(kid, listener, command)
            except Exception:
                write_all(ready_w, traceback.format_exc().encode())
                for path in paths(kid) + [log_path]:
                    try:
                        os.unlink(path)
                    except OSError:
                        pass
                raise SystemExit
            os.write(ready_w, b'\0')
            os.close(ready_w)
            keeper.run()
        except SystemExit:
            try:
                os.unlink(log_path)
            except OSError:
                pass
        except Exception:
            traceback.print_exc()
        finally:
            os._exit(0)
    os.close(ready_w)
    os.waitpid(pid, 0)
    listener.close()
    status = b''
    while True:
        data = os.read(ready_r, CHUNK)
        if not data:
            break
        status += data
    os.close(ready_r)
    return None if status == b'\0' else (status or b'the keeper did not start\n')


def client(kid, header):
    sock = socket.socket(socket.AF_UNIX)
    try:
        sock.connect(paths(kid)[0])
    except OSError:
        os.write(1, b'G\n')
        sys.exit(3)
    lock = threading.Lock()

    def send(data):
        with lock:
            sock.sendall(data)

    def leave(*_):
        # The connection to Emacs is gone: detach and leave the agent running.
        try:
            send(b'\0detach\n')
        except OSError:
            pass
        os._exit(0)

    send(header)
    if header.startswith(b'kill'):
        sock.recv(1)
        sys.exit(0)
    signal.signal(signal.SIGINT, lambda *_: send(b'\0sig %d\n' % signal.SIGINT))
    signal.signal(signal.SIGHUP, leave)
    signal.signal(signal.SIGTERM, leave)

    def up():
        # Whole lines only: a line cut off by a lost connection is dropped,
        # and the detach that follows starts a line of its own.
        pending = b''
        try:
            while True:
                data = os.read(0, CHUNK)
                if not data:
                    break
                pending += data
                end = pending.rfind(b'\n') + 1
                if end:
                    send(pending[:end])
                    pending = pending[end:]
        except OSError:
            pass
        leave()

    threading.Thread(target=up, daemon=True).start()
    while True:
        data = sock.recv(CHUNK)
        if not data:
            break
        try:
            write_all(1, data)
        except OSError:
            leave()
    os._exit(0)


def write_all(fd, data):
    view = memoryview(data)
    while view:
        view = view[os.write(fd, view):]


def main(argv):
    mode, kid = argv[0], argv[1]
    if not kid.replace('-', '').isalnum():
        sys.exit('bad keeper id')
    if mode == 'start':
        failure = daemonize(kid, argv[argv.index('--') + 1:])
        if failure:
            # Reported like an exit of the agent, with the reason as its stderr.
            write_all(1, b'E 127 %s\n' % base64.b64encode(failure[-ERR_TAIL:]))
            sys.exit(127)
        client(kid, b'attach 0\n')
    elif mode == 'attach':
        client(kid, b'attach %d\n' % int(argv[2]))
    elif mode == 'kill':
        client(kid, b'kill\n')


main(sys.argv[1:])
