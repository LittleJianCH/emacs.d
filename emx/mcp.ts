// mcp.ts --- stdio MCP facade for a daemon session, with no editor socket access.
import { createConnection } from 'node:net'
import { createInterface } from 'node:readline'
import { Connection } from './daemon/rpc.ts'

export async function serve(instructions: string, version: string): Promise<void> {
  const socket = process.env.EMX_DAEMON_SOCKET
  const session = process.env.EMX_SESSION
  if (!socket || !session) throw new Error('Daemon MCP requires EMX_DAEMON_SOCKET and EMX_SESSION')
  const connection = new Connection(createConnection(socket))
  const send = (message: object) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n')
  const running = new Map<unknown, AbortController>()
  connection.onNotification = (method) => {
    if (method === 'mcp/tools_changed') send({ method: 'notifications/tools/list_changed' })
  }
  connection.onClose = () => {
    for (const call of running.values()) call.abort()
  }
  const hello = connection.request('mcp/hello', { session })
  // Install the stdin reader before awaiting hello, including when stdin is piped.
  const input = createInterface({ input: process.stdin })
  let active = 0
  let ended = false
  const close = () => { if (ended && !active) connection.close() }
  input.on('close', () => { ended = true; close() })
  input.on('line', (line) => {
    if (!line.trim()) return
    let message: any
    try { message = JSON.parse(line) }
    catch { send({ id: null, error: { code: -32700, message: 'Parse error' } }); return }
    if (message.id === undefined) {
      if (message.method === 'notifications/cancelled') running.get(message.params?.requestId)?.abort(new Error('Cancelled'))
      return
    }
    const { id, method, params = {} } = message
    const controller = new AbortController()
    if (method === 'tools/call') running.set(id, controller)
    active++
    void (async () => {
      const host = await hello as { remote: boolean, instructions: string }
      switch (method) {
        case 'initialize': return { protocolVersion: params.protocolVersion ?? '2025-06-18',
          capabilities: { tools: { listChanged: true } }, serverInfo: { name: 'emacs', version }, instructions: instructions
            + (host.instructions ? '\n' + host.instructions : '') + (host.remote
            ? '\nYour shell and file tools run on the project host. Emacs and its configuration live on the user machine; use config_read, config_edit and config_write for that checkout (read its AGENTS.md first), then reload.' : '') }
        case 'ping': return {}
        case 'tools/list': return connection.request('mcp/tools', {})
        case 'tools/call':
          try {
            const result = await connection.request('mcp/call', { name: params.name, arguments: params.arguments ?? {} }, controller.signal)
            return { content: [{ type: 'text', text: typeof result === 'string' ? result : JSON.stringify(result, null, 2) }] }
          } catch (error) {
            return { content: [{ type: 'text', text: (error as Error).message }], isError: true }
          }
        default: throw Object.assign(new Error(`Method not found: ${method}`), { code: -32601 })
      }
    })().then((result) => send({ id, result }), (error) => send({ id,
      error: { code: error.code ?? -32603, message: error.message } }))
      .finally(() => { running.delete(id); active--; close() })
  })
  // All requests report handshake errors via JSON-RPC; avoid unhandled rejections.
  void hello.catch(() => {})
}
