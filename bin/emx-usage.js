// emx-usage.js --- `emx serve`: the usage service of agent-usage.el.
//
// Emacs records how many tokens the agent sessions it runs use, and what
// their accounts have left.  It only passes those events on: this service
// is the single writer of the two files, sums and forecasts them on
// request, and polls the agents' CLIs for their quota.  It never calls
// Emacs.
//
// Wire format: newline-delimited JSON-RPC 2.0 on stdin/stdout; logs go to
// stderr.  The service exits when stdin closes.
//
// Requests (Emacs -> emx):
//   initialize {usageFile, quotaFile, agents: [name...] (display order),
//               pollInterval (s, 0 = no polling),
//               pollers: {claude?|codex?|dsh?: {command: [argv...]}}}
//                                       -> {quotas: SNAPSHOT}
//   report     {range: today|week|month|all, filter?: {agent?, model?, root?},
//               withoutCache?, now?}   -> REPORT
//   refresh    {force?}                -> {}  polls stale sources (all with force)
//   clear      {}                      -> {}  deletes the ledger
// Notifications (Emacs -> emx):
//   record     {record}   append a ledger record
//   quota      {agent, host, windows?, balance?, plan?, credits?}   merge a reading
// Notifications (emx -> Emacs):
//   quotas     {quotas: SNAPSHOT}      after every change of the quotas
//
// Ledger (usageFile): JSON Lines of {time, agent, root, session, child?,
// model, turns, input, cache_read, cache_write, output}; input excludes
// the cache.  Lines that don't parse (a crash may cut the last one short)
// are skipped.  Another Emacs's service may share both files: records are
// only appended, the ledger is read on from where it was left before each
// report, and the quotas are read again before each merge.
//
// Quotas (quotaFile): an array of {agent, host (null: this machine), time,
// plan?, credits? (number or "unlimited"), balance? ([{amount, currency}]),
// windows: [{id, label, minutes, used (0..1), resets (epoch s),
// history: [[time, used]...]}]}.  A window keeps the readings of its
// current period (same reset time, give or take 10 minutes).
//
// SNAPSHOT: the quota entries in display order (agents' order, this
// machine first), without history; a remote entry on an account already
// listed (same agent, same windows and reset times) has duplicate: true.
//
// REPORT: {range, since, total: SUM, groups: {agent|model|root: [{key,
// ...SUM}]} (most tokens first), buckets: {start, step, count, sums:
// [SUM|null]}, quotas: SNAPSHOT whose windows have forecast (FORECAST or
// null) and wait (seconds until a forecast, or null)}.
// SUM: {input, cache_read, cache_write, output, turns, child_turns, tokens};
// tokens leaves out the cache with withoutCache.
// FORECAST: {rate (fraction per day), projected (fraction used at the
// reset at that rate), exhausts (epoch it runs out first, or null),
// since (start of the readings the rate comes from)}.

'use strict';
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');
const childProcess = require('node:child_process');

const DAY = 86400;
const HISTORY_SIZE = 300;
const POLL_TIMEOUT = 60;
const COUNTERS = ['input', 'cache_read', 'cache_write', 'output'];

// ---------------------------------------------------------------- Files

function parseLines(text, records) {
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    try {
      const record = JSON.parse(line);
      if (record && typeof record === 'object' && typeof record.time === 'number') {
        records.push(record);
      }
    } catch {
      // A line cut short: skipped, the next ones still count.
    }
  }
  return records;
}

function readLedger(file) {
  return readLedgerFrom(file, 0).records;
}

