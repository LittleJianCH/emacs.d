// Port of the emx serve fixture suite. Run: node --test test/emx/usage.test.ts
//
// The fixtures in test/fixtures/usage/ hold five records (a blank line in
// between and a last line cut short), and three quota entries; "now" is
// 2026-10-21 12:00 in Asia/Shanghai.  The expected numbers were worked out
// by hand.


process.env.TZ = 'Asia/Shanghai';

import { test } from 'node:test';
import * as assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { spawn } from 'node:child_process';
import { DaemonServer } from '../../emx/daemon/server.ts';
import { SocketClient } from './client.ts';
import type { QuotaEntry } from '../../emx/usage/types.ts';
import * as usage from '../../emx/usage/service.ts';

const FIXTURES = path.join(import.meta.dirname, '..', 'fixtures', 'usage');
const NOW = 1792555200;
const MIDNIGHT = 1792512000;
const DAY = 86400;
const AGENTS = ['claude', 'codex', 'dsh'];

function close(actual: number, expected: number) {
  assert.ok(Math.abs(actual - expected) < 1e-6, `${actual} is not ${expected}`);
}

function tempFiles() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'emx-usage-test-'));
  const usageFile = path.join(dir, 'agent-usage.jsonl');
  const quotaFile = path.join(dir, 'agent-quota.json');
  fs.copyFileSync(path.join(FIXTURES, 'agent-usage.jsonl'), usageFile);
  fs.copyFileSync(path.join(FIXTURES, 'agent-quota.json'), quotaFile);
  return { dir, usageFile, quotaFile };
}

function fixtureReport(params: any) {
  const records = usage.readLedger(path.join(FIXTURES, 'agent-usage.jsonl'));
  const quotas = usage.readQuotas(path.join(FIXTURES, 'agent-quota.json'));
  return usage.report(records, quotas, AGENTS, { now: NOW, ...params });
}

const tokensOf = (groups: any[]) => groups.map((g) => [g.key, g.tokens]);

test('the week sums, groups and buckets the records', () => {
  const report = fixtureReport({ range: 'week' });
  assert.deepEqual(report.total, {
    input: 165, cache_read: 1500, cache_write: 0, output: 2045,
    turns: 3, child_turns: 1, tokens: 3710,
  });
  assert.deepEqual(tokensOf(report.groups.agent), [['codex', 2000], ['claude', 1110], ['dsh', 600]]);
  assert.deepEqual(tokensOf(report.groups.model), [
    ['gpt-6.1-sol', 2000], ['claude-opus-5-5', 1100],
    ['deepseek-official/deepseek-flash', 600], ['claude-haiku-5-5', 10]]);
  assert.deepEqual(tokensOf(report.groups.root), [['~/b/', 2000], ['~/a/', 1110], ['/rpc:dev:/x/', 600]]);
  assert.equal(report.buckets.start, MIDNIGHT - 6 * DAY);
  assert.equal(report.buckets.step, DAY);
  assert.equal(report.buckets.count, 7);
  assert.deepEqual(report.buckets.sums.map((s) => s && s.tokens), [null, null, null, 600, null, null, 3110]);
});

test('without the cache, tokens are input and output', () => {
  const report = fixtureReport({ range: 'week', withoutCache: true });
  assert.deepEqual(tokensOf(report.groups.agent), [['codex', 2000], ['claude', 110], ['dsh', 100]]);
});

test('today buckets by hour; all spans every record; filters narrow', () => {
  const today = fixtureReport({ range: 'today' });
  assert.deepEqual([today.buckets.start, today.buckets.step, today.buckets.count], [MIDNIGHT, 3600, 24]);
  assert.equal(today.buckets.sums[10].tokens, 1100);
  assert.equal(today.buckets.sums[11].tokens, 2010);
  const all = fixtureReport({ range: 'all' });
  assert.equal(all.buckets.start, MIDNIGHT - 40 * DAY);
  assert.equal(all.buckets.count, 41);
  assert.equal(all.total.turns, 4);
  assert.equal(fixtureReport({ range: 'week', filter: { agent: 'claude' } }).total.tokens, 1110);
});

