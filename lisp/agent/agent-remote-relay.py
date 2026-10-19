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
import socket
import sys
import threading
import time

path, name = sys.argv[1], sys.argv[2]
pattern = glob.escape(path.rsplit('-', 1)[0]) + '-*.sock'
lock = threading.Lock()
state = {'sock': None, 'ready': False, 'init': None, 'initialized': None,
         'replay': None, 'pending': {}, 'queue': []}
LOST = 'Emacs is out of reach: the connection to its host was lost; retry once it is back'


def emit(line):
    """Write LINE (bytes ending in a newline) to the agent."""
    try:
        os.write(1, line)
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
        state['sock'] = None
        state['ready'] = False
        state['replay'] = None
        for raw_id in state['pending'].values():
            emit(error_line(raw_id))
        state['pending'].clear()
        state['queue'].clear()
    sock.close()


def send(sock, data):
    try:
        sock.sendall(data)
        return True
    except OSError:
        return False


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
                if isinstance(message, dict) and 'method' not in message and 'id' in message:
                    key = json.dumps(message['id'])
                    if state['replay'] == key:
                        # The new emx answered the replayed handshake: finish
                        # it, tell the agent to list the tools again, then
                        # pass on what waited.
                        state['replay'] = None
                        state['ready'] = True
                        ok = state['initialized'] is None or send(sock, state['initialized'])
                        for queued in state['queue']:
                            ok = ok and send(sock, queued)
                        state['queue'].clear()
                        emit(b'{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}\n')
                        continue
                    state['pending'].pop(key, None)
                emit(line)


def attach():
    """Connect to a bridge if there is one; return whether there is."""
    sock = connect()
    if not sock:
        return False
    with lock:
        state['sock'] = sock
        if state['init'] is None:
            state['ready'] = True
        else:
            state['replay'] = json.dumps(json.loads(state['init'])['id'])
            send(sock, state['init'])
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
            with lock:
                if isinstance(message, dict):
                    if message.get('method') == 'initialize':
                        state['init'] = line
                    elif message.get('method') == 'notifications/initialized':
                        state['initialized'] = line
                sock = state['sock']
                if sock is None:
                    if request:
                        emit(error_line(json.dumps(message['id']).encode()))
                    continue
                if request:
                    state['pending'][json.dumps(message['id'])] = json.dumps(message['id']).encode()
                if not state['ready']:
                    state['queue'].append(line)
                    continue
            if not send(sock, line):
                lost(sock)


attach()
threading.Thread(target=keep_connected, daemon=True).start()
upstream()