// The records of FILE from byte OFFSET on, and the offset to read from
// next: after the last complete line, so a line being written is read
// once it is whole.  A file shorter than OFFSET (cleared) is read anew.
function readLedgerFrom(file, offset) {
  let size;
  try {
    size = fs.statSync(file).size;
  } catch {
    return { records: [], offset: 0, reset: offset > 0 };
  }
  const reset = size < offset;
  const start = reset ? 0 : offset;
  if (size === start) return { records: [], offset: start, reset };
  const buffer = Buffer.alloc(size - start);
  const fd = fs.openSync(file, 'r');
  try {
    fs.readSync(fd, buffer, 0, buffer.length, start);
  } finally {
    fs.closeSync(fd);
  }
  let end = buffer.lastIndexOf(0x0a) + 1;
  // A last line without a newline is complete only if it parses.
  const tail = buffer.subarray(end).toString('utf8');
  let complete = buffer.subarray(0, end).toString('utf8');
  if (tail.trim()) {
    try {
      JSON.parse(tail);
      complete += tail;
      end = buffer.length;
    } catch { /* still being written, or cut short */ }
  }
  return { records: parseLines(complete, []), offset: start + end, reset };
}

function appendLedger(file, record) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  let prefix = '';
  try {
    const { size } = fs.statSync(file);
    if (size > 0) {
      const fd = fs.openSync(file, 'r');
      const last = Buffer.alloc(1);
      fs.readSync(fd, last, 0, 1, size - 1);
      fs.closeSync(fd);
      // After a line cut short, start a line of our own.
      if (last[0] !== 0x0a) prefix = '\n';
    }
  } catch {
    // No file yet.
  }
  fs.appendFileSync(file, prefix + JSON.stringify(record) + '\n');
}

function readQuotas(file) {
  try {
    const quotas = JSON.parse(fs.readFileSync(file, 'utf8'));
    return Array.isArray(quotas) ? quotas : [];
  } catch {
    return [];
  }
}

function writeQuotas(file, quotas) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temp, JSON.stringify(quotas));
  fs.renameSync(temp, file);
}

// ---------------------------------------------------------------- Quotas

function samePeriod(a, b) {
  return a.resets != null && b.resets != null && Math.abs(a.resets - b.resets) < 600;
}

// Windows OLD updated by FRESH, matched by id: the fresh ones first, then
// the old ones not updated.  Each keeps the readings of its period.
function mergeWindows(old, fresh, now) {
  const updated = fresh.map((window) => {
    const previous = old.find((w) => w.id === window.id);
    const history = previous && samePeriod(previous, window) ? previous.history || [] : [];
    const { history: _ignored, ...rest } = window;
    return { ...rest, history: [...history, [now, window.used ?? 0]].slice(-HISTORY_SIZE) };
  });
  return updated.concat(old.filter((w) => !fresh.some((f) => f.id === w.id)));
}

// Merge READING {agent, host, windows?, balance?, plan?, credits?} into
// QUOTAS (in place); a missing or null prop keeps the known value.
function mergeQuota(quotas, reading, now) {
  const host = reading.host ?? null;
  const index = quotas.findIndex((q) => q.agent === reading.agent && (q.host ?? null) === host);
  const entry = index >= 0 ? { ...quotas[index] } : { agent: reading.agent, host, windows: [] };
  for (const key of ['windows', 'balance', 'plan', 'credits']) {
    const value = reading[key];
    if (value == null) continue;
    entry[key] = key === 'windows' ? mergeWindows(entry.windows || [], value, now) : value;
  }
  entry.windows = entry.windows || [];
  entry.time = now;
  if (index >= 0) quotas[index] = entry;
  else quotas.push(entry);
  return entry;
}

function account(entry) {
  if (!entry.windows || !entry.windows.length) return null;
  return JSON.stringify(entry.windows.map((w) => [w.id, w.resets]).sort());
}

// The entries in display order, remote duplicates marked; MAP turns each
// window into what is shown (default: without its history).
function snapshot(quotas, agents, map = ({ history, ...rest }) => rest) {
  const rank = (q) => (q.host ? 100 : 0) + (agents.includes(q.agent) ? agents.indexOf(q.agent) : 99);
  const sorted = quotas.map((q, i) => [q, i])
    .sort((a, b) => rank(a[0]) - rank(b[0]) || a[1] - b[1])
    .map(([q]) => q);
  const shown = [];
  return sorted.map((q) => {
    const key = account(q);
    const duplicate = Boolean(q.host && key &&
      shown.some((other) => other.agent === q.agent && account(other) === key));
    if (!duplicate) shown.push(q);
    const entry = { ...q, windows: (q.windows || []).map(map) };
    if (duplicate) entry.duplicate = true;
    return entry;
  });
}

