# nostrLibBench harness contract

Every language harness (`<harness>/`) follows this contract so that one report can rank
Nostr client libraries across languages. Each harness is a native project in its own
language (its own build file, lockfile and launcher), driving each library through that
library's own public API, its own WebSocket client and its own verification. A harness
that breaks this contract produces numbers that cannot be compared, so read it before
adding a client.

## What is measured

**One run = one subscription, end to end:** the library sends a `REQ` to the relay,
receives every `EVENT` frame of the workload over its own WebSocket client, parses each
one into its own event type, verifies it (id = SHA-256 of the NIP-01 serialization, and
the BIP-340 signature) and hands the valid events to the app; then the relay's `EOSE`
arrives. The time of a run is from the moment the app asks for the subscription until the
app has the last event and the EOSE.

That is the job a client does when it opens a feed or syncs on startup, and it is all
library code: the WebSocket client and its frame decoding, JSON parsing, the event
model, id hashing, signature verification and the library's own subscription
bookkeeping (dedup, filter matching, queues, threads). The harness only counts what the
library delivers.

## Fairness: the same job for every library

The ranking is only meaningful if every row did the same work. Every client, in every
language:

1. **Receives** every frame over the library's own WebSocket client (or, for a library
   with no client, the one its real users pair it with: a variant).
2. **Parses** every event fully into the library's own event type: all seven fields
   decoded, escapes resolved. No lazy shortcut that skips fields the app would read.
3. **Verifies every event**: recomputes the id from the decoded fields (SHA-256 of the
   NIP-01 serialization) and compares it with the `id` field, and checks the BIP-340
   signature. If the library skips either half, the harness adds the library's own
   function for it. No sampling, no "already verified" cache carried over from an earlier
   run, no trusting the relay.
4. **Delivers** each valid event to the app as the library's event object and drops the
   invalid ones. Each library may deliver or drop the expired events, and accept or reject
   the ambiguous one; the report shows which.
5. **Does the same app work per event**: the harness callback only counts the event and
   XORs its id into the accepted set. Nothing else, in every language.

Every client uses one relay and one subscription, through the library's streaming API
(callback, channel, flow, iterator). The headline row uses the client the library's own
docs and apps use (go-nostr's `Relay`, Quartz's `NostrClient`, nostr-sdk's `Client`), even
when that client is a pool, configured with the one relay. The library's other APIs (a pool
next to a single-relay client, fetch-all instead of subscribe) are variants
(`variant: true`), shown but not ranked.

**Configuration.** Library defaults, except what is needed to do the job above correctly,
each named in `notes`:

- turn verification on (or to 100 %) if the default skips or samples it;
- raise timers that would cut a long download short (fake EOSE after N seconds, idle
  timeouts) and limits that would drop events (`max_events`, channel sizes); never lower
  anything;
- silence per-event logging to the console (an app configures its logger), keeping the
  library's own work;
- turn off work outside the job that an ordinary documented option switches off: event
  stores, caches and databases, dedup trackers the app picks, proof-of-work checks,
  NIP-11 fetches, grouping or batching delays before the `REQ`, re-matching events
  against the filter.

**Nothing beyond the job, nothing short of it.** A ranked row stores nothing: no event
store, cache, index or database, in the library or the harness. Work the library does
unconditionally (a dedup set it always keeps, a second parse inside its API, a log
string it always builds) is its cost: the row keeps it and `notes` name it. A library's
store or cache path is benchmarked only as a variant, and only when it adds information.
A row that does a different amount of work than the job (an API that streams the set
twice, a parser that never decodes content) is either fixed, left unranked with the
reason in `notes`, or dropped. When the library's id check is missing, the harness calls
the library's own id function and compares, so every row hashes and compares the id.

**Timing.** Connecting, the WebSocket handshake and any wait the API needs before it can
subscribe happen in untimed setup when the API lets the app wait for them; when it
doesn't, `notes` say the connect is inside the run. Nothing the job needs (parsing,
verification) is moved outside the run, and classifying the delivered ids (ambiguous,
expired) happens after the run, not in the per-event callback.

A build option or setting the library documents for speed (a libsecp256k1 backend behind
a build tag, a native verifier plugin) is a client entry of its own, not a variant: the
ranking shows each library at its fastest documented configuration, and the
default-configuration row is listed next to it. A row may not use a patched copy of a
library; a library that only works with a patch gets an `error` row and the patch is
described in the harness README. A loader shim that only lets the runtime load the
unmodified package (a module-resolution hook for a package published with broken import
paths) is not a patch; name it in `notes`.

**Delivery is the library's.** An event the library keeps to itself (a store or feed that
skips an older replaceable version, a `created_at` filter, a dedup rule) counts as not
delivered: the row is wrong for that workload, and its `notes` say why.

