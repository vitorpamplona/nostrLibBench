// nostrLibBench JavaScript harness: one script for Node, Bun and Deno.
// Contract: ../HARNESS.md. Run through ./run.sh.
//
// Without --child the script is the orchestrator: it re-spawns itself once per client
// (fresh process = fresh JIT profile, heap, module state and library-global caches) and
// merges the rows into one results file. With --child <id> it runs one client over every
// selected workload and prints its rows on stdout as one `@@ROWS <json>` line.

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { CLIENTS, RT, pkgMeta, runtimeInfo } from './clients.mjs';

const SCRIPT = fileURLToPath(import.meta.url);
const HERE = path.dirname(SCRIPT);
const BENCH = path.resolve(HERE, '..');

// ---------------------------------------------------------------- args

function parseArgs(argv) {
  const o = {
    relay: 'ws://127.0.0.1:7777',
    corpus: path.join(BENCH, '.corpus'),
    out: null,
    workloads: ['all'],
    clients: null,
    warmupRuns: 2,
    minRuns: 5,
    minTimeMs: 10000,
    maxRuns: 30,
    timeoutMs: 300000,
    list: false,
    child: null,
  };
  const int = (v, a) => {
    const n = Number(v);
    if (!Number.isInteger(n) || n < 0) throw new Error(`${a} needs a non-negative integer, got ${v}`);
    return n;
  };
  for (let i = 0; i < argv.length; i++) {
    let a = argv[i];
    let inline = null;
    if (a.startsWith('--') && a.includes('=')) {
      inline = a.slice(a.indexOf('=') + 1);
      a = a.slice(0, a.indexOf('='));
    }
    const val = () => {
      if (inline !== null) return inline;
      if (i + 1 >= argv.length) throw new Error(`missing value for ${a}`);
      return argv[++i];
    };
    switch (a) {
      case '--relay': o.relay = val().replace(/\/+$/, ''); break;
      case '--corpus': o.corpus = path.resolve(val()); break;
      case '--out': o.out = path.resolve(val()); break;
      case '--workloads': o.workloads = val().split(',').filter(Boolean); break;
      case '--clients': o.clients = val().split(',').filter(Boolean); break;
      case '--warmup-runs': o.warmupRuns = int(val(), a); break;
      case '--min-runs': o.minRuns = int(val(), a); break;
      case '--min-time-ms': o.minTimeMs = int(val(), a); break;
      case '--max-runs': o.maxRuns = int(val(), a); break;
      case '--timeout-ms': o.timeoutMs = int(val(), a); break;
      case '--quick': o.warmupRuns = 1; o.minRuns = 2; o.minTimeMs = 0; break;
      case '--list': o.list = true; break;
      case '--child': o.child = val(); break;
      default: throw new Error(`unknown argument: ${a}`);
    }
  }
  if (o.warmupRuns < 1) throw new Error('--warmup-runs must be >= 1 (the first warm-up run is first_run_ms)');
  if (o.minRuns < 1) o.minRuns = 1;
  if (o.maxRuns < o.minRuns) o.maxRuns = o.minRuns;
  if (!o.out) o.out = path.join(BENCH, 'results', `${RT}.json`);
  return o;
}

function listedClients() {
  return CLIENTS.filter((c) => !c.runtimes || c.runtimes.includes(RT));
}

// ---------------------------------------------------------------- accepted set

// The XOR of 32-byte ids, as 8 uint32 words.
function xorInto(words, id) {
  for (let i = 0; i < 8; i++) words[i] ^= parseInt(id.substring(i * 8, i * 8 + 8), 16);
}

function wordsHex(words) {
  let s = '';
  for (let i = 0; i < 8; i++) s += (words[i] >>> 0).toString(16).padStart(8, '0');
  return s;
}

function hexWords(hex) {
  const w = new Uint32Array(8);
  xorInto(w, hex);
  return w;
}

