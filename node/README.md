# JavaScript harness (Node, Bun, Deno)

One script, three runtimes, three harness ids: `node`, `bun` and `deno`, each with its own
results file (`results/node.json`, `results/bun.json`, `results/deno.json`), language
`JavaScript`. The contract is [`../HARNESS.md`](../HARNESS.md).

```bash
node/run.sh --runtime node --quick --workloads smoke   # check every client first
node/run.sh --runtime node --quick                 # results/node.json
node/run.sh --runtime bun  --clients ndk,welshman  # results/bun.json
node/run.sh --runtime deno --list                  # the clients listed on Deno
node/run.sh --runtime all  --quick                 # node, then bun, then deno
```

`run.sh` installs the pinned packages (`npm ci` from `package-lock.json`) when
`node_modules` is missing or older than the lockfile. Node is the one on the `PATH` (22.x
here); Bun (1.4.3) and Deno (2.9.6) are npm devDependencies, so the lockfile pins them too.
Every HARNESS.md flag is accepted (`--relay --corpus --out --workloads --clients
--warmup-runs --min-runs --min-time-ms --max-runs --timeout-ms --quick --list`), plus
`--runtime node|bun|deno|all`.

## Files

- `bench.mjs`: the harness. Without `--child` it is the orchestrator: it re-spawns itself
  (same runtime) once per client, so every client runs in a fresh process (its own JIT
  profile, heap, module state and library-global caches), and merges the rows. A child
  prints its rows as one `@@ROWS <json>` line; a child that crashes or is killed still
  gets a row with `error` set. Library output on stderr (rx-nostr prints a stack trace for
  every invalid event) is shown for the first 12 lines per client and then only counted.
- `clients.mjs`: one entry per client: how to load the library, build a new client, open
  the subscription and tear it down, plus the row's `api`, `websocket`, `crypto`, `verify`
  and `notes`.
- `snort-resolve.mjs`: a Node module-resolution hook, used only by the snort clients on Node
  (see snort below).

## How a run is measured

Per HARNESS.md "A run":

1. **Setup, untimed**: a new client instance (relay, pool, NDK, system, ...), connected and
   open when the API lets the app connect explicitly. The libraries that only connect on the
   first subscription (applesauce, nostrify-pool) say so in `notes`. Where the connect call
   returns before the socket is open (snort), setup waits for the open socket.
2. **Timed**: `t0 = performance.now()` right before the library's subscription call with
   `{"limit": <events>}`. The library's own callbacks (or async iterator) feed a sink that
   only does what HARNESS.md "Fairness" 5 allows: `accepted += 1` and the XOR of the id taken
   from the library's event object (as 8 uint32 words). The clock is read at the EOSE and,
   only after it, for each further event (those move the end). The run ends at
   `max(EOSE delivered to the app, last event)`. CPU is `process.cpuUsage()` (user + system,
   every thread of the process) at `t0` and at that end point, never in the per-event
   callback: it is read at the EOSE, then, if events still come, once when the set is
   complete or, for a library that leaves events out, by the 50 ms idle-check timer after
   the last event (that adds the idle rest of one tick).
3. The harness then waits, untimed, until the EOSE has been seen and either every possible
   event is in (valid + ambiguous) or nothing has arrived for 1 s (a library that drops the
   expired or ambiguous events always takes this 1 s). No EOSE within `--timeout-ms` is an
   error. A library exception that escapes to the event loop (a throw in a socket callback
   or a microtask) ends the run with an error instead of killing the process.
4. **Teardown, untimed**: close the subscription and the client (bounded to 10 s).

