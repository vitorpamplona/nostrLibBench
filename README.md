# Nostr Client Library Benchmark

How fast can a Nostr client library take a relay's events from its own WebSocket client,
through its JSON parser, to a verified event in the app? And does it verify them right?

We ran 59 libraries in 11 languages (JavaScript on Node, Bun and Deno) against a local relay
that streams the same 31k real events as fast as the socket takes them. Counting each
library's APIs, crypto backends and runtimes, that is 123 configurations. Every row's set
of delivered events is checked against the corpus: exactly the 29,613 valid ones, nothing
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

Measured on 2026-11-04 on a shared 4-core Xeon cloud VM (2.1 GHz), one client at a time.
Native code is built for a generic x86-64 CPU (Go `GOAMD64=v1`, Rust's default target, Zig
`-Dcpu=baseline`); the JVM, V8, JavaScriptCore and .NET JITs compile for the machine they
run on.

The harness never adds threads. A library verifies on as many cores as its default uses,
and a documented parallel verifier is a speed option with its own row; "cores used" is CPU
time over wall time. Quartz's rows are in bold: `quartz-parallelverifier` is Quartz's
documented speed option (it verifies batches of events on every core), and
`quartz-nostrclient`, its default client, is listed next to it.

| # | language | client | µs/event | CPU µs/event | cores used | peak RSS MB | forged checks |
|---:|---|---|---:|---:|---:|---:|---|
| **1** | **JVM (Kotlin/Java)** | **`quartz-parallelverifier`** | **22.8** | **69.5** | **3.04** | **616** | pass |
| **–** | **JVM (Kotlin/Java)** | **`quartz-nostrclient`** (default) | **46.6** | **56.8** | **1.22** | **295** | pass |
| 2 | Zig | `zig-nostr-relay` | 47.4 | 46.9 | 0.99 | 5 | pass |
| 3 | Rust | `nostr-sdk-stream` | 54.9 | 60.0 | 1.09 | 64 | pass |
| 4 | Rust | `nostr_rust-next_data` | 57.0 | 56.6 | 0.99 | 8 | pass |
| 5 | Rust | `nostro2-relay-secp256k1` | 62.4 | 74.6 | 1.20 | 8 | pass |
| 6 | C#/.NET | `nostr-sdk` | 63.0 | 74.2 | 1.18 | 343 | pass |
| 7 | Go | `fiatjaf-nostr-relay-libsecp256k1` | 65.0 | 109.6 | 1.69 | 26 | pass |
| 8 | JVM (Kotlin/Java) | `nostr4j-pool` | 66.5 | 234.7 | 3.53 | 1,596 | pass |
| 9 | Python | `monstr-subscribe` | 68.7 | 68.1 | 0.99 | 122 | pass |
| 10 | Rust | `nostr-types-client` | 72.3 | 79.0 | 1.09 | 83 | pass |
| 11 | Go | `go-nostr-relay-libsecp256k1` | 73.3 | 99.3 | 1.36 | 25 | pass |
| 12 | JavaScript (Bun) | `nostr-sdk-node` | 75.9 | 117.9 | 1.55 | 402 | pass |
| 13 | Python | `nostr-sdk-notifications` | 127.9 | 186.6 | 1.46 | 116 | pass |
| 14 | JavaScript (Node) | `qntx-nostr-wasm` | 130.0 | 130.4 | 1.00 | 78 | pass |
| 15 | JavaScript (Deno) | `qntx-nostr-wasm` | 135.4 | 135.8 | 1.00 | 91 | pass |
| 16 | JavaScript (Bun) | `qntx-nostr-wasm` | 170.3 | 172.8 | 1.01 | 62 | pass |
| 17 | C#/.NET | `nnostr` | 172.6 | 181.2 | 1.05 | 313 | pass |
| 18 | C#/.NET | `nostra` | 199.3 | 202.5 | 1.02 | 220 | pass |
| 19 | C#/.NET | `nostr-client` | 213.8 | 217.0 | 1.01 | 228 | pass |
| 20 | C#/.NET | `blockcore-nostr-client` | 215.7 | 220.6 | 1.02 | 227 | pass |
| 21 | Go | `nmilat-read` | 232.0 | 312.4 | 1.35 | 50 | pass |
| 22 | JVM (Kotlin/Java) | `nostr-sdk-subscribe` | 250.3 | 482.0 | 1.93 | 1,638 | pass |
| 23 | Python | `nostrclient` | 321.0 | 333.5 | 1.04 | 149 | **fails**: censored by a forged copy |
| 24 | Python | `nostrj` | 330.6 | 346.9 | 1.05 | 70 | pass |
| 25 | JavaScript (Node) | `welshman-nodelay` | 377.6 | 383.2 | 1.01 | 232 | **fails**: censored by a forged copy |
| 26 | JavaScript (Bun) | `welshman-nodelay` | 382.9 | 389.9 | 1.02 | 182 | **fails**: censored by a forged copy |
| 27 | JavaScript (Node) | `nostr-tools-relay-wasm` | 402.7 | 399.2 | 0.99 | 94 | pass |
| 28 | JavaScript (Deno) | `welshman-nodelay` | 415.8 | 421.0 | 1.01 | 280 | **fails**: censored by a forged copy |
| 29 | JavaScript (Bun) | `nostr-tools-relay-wasm` | 422.1 | 420.8 | 1.00 | 86 | pass |
| 30 | JavaScript (Deno) | `nostr-tools-relay-wasm` | 434.6 | 436.2 | 1.00 | 109 | pass |
| 31 | JavaScript (Bun) | `nostrify-relay` | 797.6 | 866.7 | 1.09 | 87 | pass |
| 32 | JavaScript (Bun) | `applesauce-relay` | 807.1 | 892.4 | 1.11 | 81 | pass |
| 33 | JavaScript (Deno) | `applesauce-relay` | 902.7 | 912.1 | 1.01 | 185 | pass |
| 34 | JavaScript (Bun) | `rx-nostr` | 927.2 | 1,036.2 | 1.12 | 73 | pass |
| 35 | JavaScript (Deno) | `nostrify-relay` | 933.0 | 943.8 | 1.01 | 206 | pass |
| 36 | JavaScript (Deno) | `rx-nostr` | 1,039.9 | 1,042.6 | 1.00 | 140 | pass |
| 37 | JavaScript (Bun) | `ndk` | 1,809.1 | 1,853.3 | 1.02 | 171 | **fails**: censored by a forged copy |
| 38 | JavaScript (Node) | `applesauce-relay` | 1,947.4 | 1,944.4 | 1.00 | 136 | pass |
| 39 | JavaScript (Node) | `nostrify-relay` | 1,957.9 | 1,957.6 | 1.00 | 132 | pass |
| 40 | JavaScript (Node) | `rx-nostr` | 2,070.7 | 2,079.2 | 1.00 | 121 | pass |
| 41 | JavaScript (Deno) | `ndk` | 2,397.8 | 2,403.2 | 1.00 | 237 | **fails**: censored by a forged copy |
| 42 | JavaScript (Node) | `ndk` | 3,504.3 | 3,504.7 | 1.00 | 160 | **fails**: censored by a forged copy |
| 43 | Dart | `nostr_tools` | 13,636.3 | 13,508.6 | 0.99 | 104 | pass |
| 44 | Dart | `dart_nostr` | 14,141.7 | 13,954.3 | 0.99 | 117 | **fails**: censored by a forged copy |
| 45 | Dart | `nostr_nips` | 14,450.9 | 14,281.3 | 0.99 | 91 | pass |
| 46 | Ruby | `nostr-client` | 14,520.0 | 14,422.9 | 0.99 | 67 | pass |
| 47 | JVM (Kotlin/Java) | `nostr-java-relaypool` | 16,938.9 | 17,013.9 | 1.00 | 431 | **fails**: censored by a forged copy |