// If (accepted, xor) is a correct set (HARNESS.md "Correctness"), which of the optional events
// it holds: { amb, exp } with exp 0 or every expired id, amb the size of a subset of the
// ambiguous ids (every subset when there are few). Null when it is not a correct set.
function explainSet(w, accepted, xor) {
  const amb = w.ambiguous_ids;
  const expired = w.expired_ids ?? [];
  const subsets = amb.length <= 4 ? 1 << amb.length : 2;
  for (const expAll of [true, false]) {
    for (let m = 0; m < subsets; m++) {
      const pick = amb.length <= 4 ? amb.filter((_, i) => m & (1 << i)) : m ? amb : [];
      const n = w.valid_events - (expAll ? 0 : expired.length) + pick.length;
      if (n !== accepted) continue;
      const x = hexWords(w.valid_id_xor);
      if (!expAll) for (const id of expired) xorInto(x, id);
      for (const id of pick) xorInto(x, id);
      if (wordsHex(x) === xor) return { amb: pick.length, exp: expAll ? expired.length : 0 };
    }
  }
  return null;
}

// ---------------------------------------------------------------- one run

const now = () => performance.now();
const cpuMs = (u) => (u.user + u.system) / 1000;

// A library exception that escapes to the event loop (a throw in a socket callback or a
// microtask) ends the current run as an error instead of killing the process.
let activeSink = null;
const seenOutside = new Set();
function trapUncaught() {
  const h = (e) => {
    if (activeSink) activeSink.error(new Error(`uncaught exception in library code: ${e?.name ?? 'Error'}: ${e?.message ?? e}${e?.stack?.split('\n').find((l) => l.trim().startsWith('at '))?.trim().replace(/^at /, ' (at ').concat(')') ?? ''}`));
    else if (!seenOutside.has(String(e?.message ?? e))) {
      seenOutside.add(String(e?.message ?? e));
      process.stderr.write(`    ! uncaught outside a run: ${e?.message ?? e}\n`);
    }
  };
  process.on('uncaughtException', h);
  process.on('unhandledRejection', h);
}

// Runs one subscription end to end (HARNESS.md "A run"). Returns
// { ms, cpu, accepted, xor, ids } or throws. HARNESS.md "Fairness" 5: the per-event callback
// only counts the event and XORs its id; the clock is read only for events that arrive after
// the EOSE (they move the end of the run), the CPU counter at the EOSE and once at the end.
// With `collect` (an extra untimed
// diagnostic run, see runChild) it also keeps the ids.
async function oneRun(C, ctx, url, w, opts, collect = false) {
  // 1. setup, untimed
  const inst = await withTimeout(C.setup(ctx, url, w, opts), opts.timeoutMs, 'setup (connect) timed out');

  const words = new Uint32Array(8);
  const ids = collect ? [] : null;
  let accepted = 0;
  let eoseAt = -1, lastAt = -1, endAt = -1, cpuEnd = null, cpuAt = -1;
  const maxAccept = w.valid_events + w.ambiguous_ids.length;
  let finish;
  const done = new Promise((r) => (finish = r));
  let idleTimer = null;
  const armIdle = () => {
    if (idleTimer) return;
    idleTimer = setInterval(() => {
      // the CPU counter for events that came after the EOSE is read here, at most once per
      // 50 ms tick, never in the per-event callback (it then also counts the idle part of the
      // tick, a few µs of CPU)
      if (lastAt > cpuAt) {
        cpuEnd = process.cpuUsage();
        cpuAt = lastAt;
      }
      if (now() - Math.max(lastAt, eoseAt) >= 1000) finish({ how: 'idle' });
    }, 50);
  };
  const afterEose = () => {
    // events delivered after the EOSE (verification on another thread, a timer, a later
    // microtask) move the end of the run: the clock is read for each of them, the CPU
    // counter once, when the set is complete (else by the idle timer above)
    endAt = lastAt = now();
    if (accepted >= maxAccept) {
      cpuEnd = process.cpuUsage();
      finish({ how: 'complete' });
    }
  };

  const sink = {
    event: collect
      ? (id) => {
          accepted++;
          xorInto(words, id);
          ids.push(id);
          if (eoseAt >= 0) afterEose();
        }
      : (id) => {
          accepted++;
          xorInto(words, id);
          if (eoseAt >= 0) afterEose();
        },
    eose() {
      if (eoseAt >= 0) return;
      cpuEnd = process.cpuUsage();
      const t = now();
      eoseAt = cpuAt = t;
      endAt = t;
      if (accepted >= maxAccept) finish({ how: 'complete' });
      else armIdle();
    },
    error(e) {
      finish({ how: 'error', error: e });
    },
  };

  activeSink = sink;
  const timeout = setTimeout(() => finish({ how: 'timeout' }), opts.timeoutMs);
  // 2. timed
  const cpu0 = process.cpuUsage();
  const t0 = now();
  try {
    const p = C.start(inst, { limit: w.events }, sink, opts);
    if (p && typeof p.then === 'function') p.then(undefined, (e) => sink.error(e));
  } catch (e) {
    sink.error(e);
  }
  const res = await done;
  activeSink = null;
  clearTimeout(timeout);
  if (idleTimer) clearInterval(idleTimer);
  // the run's numbers as they stood when it ended (a late event during teardown changes nothing)
  const out = { ms: endAt - t0, cpu: cpuEnd ? cpuMs(cpuEnd) - cpuMs(cpu0) : null, accepted, xor: wordsHex(words), ids };

  // 4. teardown, untimed (bounded: a library that hangs on close must not hang the run)
  try {
    await withTimeout(Promise.resolve(C.teardown?.(inst)), 10000, 'teardown timed out');
  } catch (e) {
    process.stderr.write(`    ! teardown: ${e?.message ?? e}\n`);
  }

  if (res.how === 'error') throw new Error(`error during the run: ${res.error?.message ?? res.error}`);
  if (res.how === 'timeout') throw new Error(`no EOSE within --timeout-ms ${opts.timeoutMs} (accepted ${accepted} events so far)`);
  return out;
}

