// cli.test.ts --- compiled bare CLI behavior, without a user's Emacs or state.
import './fixtures/environment.ts'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import * as fs from 'node:fs'
import { join, resolve } from 'node:path'
import { test } from 'node:test'
import type { TestContext } from 'node:test'

const root = resolve(import.meta.dirname, '../..')
const definition = { name: 'open', description: 'Open a file\nFull description.', inputSchema: {
  properties: { path: { type: 'string', description: 'File path' } }, required: ['path'],
} }

function fixture(t: TestContext) {
  const dir = fs.realpathSync(fs.mkdtempSync('/tmp/emx-cli-'))
  const client = join(dir, 'emacsclient'), log = join(dir, 'calls.jsonl')
  fs.writeFileSync(client, `#!${process.execPath}
const fs = require('node:fs');
const [request, response] = process.argv.at(-1).match(/"([^"\\\\]|\\\\.)*"/g).map(JSON.parse);
const call = JSON.parse(fs.readFileSync(request, 'utf8'));
fs.appendFileSync(process.env.EMX_CLI_LOG, JSON.stringify({...call, request, response,
  socket: process.env.EMACS_SOCKET_NAME}) + '\\n');
if (process.env.EMX_CLI_SCENARIO === 'client-error') { console.error('test client failure'); process.exit(7); }
if (process.env.EMX_CLI_SCENARIO === 'invalid') { fs.writeFileSync(response, '{'); process.exit(); }
const pending = process.env.EMX_CLI_SCENARIO === 'pending';
const result = process.env.EMX_CLI_SCENARIO === 'error' ? {ok: false, error: 'Editor failure'}
  : pending && call.method !== '_poll' ? {ok: true, pending: 'test-pending'}
  : {ok: true, result: call.method === 'describe' ? [${JSON.stringify(definition)}]
    : call.method === '_poll' ? 'finished' : call.params};
fs.writeFileSync(response, JSON.stringify(result));
`, { mode: 0o700 })
  const run = (args: string[], input?: string, scenario = '', runtime = root) => spawnSync(process.execPath,
    [join(runtime, 'bin/emx'), ...args], { cwd: dir, encoding: 'utf8', input, timeout: 20000,
      env: { ...process.env, EMX_EMACSCLIENT: client, EMX_CLI_LOG: log, EMX_CLI_SCENARIO: scenario,
        EMX_AGENT_BUFFER: '*test agent*', EMACS_SOCKET_NAME: 'isolated-test-server' } })
  const calls = (): any[] => fs.readFileSync(log, 'utf8').trim().split('\n').map((line) => JSON.parse(line))
  t.after(() => {
    try {
      if (fs.existsSync(log)) for (const call of calls()) {
        assert.equal(fs.existsSync(call.request), false, 'request directory must be removed')
        assert.equal(fs.existsSync(call.response), false, 'response directory must be removed')
      }
    } finally { fs.rmSync(dir, { recursive: true, force: true }) }
  })
  return { dir, run, calls }
}

function output(result: ReturnType<typeof spawnSync>): any {
  assert.equal(result.status, 0, String(result.stderr))
  assert.equal(String(result.stderr), '')
  return JSON.parse(String(result.stdout))
}

test('compiled CLI preserves positional/flag parsing, paths, stdin and reload dispatch', (t) => {
  const { dir, run, calls } = fixture(t)
  assert.deepEqual(output(run(['open', 'relative.rs', '42', '50', '--line=7'])),
    { path: join(dir, 'relative.rs'), line: '7', end_line: '50' })
  assert.deepEqual(output(run(['eval', '(+ 1 2)'])), { code: '(+ 1 2)' })
  assert.deepEqual(output(run(['reload', '--files', '/tmp/a.el /tmp/b.el'])), { files: '/tmp/a.el /tmp/b.el' })
  assert.deepEqual(output(run(['show', '-', '--format', 'org'], '* 标题\n')), { format: 'org', content: '* 标题\n' })
  const page = { title: 'Page', blocks: [{ type: 'text', text: 'Body' }] }
  fs.writeFileSync(join(dir, 'page.json'), JSON.stringify(page))
  assert.deepEqual(output(run(['render', 'page.json', '--title=Override'])), { ...page, title: 'Override' })
  assert.deepEqual(output(run(['patch', '-'], JSON.stringify(page))), page)
  for (const call of calls()) {
    assert.deepEqual(call.context, { agent_buffer: '*test agent*' })
    assert.equal(call.socket, 'isolated-test-server')
  }
})

test('help aliases and method details keep their exact output and error status', (t) => {
  const { run } = fixture(t)
  const expected = 'Usage: emx <method> [positional args] [--key value ...]\n\n' +
    'open  Open a file\n    --path <string> (required)  File path\n\n' +
    'emx help <method>  Show the full description of a method\n' +
    'emx mcp            Run as a stdio MCP server\n' +
    'emx daemon         Run the session daemon (--var DIR, --ensure, --stop)\n' +
    'Usage is served by emx daemon.\n'
  for (const args of [[], ['help'], ['-h'], ['--help']]) {
    const result = run(args)
    assert.equal(result.status, 0, result.stderr)
    assert.equal(result.stdout, expected)
  }
  const detail = run(['help', 'open'])
  assert.equal(detail.status, 0, detail.stderr)
  assert.equal(detail.stdout, `open\n\n${definition.description}\n\nParameters: ${JSON.stringify(definition.inputSchema.properties, null, 2)}\n`)
  const unknown = run(['help', 'unknown'])
  assert.equal(unknown.status, 1)
  assert.equal(unknown.stderr, 'emx: Unknown method: unknown\n')
})

test('deferred calls poll, immediate help cancels, and failures clean up transport files', (t) => {
  const { run, calls } = fixture(t)
  const pending = run(['context'], undefined, 'pending')
  assert.equal(pending.status, 0, pending.stderr)
  assert.equal(pending.stdout, 'finished\n')
  assert.deepEqual(calls().slice(-2).map(({ method, params }) => ({ method, params })),
    [{ method: 'context', params: {} }, { method: '_poll', params: { id: 'test-pending' } }])
  const help = run(['help'], undefined, 'pending')
  assert.equal(help.status, 1)
  assert.equal(help.stderr, 'emx: describe waits for its result; call it through the MCP server or the command line\n')
  assert.deepEqual(calls().at(-1).params, { id: 'test-pending', cancel: true })
  for (const [scenario, message] of [['error', /Editor failure/], ['invalid', /JSON/],
    ['client-error', /Cannot reach Emacs.*test client failure/]] as const) {
    const result = run(['context'], undefined, scenario)
    assert.equal(result.status, 1)
    assert.equal(result.stdout, '')
    assert.match(result.stderr, message)
  }
})

test('manifest-only install runs the same compiled bare CLI without sources or build tools', (t) => {
  const { dir, run } = fixture(t)
  const manifest = output(run(['daemon', '--manifest']))
  const host = join(dir, 'host')
  for (const file of manifest.files) {
    fs.mkdirSync(resolve(host, file, '..'), { recursive: true })
    fs.copyFileSync(join(root, file), join(host, file))
  }
  assert.equal(fs.existsSync(join(host, 'emx/cli')), false)
  assert.equal(fs.existsSync(join(host, 'emx/node_modules')), false)
  assert.deepEqual(output(run(['eval', '(+ 1 2)'], undefined, '', host)), { code: '(+ 1 2)' })
  assert.equal(run(['help', 'open'], undefined, '', host).status, 0)
})
