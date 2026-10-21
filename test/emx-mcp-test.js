// The agent MCP entry requires its daemon; bare CLI still uses emacsclient.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const state = path.join(__dirname, '../var/emx');
// The live daemon of the checkout Emacs runs from keeps its state there.
const stateNames = () => fs.existsSync(state) ? fs.readdirSync(state) : [];
const stateBefore = new Set(stateNames());
test.afterEach(() => assert.deepEqual(stateNames().filter((name) => !stateBefore.has(name)), [],
  'Tests must not write to the checkout default var/emx directory'));

test('MCP refuses the removed emacsclient transport without a daemon binding', () => {
  const result = spawnSync(process.execPath, [path.join(__dirname, '../bin/emx'), 'mcp'], {
    env: { ...process.env, EMX_DAEMON_SOCKET: '', EMX_SESSION: '', EMX_EMACSCLIENT: '/usr/bin/false' },
    input: '', encoding: 'utf8', timeout: 10000,
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /EMX_DAEMON_SOCKET|EMX_SESSION/);
});

test('bare command-line help retains the emacsclient dispatcher', () => {
  const fs = require('node:fs'), os = require('node:os');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'emx-cli-'));
  try {
    const client = path.join(dir, 'emacsclient');
    fs.writeFileSync(client, `#!${process.execPath}\nconst fs=require('node:fs');\n` +
      `const files=process.argv.at(-1).match(/"([^"\\\\]|\\\\.)*"/g).map(JSON.parse);\n` +
      `fs.writeFileSync(files[1], JSON.stringify({ok:true,result:[{name:'context',description:'Context',inputSchema:{properties:{},required:[]}}]}));\n`, {mode:0o700});
    const result = spawnSync(process.execPath, [path.join(__dirname, '../bin/emx'), 'help'], {
      env: {...process.env, EMX_EMACSCLIENT: client}, encoding:'utf8', timeout:5000,
    });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /context/);
  } finally { fs.rmSync(dir, {recursive:true,force:true}); }
});