// ---------------------------------------------------------------- Forecast

function lookback(window) {
  return Math.max(3600, (window.minutes * 60) / 7);
}

function usedAt(history, time) {
  let used = null;
  for (const [at, value] of history) {
    if (at > time) break;
    used = value;
  }
  return used;
}

// Where WINDOW is heading at the pace of its recent readings: the last
// seventh of the window (a day for a weekly one), so idle days don't make
// the rest look plentiful.  Null until the readings cover half of that.
function forecast(window, now) {
  const { resets, minutes } = window;
  if (resets == null || minutes == null || now >= resets) return null;
  const history = window.history || [];
  const span = lookback(window);
  const from = now - span;
  const used = window.used ?? 0;
  let base = null;
  const then = usedAt(history, from);
  if (then != null) base = [from, then];
  else if (history.length && history[0][0] <= now - span / 2) base = history[0];
  if (!base || now <= base[0]) return null;
  const rate = Math.max(0, used - base[1]) / (now - base[0]);
  const projected = used + rate * (resets - now);
  return {
    rate: rate * DAY,
    projected,
    exhausts: projected > 1 && rate > 0 ? now + Math.max(0, 1 - used) / rate : null,
    since: base[0],
  };
}

// Seconds until WINDOW's readings allow a forecast, or null.
function forecastWait(window, now) {
  const history = window.history || [];
  if (!history.length || window.minutes == null) return null;
  const due = history[0][0] + lookback(window) / 2;
  return due > now ? due - now : null;
}

// ---------------------------------------------------------------- Report

function midnightOf(time) {
  const date = new Date(time * 1000);
  date.setHours(0, 0, 0, 0);
  return date.getTime() / 1000;
}

function daysBefore(midnight, days) {
  const date = new Date(midnight * 1000);
  date.setDate(date.getDate() - days);
  return date.getTime() / 1000;
}

function rangeStart(range, now) {
  const midnight = midnightOf(now);
  switch (range) {
    case 'today': return midnight;
    case 'week': return daysBefore(midnight, 6);
    case 'month': return daysBefore(midnight, 29);
    default: return 0;
  }
}

function emptySum() {
  return { input: 0, cache_read: 0, cache_write: 0, output: 0, turns: 0, child_turns: 0 };
}

function addRecord(sum, record) {
  for (const key of COUNTERS) sum[key] += Number(record[key]) || 0;
  const turns = Number(record.turns) || 0;
  sum.turns += turns;
  if (record.child) sum.child_turns += turns;
  return sum;
}

function finish(sum, withoutCache) {
  sum.tokens = withoutCache
    ? sum.input + sum.output
    : sum.input + sum.cache_read + sum.cache_write + sum.output;
  return sum;
}

function buckets(range, records, now) {
  const midnight = midnightOf(now);
  switch (range) {
    case 'today': return { start: midnight, step: 3600, count: 24 };
    case 'week': return { start: daysBefore(midnight, 6), step: DAY, count: 7 };
    case 'month': return { start: daysBefore(midnight, 29), step: DAY, count: 30 };
  }
  // Calendar days from the first record's day to today, both included.
  let first = midnight;
  for (const record of records) if (record.time < first) first = record.time;
  first = midnightOf(first);
  const days = Math.round((midnight - first) / DAY) + 1;
  if (days <= 60) {
    return { start: daysBefore(midnight, Math.max(6, days - 1)), step: DAY, count: Math.max(7, days) };
  }
  const weeks = Math.min(52, Math.ceil(days / 7));
  return { start: daysBefore(midnight, 7 * (weeks - 1) + 6), step: 7 * DAY, count: weeks };
}

