// main.ts --- command dispatch, help and agent MCP instructions.
// Bare CLI: EMACS_SOCKET_NAME selects Emacs; EMX_EMACSCLIENT selects its client.
// Agent MCP: EMX_DAEMON_SOCKET and EMX_SESSION bind to the owning daemon.
import { parseArgs } from './args.ts'
import { call, callAsync } from './emacsclient.ts'

const VERSION = '0.1.0'

interface Method {
  name: string
  description: string
  inputSchema: {
    properties: Record<string, { type: string, description?: string }>
    required?: string[]
  }
}

function help(name?: string): string {
  const methods = call<Method[]>('describe')
  if (name) {
    const m = methods.find((m) => m.name === name)
    if (!m) throw new Error(`Unknown method: ${name}`)
    return `${m.name}\n\n${m.description}\n\nParameters: ${JSON.stringify(m.inputSchema.properties, null, 2)}`
  }
  const lines = ['Usage: emx <method> [positional args] [--key value ...]', '']
  for (const m of methods) {
    lines.push(`${m.name}  ${m.description.split('\n')[0]}`)
    const required = new Set(m.inputSchema.required)
    for (const [key, prop] of Object.entries(m.inputSchema.properties)) {
      lines.push(`    --${key} <${prop.type}>${required.has(key) ? ' (required)' : ''}  ${prop.description}`)
    }
  }
  lines.push('', 'emx help <method>  Show the full description of a method',
             'emx mcp            Run as a stdio MCP server',
             'emx daemon         Run the session daemon (--var DIR, --ensure, --stop)',
             'Usage is served by emx daemon.')
  return lines.join('\n')
}

// Clients may repeat these instructions in front of every tool description (Codex
// does), so they only say when to reach for each tool; how to use it belongs in the
// tool's own description.
const MCP_HEAD = `Your session is hosted in the user's Emacs: this conversation is an Emacs buffer, and these tools operate that Emacs.
- When the user means the current page, window, input box or editor, that is Emacs unless they name another app: call context first.`

const MCP_BODY = `
- Formatted content (option comparisons, plans, review results, diagrams, progress):
  render a native page, far clearer than long markdown in the chat.
- Point the user at code with open rather than only citing a path; show displays a
  document or diff.
- Atomic review (原子审查): follow the emacs-atomic-review skill.
- @handles name other agent sessions in this Emacs: sessions, session_read, session_ask.
- For nontrivial work with independent parts, use session_start to delegate a
  bounded task early, then continue another part yourself. Discover session_start
  if it is not listed.
  If you are a subagent assigned one task, do it yourself without starting sessions.
- After editing Lisp or emx/ code in this Emacs configuration, call reload.
- Other editor operations: eval.
- The user reads Chinese: write page content and notifications in Chinese.`

export async function main(args: string[]): Promise<void> {
  const [method, ...rest] = args
  if (method === 'daemon') {
    return (await import('../daemon/main.ts')).main(rest)
  }
  if (method === 'mcp') {
    return (await import('../mcp.ts')).serve(MCP_HEAD + MCP_BODY, VERSION)
  }
  if (!method || method === 'help' || method === '-h' || method === '--help') {
    console.log(help(rest[0]))
    return
  }
  const result = await callAsync(method, parseArgs(method, rest))
  console.log(typeof result === 'string' ? result : JSON.stringify(result, null, 2))
}
