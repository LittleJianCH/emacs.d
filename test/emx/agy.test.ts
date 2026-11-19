// agy.test.ts --- Antigravity CLI (agy acp) adapter, model discovery and history tests.
import './fixtures/environment.ts'
import * as assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { chmod, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import { test } from 'node:test'
import type { TestContext } from 'node:test'
import { AgyBackend, parseCapabilities, toolOutput, toolView } from '../../emx/backends/agy.ts'
import type { NewAsk, SessionHost } from '../../emx/backends/backend.ts'
import { history } from '../../emx/backends/history.ts'
import { agentModels } from '../../emx/backends/models.ts'
import type { AgentConfig } from '../../emx/config.ts'
import type { Answer, Block, Info, SessionEvent, Settings, Status } from '../../emx/daemon/protocol.ts'

const exec = promisify(execFile)
const fakeAgy = fileURLToPath(new URL('./fixtures/agy.mjs', import.meta.url))

async function until(predicate: () => boolean, description = 'condition'): Promise<void> {
  for (let i = 0; i < 500; i++) { if (predicate()) return; await delay(10) }
  throw new Error('Timed out: ' + description)
}

function makeHost(root: string, options: {
  settings?: Settings
  config?: Partial<AgentConfig>
  blocks?: Block[]
  onAsk?: (ask: NewAsk) => Promise<Answer> | Answer
} = {}) {
  const blocks: Block[] = [...(options.blocks ?? [])]
  const events: SessionEvent[] = []
  const asks: NewAsk[] = []
  let info: Info = {}
  let status: Status = 'starting'
  let nextId = 0

  const host: SessionHost = {
    agent: 'agy',
    root,
    settings: { ...options.settings },
    get info() { return info },
    blocks,
    id: 'sess-agy-test',
    daemonSocket: '/tmp/fake-emx.sock',
    async restart() {},
    agentConfig: () => ({ title: 'Antigravity', executable: fakeAgy, ...options.config }),
    editorTools: () => ({
      tools: [
        { name: 'context', description: 'Context', inputSchema: { type: 'object' } },
        { name: 'open', description: 'Open', inputSchema: { type: 'object' } },
      ],
      readOnly: ['context'],
    }),
    emit(event) { events.push(event) },
    setStatus(next) { status = next },
    setInfo(patch) { info = { ...info, ...patch } },
    addBlock(block) { blocks.push(block) },
    append(id, text) {
      const b = blocks.find((x) => x.id === id)
      if (b && b.type === 'text') b.text += text
    },
    update(id, fields) {
      const b = blocks.find((x) => x.id === id)
      if (b) Object.assign(b, fields)
    },
    remove(ids) {
      for (const id of ids) {
        const i = blocks.findIndex((x) => x.id === id)
        if (i >= 0) blocks.splice(i, 1)
      }
    },
    async ask(ask) {
      asks.push(ask)
      return options.onAsk ? await options.onAsk(ask) : { choice: 'allow' }
    },
    newId(prefix) { return `${prefix}-${++nextId}` },
  }
  return { host, blocks, events, asks, getStatus: () => status, getInfo: () => info }
}

async function withLog(t: TestContext) {
  const dir = await realpath(await mkdtemp(join(tmpdir(), 'emx-agy-')))
  const log = join(dir, 'agy.jsonl')
  const prevLog = process.env.EMX_AGY_LOG
  process.env.EMX_AGY_LOG = log
  await chmod(fakeAgy, 0o755)
  t.after(async () => {
    if (prevLog === undefined) delete process.env.EMX_AGY_LOG
    else process.env.EMX_AGY_LOG = prevLog
    await rm(dir, { recursive: true, force: true })
  })
  const requests = async () => (await readFile(log, 'utf8')).trim().split('\n').map((l) => JSON.parse(l))
  return { dir, requests }
}

test('parseCapabilities groups model efforts and maps ACP modes', () => {
  const caps = parseCapabilities({
    models: {
      availableModels: [
        { modelId: 'fake-pro-xhigh', name: 'Pro XHigh' },
        { modelId: 'fake-pro-low', name: 'Pro Low' },
        { modelId: 'fake-pro-high', name: 'Pro High' },
        { modelId: 'fake-oss-medium', name: 'Fake OSS' },
      ],
    },
    configOptions: [
      {
        id: 'model', currentValue: 'fake-pro',
        options: [
          { value: 'fake-pro', name: 'Fake Pro' },
          { value: 'fake-oss-medium', name: 'Fake OSS (Medium)' },
        ],
      },
      {
        id: 'mode', currentValue: 'default',
        options: [
          { value: 'default', name: 'Default' },
          { value: 'accept-edits', name: 'Accept edits' },
          { value: 'auto', name: 'Auto' },
          { value: 'plan', name: 'Plan' },
        ],
      },
    ],
  }, { models: { include: ['^fake-'], exclude: ['oss'] } })
  assert.deepEqual(caps.models, [{ id: 'fake-pro', name: 'Fake Pro', efforts: ['low', 'high', 'xhigh'] }])
  assert.deepEqual(caps.modes, ['ask', 'edits', 'auto', 'guardian', 'plan'])
})

test('toolView and toolOutput normalize ACP tool calls', () => {
  const cmd = toolView('/repo', {
    name: 'run_command', kind: 'execute', title: 'echo hi',
    rawInput: { CommandLine: 'echo hi' },
    content: [{ type: 'content', content: { type: 'text', text: 'hi\n' } }],
  })
  assert.deepEqual(cmd, { kind: 'command', name: 'run_command', title: 'echo hi', command: 'echo hi' })
  assert.equal(toolOutput({ content: [{ type: 'content', content: { type: 'text', text: 'hi\n' } }] }), 'hi\n')

  const edit = toolView('/repo', {
    name: 'edit_file', kind: 'edit', locations: [{ path: '/repo/src/a.ts' }],
    content: [{ type: 'diff', path: '/repo/src/a.ts', oldText: 'a\n', newText: 'b\n' }],
  })
  assert.equal(edit.kind, 'edit')
  assert.equal(edit.path, 'src/a.ts')
  assert.match(edit.diff ?? '', /-a\n\+b/)

  const mcp = toolView('/repo', { name: 'mcp__emacs__context', kind: 'other' })
  assert.equal(mcp.kind, 'mcp')
  assert.equal(mcp.title, 'emacs · context')
})

test('AgyBackend starts, injects MCP + system prompt, streams turns, approves tools and accounts usage', async (t) => {
  const { dir, requests } = await withLog(t)
  const img = join(dir, 'shot.png')
  await writeFile(img, Buffer.from([0x89, 0x50, 0x4e, 0x47]))

  const { host, blocks, events, asks, getStatus, getInfo } = makeHost(dir, {
    settings: { model: 'fake-flash', effort: 'low', mode: 'auto' },
    onAsk: () => ({ choice: 'always' }),
  })
  const backend = new AgyBackend(host)
  t.after(() => backend.stop())

  await backend.start()
  assert.equal(getStatus(), 'idle')
  assert.equal(backend.resumeId(), 'agy-sess-1')
  assert.equal(getInfo().model, 'fake-flash')

  const log1 = await requests()
  const sessionNew = log1.find((r) => r.method === 'session/new')
  assert.equal(sessionNew.params.cwd, dir)
  assert.equal(sessionNew.params.mcpServers[0].name, 'emacs')
  assert.deepEqual(sessionNew.params.mcpServers[0].env, [
    { name: 'EMX_DAEMON_SOCKET', value: '/tmp/fake-emx.sock' },
    { name: 'EMX_SESSION', value: 'sess-agy-test' },
  ])
  assert.match(sessionNew.params._meta.antigravity.systemPrompt.append, /Emacs/)
  assert.ok(log1.some((r) => r.method === 'session/set_config_option' && r.params.configId === 'model' && r.params.value === 'fake-flash'))
  assert.ok(log1.some((r) => r.method === 'session/set_config_option' && r.params.configId === 'thought_level' && r.params.value === 'low'))
  assert.ok(log1.some((r) => r.method === 'session/set_config_option' && r.params.configId === 'mode' && r.params.value === 'auto'))

  await backend.send('readonly-mcp run-cmd show-plan', [img], 'user-1')
  await until(() => getStatus() === 'idle' && events.some((e) => e.type === 'usage/end'), 'turn idle')

  // Audited read-only emacs MCP tool is auto-approved; run_command asks the user.
  assert.equal(asks.length, 1)
  assert.equal(asks[0].type, 'approval')
  if (asks[0].type === 'approval') {
    assert.equal(asks[0].tool, 'call-cmd')
    assert.deepEqual(asks[0].choices, ['allow', 'always', 'deny'])
  }

  assert.ok(blocks.some((b) => b.type === 'text' && b.kind === 'thinking' && b.text === 'Thinking step' && b.done))
  assert.ok(blocks.some((b) => b.type === 'text' && b.kind === 'assistant' && b.text === 'Done: readonly-mcp run-cmd show-plan' && b.done))
  assert.ok(blocks.some((b) => b.type === 'tool' && b.id === 'call-ro' && b.status === 'done' && b.output === 'buffer: init.el'))
  assert.ok(blocks.some((b) => b.type === 'tool' && b.id === 'call-cmd' && b.status === 'done' && b.output === 'hi\n'))
  assert.ok(blocks.some((b) => b.type === 'tool' && b.view.kind === 'plan' && b.view.items?.length === 2))
  assert.equal(getInfo().title, 'Auto Title')
  assert.equal(getInfo().tokens, 1234)

  const usageCall = events.find((e) => e.type === 'usage/call')
  assert.ok(usageCall && usageCall.type === 'usage/call')
  assert.deepEqual(usageCall.usage, { input: 100, cacheRead: 50, cacheWrite: 10, output: 25 })

  const log2 = await requests()
  const promptReq = log2.find((r) => r.method === 'session/prompt')
  assert.equal(promptReq.params.prompt[1].type, 'image')
  assert.equal(promptReq.params.prompt[1].mimeType, 'image/png')
})

test('AgyBackend interrupts with session/cancel and resumes with load or resume', async (t) => {
  const { dir, requests } = await withLog(t)

  // Interrupt
  const { host, blocks, getStatus } = makeHost(dir)
  const backend = new AgyBackend(host)
  t.after(() => backend.stop())
  await backend.start()
  await backend.send('cancel-me')
  await until(() => blocks.some((b) => b.type === 'text' && b.kind === 'thinking'), 'thinking started')
  backend.interrupt()
  await until(() => getStatus() === 'idle', 'cancelled idle')
  assert.ok(blocks.some((b) => b.type === 'notice' && b.notice.kind === 'interrupted'))

  // Resume with empty blocks -> session/load replays history
  const loadCtx = makeHost(dir)
  const loader = new AgyBackend(loadCtx.host)
  t.after(() => loader.stop())
  await loader.start('old-session-id')
  assert.ok(loadCtx.blocks.some((b) => b.type === 'user' && b.text === 'Past question'))
  assert.ok(loadCtx.blocks.some((b) => b.type === 'text' && b.kind === 'assistant' && b.text === 'Past answer'))
  assert.ok(loadCtx.blocks.some((b) => b.type === 'notice' && b.notice.kind === 'history-end'))

  // Resume with existing blocks -> session/resume without duplicating blocks
  const resumeCtx = makeHost(dir, {
    blocks: [{ id: 'u1', type: 'user', text: 'Existing' }],
  })
  const resumer = new AgyBackend(resumeCtx.host)
  t.after(() => resumer.stop())
  await resumer.start('old-session-id')
  assert.equal(resumeCtx.blocks.length, 1)
  const log = await requests()
  assert.ok(log.some((r) => r.method === 'session/resume' && r.params.sessionId === 'old-session-id'))
})

test('agentModels and history discover agy models and worktree sessions', async (t) => {
  const { dir } = await withLog(t)
  const root = join(dir, 'repo'), other = join(dir, 'other')
  await mkdir(root)
  await exec('git', ['init', '-q', root])
  await exec('git', ['-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'Empty', '--allow-empty'])
  await exec('git', ['-C', root, 'worktree', 'add', '-qb', 'other', other])

  const cfg: AgentConfig = { title: 'Antigravity', executable: fakeAgy }
  const models = await agentModels('agy', cfg, root)
  assert.deepEqual(models.map((m) => m.id), ['fake-pro', 'fake-flash', 'fake-oss-medium'])

  const prevHist = process.env.EMX_AGY_HISTORY
  process.env.EMX_AGY_HISTORY = JSON.stringify([
    { sessionId: 's-main', cwd: root, title: 'Main session', updatedAt: '2026-11-19T01:00:00Z' },
    { sessionId: 's-wt', cwd: other, title: 'Worktree session', updatedAt: '2026-11-19T02:00:00Z' },
    { sessionId: 's-foreign', cwd: '/unrelated', title: 'Foreign', updatedAt: '2026-11-19T03:00:00Z' },
  ])
  t.after(() => {
    if (prevHist === undefined) delete process.env.EMX_AGY_HISTORY
    else process.env.EMX_AGY_HISTORY = prevHist
  })
  const items = await history('agy', root, cfg)
  assert.equal(items.length, 2)
  assert.equal(items[0].id, 's-wt')
  assert.equal(items[0].worktree, 'other')
  assert.equal(items[0].root, other)
  assert.equal(items[1].id, 's-main')
})