A row that fails a [verification check](#verification-checks) is ranked on speed and
flagged in the last column. Peak RSS is the whole process, runtime included (a JVM or a
JavaScript engine starts at tens to hundreds of MB, a native binary at a few), and a garbage
collector grows its heap while memory is free: compare it within a runtime, not across.

The slowest rows (the Dart and Ruby rows and `nostr-java-relaypool`) ran once each instead
of taking the median of three or more. The Dart and JVM ones ran after a container restart,
on a host about 8 % slower: the go-nostr control row took 8,547 ms there against 7,881 ms in
the main pass. At over 13 ms per event, that does not change their place.

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
| other valid events rejected | Rhodium (tags of 2–4 values only), NostrSharp (`GetId` clears tags of 6+ values), nostrb (99 values per tag), ndk for Dart, aionostr and python-nostr (`created_at: 0` becomes now), nostr_dart and nostr_client (they pin bip340 0.0.4, which drops a pubkey's leading zero byte: 83 events), nostr-tools for Python (escaped NUL), snort (one event per replaceable key, none with `created_at: 0`) |
| crashes on an invalid event | snort-system (JS), nip01 (Dart), pynostr |
| loses events, a different set every run | nostr-sdk on Node and Deno, nostr-sdk's JVM stream API, NNostr's `SubscribeForEvents`, goNDK |
| never reaches EOSE | nmilat's `Subscribe` (its read loop blocks after 10,240 messages), electrum-aionostr (sleeps 5 s after every invalid event), nostr-php (slows down with every event: 25,768 events in 45 min) |
| not run on Linux | nostr-sdk-ios, NostrEssentials, rust-nostr's Swift bindings (Apple-only), swift-nostr's default `URLSession` transport |

On the 1,417-event smoke workload, nostr-dartio took 7.4 ms per event and nostr-php's
one-request API 46 ms per event, so neither ran on the full set.

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
