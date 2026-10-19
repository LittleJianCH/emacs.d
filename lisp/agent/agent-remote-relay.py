"""Relay a remote agent's MCP stdio to emx in Emacs, through a bridge socket.

Arguments: the bridge socket and the session buffer name.  The relay sends
the name as its first line, then passes MCP messages both ways.

The bridge is a forward of the SSH connection, so it goes when that does,
while the agent, kept by agent-keeper.py, may stay; and an agent drops an
MCP server whose process has exited.  So the relay stays: while there is no
bridge it answers requests with an error at once, and it connects again to
a bridge of the same Emacs (emx-<emacs pid>-*.sock next to the first one)
once there is one, replaying the MCP handshake to the new emx before
passing on anything else.
"""

import glob
import json
import os
import queue
import socket
import sys
import threading
import time

path, name = sys.argv[1], sys.argv[2]
pattern = glob.escape(path.rsplit('-', 1)[0]) + '-*.sock'
# Guards STATE.  Nothing blocks while holding it: lines for emx go to the
# connection's writer thread through a queue.
lock = threading.Lock()
state = {'sock': None, 'out': None, 'ready': False, 'init': None, 'initialized': None,
         'replay': None, 'pending': {}, 'queue': []}
LOST = 'Emacs is out of reach: the connection to its host was lost; retry once it is back'


emit_lock = threading.Lock()


def emit(line):
    """Write LINE (bytes ending in a newline) to the agent, whole: several
threads write, and a pipe interleaves writes longer than PIPE_BUF."""
    view = memoryview(line)
    with emit_lock:
        try:
            while view:
                view = view[os.write(1, view):]
        except OSError:
            os._exit(0)


def error_line(raw_id):
    return b'{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"%s"}}\n' % (
        raw_id, LOST.encode())


def bridges():
    def mtime(p):
        try:
            return os.stat(p).st_mtime
        except OSError:
            return 0
    found = sorted(glob.glob(pattern), key=mtime, reverse=True)
    return [path] + [p for p in found if p != path]


def connect():
    for p in bridges():
        s = socket.socket(socket.AF_UNIX)
        try:
            s.connect(p)
            s.sendall(name.encode() + b'\n')
            return s
        except OSError:
            s.close()
    return None


def lost(sock):
    """The bridge of SOCK is gone: fail what it owed the agent."""
    with lock:
        if state['sock'] is not sock:
            return
        owed = list(state['pending'].values())
        state['out'].put(None)
        state.update(sock=None, out=None, ready=False, replay=None, pending={}, queue=[])
    sock.close()
    for raw_id in owed:
        emit(error_line(raw_id))


def writer(sock, out):
    """Send the lines put in OUT to emx on SOCK, until None."""
    while True:
        line = out.get()
        if line is None:
            return
        try:
            sock.sendall(line)
        except OSError:
            return lost(sock)


def downstream(sock):
    """Pass emx's messages on SOCK to the agent until the bridge goes."""
    buf = b''
    while True:
        try:
            data = sock.recv(65536)
        except OSError:
            data = b''
        if not data:
            return lost(sock)
        buf += data
        *lines, buf = buf.split(b'\n')
        for line in lines:
            line += b'\n'
            try:
                message = json.loads(line)
            except ValueError:
                message = None
            with lock:
                if state['sock'] is not sock:
                    # Lost meanwhile: its requests have been failed already.
                    return
                if isinstance(message, dict) and 'method' not in message and 'id' in message:
                    key = json.dumps(message['id'])
                    if state['replay'] == key and state['sock'] is sock:
                        # The new emx answered the replayed handshake: finish
                        # it, pass on what waited, and tell the agent to list
                        # the tools again.
                        if state['initialized'] is not None:
                            state['out'].put(state['initialized'])
                        for queued in state['queue']:
                            state['out'].put(queued)
                        state.update(replay=None, ready=True, queue=[])
                        line = b'{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}\n'
                    else:
                        state['pending'].pop(key, None)
            emit(line)


def attach():
    """Connect to a bridge if there is one; return whether there is."""
    sock = connect()
    if not sock:
        return False
    out = queue.Queue()
    with lock:
        state.update(sock=sock, out=out)
        if state['init'] is None:
            state['ready'] = True
        else:
            state['replay'] = json.dumps(json.loads(state['init'])['id'])
            out.put(state['init'])
    threading.Thread(target=writer, args=(sock, out), daemon=True).start()
    threading.Thread(target=downstream, args=(sock,), daemon=True).start()
    return True


def keep_connected():
    delay = 1
    while True:
        time.sleep(delay)
        with lock:
            connected = state['sock'] is not None
        if connected:
            delay = 1
        elif not attach():
            delay = min(delay * 2, 10)


def upstream():
    """Pass the agent's messages to emx, or fail them while it is out of reach."""
    buf = b''
    while True:
        data = os.read(0, 65536)
        if not data:
            os._exit(0)
        buf += data
        *lines, buf = buf.split(b'\n')
        for line in lines:
            line += b'\n'
            try:
                message = json.loads(line)
            except ValueError:
                message = None
            request = isinstance(message, dict) and 'method' in message and 'id' in message
            failed = False
            with lock:
                if isinstance(message, dict):
                    if message.get('method') == 'initialize':
                        state['init'] = line
                    elif message.get('method') == 'notifications/initialized':
                        state['initialized'] = line
                if state['sock'] is None:
                    failed = request
                else:
                    if request:
                        raw_id = json.dumps(message['id']).encode()
                        state['pending'][raw_id.decode()] = raw_id
                    if state['ready']:
                        state['out'].put(line)
                    else:
                        state['queue'].append(line)
            if failed:
                emit(error_line(json.dumps(message['id']).encode()))


attach()
threading.Thread(target=keep_connected, daemon=True).start()
upstream()