function report(records, quotas, agents, params = {}) {
  const now = params.now ?? Date.now() / 1000;
  const range = params.range || 'week';
  const filter = params.filter || {};
  const withoutCache = Boolean(params.withoutCache);
  const since = rangeStart(range, now);
  const selected = records.filter((r) => r.time >= since &&
    Object.entries(filter).every(([key, value]) => (r[key] ?? null) === (value ?? null)));

  const total = finish(selected.reduce(addRecord, emptySum()), withoutCache);
  const groups = {};
  for (const key of ['agent', 'model', 'root']) {
    const sums = new Map();
    for (const record of selected) {
      const value = record[key] ?? null;
      if (!sums.has(value)) sums.set(value, emptySum());
      addRecord(sums.get(value), record);
    }
    groups[key] = [...sums.entries()]
      .map(([value, sum]) => ({ key: value, ...finish(sum, withoutCache) }))
      .sort((a, b) => b.tokens - a.tokens);
  }

  const bucketing = buckets(range, selected, now);
  const sums = new Array(bucketing.count).fill(null);
  for (const record of selected) {
    const index = Math.floor((record.time - bucketing.start) / bucketing.step);
    if (index < 0 || index >= bucketing.count) continue;
    sums[index] = addRecord(sums[index] || emptySum(), record);
  }

  return {
    range,
    since,
    total,
    groups,
    buckets: { ...bucketing, sums: sums.map((sum) => sum && finish(sum, withoutCache)) },
    quotas: snapshot(quotas, agents, ({ history, ...window }) => ({
      ...window,
      forecast: forecast({ ...window, history }, now),
      wait: forecast({ ...window, history }, now) ? null : forecastWait({ ...window, history }, now),
    })),
  };
}

// ---------------------------------------------------------------- Polls

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

// The wall-clock time at epoch milliseconds TIME in ZONE, as if in UTC.
function wallTime(time, zone) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat('en-US', {
    timeZone: zone, hourCycle: 'h23',
    year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric',
  }).formatToParts(new Date(time)).map(({ type, value }) => [type, Number(value)]));
  return Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute);
}

// Epoch seconds at which the clocks of time zone ZONE (an IANA name) show
// a wall-clock time: two of them when it repeats as DST ends.
function zonedTimes(year, month, day, hour, minute, zone) {
  const target = Date.UTC(year, month, day, hour, minute);
  let time = target;
  for (let i = 0; i < 3; i++) {
    const wall = wallTime(time, zone);
    if (wall === target) break;
    time += target - wall;
  }
  return [time - 3600000, time, time + 3600000]
    .filter((t) => wallTime(t, zone) === target)
    .map((t) => t / 1000);
}

// "Oct 20 at 2:10am (Asia/Shanghai)": the nearest such time after NOW.
function parseReset(text, now) {
  const match = /^([A-Z][a-z]{2}) (\d{1,2})(?:,? at (\d{1,2})(?::(\d{2}))?\s*(am|pm))?(?: \(([^)]+)\))?$/i
    .exec(text.trim());
  if (!match) return null;
  const month = MONTHS.findIndex((m) => m.toLowerCase() === match[1].toLowerCase());
  if (month < 0) return null;
  let hour = Number(match[3] || 0) % 12;
  if ((match[5] || '').toLowerCase() === 'pm') hour += 12;
  const zone = match[6] || Intl.DateTimeFormat().resolvedOptions().timeZone;
  const year = new Date(now * 1000).getUTCFullYear();
  const candidates = [year - 1, year, year + 1]
    .flatMap((y) => {
      try {
        return zonedTimes(y, month, Number(match[2]), hour, Number(match[4] || 0), zone);
      } catch {
        return [];
      }
    })
    .filter((t) => t >= now - 600);
  return candidates.length ? Math.min(...candidates) : null;
}

