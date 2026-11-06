# Nostr Client Library Benchmark

How fast can a Nostr client library take a relay's events from its own WebSocket client,
through its JSON parser, to a verified event in the app? How much memory does that take? And
does it verify them right?

We ran 59 libraries in 11 languages (JavaScript on Node, Bun and Deno) against a local relay
that streams the same 31k real events as fast as the socket takes them. Counting each
library's APIs, crypto backends and runtimes, that is 129 configurations. Every row's set of
delivered events is checked against the corpus: exactly the 29,613 valid ones, nothing
forged, nothing lost.

How it works: [HARNESS.md](HARNESS.md). Every table, including the variants, the forged-event
checks and the failures with their reasons: [report.md](results/reference/2026-11-05/report.md).

## Results

Each row is one library on one runtime, at its fastest correct configuration. The clock
runs from the REQ to the EOSE over all 31,161 events (1,547 of them invalid). Every library
does the same job: one connection, one subscription, every event parsed, its id recomputed
and compared, its signature verified, and handed to a callback that only counts it. Nothing
is stored: a store, cache, dedup tracker, NIP-11 fetch or batching delay that an option can
turn off is off, and the work a library cannot turn off is named in its notes.

Measured on 2026-11-05 on a shared 4-core Xeon cloud VM (2.1 GHz), one client at a time, with
Quartz 2.16.0. A Go row measured at the start, between the two passes and at the end tracks the
host's speed (63.8-66.8 µs/event over the run); the slow Dart rows ran after a container restart,
on a host about 20% faster, and say so in the report. Native code is built for a generic x86-64 CPU
(Go `GOAMD64=v1`, Rust's default target, Zig `-Dcpu=baseline`); the JVM, V8, JavaScriptCore and
.NET JITs compile for the machine they run on.

The JVM rows ran on JDK 21. The harness now runs on JDK 27, which on one host matched JDK 21
on warm runs and was 6-9% faster on the first: [2026-11-06 JDK 27 rerun](results/reference/2026-11-06-jdk27/README.md).

The harness never adds threads. A library verifies on as many cores as its default uses,
and a documented parallel verifier is a speed option with its own row; "cores used" is CPU
time over wall time. Quartz's rows are in bold. Both use Quartz's one-relay read, `fetch`:
`quartz-fetch` verifies each event inline with `Event.verify()`, as Amethyst does, and
`quartz-parallelverifier`, Quartz's documented speed option, hands each event to its
`ParallelEventVerifier`, which verifies batches on every core.

| # | language | client | µs/event | CPU µs/event | cores used | accepted | memory growth MB | alloc B/event | forged checks |
|---:|---|---|---:|---:|---:|---:|---:|---:|---|
| **1** | **JVM (Kotlin/Java)** | **`quartz-parallelverifier`** | **21.1** | **63.9** | **3.03** | **29,614** | **269** | **3,607** | pass |
| 2 | Zig | `zig-nostr-relay` | 46.2 | 45.6 | 0.99 | 29,614 | 1 | 1,673 | pass |
| **–** | **JVM (Kotlin/Java)** | **`quartz-fetch`** (default) | **48.7** | **62.4** | **1.28** | **29,614** | **267** | **3,631** | pass |
| 3 | Rust | `nostr-sdk-stream` | 55.3 | 58.8 | 1.06 | 29,548 | 61 | 8,718 | pass |
| 4 | Rust | `nostr_rust-next_data` | 57.9 | 57.2 | 0.99 | 29,614 | 2 | 11,038 | pass |
| 5 | Rust | `nostro2-relay-secp256k1` | 60.9 | 71.8 | 1.18 | 29,614 | 3 | 2,758 | pass |
| 6 | C#/.NET | `nostr-sdk` | 62.3 | 75.9 | 1.22 | 29,548 | 275 | 2,225 | pass |
| 7 | Go | `fiatjaf-nostr-relay-libsecp256k1` | 64.9 | 107.6 | 1.66 | 29,613 | 6 | 4,036 | pass |
| 8 | Python | `monstr-subscribe` | 64.9 | 64.8 | 1.00 | 29,614 | 70 | – | pass |
| 9 | JavaScript (Bun) | `nostr-sdk-node` | 70.4 | 105.9 | 1.50 | 29,548 | 348 | – | pass |
| 10 | Rust | `nostr-types-client` | 71.3 | 76.0 | 1.06 | 29,614 | 78 | 3,830 | pass |
| 11 | JVM (Kotlin/Java) | `nostr4j-pool` | 74.2 | 261.5 | 3.53 | 29,548 | 1,358 | 139,762 | pass |
| 12 | Go | `go-nostr-relay-libsecp256k1` | 74.3 | 100.1 | 1.35 | 29,614 | 6 | 5,312 | pass |
| 13 | JavaScript (Node) | `nostr-sdk-node` | 91.7 | 155.8 | 1.70 | 29,548 | 598 | – | pass |
| 14 | Python | `nostr-sdk-notifications` | 120.3 | 176.4 | 1.47 | 29,548 | 66 | – | pass |
| 15 | JavaScript (Node) | `qntx-nostr-wasm` | 129.1 | 130.1 | 1.01 | 29,614 | 13 | – | pass |
| 16 | JavaScript (Deno) | `qntx-nostr-wasm` | 130.1 | 130.9 | 1.01 | 29,614 | 47 | 6,026 | pass |
| 17 | JavaScript (Bun) | `qntx-nostr-wasm` | 168.3 | 167.8 | 1.00 | 29,614 | 23 | – | pass |
| 18 | C#/.NET | `nnostr` | 173.9 | 182.2 | 1.05 | 29,614 | 268 | 16,426 | pass |
| 19 | C#/.NET | `nostra` | 191.6 | 195.1 | 1.02 | 29,614 | 166 | 33,249 | pass |
| 20 | C#/.NET | `blockcore-nostr-client` | 215.1 | 218.9 | 1.02 | 29,614 | 173 | 62,845 | pass |
| 21 | C#/.NET | `nostr-client` | 216.9 | 222.2 | 1.02 | 29,614 | 173 | 57,957 | pass |
| 22 | Go | `nmilat-read` | 227.4 | 304.3 | 1.34 | 29,614 | 30 | 10,288 | pass |
| 23 | JVM (Kotlin/Java) | `nostr-sdk-subscribe` | 237.5 | 487.1 | 2.05 | 29,548 | 1,408 | 105,466 | pass |
| 24 | Python | `nostrj` | 323.0 | 340.9 | 1.06 | 29,614 | 39 | – | pass |
| 25 | Python | `nostrclient` | 324.4 | 337.1 | 1.04 | 29,614 | 106 | – | **fails**: a forged copy censors the genuine event |
| 26 | JavaScript (Node) | `welshman-nodelay` | 363.0 | 370.3 | 1.02 | 29,614 | 79 | – | **fails**: a forged copy censors the genuine event |
| 27 | JavaScript (Node) | `nostr-tools-relay-wasm` | 380.5 | 376.9 | 0.99 | 29,614 | 32 | – | pass |
| 28 | JavaScript (Bun) | `nostr-tools-relay-wasm` | 395.5 | 394.0 | 1.00 | 29,614 | 56 | – | pass |
| 29 | JavaScript (Bun) | `welshman-nodelay` | 397.8 | 399.1 | 1.00 | 29,614 | 131 | – | **fails**: a forged copy censors the genuine event |
| 30 | JavaScript (Deno) | `nostr-tools-relay-wasm` | 411.6 | 408.5 | 0.99 | 29,614 | 59 | 11,368 | pass |
| 31 | JavaScript (Deno) | `welshman-nodelay` | 421.6 | 427.3 | 1.01 | 29,614 | 166 | 12,053 | **fails**: a forged copy censors the genuine event |
| 32 | JavaScript (Bun) | `nostrify-relay` | 758.2 | 814.9 | 1.07 | 29,614 | 40 | – | pass |
| 33 | JavaScript (Bun) | `applesauce-relay` | 829.5 | 916.9 | 1.11 | 29,614 | 36 | – | pass |
| 34 | JavaScript (Deno) | `nostrify-relay` | 841.4 | 848.7 | 1.01 | 29,614 | 151 | 978,392 | pass |
| 35 | JavaScript (Deno) | `applesauce-relay` | 849.5 | 852.2 | 1.00 | 29,614 | 112 | 974,245 | pass |
| 36 | JavaScript (Bun) | `rx-nostr` | 898.3 | 1,005.7 | 1.12 | 29,548 | 43 | – | pass |
| 37 | JavaScript (Deno) | `rx-nostr` | 941.5 | 946.1 | 1.00 | 29,548 | 94 | 970,584 | pass |
| 38 | JavaScript (Bun) | `ndk` | 1,697.7 | 1,735.2 | 1.02 | 29,614 | 122 | – | **fails**: a forged copy censors the genuine event |
| 39 | JavaScript (Node) | `nostrify-relay` | 1,910.4 | 1,899.5 | 0.99 | 29,614 | 44 | – | pass |
| 40 | JavaScript (Node) | `applesauce-relay` | 1,932.8 | 1,918.7 | 0.99 | 29,614 | 52 | – | pass |
| 41 | JavaScript (Node) | `rx-nostr` | 2,027.1 | 2,028.5 | 1.00 | 29,548 | 64 | – | pass |
| 42 | JavaScript (Deno) | `ndk` | 2,123.1 | 2,120.9 | 1.00 | 29,614 | 148 | 1,250,220 | **fails**: a forged copy censors the genuine event |
| 43 | JavaScript (Node) | `ndk` | 3,436.0 | 3,435.7 | 1.00 | 29,614 | 83 | – | **fails**: a forged copy censors the genuine event |
| 44 | Dart | `nostr_tools` | 10,597.4 | 10,573.5 | 1.00 | 29,614 | 64 | – | pass |
| 45 | Dart | `dart_nostr` | 10,958.1 | 10,939.6 | 1.00 | 29,614 | 111 | – | **fails**: a forged copy censors the genuine event |
| 46 | Dart | `nostr_nips` | 11,199.6 | 11,170.1 | 1.00 | 29,614 | 69 | – | pass |
| 47 | Ruby | `nostr-client` | 13,701.7 | 13,633.5 | 1.00 | 29,614 | 26 | – | pass |
| 48 | JVM (Kotlin/Java) | `nostr-java-relaypool` | 14,956.2 | 15,048.6 | 1.01 | 29,614 | 202 | 3,860,448 | **fails**: a forged copy censors the genuine event |
| 49 | PHP | `nostr-php-persistent` | 86,253.3 | 85,852.0 | 1.00 | 29,614 | 88 | – | pass |

**Accepted** is the count the row delivered: 29,613 valid events, plus the one ambiguous
event if the library takes it, minus the 66 expired ones (29,547 or 29,548) if it drops
them. A row that fails a [verification check](#verification-checks) is ranked on speed and
flagged in the last column.

**Memory** leaves the runtime out. *Memory growth* is how much the process's resident memory
grew from the end of its first setup (runtime and library loaded, connected, after a GC) to its
peak over every run. A garbage collector grows its heap while memory is free, so a JVM row's
growth is mostly heap the collector chose to use (they run with up to 2 GB). *Alloc B/event*
is the heap the process allocated per event sent, from the runtime's own counter: the JVM,
Go, .NET, Deno's V8, and a counting allocator in Rust and Zig. Node, Bun, Python, Ruby, PHP,
Dart and Swift have no such counter (–). It does not count what native code allocates on its
own (libsecp256k1 doesn't; nostr-sdk's Rust core behind the JVM, .NET and JavaScript bindings
does), and runtimes count differently, so compare it within a runtime. Peak and base memory are
in the report.

The slowest rows (the Dart and Ruby rows and `nostr-java-relaypool`) ran once each instead
of taking the median of three or more. At over 12 ms per event, that does not change their
place.

## Verification checks

Three more workloads send 197 valid events, each with a forged copy: changed content (id
and sig kept), a changed `id` field, or another event's sig. The copy goes first for every
other event. A library that marks an id as seen before it verifies the event lets the
forged copy censor the genuine one: it keeps only the 98 events whose genuine copy came
first. A library that fails a check is still ranked on speed, with the failure flagged in
the ranking.

| failure | libraries |
|---|---|
| a forged copy censors the genuine event (dedup by id before verifying) | the go-nostr and fiatjaf.com/nostr pools (their single-relay `Relay` passes), nostr-tools' `SimplePool` (JS), NDK (JS), welshman, nostr-java, dart_nostr, swift-nostr (websocket-kit transport), aionostr, basic-nostr, nostrclient, libnostr-z's pool |
| delivers an event whose `id` field is wrong | pynostr's pool |

No library that ran the checks accepted forged content or a forged signature.

## Not ranked

| reason | libraries |
|---|---|
| JSON escapes break the id check (`\uXXXX` kept verbatim, or the raw text hashed): ~2,380 valid events lost | orly, NostrNet, libnostr-z, nostrdb |
| other valid events rejected | Rhodium (tags of 2–4 values only), NostrSharp (`GetId` clears tags of 6+ values), nostrb (99 values per tag), ndk for Dart, aionostr and python-nostr (`created_at: 0` becomes now), nostr-dartio (rejects `created_at: 0`), nostr_dart and nostr_client (they pin bip340 0.0.4, which drops a pubkey's leading zero byte: 83 events), nostr-tools for Python (escaped NUL), snort (one event per replaceable key, none with `created_at: 0`) |
| crashes on an invalid event | snort-system (JS), nip01 (Dart), pynostr |
| loses events, a different set every run | nostr-sdk on Node and Deno, nostr-sdk's stream API on the JVM and in Python, NNostr's `SubscribeForEvents`, goNDK |
| never reaches EOSE | nmilat's `Subscribe` (its read loop blocks after 10,240 messages), electrum-aionostr (sleeps 5 s after every invalid event), nostr-php (slows down with every event: 25,768 events in 45 min) |
| not run on Linux | nostr-sdk-ios, NostrEssentials, rust-nostr's Swift bindings (Apple-only), swift-nostr's default `URLSession` transport |

nostr-php's one-request API took 46 ms per event on the 1,417-event smoke workload, so it
did not run on the full set.

nostrdb is a database, not a client: it writes every event to LMDB before it delivers it,
so its row is a variant either way.

## Run

```bash
./run.sh                         # every harness whose toolchain is installed, several hours
./run.sh --quick                 # smoke test
./run.sh --only jvm,rust         # a subset
./run.sh --quick --workloads forged-content,forged-id,forged-sig   # the verification checks
```

Most Swift libraries need Apple's frameworks: run `./swift/run.sh` on a Mac (see
[swift/README.md](swift/README.md) for what to check there).