test('quotas come in display order with their forecasts', () => {
  const { quotas } = fixtureReport({ range: 'week' });
  assert.deepEqual(quotas.map((q) => [q.agent, q.host]), [['claude', null], ['dsh', null], ['codex', 'dev']]);
  const [fiveHour, sevenDay] = quotas[0].windows;
  assert.equal(fiveHour.forecast, null);
  assert.equal(fiveHour.wait, 1200);
  assert.equal(fiveHour.history, undefined);
  close(sevenDay.forecast.rate, 0.2);
  close(sevenDay.forecast.projected, 1.0);
  assert.equal(sevenDay.forecast.exhausts, null);
  assert.equal(sevenDay.forecast.since, NOW - DAY);
  const codex = quotas[2].windows[0].forecast;
  close(codex.rate, 0.3);
  close(codex.projected, 1.6);
  close(codex.exhausts, NOW + 2 * DAY);
  assert.equal(quotas[2].credits, 'unlimited');
  assert.deepEqual(quotas[1].balance, [{ amount: 9.03, currency: 'CNY' }]);
});

test('the forecast follows the recent trend', () => {
  const weekly = (used: number, history: number[][]) => ({ id: 'seven_day', minutes: 10080, used, resets: NOW + 4 * DAY, history });
  // Idle over the weekend, 20% today, four days left: right on pace.
  close(usage.forecast(weekly(0.2, [[NOW - 3 * DAY, 0], [NOW - DAY, 0], [NOW, 0.2]]), NOW)!.projected, 1);
  // Minutes of readings tell nothing yet; half a day does.
  assert.equal(usage.forecast(weekly(0.12, [[NOW - 600, 0.1], [NOW, 0.12]]), NOW), null);
  close(usage.forecast(weekly(0.12, [[NOW - DAY / 2, 0.1], [NOW, 0.12]]), NOW)!.rate, 0.04);
  // Past its reset, a window has none.
  assert.equal(usage.forecast({ ...weekly(0.5, []), resets: NOW - 1 }, NOW), null);
});

test('the ledger skips broken lines and appends after a cut-short one', () => {
  const { dir, usageFile } = tempFiles();
  try {
    assert.equal(usage.readLedger(usageFile).length, 5);
    usage.appendLedger(usageFile, { time: NOW, agent: 'claude', input: 1 });
    const records = usage.readLedger(usageFile);
    assert.equal(records.length, 6);
    assert.equal(records[5].input, 1);
  } finally {
    fs.rmSync(dir, { recursive: true });
  }
});

test('quota readings merge, keep their period and round-trip', () => {
  const quotas: QuotaEntry[] = [];
  const window = (id: string, used: number, resets: number) => ({ id, label: id, minutes: 10080, used, resets });
  usage.mergeQuota(quotas, { agent: 'codex', host: null, windows: [window('a', 0.1, 1000), window('b', 0.5, 1000)],
                             credits: 42 }, 1);
  usage.mergeQuota(quotas, { agent: 'codex', host: null, windows: [window('a', 0.2, 1100)] }, 2);
  let [entry] = quotas;
  assert.deepEqual(entry.windows.map((w) => w.id), ['a', 'b']);
  assert.deepEqual(entry.windows[0].history, [[1, 0.1], [2, 0.2]]);
  assert.equal(entry.credits, 42);
  usage.mergeQuota(quotas, { agent: 'codex', host: null, windows: [window('a', 0.01, 900000)],
                             credits: 'unlimited' }, 3);
  [entry] = quotas;
  assert.deepEqual(entry.windows[0].history, [[3, 0.01]]);
  assert.equal(entry.credits, 'unlimited');
  // A remote host on the same account is a duplicate.
  usage.mergeQuota(quotas, { agent: 'codex', host: 'dev', windows: entry.windows.map(({ history, ...w }) => w) }, 4);
  const shown = usage.snapshot(quotas, AGENTS);
  assert.deepEqual(shown.map((q) => [q.host, Boolean(q.duplicate)]), [[null, false], ['dev', true]]);
  assert.equal(shown[0].windows[0].history, undefined);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'emx-usage-test-'));
  try {
    const file = path.join(dir, 'quota.json');
    usage.writeQuotas(file, quotas);
    assert.deepEqual(usage.readQuotas(file), quotas);
  } finally {
    fs.rmSync(dir, { recursive: true });
  }
});

