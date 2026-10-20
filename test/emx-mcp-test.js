// Exercise the stdio server without connecting to the user's Emacs.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

test('tools/list grants no read-only hint, including remote offline fallback', () => {
  for (const remote of ['0', '1']) {
    const result = spawnSync(process.execPath, [path.join(__dirname, '../bin/emx'), 'mcp'], {
      env: { ...process.env, EMX_REMOTE_AGENT: remote, EMX_EMACSCLIENT: '/usr/bin/false',
             EMX_TOOLS_STAMP: '' },
      input: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }) + '\n',
      encoding: 'utf8', timeout: 5000,
    });
    assert.equal(result.status, 0, result.stderr);
    const tools = JSON.parse(result.stdout).result.tools;
    assert.deepEqual(tools.map(t => [t.name, t.annotations?.readOnlyHint]), remote === '1'
      ? [['config_read', undefined], ['config_edit', undefined], ['config_write', undefined]] : []);
  }
});

test('tools/list preserves the internal-classification-free describe result', () => {
  const fs = require('node:fs');
  const os = require('node:os');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'emx-describe-'));
  const fixture = [{ name: 'read_buffer', description: 'Read', inputSchema: { type: 'object' } },
  { name: 'eval', description: 'Execute', inputSchema: { type: 'object' } }];
  try {
    const client = path.join(dir, 'emacsclient');
    fs.writeFileSync(client, `#!${process.execPath}\n` +
      `const fs = require('node:fs');\n` +
      `const files = process.argv.at(-1).match(/"([^"\\\\]|\\\\.)*"/g).map(JSON.parse);\n` +
      `if (JSON.parse(fs.readFileSync(files[0])).method !== 'describe') process.exit(1);\n` +
      `fs.writeFileSync(files[1], JSON.stringify({ok:true,result:${JSON.stringify(fixture)}}));\n`,
      { mode: 0o755 });
    const result = spawnSync(process.execPath, [path.join(__dirname, '../bin/emx'), 'mcp'], {
      env: { ...process.env, EMX_REMOTE_AGENT: '0', EMX_EMACSCLIENT: client, EMX_TOOLS_STAMP: '' },
      input: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }) + '\n',
      encoding: 'utf8', timeout: 5000,
    });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout).result.tools, fixture);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
