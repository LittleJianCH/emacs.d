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