test("Claude's /usage text becomes windows", () => {
  const text = [
    'You are currently using your subscription to power your Claude Code usage',
    '',
    'Current session: 67% used · resets Oct 20 at 2:10am (Asia/Shanghai)',
    'Current week (all models): 19% used · resets Oct 24 at 11am (Asia/Shanghai)',
    'Current week (Fable): 0% used · resets Oct 24 at 11am (Asia/Shanghai)',
  ].join('\n');
  assert.deepEqual(usage.parseClaudeUsage(text, 1792423200), [
    { id: 'five_hour', label: '5h', minutes: 300, used: 0.67, resets: 1792433400 },
    { id: 'seven_day', label: '周', minutes: 10080, used: 0.19, resets: 1792810800 },
    { id: 'seven_day_fable', label: '周·Fable', minutes: 10080, used: 0, resets: 1792810800 },
  ]);
});

test("Codex's rate limits become a reading", () => {
  assert.deepEqual(usage.codexReading({
    primary: { usedPercent: 15, windowDurationMins: 10080, resetsAt: 5 },
    secondary: null,
    credits: { unlimited: false, balance: '62500.0' },
    planType: 'pro',
  }), {
    agent: 'codex', host: null, plan: 'pro', credits: 62500,
    windows: [{ id: '10080', label: '周', minutes: 10080, used: 0.15, resets: 5 }],
  });
});

test('polls skip fresh sources, back off on failure and push quotas', async () => {
  const { dir, usageFile, quotaFile } = tempFiles();
  let now = NOW;
  const sent: any[] = [];
  const calls = { claude: 0, dsh: 0 };
  const service = new usage.UsageService({
    send: (message) => sent.push(message),
    now: () => now,
    log: () => {},
    fetchers: {
      async claude() {
        calls.claude++;
        return { agent: 'claude', host: null, windows: [{ id: 'seven_day', label: '周', minutes: 10080, used: 0.3, resets: NOW + 4 * DAY }] };
      },
      async dsh() {
        calls.dsh++;
        throw new Error('no key');
      },
    },
  });
  try {
    // Readings of the fixtures are a minute old: younger than the interval.
    service.initialize({ usageFile, quotaFile, agents: AGENTS, pollInterval: 900, pollers: { claude: { command: ['x'] }, dsh: { command: ['y'] } } });
    service.stop();
    await service.pollAll(false);
    assert.deepEqual(calls, { claude: 0, dsh: 0 });
    // Forced, both are polled: one pushes quotas, the other fails.
    await service.pollAll(true);
    assert.deepEqual(calls, { claude: 1, dsh: 1 });
    assert.equal(sent.length, 1);
    assert.equal(sent[0].method, 'quotas');
    assert.equal(service.quotas.find((q) => q.agent === 'claude')!.windows.find((w) => w.id === 'seven_day')!.used, 0.3);
    // 1000 s later the stale claude is polled again; dsh waits out its
    // backoff, twice the interval.
    now += 1000;
    await service.pollAll(false);
    assert.deepEqual(calls, { claude: 2, dsh: 1 });
  } finally {
    fs.rmSync(dir, { recursive: true });
  }
});

test('the daemon answers usage requests over its socket', async () => {
  const { dir, usageFile } = tempFiles();
  const daemon = new DaemonServer({ varDir: dir });
  await daemon.start();
  const client = await SocketClient.connect(daemon.socket);
  try {
    await client.request('hello', {client: 'usage-test', version: daemon.version});
    const init = await client.request('usage/configure', {agents: AGENTS, pollInterval: 0});
    assert.equal(init.quotas.length, 3);
    client.notify('usage/record', {record: {
      time: NOW, agent: 'dsh', root: '~/c/', model: 'm', turns: 1, input: 10,
      cache_read: 0, cache_write: 0, output: 0,
    }});
    const report = await client.request('usage/report', {range: 'week', now: NOW});
    assert.equal(report.total.tokens, 3720);
    assert.equal(usage.readLedger(usageFile).length, 6);
  } finally {
    await client.close();
    await daemon.stop();
    fs.rmSync(dir, {recursive: true});
  }
});

