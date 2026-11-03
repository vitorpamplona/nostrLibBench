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

The corpus is real: 1,547 of its events are **invalid** and must be dropped by every
client. Most are unsigned NIP-17 rumors (`"sig":""`, kinds 14, 7, 2044, 1) that a client
had decrypted out of gift wraps and stored. One event is **ambiguous**: its content holds a
U+0000, and its id matches only when the serializer writes it as `\u0000` (what
`JSON.stringify` and serde_json do) instead of verbatim (the letter of NIP-01). Either
outcome is correct for an ambiguous event; the report shows which way each library went.

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
   waits until EOSE has been seen and either `accepted` is complete (valid + every
   ambiguous) or no event has arrived for 1 s (rejected ambiguous / broken library); the
   wait after `t_end` is not timed. A run that sees no EOSE within `--timeout-ms` is an
   error.
4. **Teardown, untimed.** Close the subscription and the client.

Per client and workload: `--warmup-runs` runs (default 2) that are timed but not
ranked, so JITs, connection pools and allocators are warm; then measured runs until at
least `--min-runs` (default 5) runs **and** `--min-time-ms` (default 10 000) have passed,
stopping at `--max-runs` (default 30). The first warm-up run is also reported alone as
`first_run_ms`: a cold library, as on app startup.

**CPU and memory.** Per run, the process CPU time (user + system, all threads; e.g.
`getrusage(RUSAGE_SELF)`, `process.cpuUsage()`, `OperatingSystemMXBean.getProcessCpuTime`)
over the timed part: `cpu_ms`. A library that verifies on several threads can be faster
than a single-threaded one on the wall clock and still burn more CPU; `cpu_ms` shows it.
`peak_rss_mb` is the process's peak resident set at the end (`ru_maxrss`), over warm-up
and every run.

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
--quick               warmup-runs 1, min-runs 2, min-time-ms 0 (smoke test)
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
      "peak_rss_mb": 210.4
    }
  ]
}
```

Derived from the median run: `events_per_s = events / (median_ms / 1000)` and
`us_per_event = median_ms * 1000 / events`, over **every** event the relay sent (valid or
not: rejecting an invalid event is work too). `cpu_ms` is the median of the runs' CPU
times. A client that fails (throws, never sees EOSE, crashes) still gets a row with
`error` set and null timings.

`client` ids are unique within a harness, lowercase, `<library>-<variant>`. Record the
library's resolved version and its license (SPDX) as found in its own LICENSE file or
package metadata. `variant: true` marks a diagnostic row (another API or option of a
library that has a headline row); the report ranks one row per library: its fastest
correct, non-variant row on `all`.
