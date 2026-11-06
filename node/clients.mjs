// The clients of the JavaScript harness: one entry per library entry point.
//
// Each client: id, library, pkg (whose package.json gives version and license) or meta(),
// api, websocket (string or (runtime) => string), crypto, verify, notes, variant,
// runtimes (where it is listed; default all three), and
//   load(opts)               untimed, once per process: imports, wasm init
//   setup(ctx, url, w, opts) untimed, per run: a NEW client instance, connected when the API allows
//   start(inst, filter, sink, opts)  timed: open the subscription; call sink.event(id) for every
//                            event the library delivers as valid, sink.eose() when the app gets
//                            the EOSE, sink.error(e) on failure (or return a rejecting promise)
//   teardown(inst)           untimed: close the subscription and the client

import { readFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));

export const RT = globalThis.Bun ? 'bun' : globalThis.Deno ? 'deno' : 'node';

export function runtimeInfo() {
  if (RT === 'bun') return { label: `Bun ${Bun.version} (JavaScriptCore, WebKit ${process.versions.webkit.slice(0, 12)})` };
  if (RT === 'deno') return { label: `Deno ${Deno.version.deno} (V8 ${Deno.version.v8})` };
  return { label: `Node.js ${process.versions.node} (V8 ${process.versions.v8})` };
}

// version and SPDX license from the package's own package.json, or its LICENSE file
export function pkgMeta(name) {
  const dir = path.join(HERE, 'node_modules', name);
  const p = JSON.parse(readFileSync(path.join(dir, 'package.json'), 'utf8'));
  let license = typeof p.license === 'string' ? p.license : p.license?.type ?? null;
  if (!license) {
    for (const f of ['LICENSE', 'LICENSE.md', 'LICENSE.txt', 'LICENSE-MIT']) {
      const fp = path.join(dir, f);
      if (!existsSync(fp)) continue;
      const t = readFileSync(fp, 'utf8');
      if (/^\s*MIT License/i.test(t) || /Permission is hereby granted, free of charge/.test(t)) license = 'MIT';
      else if (/unencumbered software released into the public domain/.test(t)) license = 'Unlicense';
      if (license) break;
    }
  }
  return { version: p.version, license };
}

const ver = (name) => pkgMeta(name).version;
const short = (v) => v.split('.').slice(0, 2).join('.');

// The WebSocket client each runtime gives a library, by how the library gets one.
const WS_GLOBAL = {
  node: 'Node global WebSocket (undici)',
  bun: 'Bun global WebSocket (native, Zig)',
  deno: 'Deno global WebSocket (Rust, fastwebsockets)',
};
const wsGlobal = (rt) => WS_GLOBAL[rt];
const wsPackage = (via) => (rt) =>
  rt === 'bun'
    ? `${via} → Bun's built-in 'ws' module (native WebSocket client)`
    : rt === 'deno'
      ? `${via} → ws ${ver('ws')} on Deno's node:http/node:net compat`
      : `${via} → ws ${ver('ws')} (pure JS on node:net)`;

const noble = (owner) => `@noble/curves ${short(nestedVer(owner, '@noble/curves'))} (pure JS)`;