test('a poll child that closes its stdin fails the poll, not the service', async () => {
  // It answers the first request after closing stdin: the second write
  // gets EPIPE.
  const child = 'require("fs").closeSync(0); setTimeout(() => { console.log(JSON.stringify({ id: 1, result: {} })); setTimeout(() => {}, 3000); }, 200);';
  await assert.rejects(usage.converse(spawn, [process.execPath, '-e', child],
                                      [{ id: 1, method: 'a' }, { id: 2, method: 'b' }], 10));
});

test('stopping the service kills the polls still running', async () => {
  const service = new usage.UsageService({ log: () => {} });
  const silent = usage.converse(spawn, [process.execPath, '-e', 'setTimeout(() => {}, 30000)'],
                                [{ id: 1, method: 'a' }], 60);
  const started = Date.now();
  setTimeout(() => service.stop(), 200);
  await assert.rejects(silent);
  assert.ok(Date.now() - started < 10000);
});

test('two services sharing the files see each other', () => {
  const { dir, usageFile, quotaFile } = tempFiles();
  try {
    const make = () => {
      const service = new usage.UsageService({ now: () => NOW, log: () => {} });
      service.initialize({ usageFile, quotaFile, agents: AGENTS, pollInterval: 0 });
      return service;
    };
    const a = make();
    const b = make();
    const record = (input: number) => ({ record: { time: NOW, agent: 'dsh', root: '~/c/', model: 'm', turns: 1, input,
                                           cache_read: 0, cache_write: 0, output: 0 } });
    a.record(record(10));
    b.record(record(20));
    assert.equal(a.report({ range: 'week', now: NOW }).total.tokens, 3710 + 30);
    assert.equal(b.report({ range: 'week', now: NOW }).total.tokens, 3710 + 30);
    a.quota({ agent: 'claude', host: null, plan: 'max' });
    b.quota({ agent: 'codex', host: null, plan: 'pro' });
    const stored = usage.readQuotas(quotaFile);
    assert.equal(stored.find((q) => q.agent === 'claude')!.plan, 'max');
    assert.equal(stored.find((q) => q.agent === 'codex' && !q.host)!.plan, 'pro');
    // Cleared by one, the other starts over too.
    a.clear();
    assert.equal(b.report({ range: 'week', now: NOW }).total.tokens, 0);
  } finally {
    fs.rmSync(dir, { recursive: true });
  }
});

test('a reset time repeated as DST ends is the next one', () => {
  assert.equal(usage.parseReset('Nov 1 at 1:30am (America/New_York)', Date.parse('2026-11-01T06:00:00Z') / 1000),
               Date.parse('2026-11-01T06:30:00Z') / 1000);
});

test('records of no model can be filtered to', () => {
  const records = [{ time: NOW, agent: 'claude', model: null, turns: 1, input: 10, cache_read: 0, cache_write: 0, output: 0 },
                   { time: NOW, agent: 'claude', model: 'm', turns: 1, input: 5, cache_read: 0, cache_write: 0, output: 0 }];
  assert.equal(usage.report(records, [], AGENTS, { range: 'week', now: NOW, filter: { model: null } }).total.tokens, 10);
  assert.deepEqual(usage.report(records, [], AGENTS, { range: 'week', now: NOW }).groups.model.map((g) => g.key), [null, 'm']);
});

test('a large ledger reports over all its time', () => {
  const records = Array.from({ length: 150000 }, (_, i) => ({
    time: NOW - (i % 400) * DAY, agent: 'claude', model: 'm', turns: 1, input: 1, cache_read: 0, cache_write: 0, output: 0,
  }));
  const report = usage.report(records, [], AGENTS, { range: 'all', now: NOW });
  assert.equal(report.total.tokens, 150000);
  assert.equal(report.buckets.step, 7 * DAY);
});