Warm-up and measured runs, `first_run_ms`, the accepted-set check, "every run must deliver
the same set as the first" and the derived numbers are exactly HARNESS.md. Since the sink
keeps no ids, `ambiguous_accepted` and `expired_accepted` of a correct set follow from its
count and XOR (the one combination of "expired: all or none" and a subset of the ambiguous
ids that matches both); a set that matches none is `accepted_ok: false`, and one extra,
untimed diagnostic run that keeps the ids says which of the optional events it holds. Measured runs stop once `--min-runs` runs are
done and their timed milliseconds add up to `--min-time-ms`, or at `--max-runs`.
`peak_rss_mb` is `process.resourceUsage().maxRSS` (KiB on all three runtimes) at the end of
the child, over its warm-up and measured runs. `base_rss_mb` is `process.memoryUsage().rss`
right after each workload's first setup, after a full GC (`Bun.gc(true)`; `gc()` on Node and
Deno, whose children run with `--expose-gc`): one child runs every workload of a client, so a
later workload's base follows the earlier workloads in that process. `alloc_bytes` is V8's
cumulative `total_allocated_bytes` from `v8.getHeapStatistics()` (read before `t0` and where
the run's end CPU time is read; the median run's value, the mean of the two middle runs with
an even count), which only Deno's V8 has: Node 22's V8 lacks it and Bun's field of that name
is a current heap size, so both report `null`. It counts the main isolate's JS heap only:
WebAssembly memory (nostr-wasm), native addons (nostr-sdk-node's Rust), `ArrayBuffer`
backing stores and Workers are not counted, and V8 adds it per allocation buffer, so it is
coarse (~100 KB) on small workloads.

**WebSocket.** Each library gets the WebSocket it picks by default in that runtime: the
global `WebSocket` (Node 22: undici; Bun: its native client; Deno: its Rust client), or the
`ws` package where the library imports it (welshman and snort through `isomorphic-ws`, which
is `ws` on Node and Deno, and Bun's built-in replacement of the `ws` module on Bun). The
`websocket` field of each row names the one used on that runtime.

**Verification** (`verify`): `library` when the library verifies before delivering (its
default, or a documented option the harness turns on, named in `notes`). Three libraries
check the signature against a hash they recompute but never compare that hash with
`event.id` (NDK, rx-nostr, snort): for those the harness also calls the library's own hash
function (`ndkEvent.getEventHash()`, `@rx-nostr/crypto` `getEventHash`, snort
`EventExt.createId`) on every delivered event, inside the run, and drops the ones whose id
differs. applesauce-relay delivers unverified events: its row is `explicit` (the harness
calls applesauce-core's `verifyEvent`).

**Configuration** (HARNESS.md "Fairness"): library defaults, except, each named in the row's
`notes`: verification turned on or to 100 % (snort `checkSigs`, NDK validation ratios);
timers that would cut a long stream short raised to `--timeout-ms` (nostr-tools
`eoseTimeout`/`maxWait`, rx-nostr `eoseTimeout`, snort's 30 s query timeout through
`leaveOpen`); one relay (NDK outbox model off); work outside the job that a documented
option turns off, turned off (rx-nostr `skipFetchNip11` and `skipValidateFilterMatching`,
snort `groupingDelay: 0`); per-event console logging silenced (rx-nostr's `console.warn`
stack trace for each invalid event: `console.warn` is a no-op in that child process);
verification caches that would carry over between runs cleared (NDK). Work a library does
unconditionally (welshman's request tracker and result array, snort's sorted feed store) is
its cost and named in `notes`. No ranked row stores events (no event store, cache or
index). A documented speed option is its own ranked client (`nostr-tools-relay-wasm`,
`qntx-nostr-wasm`, `snort-system-wasm`, `welshman-nodelay`), listed next to the
default-configuration row; pools are variants. The harness adds no threads (NDK's
verification worker is therefore not a client; see NDK below).

## Clients

Versions are the ones `package-lock.json` resolves (latest releases on 2026-11-03).

| client | library (npm) | API | verification and crypto | WebSocket |
|---|---|---|---|---|
| `nostr-tools-relay` | nostr-tools 2.25.5 (Unlicense) | `new Relay(url)`, `connect()`, `relay.subscribe([filter], {onevent, oneose})` | library: `nostr-tools/pure` `verifyEvent` (id + sig), @noble/curves 2.0 | global |
| `nostr-tools-pool` (variant) | nostr-tools | `SimplePool.subscribeMany([url], filter, …)` | same, plus the pool's id dedup | global |
| `nostr-tools-relay-wasm` | nostr-tools + nostr-wasm 0.1.0 | `AbstractRelay` with `nostr-tools/wasm` `verifyEvent` | library: nostr-wasm (libsecp256k1 in wasm), id + sig | global |
| `ndk` | @nostr-dev-kit/ndk 3.0.3 (MIT) | `ndk.subscribe(filter, {}, {onEvent, onEose})` (default options) | library (sig) + harness id check; validation ratios forced to 1; @noble/curves 1.9 | global |
| `nostrify-relay` | @nostrify/nostrify 0.55.1 (MIT) | `for await (msg of new NRelay1(url).req([filter]))` | library: zod schema, then nostr-tools `verifyEvent` | websocket-ts over global |
| `nostrify-pool` (variant) | @nostrify/nostrify | `NPool.req([filter])` over one NRelay1 | same, plus pool dedup | websocket-ts over global |
| `welshman` | @welshman/net + util 0.14.0-pre5 (MIT) | `request({relays, filters, context: {pool}, onEvent, onEose})` | library: `@welshman/util` `verifyEvent` → nostr-tools/wasm (nostr-wasm) | `isomorphic-ws` → `ws` |
| `welshman-nodelay` | @welshman/net | as `welshman`, `Socket.sendBatchDelay = 0`, `Socket.recvBatchDelay = 0` | same | same |
| `applesauce-relay` | applesauce-relay 7.0.0 + applesauce-core 7.0.3 (MIT) | `relay.subscription(filter)` (rxjs) | explicit: applesauce-core `verifyEvent` (nostr-tools/pure) | rxjs `webSocket` over global |
| `rx-nostr` | rx-nostr 3.7.8 + @rx-nostr/crypto 3.1.6 (MIT) | `rxNostr.use(createRxBackwardReq())`, `emit(filter)`, `over()`; `skipFetchNip11`, `skipValidateFilterMatching` | library (sig) + harness id check; @noble/curves 2.4 | global |
| `snort-system` | @snort/system 2.1.11 (MIT) | `system.Query(RequestBuilder…)` `.on("event"/"eose")`, `leaveOpen: true`, `groupingDelay: 0` | library with `checkSigs: true` (sig) + harness id check; @noble/curves 2.4 | `isomorphic-ws` → `ws` |
| `snort-system-wasm` | @snort/system + @snort/system-wasm 2.0.0 | same, with the wasm optimizer the snort app uses | library: `schnorr_verify_batch` (secp256k1-sys 0.10 in wasm) + harness id check | same |
| `nostr-sdk-node` | @nostrdevkit/nostr-sdk-node 0.45.1 (MIT) | `client.streamEvents(ReqTarget.single(url, [filter]), ExitOnEose)` + `stream.next()` | library: Rust nostr-sdk, libsecp256k1 (native addon) | the Rust SDK's own (native) |
| `qntx-nostr` | @qntx/nostr 0.15.3 (MIT OR Apache-2.0) | `relay.subscribe([filter], {onEvent, onEose})` | library: default `verifyEvent` (id + sig), @noble/curves 2.4 | global |
| `qntx-nostr-wasm` | @qntx/nostr + @qntx/nostr-wasm 0.15.3 | same, `verifyEvent` from `loadNostrWasm()` | library: libsecp256k1 in wasm | global |

## What each library does (and what surprised)

**nostr-tools.** Verifies id and signature by default (`verifyEvent` from `nostr-tools/pure`;
the cached result is a symbol on the parsed object, so nothing carries across runs).
`AbstractRelay` reads the subscription id and event id out of the raw frame with string
scans before `JSON.parse`, for `alreadyHaveEvent` dedup (the pool uses it). **Its EOSE
timer is a trap for big streams:** each subscription arms `eoseTimeout` (default
`relay.baseEoseTimeout` = 4400 ms) at the REQ and fakes an EOSE when it fires, whatever is
still streaming; with the pure verifier the `all` workload takes far longer than 4.4 s, so
the harness raises it to `--timeout-ms` (SimplePool: `maxWait`). Rejects the `"sig":""`
events quietly; accepts the ambiguous event (it serializes with `JSON.stringify`).

**NDK.** Samples verification by default: `initialValidationRatio` 1 decaying toward
`lowestValidationRatio` 0.1 as a relay keeps sending valid events, so an app verifies only a
fraction of a long stream; the harness sets both to 1. `NDKEvent.verifySignature` checks the
signature against the hash of its own serialization and never compares that hash with
`event.id` (an event with a valid signature and a wrong id passes); hence the harness id
check with `getEventHash()`. A process-global `verifiedSignatures` LRU (1000 ids, 60 s,
not exported) caches results by id: on `smoke` (994 valid ids) every run after the first
skipped verification entirely (225 ms instead of ~3 s). The harness reaches the cache once
in `load()` (untimed: `LRUCache.prototype.set` wrapped for one `verifySignature` call on a
dummy event, then restored, so the runs use the library unmodified) and clears it in every
teardown. The outbox model is on by default and would dial public relays: the harness turns
it off. Not a client, but checked while building this harness (Bun, Deno; Node has no Web
Worker): with a `signatureVerificationWorker` NDK emits every event to the app **before** the
worker answers (the async verify is not awaited; a bad one is only reported later through
`event:invalid-sig`), so the app receives the invalid events too (all 3,568 `notes` events
delivered), and the worker's `schnorr.verify` call has no try/catch: an empty signature
throws inside the worker (on Deno that error kills the worker).

**Nostrify.** Parses every frame through a zod schema (`NSchema`) before the default
nostr-tools `verifyEvent`; events come out of an async generator. `NRelay1` opens its
socket in the constructor. `NPool` adds routing and a per-request dedup; it opens relays on
the first request.

**welshman.** **Delays both ways by default:** each `Socket` sends through a `TaskQueue`
that waits `Socket.sendBatchDelay` (100 ms, a `setTimeout`) before each batch, so the `REQ`
itself leaves 100 ms after `request()`, and passes received messages to subscribers through
a `TaskQueue` of `recvBatchSize` 20 per `recvBatchDelay` 100 ms, i.e. at most ~200 messages
per second per relay, whatever the CPU. The `welshman` row (library defaults, the
default-configuration row) is therefore bound by those timers (the `all` workload takes
~156 s, `cpu_ms` stays low); `welshman-nodelay`, ranked as welshman's speed configuration,
sets the public statics `Socket.sendBatchDelay = 0` and `Socket.recvBatchDelay = 0` (the
queues then drain on a microtask). Verification is `@welshman/util` `verifyEvent`:
nostr-tools/pure until nostr-wasm (imported dynamically at module load) is ready, then
nostr-tools/wasm; if the wasm fails to load it only `console.warn`s and stays on pure.
`load()` therefore checks: it initializes nostr-wasm itself (an error there fails the row)
and probes `verifyEvent` until it behaves as nostr-tools/wasm (a valid event with its id in
upper-case hex passes nostr-wasm, which compares id bytes, and fails nostr-tools/pure, which
compares hex strings); after 10 s it fails the row. `request()` also runs its dedup `Tracker`
and `matchFilters` on every event and keeps every event in an array (it resolves with the
deduplicated list): unconditional, named in `notes`. Its `isomorphic-ws`
import means the `ws` package on Node and Deno. On Deno, `@welshman/util` cannot be imported
as is: at module load it benchmarks proof of work in a Worker created from a blob URL as a
classic worker, which Deno rejects (`Classic workers are not supported`); the harness hides
`globalThis.Worker` during the import.

**applesauce.** `applesauce-relay` does not verify (verification belongs to applesauce-core's
`EventStore`), so the row calls applesauce-core's `verifyEvent` itself (`explicit`). The
rxjs `webSocket` connects lazily on the first subscription (inside the timed run). The app
path through an `EventStore` is not a row (a store is outside the job). When it was tested
(as an `applesauce-eventstore` variant, since dropped): `EventStore.add` keeps only the
newest version of replaceable events by default and drops expired events
(`keepExpired: false`), except one whose `expiration` tag is `"0"`: it tests the timestamp
for truthiness, so `0` reads as "no expiration"; and it handles kind 5 deletions before
verifying, so a kind-5 event is applied to the delete index without its signature being
checked.

**rx-nostr.** Requires a verifier; `@rx-nostr/crypto`'s `verifier` checks the signature
against the recomputed hash but not against `event.id` (harness id check with its
`getEventHash`). It `console.warn`s a full stack trace for every event whose signature does
not parse (the 1,547 `"sig":""` events); per HARNESS.md that per-event logging is silenced
(`console.warn` is a no-op in its process). It drops expired
events by default (`skipExpirationCheck: false`): `expired_accepted` 0. `eoseTimeout`
(default 30 s from the REQ) would complete a slow stream early: raised to `--timeout-ms`.
By default each relay connection starts a NIP-11 fetch and the first `REQ` of a process
waits for it (to read `max_subscriptions`), and every event is matched against the filter
again: the documented `skipFetchNip11: true` and `skipValidateFilterMatching: true` turn
both off. The backward request completes on EOSE; completion is the EOSE.

**snort (@snort/system).** Does not verify by default (`checkSigs: false`); the harness sets
`checkSigs: true`. **With its default optimizer it crashes on the first unsigned event:**
`DefaultOptimizer.batchVerify` calls `schnorr.verify` without a try/catch, @noble/curves
throws on a 0-byte signature, and the throw escapes from a `queueMicrotask` (in an app that
is an uncaught exception that kills the batch, in Node the process); the `snort-system` row
reports that error. The snort app wires the WebAssembly optimizer from `@snort/system-wasm`
(its `schnorr_verify_batch` returns false instead of throwing); `snort-system-wasm` does the
same and is a headline row. Neither compares the recomputed id with `event.id` (harness id
check with `EventExt.createId`). `Query.start()` waits `groupingDelay` (default 100 ms, a
`setTimeout`) before it sends the `REQ`, to merge requests: the harness sets
`groupingDelay: 0`, as snort's own `fetch()` does. `ConnectToRelay` returns before the
socket is open; setup waits until the pool's connection is open, so the handshake is
untimed (each connection also fetches NIP-11 at connect, in parallel, cached per process).
With the default `leaveOpen: false` the query closes its
trace at the EOSE while the last events of the socket read that carried the EOSE still sit in
the pool's microtask verify batch, so a tail of ~50 events is lost (a different number each
run), and a 30 s `QueryFetchTimeout` would cut a longer stream: the harness uses
`leaveOpen: true` and closes the query in teardown. The query delivers through its feed, a
`NoteCollection`: a sorted in-memory store (a `SortedMap` insert with `splice` per event, an
unconditional cost) that emits new events to listeners on a timer (`emitInterval` 300 ms,
so up to 300 ms after the EOSE), keeps
one event per replaceable key (older kind 0/3/10000+ versions are never delivered) and
adds an event only if `created_at > (stored?.created_at ?? 0)`, so the `created_at: 0`
event is never delivered: `snort-system-wasm` misses 2 valid events on `smoke`
(`accepted_ok: false`). The published `dist` uses extensionless relative ESM imports
(`export * from "./cache/index"`) that only a bundler or Bun resolves: on Node the harness
registers `snort-resolve.mjs` (a resolve hook that retries `.js` and `/index.js`, what a
bundler does); on Deno there is no such hook and the rows report the load error.

**Nostr Dev Kit nostr-sdk (formerly rust-nostr).** `@nostrdevkit/nostr-sdk-node` is the
native (uniffi/napi) binding of the Rust SDK: the socket, JSON parsing and verification
run in Rust on its own threads (`cpu_ms` includes them), and each event crosses into JS as a
handle whose id the harness reads with `event.id().toHex()`. It drops expired events
unconditionally (`expired_accepted` 0) and accepts the ambiguous event. The stream ends at
EOSE (`ReqExitPolicy.ExitOnEose`). Runs on Node, Bun and Deno. `streamEvents`' `timeout`
is in milliseconds.

**@qntx/nostr.** A new (2026) TypeScript SDK with a nostr-tools-like `Relay`; verifies id
and signature by default (WeakSet caches per object). `@qntx/nostr-wasm` injects a
libsecp256k1-in-wasm verifier: the library's documented speed option, ranked as its own
client (`qntx-nostr-wasm`) next to the default `qntx-nostr`.

## Not included

- **@nostr/gadgets** (jsr, fiatjaf): high-level helpers (profiles, lists, outbox) on top of a
  global nostr-tools `SimplePool`; its relay client and verification are nostr-tools'
  (`nostr-tools-pool`).
- **@rust-nostr/nostr-sdk** (wasm): deprecated on npm in favour of the `@nostrdevkit`
  packages (the project was renamed Nostr Dev Kit); `nostr-sdk-node` is the current binding.
  The browser build, `@nostrdevkit/nostr-sdk-web`, is the same Rust SDK in wasm.
- **@candypoets/nipworker**: a browser runtime built from four Rust/WASM module workers, an
  IndexedDB cache and FlatBuffer views, distributed for Vite; it has no Node entry point
  (its Node export is a relay proxy).
- **nostr-relaypool**: unmaintained since 2023, built on nostr-tools 1.x.
- **nostr-fetch**: a fetcher of past events with no live subscription; it cannot do the job
  once. `allEventsIterator` pages backwards, each page a `REQ` with `until` = the oldest
  `created_at` seen and `limit = min(limitPerReq, 5000)`, and stops only when a page brings
  nothing new, so even a relay that honors the filter is asked a second time, and against a
  relay that returns the whole set (as this one does) the second page streams and verifies
  every event again before its dedup drops them: two full streams. (It was benchmarked as a
  variant and dropped.)
- **@cmdcode/nostr-sdk, @vbyte/nostr-sdk, nostr-websocket-utils, nostr-headless-client,
  nostr-wot-sdk** and the many forks of nostr-tools on npm: small or single-app packages with
  no known use as a client core.

## Caveats

- Pure-JS verifiers (@noble/curves) run at ~0.6-2k events/s here, so one run of the `all`
  workload takes 15-60 s (welshman with its throttle ~156 s); a `--quick` run of the three
  runtimes on `all` takes a long while. `--workloads smoke` (1,417 events) takes a few
  minutes per runtime and has every edge case.
- Timings on a shared machine are noisy; `cpu_ms` (all threads) is the steadier number.
- Bun's `node:` compat runs these libraries unmodified; Deno runs them from `node_modules`
  (`deno run -A`, npm packages resolved through `package.json`).
