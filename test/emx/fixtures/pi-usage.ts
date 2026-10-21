// Loopback-only OpenCode Go peer; never use credentials or the public endpoint.
import { createServer } from 'node:http'
import type { TestContext } from 'node:test'

export const PI_USAGE = {usage: {
  rolling: {status: 'ok', percent: 0, resetsAt: '2026-10-21T12:05:36.000Z'},
  weekly: {status: 'ok', percent: 0, resetsAt: '2026-10-26T00:00:00.000Z'},
  monthly: {status: 'ok', percent: 0, resetsAt: '2026-11-20T18:02:56.000Z'},
}}

export async function piUsageServer(t: TestContext) {
  const response: {status: number, body: unknown} = {status: 200, body: structuredClone(PI_USAGE)}
  const requests: {method?: string, url?: string, authorization?: string}[] = []
  const server = createServer((req, res) => {
    requests.push({method: req.method, url: req.url, authorization: req.headers.authorization})
    res.writeHead(response.status, {'Content-Type': 'application/json'})
    res.end(typeof response.body === 'string' ? response.body : JSON.stringify(response.body))
  })
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', resolve)
  })
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('No loopback server address')
  const previous = process.env.EMX_PI_USAGE_URL
  process.env.EMX_PI_USAGE_URL = `http://127.0.0.1:${address.port}/zen/go/v1/usage`
  t.after(async () => {
    if (previous === undefined) delete process.env.EMX_PI_USAGE_URL
    else process.env.EMX_PI_USAGE_URL = previous
    await new Promise<void>((resolve) => { server.close(() => resolve()); server.closeAllConnections() })
  })
  return {response, requests}
}
