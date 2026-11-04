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
checks and the failures with their reasons: [report.md](results/reference/2026-11-04/report.md).

## Results

Each row is one library on one runtime, at its fastest correct configuration. The clock
runs from the REQ to the EOSE over all 31,161 events (1,547 of them invalid). Every library
does the same job: one connection, one subscription, every event parsed, its id recomputed
and compared, its signature verified, and handed to a callback that only counts it. Nothing
is stored: a store, cache, dedup tracker, NIP-11 fetch or batching delay that an option can
turn off is off, and the work a library cannot turn off is named in its notes.

Measured on 2026-11-04 on a shared 4-core Xeon cloud VM (2.1 GHz), one client at a time; the
two Quartz rows were re-run later that day on Quartz 2.15.1. Native code is built for a generic x86-64 CPU
(Go `GOAMD64=v1`, Rust's default target, Zig `-Dcpu=baseline`); the JVM, V8, JavaScriptCore and
.NET JITs compile for the machine they run on.

The harness never adds threads. A library verifies on as many cores as its default uses,
and a documented parallel verifier is a speed option with its own row; "cores used" is CPU
time over wall time. Quartz's rows are in bold. Both use Quartz's one-relay read, `fetch`:
`quartz-fetch` verifies each event inline with `Event.verify()`, as Amethyst does, and
`quartz-parallelverifier`, Quartz's documented speed option, hands each event to its
`ParallelEventVerifier`, which verifies batches on every core.

| # | language | client | µs/event | CPU µs/event | cores used | accepted | memory growth MB | alloc B/event | forged checks |
|---:|---|---|---:|---:|---:|---:|---:|---:|---|
| **1** | **JVM (Kotlin/Java)** | **`quartz-parallelverifier`** | **18.9** | **54.4** | **2.88** | **29,614** | **227** | **3,594** | pass |
| **–** | **JVM (Kotlin/Java)** | **`quartz-fetch`** (default) | **45.3** | **55.4** | **1.22** | **29,614** | **188** | **3,620** | pass |
| 2 | Zig | `zig-nostr-relay` | 47.5 | 46.1 | 0.97 | 29,614 | 1 | 1,673 | pass |
| 3 | Go | `fiatjaf-nostr-relay-libsecp256k1` | 51.7 | 87.8 | 1.70 | 29,613 | 6 | 4,036 | pass |
| 4 | Rust | `nostr-sdk-stream` | 53.0 | 56.2 | 1.06 | 29,548 | 65 | 8,722 | pass |
| 5 | Rust | `nostro2-relay-secp256k1` | 56.2 | 67.4 | 1.20 | 29,614 | 3 | 2,758 | pass |
| 6 | Rust | `nostr_rust-next_data` | 58.0 | 56.9 | 0.98 | 29,614 | 2 | 11,038 | pass |
| 7 | C#/.NET | `nostr-sdk` | 59.0 | 69.2 | 1.17 | 29,548 | 284 | 2,346 | pass |
| 8 | Python | `monstr-subscribe` | 60.5 | 60.2 | 0.99 | 29,614 | 71 | – | pass |
| 9 | Go | `go-nostr-relay-libsecp256k1` | 66.3 | 88.8 | 1.34 | 29,614 | 6 | 5,312 | pass |
| 10 | JVM (Kotlin/Java) | `nostr4j-pool` | 69.3 | 237.2 | 3.42 | 29,548 | 1,445 | 139,590 | pass |
| 11 | Rust | `nostr-types-client` | 71.4 | 77.1 | 1.08 | 29,614 | 69 | 3,830 | pass |
| 12 | JavaScript (Bun) | `nostr-sdk-node` | 75.8 | 128.7 | 1.70 | 29,548 | 348 | – | pass |
| 13 | Python | `nostr-sdk-notifications` | 115.0 | 166.5 | 1.45 | 29,548 | 71 | – | pass |
| 14 | JavaScript (Node) | `qntx-nostr-wasm` | 121.4 | 120.9 | 1.00 | 29,614 | 11 | – | pass |
| 15 | JavaScript (Deno) | `qntx-nostr-wasm` | 140.4 | 144.0 | 1.03 | 29,614 | 46 | 6,653 | pass |
| 16 | C#/.NET | `nnostr` | 153.7 | 161.8 | 1.05 | 29,614 | 270 | 16,427 | pass |
| 17 | C#/.NET | `nostra` | 172.3 | 173.8 | 1.01 | 29,614 | 168 | 33,249 | pass |
| 18 | JavaScript (Bun) | `qntx-nostr-wasm` | 182.4 | 183.5 | 1.01 | 29,614 | 24 | – | pass |
| 19 | C#/.NET | `nostr-client` | 194.4 | 197.1 | 1.01 | 29,614 | 167 | 57,957 | pass |
| 20 | C#/.NET | `blockcore-nostr-client` | 200.2 | 206.0 | 1.03 | 29,614 | 180 | 62,835 | pass |
| 21 | Go | `nmilat-read` | 204.2 | 270.2 | 1.32 | 29,614 | 29 | 10,287 | pass |
| 22 | JVM (Kotlin/Java) | `nostr-sdk-subscribe` | 241.2 | 476.2 | 1.97 | 29,548 | 1,373 | 105,354 | pass |
| 23 | Python | `nostrj` | 306.5 | 322.8 | 1.05 | 29,614 | 40 | – | pass |
| 24 | JavaScript (Node) | `welshman-nodelay` | 325.4 | 330.3 | 1.02 | 29,614 | 82 | – | **fails**: censored by a forged copy |
| 25 | Python | `nostrclient` | 328.4 | 339.3 | 1.03 | 29,614 | 109 | – | **fails**: censored by a forged copy |
| 26 | JavaScript (Node) | `nostr-tools-relay-wasm` | 335.7 | 333.8 | 0.99 | 29,614 | 31 | – | pass |
| 27 | JavaScript (Bun) | `nostr-tools-relay-wasm` | 384.8 | 381.1 | 0.99 | 29,614 | 49 | – | pass |
| 28 | JavaScript (Bun) | `welshman-nodelay` | 417.0 | 421.6 | 1.01 | 29,614 | 126 | – | **fails**: censored by a forged copy |
| 29 | JavaScript (Deno) | `nostr-tools-relay-wasm` | 426.2 | 423.4 | 0.99 | 29,614 | 55 | 11,397 | pass |
| 30 | JavaScript (Deno) | `welshman-nodelay` | 470.7 | 474.4 | 1.01 | 29,614 | 162 | 12,169 | **fails**: censored by a forged copy |
| 31 | JavaScript (Bun) | `nostrify-relay` | 738.5 | 793.5 | 1.07 | 29,614 | 40 | – | pass |
| 32 | JavaScript (Deno) | `nostrify-relay` | 820.7 | 824.1 | 1.00 | 29,614 | 152 | 977,456 | pass |
| 33 | JavaScript (Deno) | `applesauce-relay` | 881.1 | 886.4 | 1.01 | 29,614 | 128 | 974,400 | pass |
| 34 | JavaScript (Bun) | `applesauce-relay` | 884.2 | 967.9 | 1.09 | 29,614 | 38 | – | pass |
| 35 | JavaScript (Bun) | `rx-nostr` | 938.8 | 1,041.3 | 1.11 | 29,548 | 43 | – | pass |
| 36 | JavaScript (Deno) | `rx-nostr` | 1,017.7 | 1,020.5 | 1.00 | 29,548 | 93 | 971,403 | pass |
| 37 | JavaScript (Bun) | `ndk` | 1,606.6 | 1,634.6 | 1.02 | 29,614 | 125 | – | **fails**: censored by a forged copy |
| 38 | JavaScript (Node) | `nostrify-relay` | 1,903.4 | 1,893.1 | 0.99 | 29,614 | 56 | – | pass |
| 39 | JavaScript (Node) | `applesauce-relay` | 1,929.7 | 1,909.3 | 0.99 | 29,614 | 50 | – | pass |
| 40 | JavaScript (Node) | `rx-nostr` | 2,043.8 | 2,032.8 | 0.99 | 29,548 | 66 | – | pass |
| 41 | JavaScript (Deno) | `ndk` | 2,194.6 | 2,190.9 | 1.00 | 29,614 | 137 | 1,249,608 | **fails**: censored by a forged copy |
| 42 | JavaScript (Node) | `ndk` | 3,282.4 | 3,250.1 | 0.99 | 29,614 | 83 | – | **fails**: censored by a forged copy |
| 43 | Dart | `nostr_tools` | 12,087.1 | 11,973.0 | 0.99 | 29,614 | 66 | – | pass |
| 44 | Dart | `dart_nostr` | 12,381.1 | 12,279.8 | 0.99 | 29,614 | 106 | – | **fails**: censored by a forged copy |
| 45 | Dart | `nostr_nips` | 12,812.3 | 12,703.7 | 0.99 | 29,614 | 96 | – | pass |
| 46 | Ruby | `nostr-client` | 13,356.4 | 13,233.0 | 0.99 | 29,614 | 26 | – | pass |
| 47 | JVM (Kotlin/Java) | `nostr-java-relaypool` | 14,618.9 | 14,670.3 | 1.00 | 29,614 | 197 | 3,860,197 | **fails**: censored by a forged copy |

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
