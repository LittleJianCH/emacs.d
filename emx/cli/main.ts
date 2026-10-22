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
- When the user means the current page, window, input box or editor, that is Emacs unless they name another app: call context first.
- Long-running commands, when your Bash tool has run_in_background: use it rather than a detached shell waiter; this session's process stays alive while they run, and their completion starts a new turn for you to report back.  It is for one long command; a multi-step job around runs (implement, build, measure, compare) is independent work for session_start.`

const MCP_BODY = `
- Formatted content (option comparisons, plans, review results, diagrams, progress):
  render a native page, far clearer than long markdown in the chat.
- Point the user at code with open rather than only citing a path; show displays a
  document or diff.
- Atomic review (原子审查): follow the emacs-atomic-review skill.
- @handles name other agent sessions in this Emacs: sessions, session_read, session_ask.
- Delegate with session_start (discover it if it is not listed); the available
  profiles and when to start each are listed below.  Two triggers:
  - An investigation needing more than 3 reads (where something is used, how a
    path works, comparing with another codebase), even when it is the user's
    whole question: a cheaper profile reads and returns a focused summary with
    file:line refs.  End your turn if you need its answer first.
  - Nontrivial work with independent parts: delegate a bounded part early,
    then continue another part yourself.
  Project instructions that say to spawn an Agent, Explore or other built-in
  subagent mean session_start here.
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