// The windows in the text of Claude Code's /usage.
function parseClaudeUsage(text, now) {
  const windows = [];
  for (const line of String(text).split('\n')) {
    const match = /^\s*Current (session|week(?: \(([^)]+)\))?):\s*([0-9.]+)% used(?:\s*·\s*resets (.+?))?\s*$/
      .exec(line);
    if (!match) continue;
    const used = Number(match[3]) / 100;
    const resets = match[4] ? parseReset(match[4], now) : null;
    let window;
    if (match[1] === 'session') {
      window = { id: 'five_hour', label: '5h', minutes: 300 };
    } else if (!match[2] || match[2] === 'all models') {
      window = { id: 'seven_day', label: '周', minutes: 10080 };
    } else {
      const name = match[2];
      window = { id: `seven_day_${name.toLowerCase().replace(/[^a-z0-9]+/g, '_')}`,
                 label: `周·${name}`, minutes: 10080 };
    }
    windows.push({ ...window, used, ...(resets != null ? { resets } : {}) });
  }
  return windows;
}

function windowLabel(minutes) {
  if (minutes == null) return '限额';
  if (minutes === 10080) return '周';
  if (minutes === 1440) return '日';
  if (minutes % 60 === 0) return `${minutes / 60}h`;
  return `${minutes}m`;
}

// Codex's account/rateLimits/read result as a reading.
function codexReading(rateLimits) {
  const windows = [];
  for (const key of ['primary', 'secondary']) {
    const window = rateLimits[key];
    if (!window) continue;
    const minutes = window.windowDurationMins ?? null;
    windows.push({
      id: String(minutes ?? key),
      label: windowLabel(minutes),
      minutes,
      used: (window.usedPercent || 0) / 100,
      ...(window.resetsAt != null ? { resets: window.resetsAt } : {}),
    });
  }
  const reading = { agent: 'codex', host: null, windows };
  const credits = rateLimits.credits;
  if (credits && credits.unlimited) reading.credits = 'unlimited';
  else if (credits && credits.balance != null) reading.credits = Number(credits.balance);
  if (rateLimits.planType) reading.plan = rateLimits.planType;
  return reading;
}

// The poll children still running, killed when the service stops.
const children = new Set();

function start(spawn, command, stdio) {
  const child = spawn(command[0], command.slice(1), { stdio });
  children.add(child);
  child.on('close', () => children.delete(child));
  return child;
}

// Stop CHILD: SIGTERM, then SIGKILL if it is still there 5 s later.
function terminate(child) {
  try { child.kill('SIGTERM'); } catch { /* gone */ }
  const timer = setTimeout(() => {
    if (child.exitCode === null && child.signalCode === null) {
      try { child.kill('SIGKILL'); } catch { /* gone */ }
    }
  }, 5000);
  timer.unref?.();
}

function killChildren() {
  for (const child of children) terminate(child);
}

// Run COMMAND and talk JSON-RPC with it: send the messages of STEPS in
// turn, each after the response to the previous request; resolve with the
// last response's result.  The child is killed afterwards.
function converse(spawn, command, steps, timeout = POLL_TIMEOUT) {
  return new Promise((resolve, reject) => {
    const child = start(spawn, command, ['pipe', 'pipe', 'ignore']);
    let done = false;
    const finishWith = (fn, value) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      terminate(child);
      fn(value);
    };
    const timer = setTimeout(() => finishWith(reject, new Error('timed out')), timeout * 1000);
    child.on('error', (err) => finishWith(reject, err));
    // A child gone before reading what is sent: EPIPE fails this poll only.
    child.stdin.on('error', (err) => finishWith(reject, err));
    child.on('close', () => finishWith(reject, new Error('exited early')));
    let step = 0;
    const next = () => {
      while (step < steps.length) {
        const message = steps[step++];
        child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n');
        if (message.id != null) return;
      }
    };
    readline.createInterface({ input: child.stdout }).on('line', (line) => {
      let message;
      try { message = JSON.parse(line); } catch { return; }
      const expected = [...steps.slice(0, step)].reverse().find((m) => m.id != null);
      if (!expected || message.id !== expected.id || message.method) return;
      if (message.error) return finishWith(reject, new Error(message.error.message || 'error'));
      if (step >= steps.length) return finishWith(resolve, message.result);
      next();
    });
    next();
  });
}