**Threads.** A library may verify on as many threads as its default configuration uses
(that is its design), and a documented option that verifies on more threads (a parallel
verifier accessory) is a speed option like any other: a ranked entry of its own, next to
the default row. The harness never adds threads. Clients run one at a time, so no two
libraries share the machine. The ranking is by wall time on the machine's cores; the
report also ranks by CPU time per event (all threads summed: the work the job costs) and
shows the cores used (CPU / wall), so a library that is fast only because it uses every
core is visible as such.

**Build flags.** Compiled harnesses build for a generic CPU of the architecture, as apps
ship: Go `GOAMD64=v1`, Rust's default `x86-64` target (no `-C target-cpu=native`), Zig
`-Dcpu=baseline`. JIT runtimes (JVM, V8, .NET) compile for the machine they run on; that
is how they ship.

**Same conditions.** One relay, one machine, the same workload bytes, warm-up runs, one
client at a time in a fresh process, runtime flags as a typical app ships them (recorded
in `runtime`).

## The relay

`relay/` (Rust, `blast-relay`) answers every `REQ` with every event of a workload, in file
order, as `["EVENT",<sub>,<event>]` text frames, then `["EOSE",<sub>]`. Each event is the
exact bytes of its corpus line (what a real relay sent in 2024). It ignores filters,
stores nothing, never compresses (no `permessage-deflate`), answers `EVENT` with an
accepting `OK`, and assembles frames into 1 MiB writes, so it spends about 1 ms of CPU per
27 MB stream and is never the bottleneck (Node's bare `WebSocket`, which does nothing with
the frames, drains the `all` workload at ~400,000 events/s).

The workload is the URL path: `ws://127.0.0.1:7777/all`, `…/notes`. The top-level
`run.sh` builds and starts one relay and passes `--relay ws://127.0.0.1:7777` to every
harness; a harness connects to `<relay>/<workload>`.

## Input: the corpus

`.corpus/` (built by `corpus/prepare.py`, git-ignored): the 31,161 events of
nostrJsonBench, one per line, and `manifest.json` with, per workload: `name`, `file`,
`events`, `bytes`, `valid_events`, `valid_id_xor`, `ambiguous_ids` and `expired_ids`.

`smoke` (1,417 events, 1.1 MB) is a slice of `all` that keeps every case a client can get
wrong: every 32nd event plus the ambiguous one, all expired ones, the `created_at: 0` one,
the one whose text contains a literal `\u0000`, and a quarter of the invalid ones. Run it first (`./run.sh --quick --workloads smoke`) to
check that every client delivers the same set before the long runs.

The corpus is real: 1,547 of its events are **invalid** and must be dropped by every
client. Most are unsigned NIP-17 rumors (`"sig":""`, kinds 14, 7, 2044, 1) that a client
had decrypted out of gift wraps and stored. One event is **ambiguous**: its content holds a
U+0000, and its id matches only when the serializer writes it as `\u0000` (what
`JSON.stringify` and serde_json do) instead of verbatim (the letter of NIP-01). Either
outcome is correct for an ambiguous event; the report shows which way each library went.

The corpus's invalid events are all invalid the same way (an empty `sig`), so they cannot
show whether a client compares the id. Three **forged** workloads, built from ~200 clean
valid events of `all`, check verification itself: each valid event is sent with a forged
copy, the copy first for every other event (a client that marks an id as seen before
verifying it then loses the genuine one):

| workload | the forged copy | caught by |
|---|---|---|
| `forged-content` | content changed, `id` and `sig` kept | recomputing the id (the sig still matches the `id` field) |
| `forged-id` | `id` field changed, content and `sig` kept | comparing the recomputed id with the `id` field |
| `forged-sig` | another event's `sig` | the signature check |

Only the genuine events are valid (`"forged": true` in the manifest). They are correctness
checks, not speed runs: every client runs them once (`--quick`). A client that fails one
is still ranked on speed; the ranking flags the failure next to its time.

66 valid events are **expired**: a NIP-40 `expiration` tag that passed in 2024 (kinds 15,
30315 and 1). Some libraries drop expired events (rust-nostr does, unconditionally). A
library may deliver all of them or none of them; the report shows which. They are part of
`valid_events` and `valid_id_xor`.

## Correctness: the accepted set