function withTimeout(p, ms, msg) {
  let t;
  return Promise.race([
    p,
    new Promise((_, rej) => {
      t = setTimeout(() => rej(new Error(msg)), ms);
    }),
  ]).finally(() => clearTimeout(t));
}

// ---------------------------------------------------------------- child: one client

function percentile(sorted, p) {
  const k = Math.max(0, Math.ceil(p * sorted.length) - 1);
  return sorted[k];
}

function median(sorted) {
  const n = sorted.length;
  return n % 2 ? sorted[(n - 1) >> 1] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
}

const r1 = (x) => (x == null ? null : Math.round(x * 10) / 10);

function baseRow(C, meta, w) {
  return {
    client: C.id,
    library: C.library,
    version: meta.version,
    license: meta.license,
    api: C.api,
    websocket: typeof C.websocket === 'function' ? C.websocket(RT) : C.websocket,
    crypto: C.crypto,
    verify: C.verify,
    notes: C.notes ?? '',
    variant: C.variant === true,
    workload: w.name,
    events: w.events,
    bytes: w.bytes,
    accepted: null,
    accepted_xor: null,
    ambiguous_accepted: null,
    expired_accepted: null,
    accepted_ok: false,
    errors: 0,
    error: null,
    warmup_runs: 0,
    runs: 0,
    first_run_ms: null,
    median_ms: null,
    min_ms: null,
    p90_ms: null,
    run_ms: [],
    events_per_s: null,
    us_per_event: null,
    cpu_ms: null,
    peak_rss_mb: null,
  };
}