// Run COMMAND to its end; resolve with its stdout.
function capture(spawn, command, timeout = POLL_TIMEOUT) {
  return new Promise((resolve, reject) => {
    const child = start(spawn, command, ['ignore', 'pipe', 'ignore']);
    let out = '';
    const timer = setTimeout(() => { terminate(child); reject(new Error('timed out')); }, timeout * 1000);
    child.stdout.on('data', (chunk) => { out += chunk; });
    child.on('error', (err) => { clearTimeout(timer); reject(err); });
    child.on('close', (code) => {
      clearTimeout(timer);
      if (code === 0) resolve(out);
      else reject(new Error(`exit ${code}`));
    });
  });
}

const FETCHERS = {
  async claude(command, { spawn, now }) {
    const out = await capture(spawn, [...command, '-p', '/usage', '--output-format', 'json',
                                      '--no-session-persistence']);
    const windows = parseClaudeUsage(JSON.parse(out).result, now());
    if (!windows.length) throw new Error('no usage in /usage');
    return { agent: 'claude', host: null, windows };
  },
  async codex(command, { spawn }) {
    const result = await converse(spawn, [...command, 'app-server'], [
      { id: 1, method: 'initialize', params: { clientInfo: { name: 'emx', version: '0' } } },
      { method: 'initialized' },
      { id: 2, method: 'account/rateLimits/read' },
    ]);
    if (!result || !result.rateLimits) throw new Error('no rate limits');
    return codexReading(result.rateLimits);
  },
  async dsh(command, { spawn }) {
    const result = await converse(spawn, command, [{ id: 1, method: 'balance', params: {} }]);
    const balance = (result.balances || [])
      .filter((b) => b.total != null)
      .map((b) => ({ amount: Number(b.total), currency: b.currency }));
    return { agent: 'dsh', host: null, balance };
  },
};

// ---------------------------------------------------------------- Service

class UsageService {
  // OPTIONS: send (message -> void), now (() -> epoch s), spawn, fetchers,
  // log.
  constructor(options = {}) {
    this.send = options.send || (() => {});
    this.now = options.now || (() => Date.now() / 1000);
    this.spawn = options.spawn || childProcess.spawn;
    this.fetchers = { ...FETCHERS, ...(options.fetchers || {}) };
    this.log = options.log || ((text) => process.stderr.write(`emx serve: ${text}\n`));
    this.initialized = false;
    this.busy = new Set();
    this.failures = {};
    this.retryAt = {};
    this.timer = null;
  }

  initialize(params) {
    this.usageFile = params.usageFile;
    this.quotaFile = params.quotaFile;
    this.agents = params.agents || [];
    this.pollInterval = params.pollInterval || 0;
    this.pollers = params.pollers || {};
    this.records = [];
    this.offset = 0;
    this.syncLedger();
    this.quotas = readQuotas(this.quotaFile);
    this.initialized = true;
    if (this.pollInterval > 0 && Object.keys(this.pollers).length) {
      this.timer = setInterval(() => this.pollAll(false), Math.min(this.pollInterval, 60) * 1000);
      this.timer.unref?.();
      this.pollAll(false);
    }
    return { quotas: snapshot(this.quotas, this.agents) };
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    killChildren();
  }

  // Another Emacs may share the files: the ledger is read from where it
  // was left before each report, and the quotas are read before each use.

  syncLedger() {
    const { records, offset, reset } = readLedgerFrom(this.usageFile, this.offset);
    if (reset) this.records = [];
    this.records.push(...records);
    this.offset = offset;
  }