The harness counts every event the library delivers as valid (`accepted`) and XORs their
32-byte ids (`accepted_xor`, lowercase hex of the 32-byte XOR, taken from the id field of
the library's own event object). A row is correct (`accepted_ok: true`) when

    expired_accepted is 0 or len(expired_ids)
    accepted     == valid_events - len(expired_ids) + expired_accepted + ambiguous_accepted
    accepted_xor == valid_id_xor XOR (ids of the expired events it dropped)
                                 XOR (ids of the ambiguous events it accepted)

`ambiguous_accepted` and `expired_accepted` are how many of `ambiguous_ids` and
`expired_ids` the library delivered. Every run must
deliver the same set as the first; a run that doesn't is an error. A row with
`accepted_ok: false` (it accepted an invalid event, rejected a valid one, delivered a
duplicate, or stopped early) is still reported but not ranked.

## Verification: whose code

`verify` says who verified the events:

| verify | meaning |
|---|---|
| `library` | the library verifies every event itself before delivering it (its default, or a documented option the harness turns on, named in `notes`) |
| `explicit` | the library delivers events unverified by default; the harness calls the library's **own** verify function (id + signature) on every delivered event, inside the run, and drops the ones that fail |
| `harness` | the library has no verify function at all; the harness verifies with the language's usual secp256k1 binding, named in `crypto`. Diagnostic: such a row is reported, ranked separately |

If a library's verify checks only the signature, the harness also calls its id check
(recompute the hash and compare). If a library samples (verifies only a fraction of
events, e.g. NDK's validation ratio) or caches verification by id, the harness configures
it to verify every event of every run and says how in `notes`. `crypto` names the
secp256k1 implementation that actually ran (e.g. `libsecp256k1 0.6 (C, via secp256k1-sys)`,
`@noble/curves 1.9 (pure JS)`, `btcec/v2 (pure Go)`).

## A run

1. **Setup, untimed.** Create a **new** client instance (pool, relay object, NDK, …) and,
   where the API lets the app connect explicitly, connect it to `<relay>/<workload>` and
   wait for the connection to open. A new instance per run keeps the library's per-client
   caches (seen ids, verified ids, event stores) from turning a later run into a no-op;
   clear process-global caches the same way and say so in `notes`. If the library only
   connects lazily on the first subscription, the connect is inside the timed part; say so
   in `notes` (it is ~1 ms on loopback).
2. **Timed.** `t0` = a monotonic clock, read right before calling the library's
   subscription API with one filter `{"limit": <events in the workload>}` (a filter every
   library accepts that matches every event; `limit` is ignored by filter matching).
   Use the library's streaming subscription (callback, channel, flow, iterator) as an app
   rendering a feed would; a fetch-all API that returns a list after EOSE may be a second
   client entry. For each event the library delivers: verify it if `verify` is
   `explicit`, then `accepted += 1`, XOR its id into `accepted_xor`, note the time.
   Record the time EOSE is delivered to the app.
3. **End.** The run ends at `t_end = max(EOSE time, time of the last accepted event)`:
   some libraries verify on other threads and keep delivering after the EOSE. The harness
   waits until EOSE has been seen and either `accepted` is complete (`valid_events` +
   every ambiguous event, expired ones included) or no event has arrived for 1 s (a
   library that drops the expired or the ambiguous events, or a broken one); the wait
   after `t_end` is not timed. A run that sees no EOSE within `--timeout-ms` is an
   error.
4. **Teardown, untimed.** Close the subscription and the client.

Per client and workload: `--warmup-runs` runs (default 2) that are timed but not
ranked, so JITs, connection pools and allocators are warm; then measured runs until at
least `--min-runs` (default 5) runs are done **and** their timed parts add up to
`--min-time-ms` (default 10 000),
stopping at `--max-runs` (default 30). The first warm-up run is also reported alone as
`first_run_ms`: a cold library, as on app startup.

**CPU and memory.** Per run, the process CPU time (user + system, all threads; e.g.
`getrusage(RUSAGE_SELF)`, `process.cpuUsage()`, `OperatingSystemMXBean.getProcessCpuTime`)
over the timed part: `cpu_ms`. A library that verifies on several threads can be faster
than a single-threaded one on the wall clock and still burn more CPU; `cpu_ms` shows it.
`peak_rss_mb` is the process's peak resident set at the end (`ru_maxrss`), over warm-up
and every run.

Peak RSS counts the runtime too (a JVM, a JavaScript engine or a Python interpreter holds
tens to hundreds of MB before the library sees an event), so two more numbers isolate the
library:

- `base_rss_mb`: the process's current resident set (`VmRSS` in `/proc/self/status`,
  `process.memoryUsage().rss`, `task_info` on macOS, …) at the end of the **first** setup,
  just before the first REQ: runtime and library loaded, client connected, no event
  received yet. Read it after a full GC where the runtime offers one cheaply
  (`System.gc()`, `runtime.GC()`, `GC.Collect()`), so it is the steady state, not leftover
  startup garbage. The report shows `peak_rss_mb - base_rss_mb` as the memory the run
  itself took.
- `alloc_bytes`: heap bytes the process allocated over the timed part of each run (all
  threads), read from the runtime's own cumulative counter just before `t0` and just after
  `t_end`; the row reports the median run's value, and the report divides it by the events
  sent (`alloc B/event`). Sources: JVM `com.sun.management.ThreadMXBean.
  getTotalThreadAllocatedBytes()` (live and terminated threads), Go
  `runtime.MemStats.TotalAlloc`, .NET `GC.GetTotalAllocatedBytes(true)`, Rust a counting
  `#[global_allocator]` around `System`, Zig a counting wrapper around the allocator the
  harness hands the library. Memory a library allocates outside that counter (C code
  calling `malloc` directly, a native addon) is not counted: say so in `notes` when the
  library does. A runtime without a cumulative counter reports `null`; do not substitute
  a sampled or current-heap number. Reading the counter must not trigger a GC or add work
  inside the timed part (Go's `ReadMemStats` stops the world: read it outside `t0`..`t_end`).
  Compare `alloc B/event` within a runtime: runtimes count differently (a JVM TLAB, a Go
  size class, a Rust exact request).

**Isolation.** Every client runs in a **fresh process** (the harness re-executes itself or
launches one binary per client), so one library's JIT profile, heap, thread pools and
global caches never tax the next. Clients run one after another, never in parallel.

## Command line

Every harness exposes the same flags through its launcher (`<harness>/run.sh`):

```
--relay URL           default ws://127.0.0.1:7777 (the harness appends /<workload>)
--corpus DIR          default .corpus
--out FILE            default results/<harness>.json
--workloads a,b       default: all (the workload named "all")
--clients x,y         default: every client of the harness
--warmup-runs N       default 2
--min-runs N          default 5
--min-time-ms N       default 10000
--max-runs N          default 30
--timeout-ms N        per run, default 300000
--quick               warmup-runs 1, min-runs 2, min-time-ms 0 (smoke test; overrides those flags)
--list                print client ids, one per line, and exit
```

Launchers run from the repo root, so relative paths are relative to it. A launcher
builds its project from pinned versions (lockfile) before running.

## Output

`results/<harness>.json`:

```json
{
  "harness": "node",
  "language": "JavaScript",
  "runtime": "Node.js 22.23.4 (V8 12.4)",
  "host": { "cpu": "…", "cores": 4, "os": "Linux 6.x" },
  "settings": { "warmup_runs": 2, "min_runs": 5, "min_time_ms": 10000, "max_runs": 30 },
  "relay": "ws://127.0.0.1:7777",
  "corpus_fingerprint": "<manifest.fingerprint>",
  "results": [
    {
      "client": "nostr-tools-relay",
      "library": "nostr-tools",
      "version": "2.17.0",
      "license": "Unlicense",
      "api": "Relay.connect + relay.subscribe (one relay)",
      "websocket": "Node 22 global WebSocket (undici)",
      "crypto": "@noble/curves 2.0 (pure JS)",
      "verify": "library",
      "notes": "",
      "variant": false,
      "workload": "all",
      "events": 31161, "bytes": 26995371,
      "accepted": 29614,
      "accepted_xor": "…",
      "ambiguous_accepted": 1,
      "expired_accepted": 66,
      "accepted_ok": true,
      "errors": 0, "error": null,
      "warmup_runs": 2, "runs": 5,
      "first_run_ms": 4012.1,
      "median_ms": 3501.2, "min_ms": 3480.0, "p90_ms": 3550.9,
      "run_ms": [3501.2, 3480.0, 3550.9, 3499.0, 3510.3],
      "events_per_s": 8900.0,
      "us_per_event": 112.4,
      "cpu_ms": 3620.5,
      "peak_rss_mb": 210.4,
      "base_rss_mb": 61.2,
      "alloc_bytes": null
    }
  ]
}
```

Derived from the median run: `events_per_s = events / (median_ms / 1000)` and
`us_per_event = median_ms * 1000 / events`, over **every** event the relay sent (valid or
not: rejecting an invalid event is work too). `cpu_ms` is the median of the runs' CPU
times. A client that fails (throws, never sees EOSE, crashes) still gets a row with
`error` set and null timings; `errors` is the number of runs that failed (a harness stops
at the first, so it is 0 or 1).

Streams can end early without an error (a library that drops events when the app falls
behind its reader); "every run must deliver the same set as the first" is what catches it,
so keep that check even when a library looks reliable.

`client` ids are unique within a harness, lowercase, `<library>-<variant>`. Record the
library's resolved version and its license (SPDX) as found in its own LICENSE file or
package metadata. `variant: true` marks a diagnostic row (another API or option of a
library that has a headline row); the report ranks one row per library: its fastest
correct, non-variant row on `all`.