async function runChild(opts, workloads) {
  const C = CLIENTS.find((c) => c.id === opts.child);
  if (!C) throw new Error(`unknown client ${opts.child}`);
  trapUncaught();
  let meta = { version: null, license: null };
  let ctx = null;
  let loadError = null;
  try {
    meta = C.meta ? C.meta() : pkgMeta(C.pkg);
    ctx = await C.load(opts);
  } catch (e) {
    loadError = `load failed: ${e?.stack ?? e?.message ?? e}`;
  }
  const rows = [];
  for (const w of workloads) {
    const row = baseRow(C, meta, w);
    rows.push(row);
    if (loadError) {
      row.errors = 1;
      row.error = loadError;
      process.stderr.write(`  ${RT} ${C.id.padEnd(28)} ${w.name.padEnd(9)} ERROR ${loadError.split('\n')[0]}\n`);
      continue;
    }
    const url = `${opts.relay}/${w.name}`;

    let ref = null; // the first run's set
    const runMs = [];
    const cpus = [];
    let measuredMs = 0;
    const total = () => row.warmup_runs + row.runs;
    try {
      for (;;) {
        const warm = row.warmup_runs < opts.warmupRuns;
        if (!warm && (row.runs >= opts.maxRuns || (row.runs >= opts.minRuns && measuredMs >= opts.minTimeMs))) break;
        const r = await oneRun(C, ctx, url, w, opts);
        if (!ref) {
          ref = r;
          row.first_run_ms = r1(r.ms);
        } else if (r.accepted !== ref.accepted || r.xor !== ref.xor) {
          row.errors++;
          if (!row.error) {
            row.error = `run ${total() + 1} delivered a different set than the first run (${r.accepted} events, xor ${r.xor} vs ${ref.accepted}, ${ref.xor})`;
          }
        }
        if (warm) row.warmup_runs++;
        else {
          row.runs++;
          runMs.push(r.ms);
          cpus.push(r.cpu);
          measuredMs += r.ms;
        }
        process.stderr.write(
          `    ${warm ? 'warmup' : 'run   '} ${String(total()).padStart(2)}: ${r.ms.toFixed(1).padStart(9)} ms  cpu ${r.cpu.toFixed(0).padStart(6)} ms  accepted ${r.accepted}\n`,
        );
      }
    } catch (e) {
      row.errors++;
      row.error = e?.message ?? String(e);
      process.stderr.write(`    ! ${row.error}\n`);
    }
    if (ref) {
      row.accepted = ref.accepted;
      row.accepted_xor = ref.xor;
      const how = explainSet(w, ref.accepted, ref.xor);
      if (how) {
        // a correct set: which optional events it took follows from the count and the XOR
        row.accepted_ok = true;
        row.ambiguous_accepted = how.amb;
        row.expired_accepted = how.exp;
      } else {
        // not a correct set: one extra, untimed diagnostic run that keeps the ids says which
        // of the optional events it delivered
        row.accepted_ok = false;
        try {
          const d = await oneRun(C, ctx, url, w, opts, true);
          const got = new Set(d.ids);
          row.ambiguous_accepted = w.ambiguous_ids.filter((id) => got.has(id)).length;
          row.expired_accepted = (w.expired_ids ?? []).filter((id) => got.has(id)).length;
          process.stderr.write(`    diagnostic run: ${d.accepted} events, ${d.accepted - got.size} duplicates, ambiguous ${row.ambiguous_accepted}, expired ${row.expired_accepted}\n`);
        } catch (e) {
          process.stderr.write(`    ! diagnostic run: ${e?.message ?? e}\n`);
        }
      }
    }
    if (row.error === null && runMs.length) {
      const sorted = [...runMs].sort((a, b) => a - b);
      const med = median(sorted);
      row.run_ms = runMs.map(r1);
      row.median_ms = r1(med);
      row.min_ms = r1(sorted[0]);
      row.p90_ms = r1(percentile(sorted, 0.9));
      row.events_per_s = r1(w.events / (med / 1000));
      row.us_per_event = Math.round((med * 1000 / w.events) * 1000) / 1000;
      row.cpu_ms = r1(median([...cpus].sort((a, b) => a - b)));
    } else if (row.error !== null) {
      row.run_ms = [];
      row.first_run_ms = null;
    }
    row.peak_rss_mb = r1(process.resourceUsage().maxRSS / 1024); // maxRSS is in KiB on all three runtimes
    process.stderr.write(
      `  ${RT} ${C.id.padEnd(28)} ${w.name.padEnd(9)} ` +
        (row.median_ms == null ? `ERROR ${row.error}` : `${row.median_ms.toFixed(1).padStart(9)} ms  cpu ${String(row.cpu_ms).padStart(8)} ms`) +
        `  accepted ${row.accepted} (ambiguous ${row.ambiguous_accepted}, expired ${row.expired_accepted}) ok=${row.accepted_ok} rss ${row.peak_rss_mb} MB\n`,
    );
  }
  process.stdout.write('@@ROWS ' + JSON.stringify(rows) + '\n');
  // libraries keep sockets, timers and native threads alive: do not wait for them
  setTimeout(() => process.exit(0), 50);
}

// ---------------------------------------------------------------- orchestrator

function childCommand(args) {
  if (RT === 'deno') return [Deno.execPath(), ['run', '-A', SCRIPT, ...args]];
  if (RT === 'bun') return [process.execPath, [SCRIPT, ...args]];
  return [process.execPath, [...process.execArgv, SCRIPT, ...args]];
}