  loadQuotas() {
    this.quotas = readQuotas(this.quotaFile);
    return this.quotas;
  }

  record(params) {
    const record = { ...params.record };
    if (typeof record.time !== 'number') record.time = this.now();
    appendLedger(this.usageFile, record);
  }

  quota(reading) {
    mergeQuota(this.loadQuotas(), reading, this.now());
    writeQuotas(this.quotaFile, this.quotas);
    this.send({ method: 'quotas', params: { quotas: snapshot(this.quotas, this.agents) } });
  }

  report(params) {
    this.syncLedger();
    return report(this.records, this.loadQuotas(), this.agents, params);
  }

  clear() {
    try { fs.unlinkSync(this.usageFile); } catch { /* none */ }
    this.records = [];
    this.offset = 0;
    return {};
  }

  // The latest reading of SOURCE on this machine.
  latest(source) {
    const entry = this.loadQuotas().find((q) => q.agent === source && !q.host);
    return entry ? entry.time : null;
  }

  pollAll(force) {
    return Promise.all(Object.keys(this.pollers).map((source) => this.poll(source, force)));
  }

  async poll(source, force) {
    if (!(this.pollInterval > 0) || this.busy.has(source) || !this.fetchers[source]) return;
    const now = this.now();
    const latest = this.latest(source);
    if (!force) {
      if (latest != null && now - latest < this.pollInterval) return;
      if (this.retryAt[source] && now < this.retryAt[source]) return;
    }
    this.busy.add(source);
    try {
      const reading = await this.fetchers[source](this.pollers[source].command,
                                                  { spawn: this.spawn, now: this.now });
      this.failures[source] = 0;
      this.retryAt[source] = 0;
      this.quota(reading);
    } catch (err) {
      const failures = (this.failures[source] || 0) + 1;
      this.failures[source] = failures;
      this.retryAt[source] = this.now() + Math.min(3600, this.pollInterval * 2 ** failures);
      this.log(`polling ${source} failed: ${err.message}`);
    } finally {
      this.busy.delete(source);
    }
  }

  refresh(params) {
    this.pollAll(Boolean(params.force));
    return {};
  }

  // Handle one JSON-RPC MESSAGE; return the response to write, if any.
  handle(message) {
    const { id, method, params = {} } = message;
    const reply = (result) => (id == null ? null : { jsonrpc: '2.0', id, result });
    const fail = (text) => (id == null ? null : { jsonrpc: '2.0', id, error: { code: -32603, message: text } });
    try {
      if (method === 'initialize') return reply(this.initialize(params));
      if (!this.initialized) return fail('not initialized');
      switch (method) {
        case 'record': this.record(params); return reply({});
        case 'quota': this.quota(params); return reply({});
        case 'report': return reply(this.report(params));
        case 'refresh': return reply(this.refresh(params));
        case 'clear': return reply(this.clear());
        default: return id == null ? null : { jsonrpc: '2.0', id, error: { code: -32601, message: `unknown method: ${method}` } };
      }
    } catch (err) {
      this.log(`${method}: ${err.message}`);
      return fail(err.message);
    }
  }
}

// `emx serve`: the service on stdin/stdout.
function serve() {
  const write = (message) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n');
  const service = new UsageService({ send: write });
  const input = readline.createInterface({ input: process.stdin });
  input.on('line', (line) => {
    if (!line.trim()) return;
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      service.log(`not JSON: ${line.slice(0, 80)}`);
      return;
    }
    const response = service.handle(message);
    if (response) process.stdout.write(JSON.stringify(response) + '\n');
  });
  input.on('close', () => {
    service.stop();
    process.exit(0);
  });
}

module.exports = {
  serve, UsageService, report, forecast, forecastWait, snapshot, mergeQuota, mergeWindows,
  readLedger, readLedgerFrom, appendLedger, readQuotas, writeQuotas, parseClaudeUsage, parseReset,
  codexReading, rangeStart, converse, capture,
};
