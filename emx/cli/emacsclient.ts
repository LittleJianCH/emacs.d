// emacsclient.ts --- bare CLI transport through temporary request/response files.
import { execFileSync } from 'node:child_process'
import * as fs from 'node:fs'
import * as os from 'node:os'
import * as path from 'node:path'

const EMACSCLIENT = process.env.EMX_EMACSCLIENT || 'emacsclient'

const lispString = (s: string) => '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"'

// Call an agent-ui method in Emacs; return its response {ok, result | pending} or throw
// an error.
function request<T>(method: string, params: Record<string, unknown> = {}): { result: T, pending?: string } {
  params = { ...params }
  if (typeof params.path === 'string') params.path = path.resolve(params.path)

  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'emx-'))
  const request = path.join(dir, 'request.json')
  const response = path.join(dir, 'response.json')
  try {
    // Tell Emacs which agent session is calling, so page buttons etc. can send
    // messages back to that session.
    const context = { agent_buffer: process.env.EMX_AGENT_BUFFER || null }
    fs.writeFileSync(request, JSON.stringify({ method, params, context }))
    try {
      execFileSync(EMACSCLIENT,
        ['--eval', `(agent-ui-rpc ${lispString(request)} ${lispString(response)})`],
        { stdio: ['ignore', 'ignore', 'pipe'], timeout: 30000 })
    } catch (error) {
      const err = error as Error & { stderr?: Buffer }
      const detail = (err.stderr && err.stderr.toString().trim()) || err.message
      throw new Error(`Cannot reach Emacs (is Emacs running with a server started?): ${detail}`)
    }
    const out = JSON.parse(fs.readFileSync(response, 'utf8'))
    if (!out.ok) throw new Error(out.error)
    return out
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

// Call an agent-ui method that answers at once; return the result or throw an error.
export function call<T>(method: string, params: Record<string, unknown> = {}): T {
  const out = request<T>(method, params)
  if (out.pending) {
    request('_poll', { id: out.pending, cancel: true })
    throw new Error(`${method} waits for its result; call it through the MCP server or the command line`)
  }
  return out.result
}

const POLL_INTERVAL = 1000
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

// Call an agent-ui method and wait for its result. A method that would block Emacs
// while it waits (e.g. for another agent) answers {pending: id} at once
// poll it until it is done.
export async function callAsync(method: string, params: Record<string, unknown> = {}): Promise<unknown> {
  let out = request(method, params)
  while (out.pending) {
    await sleep(POLL_INTERVAL)
    out = request('_poll', { id: out.pending })
  }
  return out.result
}