// Runs a child, streaming its stderr: the harness's own lines pass through; library output
// (some libraries log a warning, with a stack, for every invalid event) is shown for the
// first 12 lines, then only counted.
const HARNESS_LINE = /^(    (warmup|run |! |diagnostic)|  (node|bun|deno) )/;
function runProcess(cmd, args, capMs) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { cwd: HERE, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let buf = '';
    let noise = 0;
    const line = (l) => {
      if (HARNESS_LINE.test(l)) process.stderr.write(l + '\n');
      else if (++noise <= 12) process.stderr.write(`    | ${l}\n`);
    };
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (d) => (stdout += d));
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (d) => {
      buf += d;
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        line(buf.slice(0, i));
        buf = buf.slice(i + 1);
      }
    });
    let error = null;
    const cap = setTimeout(() => {
      error = new Error(`killed after ${capMs} ms`);
      child.kill('SIGKILL');
    }, capMs);
    child.on('error', (e) => (error = e));
    child.on('close', (status, signal) => {
      clearTimeout(cap);
      if (buf) line(buf);
      if (noise > 12) process.stderr.write(`    | (${noise - 12} more lines of library output not shown)\n`);
      resolve({ stdout, status, signal, error });
    });
  });
}

function hostInfo() {
  let cpu = os.cpus()[0]?.model ?? 'unknown';
  try {
    const m = readFileSync('/proc/cpuinfo', 'utf8').match(/^model name\s*:\s*(.+)$/m);
    if (m) cpu = m[1].trim();
  } catch {}
  return { cpu, cores: os.cpus().length, os: `${os.type()} ${os.release()}` };
}

async function main() {
  const opts = parseArgs(RT === 'deno' ? Deno.args : process.argv.slice(2));
  if (opts.list) {
    for (const c of listedClients()) console.log(c.id);
    return;
  }
  const manifestPath = path.join(opts.corpus, 'manifest.json');
  if (!existsSync(manifestPath)) throw new Error(`no corpus at ${opts.corpus}: run python3 corpus/prepare.py`);
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  for (const n of opts.workloads) if (!manifest.workloads.some((w) => w.name === n)) throw new Error(`unknown workload ${n}`);
  const workloads = manifest.workloads.filter((w) => opts.workloads.includes(w.name));

  if (opts.child) return runChild(opts, workloads);

  let clients = listedClients();
  if (opts.clients) {
    for (const n of opts.clients) if (!clients.some((c) => c.id === n)) throw new Error(`unknown client ${n} for ${RT} (see --list)`);
    clients = clients.filter((c) => opts.clients.includes(c.id));
  }

  const passArgs = [
    '--relay', opts.relay,
    '--corpus', opts.corpus,
    '--workloads', workloads.map((w) => w.name).join(','),
    '--warmup-runs', String(opts.warmupRuns),
    '--min-runs', String(opts.minRuns),
    '--min-time-ms', String(opts.minTimeMs),
    '--max-runs', String(opts.maxRuns),
    '--timeout-ms', String(opts.timeoutMs),
  ];
  // generous wall-clock cap for a child, so a library that wedges its process still gets a row
  const childCap = (opts.warmupRuns + opts.maxRuns) * (opts.timeoutMs + 20000) * workloads.length + 120000;
  const results = [];
  for (const c of clients) {
    process.stderr.write(`[${RT}] ${c.id}\n`);
    const [cmd, args] = childCommand([...passArgs, '--child', c.id]);
    const r = await runProcess(cmd, args, childCap);
    const line = (r.stdout ?? '').split('\n').find((l) => l.startsWith('@@ROWS '));
    if (line) {
      results.push(...JSON.parse(line.slice(7)));
    } else {
      const why = `child process failed: exit ${r.status ?? r.signal}${r.error ? ': ' + r.error.message : ''}`;
      process.stderr.write(`  ${why}\n`);
      let meta = { version: null, license: null };
      try {
        meta = c.meta ? c.meta() : pkgMeta(c.pkg);
      } catch {}
      for (const w of workloads) {
        const row = baseRow(c, meta, w);
        row.errors = 1;
        row.error = why;
        results.push(row);
      }
    }
  }

  const doc = {
    harness: RT,
    language: 'JavaScript',
    runtime: runtimeInfo().label,
    host: hostInfo(),
    settings: { warmup_runs: opts.warmupRuns, min_runs: opts.minRuns, min_time_ms: opts.minTimeMs, max_runs: opts.maxRuns, timeout_ms: opts.timeoutMs },
    relay: opts.relay,
    corpus_fingerprint: manifest.fingerprint,
    results,
  };
  mkdirSync(path.dirname(opts.out), { recursive: true });
  writeFileSync(opts.out, JSON.stringify(doc, null, 2) + '\n');
  process.stderr.write(`wrote ${opts.out}\n`);
}

await main();
