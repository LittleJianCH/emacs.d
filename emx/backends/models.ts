// models.ts --- bounded model discovery without opening a daemon session.
import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import type { AgentConfig } from '../config.ts'
import { allowedModel } from './pi.ts'

export interface ModelChoice { id: string, label?: string }

/** Query only capabilities; never create a thread or send a model prompt. */
export async function agentModels(agent: string, config: AgentConfig, root: string, env: NodeJS.ProcessEnv = process.env): Promise<ModelChoice[]> {
  if (agent === 'claude') return ['default', 'sonnet', 'opus', 'haiku'].map((id) => ({ id }))
  if (!['codex', 'pi'].includes(agent)) return []
  const pi = agent === 'pi'
  const args = pi ? ['--mode', 'rpc', '--no-session', '--no-extensions', '--no-skills'] : ['app-server']
  const child = spawn(env[`EMX_${agent.toUpperCase()}_EXECUTABLE`] ?? config.executable,
    [...args, ...config.extraArgs ?? []], { cwd: root, env, stdio: 'pipe' })
  child.stdin.on('error', () => {})
  child.stderr.resume()
  const lines = createInterface({ input: child.stdout })
  let next = 0
  const pending = new Map<string, { resolve: (v: any) => void, reject: (error: Error) => void }>()
  const fail = (error: Error) => { for (const p of pending.values()) p.reject(error); pending.clear() }
  child.once('error', fail)
  child.once('close', () => fail(new Error('Model discovery process exited')))
  const timer = setTimeout(() => fail(new Error('Model discovery timed out')), 10000)
  lines.on('line', (line) => {
    let msg: any
    try { msg = JSON.parse(line) } catch { return }
    const p = pending.get(String(msg.id))
    if (!p) return
    pending.delete(String(msg.id))
    if (msg.error || msg.success === false) p.reject(new Error(msg.error?.message ?? msg.error ?? 'Model discovery failed'))
    else p.resolve(pi ? msg.data : msg.result)
  })
  const write = (message: object) => child.stdin.write(JSON.stringify(message) + '\n')
  const request = (method: string, params: object = {}): Promise<any> => new Promise((resolve, reject) => {
    const id = String(++next)
    pending.set(id, { resolve, reject })
    write(pi ? { id, type: method, ...params } : { jsonrpc: '2.0', id, method, params })
  })
  try {
    if (pi) {
      const result = await request('get_available_models')
      return (result.models ?? []).map((m: any) => ({ id: `${m.provider}/${m.id}`, label: m.name }))
        .filter((m: ModelChoice) => allowedModel(m.id, config))
    }
    await request('initialize', { clientInfo: { name: 'emx-models', version: '1' } })
    write({ jsonrpc: '2.0', method: 'initialized' })
    const models: ModelChoice[] = []
    let cursor: string | undefined
    do {
      const result = await request('model/list', { limit: 100, ...(cursor ? { cursor } : {}) })
      models.push(...(result.data ?? []).filter((m: any) => !m.hidden)
        .map((m: any) => ({ id: m.model, label: m.displayName })))
      cursor = result.nextCursor ?? undefined
    } while (cursor)
    return models
  } finally { clearTimeout(timer); lines.close(); child.kill() }
}