// version of a dependency as resolved for `owner` (nested node_modules first)
function nestedVer(owner, dep) {
  const nested = path.join(HERE, 'node_modules', owner, 'node_modules', dep, 'package.json');
  if (existsSync(nested)) return JSON.parse(readFileSync(nested, 'utf8')).version;
  return ver(dep);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function waitOpen(ws, ms = 10000) {
  return new Promise((resolve, reject) => {
    if (ws.readyState === 1) return resolve();
    const t = setTimeout(() => reject(new Error('socket did not open')), ms);
    ws.addEventListener('open', () => {
      clearTimeout(t);
      resolve();
    }, { once: true });
    ws.addEventListener('error', (e) => {
      clearTimeout(t);
      reject(new Error(`socket error: ${e?.message ?? e}`));
    }, { once: true });
  });
}

async function poll(cond, ms, what) {
  const end = Date.now() + ms;
  while (!cond()) {
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(5);
  }
}

// ---------------------------------------------------------------- nostr-tools

const NT_EOSE =
  'Subscription eoseTimeout raised to --timeout-ms: its default (relay.baseEoseTimeout, 4400 ms) starts at the REQ and fakes an EOSE when it fires, which a slow verifier streaming 31k events would hit long before the real EOSE.';

const nostrToolsRelay = {
  id: 'nostr-tools-relay',
  library: 'nostr-tools',
  pkg: 'nostr-tools',
  api: 'new Relay(url) + relay.connect(), relay.subscribe([filter], {onevent, oneose})',
  websocket: wsGlobal,
  get crypto() {
    return `${noble('nostr-tools')}, @noble/hashes sha256`;
  },
  verify: 'library',
  notes: `verifyEvent from nostr-tools/pure on every EVENT (id = sha256 of JSON.stringify serialization, then schnorr.verify); its verified-symbol cache is a property of each parsed event object, so it never carries across events or runs. matchFilters runs on every event. ${NT_EOSE}`,
  async load() {
    return import('nostr-tools/relay');
  },
  async setup(m, url) {
    const relay = new m.Relay(url);
    await relay.connect();
    return { relay };
  },
  start(inst, filter, sink, opts) {
    inst.sub = inst.relay.subscribe([filter], {
      onevent: (e) => sink.event(e.id),
      oneose: () => sink.eose(),
      eoseTimeout: opts.timeoutMs,
    });
  },
  teardown(inst) {
    inst.sub?.close();
    inst.relay.close();
  },
};

const nostrToolsPool = {
  ...nostrToolsRelay,
  id: 'nostr-tools-pool',
  api: 'new SimplePool() + pool.ensureRelay(url), pool.subscribeMany([url], filter, {onevent, oneose})',
  variant: true,
  notes: `SimplePool: the same AbstractRelay underneath plus the pool's per-subscription dedup (alreadyHaveEvent over a Set of ids read from the raw frame before JSON.parse); seenOn tracking stays off (trackRelays defaults to false). verifyEvent from nostr-tools/pure. maxWait (the subscription eoseTimeout) raised to --timeout-ms (default 4400 ms). A new SimplePool per run.`,
  async load() {
    return import('nostr-tools/pool');
  },
  async setup(m, url) {
    const pool = new m.SimplePool();
    await pool.ensureRelay(url);
    return { pool, url };
  },
  start(inst, filter, sink, opts) {
    inst.sub = inst.pool.subscribeMany([inst.url], filter, {
      onevent: (e) => sink.event(e.id),
      oneose: () => sink.eose(),
      maxWait: opts.timeoutMs,
    });
  },
  teardown(inst) {
    inst.sub?.close();
    inst.pool.close([inst.url]);
    inst.pool.destroy?.();
  },
};

const nostrToolsWasm = {
  ...nostrToolsRelay,
  id: 'nostr-tools-relay-wasm',
  api: 'new AbstractRelay(url, {verifyEvent: nostr-tools/wasm verifyEvent}) + connect(), relay.subscribe([filter], {onevent, oneose})',
  get crypto() {
    return `nostr-wasm ${ver('nostr-wasm')} (libsecp256k1 + its sha256, compiled to WebAssembly)`;
  },
  notes: `nostr-tools' documented fast verifier (its README: "nostr-tools/wasm" for faster verification), its own client entry per HARNESS.md "Fairness". The documented nostr-tools/wasm setup: setNostrWasm(await initNostrWasm()) and an AbstractRelay with the wasm verifyEvent (id recomputed from a JS serialization and hashed in wasm, compared to event.id, then schnorrsig_verify). ${NT_EOSE}`,
  async load() {
    const [{ AbstractRelay }, wasm, { initNostrWasm }] = await Promise.all([
      import('nostr-tools/abstract-relay'),
      import('nostr-tools/wasm'),
      import('nostr-wasm'),
    ]);
    wasm.setNostrWasm(await initNostrWasm());
    return { AbstractRelay, verifyEvent: wasm.verifyEvent };
  },
  async setup(m, url) {
    const relay = new m.AbstractRelay(url, { verifyEvent: m.verifyEvent, websocketImplementation: globalThis.WebSocket });
    await relay.connect();
    return { relay };
  },
};

// ---------------------------------------------------------------- NDK

const ndk = {
  id: 'ndk',
  library: 'NDK (@nostr-dev-kit/ndk)',
  pkg: '@nostr-dev-kit/ndk',
  api: 'new NDK({explicitRelayUrls}) + ndk.connect(), ndk.subscribe(filter, {}, {onEvent, onEose})',
  websocket: wsGlobal,
  get crypto() {
    return `${noble('@nostr-dev-kit/ndk')}, @noble/hashes sha256`;
  },
  verify: 'library',
  notes:
    'NDK samples verification: initialValidationRatio and lowestValidationRatio set to 1 so every event is verified (defaults 1 and 0.1: the ratio decays toward 0.1 as a relay sends valid events). ' +
    "NDKEvent.verifySignature checks the schnorr signature against the hash it recomputes from the event, but never compares that hash to event.id, so the harness also calls the library's own ndkEvent.getEventHash() and drops events whose id differs (inside the timed run; it re-serializes and re-hashes, a second sha256 per event). " +
    'NDK caches verification results by id in a process-global LRU (verifiedSignatures: 1000 ids, 60 s) that is not exported: on a workload of up to 1000 events every run after the first would skip verification. The harness reaches it once in load() (untimed: LRUCache.prototype.set wrapped for a single verifySignature call on a dummy event, then restored) and clears it in every teardown. ' +
    'Outbox model and user-relay autoconnect off (one relay: they would dial public relays). Subscription options are the defaults (live subscription, groupable with its 10 ms grouping delay, no cache adapter). A new NDK instance per run; connect() waits for the relay.',
  async load() {
    const m = await import('@nostr-dev-kit/ndk');
    // NDK caches verification results by id in a module-level LRU (verifiedSignatures, 1000
    // ids, 60 s), not exported. To clear it between runs (HARNESS.md "Fairness" 3) the harness
    // catches a reference once, here, untimed: LRUCache.prototype.set is wrapped for one
    // verifySignature call on a dummy event, then restored. Runs use the library unmodified.
    const { LRUCache } = await import('typescript-lru-cache');
    const proto = LRUCache.prototype;
    const set = proto.set;
    let cache = null;
    proto.set = function (...a) {
      cache ??= this;
      return set.apply(this, a);
    };
    try {
      const pubkey = '460c25e682fda7832b52d1f22d3d22b3176d972f60dcdc3212ed8c92ef85065c';
      new m.NDKEvent(undefined, { kind: 1, content: '', tags: [], created_at: 1, pubkey, id: '0'.repeat(64), sig: '0'.repeat(128) }).verifySignature(true);
    } finally {
      proto.set = set;
    }
    if (!cache) throw new Error('could not reach NDK verifiedSignatures cache');
    cache.clear();
    return { ...m, sigCache: cache };
  },
  async setup(m, url) {
    const NDK = m.default ?? m.NDK;
    const n = new NDK({
      explicitRelayUrls: [url],
      enableOutboxModel: false,
      autoConnectUserRelays: false,
      initialValidationRatio: 1,
      lowestValidationRatio: 1,
    });
    await n.connect(10000);
    const relay = [...n.pool.relays.values()][0];
    await poll(() => relay?.connected || relay?.status >= 5, 10000, 'NDK relay connection');
    return { ndk: n, m };
  },
  start(inst, filter, sink) {
    inst.sub = inst.ndk.subscribe(
      filter,
      {},
      {
        onEvent: (e) => {
          if (e.getEventHash() !== e.id) return;
          sink.event(e.id);
        },
        onEose: () => sink.eose(),
      },
    );
  },
  teardown(inst) {
    inst.sub?.stop();
    for (const r of inst.ndk.pool.relays.values()) r.disconnect();
    inst.m.sigCache.clear();
  },
};

// ---------------------------------------------------------------- nostrify

const nostrifyRelay = {
  id: 'nostrify-relay',
  library: 'Nostrify (@nostrify/nostrify)',
  pkg: '@nostrify/nostrify',
  api: 'new NRelay1(url), for await (msg of relay.req([filter]))',
  websocket: (rt) => `websocket-ts ${nestedVer('@nostrify/nostrify', 'websocket-ts')} over the ${WS_GLOBAL[rt]}`,
  get crypto() {
    return `${noble('nostr-tools')} via nostr-tools ${ver('nostr-tools')} verifyEvent`;
  },
  verify: 'library',
  notes:
    'Every frame is parsed and validated by a zod schema (NSchema relayMsg) before verifyEvent (nostr-tools default, id + signature); req() also runs matchFilters. The connection opens in the NRelay1 constructor; setup waits for it. Default options. Events reach the app through an async generator (one await per event).',
  async load() {
    return import('@nostrify/nostrify');
  },
  async setup(m, url) {
    const relay = new m.NRelay1(url);
    await poll(() => relay.socket.readyState === 1, 10000, 'NRelay1 socket open');
    return { relay };
  },
  start(inst, filter, sink) {
    inst.ac = new AbortController();
    return (async () => {
      for await (const msg of inst.relay.req([filter], { signal: inst.ac.signal })) {
        if (msg[0] === 'EVENT') sink.event(msg[2].id);
        else if (msg[0] === 'EOSE') {
          sink.eose();
          break;
        } else if (msg[0] === 'CLOSED') throw new Error(`CLOSED: ${msg[2]}`);
      }
    })();
  },
  async teardown(inst) {
    inst.ac?.abort();
    await inst.relay.close();
  },
};

const nostrifyPool = {
  ...nostrifyRelay,
  id: 'nostrify-pool',
  variant: true,
  api: 'new NPool({open: url => new NRelay1(url), reqRouter, eventRouter}), for await (msg of pool.req([filter]))',
  notes:
    'NPool over one NRelay1 (same parsing and verification), plus the pool\'s fan-in and per-request dedup. reqRouter routes the filter to the workload relay; the pool opens the relay on the first req (the connection is inside the timed run, ~1 ms on loopback). eoseTimeout left unset (it only applies with several relays).',
  async setup(m, url) {
    const pool = new m.NPool({
      open: (u) => new m.NRelay1(u),
      reqRouter: async (filters) => new Map([[url, filters]]),
      eventRouter: async () => [url],
    });
    return { relay: pool };
  },
};

// ---------------------------------------------------------------- welshman

// @welshman/util's verifyEvent is nostr-tools/pure until a dynamic import of nostr-wasm
// resolves at module load; then it switches to nostr-tools/wasm. If the wasm fails to load it
// only console.warns and stays on pure. This probe tells the two apart: a validly signed event
// whose id is written in upper-case hex passes nostr-wasm (it compares the id bytes it parses
// from hex) and fails nostr-tools/pure (it compares hex strings).
async function welshmanWasmVerifier(util) {
  const { initNostrWasm } = await import('nostr-wasm');
  await initNostrWasm(); // throws here if nostr-wasm cannot start in this runtime
  const { finalizeEvent, generateSecretKey } = await import('nostr-tools/pure');
  const ev = finalizeEvent({ kind: 1, created_at: 1, tags: [], content: 'probe' }, generateSecretKey());
  // a fresh plain object each time (finalizeEvent marks its result as verified, and a spread
  // would copy that mark)
  const plain = (id) => ({ kind: ev.kind, created_at: ev.created_at, tags: [], content: ev.content, pubkey: ev.pubkey, id, sig: ev.sig });
  const probe = () => util.verifyEvent(plain(ev.id.toUpperCase()));
  if (!util.verifyEvent(plain(ev.id))) throw new Error('@welshman/util verifyEvent rejected a valid event');
  const end = Date.now() + 10000;
  while (!probe()) {
    if (Date.now() > end) throw new Error('@welshman/util verifyEvent did not switch to nostr-tools/wasm within 10 s (still nostr-tools/pure)');
    await sleep(5);
  }
}

const welshman = {
  id: 'welshman',
  library: 'welshman (@welshman/net)',
  pkg: '@welshman/net',
  api: 'request({relays: [url], filters: [filter], context: {pool}, onEvent, onEose})',
  websocket: wsPackage('isomorphic-ws'),
  get crypto() {
    return `nostr-wasm ${ver('nostr-wasm')} (libsecp256k1 in WebAssembly) via @welshman/util verifyEvent → nostr-tools/wasm`;
  },
  verify: 'library',
  notes:
    'Library defaults (the default-configuration row; welshman-nodelay is the ranked speed configuration), including the Socket send and receive queues: the REQ itself waits in the send queue for Socket.sendBatchDelay (100 ms, a setTimeout before each batch of sendBatchSize 5), inside the timed run, and inbound messages reach subscribers through a TaskQueue of recvBatchSize 20 per recvBatchDelay 100 ms, i.e. at most ~200 messages/s per socket, so this row is bound by those timers, not the CPU. ' +
    'On Deno, @welshman/util cannot be imported as is (its module-load proof-of-work benchmark starts a classic Worker, which Deno rejects), so the harness hides globalThis.Worker during the import. ' +
    '@welshman/util verifyEvent: nostr-tools/pure until nostr-wasm finishes loading (it imports it dynamically at module load), then nostr-tools/wasm (id + signature); load() waits until a probe confirms the wasm verifier is the one in use and fails otherwise. Unconditional library work on every event: the request Tracker (dedup by id), matchFilters, and the request\'s result array (request() resolves with the deduplicated list). A new Pool per run (context.pool), socket opened in setup.',
  async load() {
    // @welshman/util runs a proof-of-work benchmark at module load in a Worker built from a
    // blob URL as a classic worker; Deno only has module workers and throws, which fails the
    // import. On Deno the harness hides Worker during the import (the benchmark is then skipped,
    // as on Node, which has no Worker global).
    const W = globalThis.Worker;
    if (RT === 'deno') globalThis.Worker = undefined;
    let net, util;
    try {
      [net, util] = await Promise.all([import('@welshman/net'), import('@welshman/util')]);
    } finally {
      if (RT === 'deno') globalThis.Worker = W;
    }
    await welshmanWasmVerifier(util);
    return { net, util };
  },
  async setup(m, url) {
    const pool = new m.net.Pool();
    const socket = pool.get(url);
    socket.open();
    await poll(() => socket.status === m.net.SocketStatus.Open, 10000, 'welshman socket open');
    return { pool, url, request: m.net.request };
  },
  start(inst, filter, sink) {
    inst.ac = new AbortController();
    return inst.request({
      relays: [inst.url],
      filters: [filter],
      context: { pool: inst.pool },
      signal: inst.ac.signal,
      onEvent: (e) => sink.event(e.id),
      onEose: () => sink.eose(),
    });
  },
  teardown(inst) {
    inst.ac?.abort();
    inst.pool.clear?.();
    for (const s of inst.pool._data?.values?.() ?? []) s.cleanup?.() ?? s.close?.();
  },
};

const welshmanNoDelay = {
  ...welshman,
  id: 'welshman-nodelay',
  variant: false,
  api: 'Socket.sendBatchDelay = 0 and Socket.recvBatchDelay = 0, then request({relays: [url], filters: [filter], context: {pool}, onEvent, onEose})',
  notes:
    'welshman at its fastest configuration (ranked; the `welshman` row is the default configuration): its send and receive queue delays off through the public static settings. By default every Socket sends through a TaskQueue that waits Socket.sendBatchDelay (100 ms, a setTimeout) before each batch, so the REQ leaves 100 ms after request(), and hands inbound messages to subscribers through a TaskQueue of recvBatchSize 20 per recvBatchDelay 100 ms, so a socket delivers at most ~200 messages per second whatever the CPU; here Socket.sendBatchDelay = 0 and Socket.recvBatchDelay = 0 (the queues then drain on a microtask), which leaves the cost of the parsing, verification and bookkeeping. Otherwise as the welshman row (nostr-tools/wasm verifier confirmed in load(); Tracker dedup, matchFilters and the result array on every event, unconditional).',
  async load(opts) {
    const m = await welshman.load(opts);
    m.net.Socket.sendBatchDelay = 0;
    m.net.Socket.recvBatchDelay = 0;
    return m;
  },
};

// ---------------------------------------------------------------- applesauce

const applesauce = {
  id: 'applesauce-relay',
  library: 'applesauce (applesauce-relay)',
  pkg: 'applesauce-relay',
  api: 'new Relay(url), relay.subscription(filter).subscribe({next}) (rxjs; emits events and "EOSE")',
  websocket: (rt) => `rxjs webSocket over the ${WS_GLOBAL[rt]}`,
  get crypto() {
    return `${noble('nostr-tools')} via applesauce-core verifyEvent (= nostr-tools/pure)`;
  },
  verify: 'explicit',
  notes:
    'applesauce-relay delivers events unverified (verification belongs to applesauce-core\'s EventStore); the harness calls applesauce-core/helpers verifyEvent (nostr-tools/pure: id + signature) on each event. The rxjs WebSocketSubject connects lazily on the first subscription, so the connect is inside the timed run (~1 ms on loopback). A new Relay per run. ' +
    'The applesauce app path (relay → EventStore.add, which verifies and indexes) is not a row: a store is outside the job. When it was tested, applesauce-core\'s EventStore dropped expired events (keepExpired false by default) except one whose expiration tag is "0": it tests the timestamp for truthiness, so 0 reads as no expiration.',
  async load() {
    const [relay, helpers] = await Promise.all([import('applesauce-relay'), import('applesauce-core/helpers')]);
    return { Relay: relay.Relay, verifyEvent: helpers.verifyEvent };
  },
  async setup(m, url) {
    return { relay: new m.Relay(url), verifyEvent: m.verifyEvent };
  },
  start(inst, filter, sink) {
    const verify = inst.verifyEvent;
    inst.sub = inst.relay.subscription(filter).subscribe({
      next: (m) => {
        if (m === 'EOSE') sink.eose();
        else if (verify(m)) sink.event(m.id);
      },
      error: (e) => sink.error(e),
    });
  },
  teardown(inst) {
    inst.sub?.unsubscribe();
    inst.relay.close?.();
  },
};

// ---------------------------------------------------------------- rx-nostr

const rxNostr = {
  id: 'rx-nostr',
  library: 'rx-nostr',
  pkg: 'rx-nostr',
  api: 'createRxNostr({verifier, skipFetchNip11, skipValidateFilterMatching}) + setDefaultRelays([url]), rxNostr.use(createRxBackwardReq()).subscribe({next, complete}); req.emit(filter); req.over()',
  websocket: wsGlobal,
  get crypto() {
    return `@noble/curves ${short(nestedVer('@rx-nostr/crypto', '@noble/curves'))} (pure JS) via @rx-nostr/crypto ${ver('@rx-nostr/crypto')} verifier`;
  },
  verify: 'library',
  notes:
    "createRxNostr requires a verifier; the standard one is @rx-nostr/crypto's verifier (async, on the main thread). It checks the signature against the hash it recomputes and never compares it to event.id, so the harness also calls @rx-nostr/crypto getEventHash(event) and drops events whose id differs (a second serialization + sha256 per event). " +
    '@rx-nostr/crypto verify() calls console.warn with a stack trace for every event whose signature does not parse (the "sig":"" events): console.warn is silenced in this process. ' +
    'rx-nostr drops expired (NIP-40) events by default (skipExpirationCheck: false). The backward request completes on EOSE: completion is the EOSE delivered to the app. eoseTimeout raised to --timeout-ms (default 30 s: it would complete a slow stream early). connectionStrategy "aggressive" + a wait for the relay state "connected" puts the connect in setup. ' +
    'skipFetchNip11: true (documented option; by default each relay connection starts a NIP-11 fetch and the first REQ of a process waits for it, to read max_subscriptions) and skipValidateFilterMatching: true (documented option; by default every event is matched against the REQ filter again). A new rxNostr per run.',
  async load() {
    // @rx-nostr/crypto's verify() console.warns a stack trace for every event whose signature
    // does not parse; an app would route that to its logger: silenced (HARNESS.md "Fairness").
    console.warn = () => {};
    const [rx, crypto] = await Promise.all([import('rx-nostr'), import('@rx-nostr/crypto')]);
    return { rx, crypto };
  },
  async setup(m, url, w, opts) {
    const rx = m.rx.createRxNostr({
      verifier: m.crypto.verifier,
      eoseTimeout: opts.timeoutMs,
      connectionStrategy: 'aggressive',
      skipFetchNip11: true,
      skipValidateFilterMatching: true,
    });
    rx.setDefaultRelays([url]);
    const norm = Object.keys(rx.getDefaultRelays())[0] ?? url;
    await poll(() => rx.getRelayStatus(norm)?.connection === 'connected', 10000, 'rx-nostr connection');
    return { rx, m };
  },
  start(inst, filter, sink) {
    const getEventHash = inst.m.crypto.getEventHash;
    const req = inst.m.rx.createRxBackwardReq();
    inst.sub = inst.rx.use(req).subscribe({
      next: (p) => {
        if (getEventHash(p.event) !== p.event.id) return;
        sink.event(p.event.id);
      },
      complete: () => sink.eose(),
      error: (e) => sink.error(e),
    });
    req.emit(filter);
    req.over();
  },
  teardown(inst) {
    inst.sub?.unsubscribe();
    inst.rx.dispose();
  },
};

// ---------------------------------------------------------------- snort

const snortCommon = {
  library: 'snort (@snort/system)',
  pkg: '@snort/system',
  api: 'new NostrSystem({checkSigs: true}) + ConnectToRelay(url), system.Query(RequestBuilder.withOptions({leaveOpen: true, groupingDelay: 0}).withFilter().limit(n)).on("event"/"eose"), query.start()',
  websocket: wsPackage('isomorphic-ws'),
  verify: 'library',
  async setup(m, url) {
    const sys = new m.sys.NostrSystem({
      checkSigs: true,
      ...(m.optimizer ? { optimizer: m.optimizer } : {}),
    });
    await sys.ConnectToRelay(url, { read: true, write: false });
    // ConnectToRelay resolves before the socket is open (Connection.connect(awaitOpen = false)):
    // wait for the handshake here, untimed
    await poll(() => sys.pool.getConnection(url)?.isOpen === true, 10000, 'snort relay connection open');
    return { sys, m, url };
  },
  start(inst, filter, sink) {
    const { RequestBuilder, EventExt } = inst.m.sys;
    const rb = new RequestBuilder(`bench-${Math.random().toString(36).slice(2)}`);
    rb.withOptions({ leaveOpen: true, groupingDelay: 0 });
    rb.withFilter().limit(filter.limit).relay(inst.url);
    const q = inst.sys.Query(rb);
    inst.q = q;
    q.on('event', (evs) => {
      for (const e of evs) {
        if (EventExt.createId(e) !== e.id) continue;
        sink.event(e.id);
      }
    });
    q.on('eose', () => sink.eose());
    q.start?.();
  },
  teardown(inst) {
    inst.q?.cancel?.();
    inst.q?.cleanup?.();
    inst.sys.DisconnectRelay(inst.url);
  },
};

// @snort/system's dist has extensionless relative ESM imports: Bun resolves them, Node needs
// a bundler-like resolve hook, Deno has no such hook (its row reports the load error).
async function importSnort() {
  if (RT === 'node') {
    const { register } = await import('node:module');
    register('./snort-resolve.mjs', import.meta.url);
  }
  return import('@snort/system');
}

const SNORT_NOTES =
  'NostrSystem does not verify by default (checkSigs: false); the harness turns checkSigs on. ' +
  'Request options: groupingDelay: 0 (the option snort\'s own fetch() sets; by default Query.start waits groupingDelay = 100 ms on a setTimeout before it sends the REQ, to merge requests) and leaveOpen: true (the query is closed in teardown): with the default (false) a 30 s QueryFetchTimeout hard timer would cut a long stream, and the trace closes at the EOSE while the last events of the socket read that carried it still wait in the pool\'s queueMicrotask verify batch, so those are dropped (a tail of ~50 events lost, a different number every run). ' +
  'ConnectToRelay does not wait for the socket to open; setup waits until the pool\'s connection reports isOpen, so the handshake is untimed. Each connection also starts a NIP-11 fetch at connect (in parallel with the handshake, kept in a module-level cache). ' +
  'Unconditional library work: the Query delivers through its feed, a NoteCollection, a sorted in-memory store (a SortedMap insert with splice per event) that hands new events to "event" listeners on a timer (emitInterval 300 ms), so events reach the app up to 300 ms after the EOSE and the run ends at the last one. That store keeps one event per replaceable key (an older kind 0/3/1xxxx version is never delivered) and adds an event only if created_at > (stored.created_at ?? 0), so an event with created_at 0 is never delivered: on the corpus it drops valid events (accepted_ok false). ' +
  'The connection pool batches the events of one microtask turn into one optimizer.batchVerify call; verification checks the signature against an id it recomputes (EventExt.createId) but never compares it to event.id, so the harness also calls EventExt.createId(event) and drops events whose id differs (a second serialization + sha256 per event). "event" handlers receive arrays of new events. Other options default (the automatic outbox model only acts on filters with authors). A new NostrSystem per run. The published dist has extensionless relative ESM imports: on Node the harness registers a module-resolution hook (snort-resolve.mjs: retries .js and /index.js, as a bundler does) to load the unmodified package; Bun resolves them itself; Deno cannot load it.';

const snort = {
  ...snortCommon,
  id: 'snort-system',
  get crypto() {
    return `@noble/curves ${short(nestedVer('@snort/system', '@noble/curves'))} (pure JS), DefaultOptimizer`;
  },
  notes: SNORT_NOTES,
  async load() {
    return { sys: await importSnort() };
  },
};

const snortWasm = {
  ...snortCommon,
  id: 'snort-system-wasm',
  get crypto() {
    return `@snort/system-wasm ${ver('@snort/system-wasm')} (libsecp256k1 via the Rust secp256k1-sys 0.10 crate, compiled to WebAssembly), schnorr_verify_batch`;
  },
  notes:
    SNORT_NOTES +
    ' Optimizer: the WebAssembly one the snort app wires in (@snort/system-wasm: expand_filter/get_diff/flat_merge/compress, schnorr_verify_event, schnorr_verify_batch, which recompute the id in Rust and check the signature, again without comparing to event.id).',
  async load() {
    const sys = await importSnort();
    const w = await import('@snort/system-wasm/pkg/system_wasm.js');
    const bytes = readFileSync(path.join(HERE, 'node_modules/@snort/system-wasm/pkg/system_wasm_bg.wasm'));
    w.initSync({ module: bytes });
    const optimizer = {
      expandFilter: (f) => w.expand_filter(f),
      getDiff: (prev, next) => w.get_diff(prev, next),
      flatMerge: (all) => w.flat_merge(all),
      compress: (all) => w.compress(all),
      schnorrVerify: (ev) => w.schnorr_verify_event(ev),
      batchVerify: (evs) => Array.from(w.schnorr_verify_batch(evs), (b) => b === 1),
    };
    return { sys, optimizer };
  },
};

// ---------------------------------------------------------------- Nostr Dev Kit (rust-nostr)

const nostrSdk = {
  id: 'nostr-sdk-node',
  library: 'Nostr Dev Kit nostr-sdk (formerly rust-nostr; @nostrdevkit/nostr-sdk-node)',
  pkg: '@nostrdevkit/nostr-sdk-node',
  runtimes: ['node', 'bun', 'deno'],
  api: 'new Client() + addRelay + tryConnect, client.streamEvents(ReqTarget.single(url, [filter]), ExitOnEose) → stream.next() until it ends',
  websocket: 'the Rust SDK\'s own client: async-wsocket 0.17 over tokio-tungstenite 0.28 (native, on its tokio threads)',
  crypto: 'libsecp256k1 (C, secp256k1-sys 0.10.1 via the Rust secp256k1 0.30 crate, in the native addon; nostr 0.45.3, nostr-sdk 0.45.2)',
  verify: 'library',
  notes:
    'Native bindings (uniffi, napi) of the Rust nostr-sdk: socket, JSON parsing, id and signature verification run in Rust on its own threads; each delivered event crosses the FFI as an Event handle and the harness reads its id with event.id().toHex() (an FFI call). The stream ends at EOSE (ReqExitPolicy.ExitOnEose): its end is the EOSE; the timeout argument of streamEvents is left unset (none). It drops expired (NIP-40) events unconditionally. Deduplication across relays is by id. A new Client per run.',
  async load() {
    return import('@nostrdevkit/nostr-sdk-node');
  },
  async setup(m, url) {
    const client = new m.Client();
    const ru = m.RelayUrl.parse(url);
    await client.addRelay(ru);
    await client.tryConnect(10000);
    return { client, ru, m };
  },
  start(inst, filter, sink, opts) {
    const m = inst.m;
    return (async () => {
      const f = new m.Filter().limit(BigInt(filter.limit));
      const stream = await inst.client.streamEvents(m.ReqTarget.single(inst.ru, [f]), undefined, undefined, m.ReqExitPolicy.ExitOnEose.new());
      for (;;) {
        const it = await stream.next();
        if (it === undefined) break;
        if (it.event) sink.event(it.event.id().toHex());
        else if (it.error) throw new Error(String(it.error));
      }
      sink.eose();
    })();
  },
  async teardown(inst) {
    await inst.client.disconnect();
  },
};

// ---------------------------------------------------------------- @qntx/nostr

const qntx = {
  id: 'qntx-nostr',
  library: '@qntx/nostr',
  pkg: '@qntx/nostr',
  api: 'new Relay(url) + relay.connect(), relay.subscribe([filter], {onEvent, onEose})',
  websocket: wsGlobal,
  get crypto() {
    return `${noble('@qntx/nostr')} (nobleBackend)`;
  },
  verify: 'library',
  notes: 'Default verifyEvent (id + signature, results cached in WeakSets keyed by the event object, so never across events or runs). matchFilters on every event. A new Relay per run.',
  async load() {
    return import('@qntx/nostr/relay');
  },
  async setup(m, url) {
    const relay = new m.Relay(url, m.extra ?? {});
    await relay.connect();
    return { relay };
  },
  start(inst, filter, sink) {
    inst.sub = inst.relay.subscribe([filter], {
      onEvent: (e) => sink.event(e.id),
      onEose: () => sink.eose(),
    });
  },
  teardown(inst) {
    inst.sub?.close();
    inst.relay.close();
  },
};

const qntxWasm = {
  ...qntx,
  id: 'qntx-nostr-wasm',
  api: 'new Relay(url, {verifyEvent: (await loadNostrWasm()).verifyEvent}), relay.subscribe([filter], {onEvent, onEose})',
  get crypto() {
    return `@qntx/nostr-wasm ${ver('@qntx/nostr-wasm')} (libsecp256k1 in WebAssembly)`;
  },
  notes: 'The documented @qntx/nostr-wasm verifier (its README: WebAssembly-accelerated verification) injected into Relay (id + signature in wasm): the library\'s documented speed option, its own client entry. Otherwise as qntx-nostr.',
  async load() {
    const [m, w] = await Promise.all([import('@qntx/nostr/relay'), import('@qntx/nostr-wasm')]);
    const wasm = await w.loadNostrWasm();
    return { Relay: m.Relay, extra: { verifyEvent: wasm.verifyEvent } };
  },
};

export const CLIENTS = [
  nostrToolsRelay,
  nostrToolsPool,
  nostrToolsWasm,
  ndk,
  nostrifyRelay,
  nostrifyPool,
  welshman,
  welshmanNoDelay,
  applesauce,
  rxNostr,
  snort,
  snortWasm,
  nostrSdk,
  qntx,
  qntxWasm,
];
