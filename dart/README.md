# nostrLibBench: Dart harness

The Dart side of [nostrLibBench](../HARNESS.md): which Dart Nostr client library gets a
relay's events through its own WebSocket client, JSON parser and signature verification
fastest.

```bash
./dart/run.sh --quick --workloads smoke --relay ws://127.0.0.1:7807
./dart/run.sh --clients ndk-rust,dart_nostr --workloads all
./dart/run.sh --list
```

`run.sh` installs the pinned Dart SDK (3.13.7 stable, from the official archive at
storage.googleapis.com/dart-archive) into `.tools/dart-sdk/` when it is missing (and links
`.tools/dart/dart`, where the top-level `run.sh` looks for it), resolves every package with
`dart pub get --enforce-lockfile`, AOT-compiles one native binary per library into
`dart/build/` (skipped when nothing changed), and runs the orchestrator from the repo root.
It takes every HARNESS.md flag.

**ndk needs Rust to build.** ndk 0.10 ships a build hook (`native_toolchain_rust`) that
compiles its Rust library with `cargo` whatever verifier the app picks, so `dart compile exe`
refuses it and the harness uses `dart build cli` (a binary plus `librust_lib_ndk.so`). The
hook asks rustup for the toolchain pinned in ndk's `rust-toolchain.toml` (1.98.1, with ~13
cross targets: about 3 GB in `~/.rustup` the first time) and takes about 2 minutes. Without
rustup the ndk build fails and its rows report the error; the other libraries still run.

## Layout

- `common/`: package `bench_common`, the shared driver (one run, warm-ups, measured runs,
  the accepted-set check, the result row).
- `clients/<package>/`: one package per library, each with its own `pubspec.lock`: the old
  libraries pin `bip340 0.0.4` / `web_socket_channel 2`, ndk needs `bip340 0.3`, so they
  cannot share one resolution.
- `bench/`: the orchestrator. It asks each client binary for its clients (`--list-json`),
  runs every client on every workload in a **fresh process** (`--child <client>`), one
  after another, and writes `results/dart.json`. A child that crashes or hangs still gets a
  row with `error` set.

## How it measures

- **A run** (HARNESS.md "A run"): setup, untimed: a new client object, connected and the
  connection awaited where the API allows. Timed: `t0` (`Stopwatch`) right before the
  subscription call with the filter `{"limit": <events>}`; each delivered event is counted
  and its id XORed into the accepted set (after the library's own verify for `explicit`
  rows); `t_end = max(EOSE time, last accepted event)`. The driver waits until EOSE and
  either the accepted set is complete or no event came for 1 s. Teardown, untimed.
- **Uncaught errors.** The child runs inside `runZonedGuarded`: an exception a library throws
  on the event loop (which would kill an app) ends the run with that error in the row.
- **CPU**: utime + stime from `/proc/self/stat` (all threads and isolates; clock ticks, 10 ms
  resolution), from `t0` to the moment the run completed.
- **Memory**: `peak_rss_mb` is `VmHWM` from `/proc/self/status` at the end of the child.
- **Runtime**: AOT (`dart compile exe`; `dart build cli` for ndk), default VM flags.
- `LIBBENCH_DUMP=<file>` makes a child write the accepted ids of each run (debugging aid).

## Clients

| client | library | API | verify | crypto | websocket |
|---|---|---|---|---|---|
| `ndk` | ndk 0.10.1 (relaystr) | `Ndk.requests.query(filter, explicitRelays).stream`, `Bip340EventVerifier` (default) | library | bip340 0.3.1 (pure Dart, on compute isolates) | ndk's vendored web_socket_client (dart:io) |
| `ndk-rust` | ndk 0.10.1 | same, `RustEventVerifier` (documented native verifier) | library | libsecp256k1 via Rust FFI | same |
| `ndk-cache` (variant) | ndk 0.10.1 | as `ndk-rust`, `query()` with its default `cacheRead`/`cacheWrite: true` | library | libsecp256k1 via Rust FFI | same |
| `dart_nostr` | dart_nostr 10.0.1 (anasfik) | `Nostr().services.relays.startEventsSubscription(request, onEose)` | explicit | bip340 0.3.0 | web_socket_channel 3 |
| `nostr_nips` | nostr_nips 0.2.0 | `Relay.connect` + `relay.messages` + `relay.subscribe` | explicit | bip340 0.3.0 | web_socket_channel 3 |
| `nostr_tools` | nostr_tools 1.0.9 | `RelayApi.connect()` stream + `relay.sub` | explicit | bip340 0.2.0 | web_socket_channel 2 |
| `nostr_dart` | nostr_dart 0.6.5 (Satswalker) | `Nostr().pool.add(Relay)` + `await pool.subscribe(filters, onEvent)` | library | bip340 0.0.4 | web_socket_channel 2 |
| `nostr_client` | nostr_client 0.2.0 (UlrichRaab) | `Relay.connect` + `relay.stream` + `relay.subscribe` | explicit | bip340 0.0.4 | web_socket_channel 2 |
| `nip01` | nip01 0.3.0+1 (dartstr) | `WebSocketRelayDataSource` + repositories' event/EOSE streams | library | bip340 0.3.1 | web_socket_channel 3 |
| `nostr-dartio` (variant) | nostr 2.0.0 (ethicnology) | dart:io `WebSocket` + `Message.deserialize` | library | bip340 0.3.1 | dart:io WebSocket |

All pure-Dart verification goes through the `bip340` package (BigInt arithmetic on
pointycastle), about 10 ms per signature on this machine: a smoke run takes ~11 s, an `all`
run about 5 minutes, close to the default `--timeout-ms` of 300 s.

Per library (each row's `notes` has the details):

- **ndk** verifies every event (`VerifyEventStream`: Dart id recompute + NIP-13 check, then
  the verifier) and keeps an LRU of verified id/sig pairs per `Ndk` instance (a new `Ndk` per
  run). The default `Bip340EventVerifier` runs on a compute isolate and JSON decoding runs on
  an encoding isolate. Config: `bootstrapRelays` = the relay, `MemCacheManager` (a required
  parameter), log level off, the query timeout raised to 1 h (the default 10 s would cut the
  stream), and `query(cacheRead: false, cacheWrite: false)`: `query` defaults to writing every
  verified event to the cache (save, add sources, then reload it under the cache's visibility
  rules and deliver it only if it is still visible), a store outside the job; with
  `cacheWrite: false` ndk hands back the verified stream unchanged. So expired events and a
  kind-0 profile older than another by the same author are delivered. The defaults run in the
  `ndk-cache` variant (Rust verifier, to compare with `ndk-rust`), which drops both. Always
  paid, named in `notes`: the id is computed twice (`isIdValid` in the stream, then again in
  `Bip340EventVerifier`, or in the native call for `RustEventVerifier`), the NIP-13 check, the
  frame's string length for relay stats, the query's `returnedIds` dedup set, and an unawaited
  NIP-11 HTTP GET after connect. One valid event is still **dropped**: `Nip01Event`'s
  constructor replaces `created_at: 0` with the current time, so its id no longer matches
  (`accepted_ok: false` on every ndk row). For every `"sig":""` event the Bip340 verifier
  throws inside the isolate and ndk prints a stack trace (not silenceable without a patch).
  `ndk-rust` rejects the ambiguous U+0000 event; `ndk` accepts it.
- **dart_nostr**: `Nostr.instance` is a singleton whose registry drops ids it has seen, so
  each run builds `Nostr()`; per-event console logging is on by default and is turned off.
  The relay layer does not verify: the harness calls `NostrEvent.getEventId` and
  `isVerified()`. It decodes each frame once. Always paid: every raw frame string goes into
  an LRU set of 5000 and onto an all-entities sink, every event is kept in the instance's
  unbounded `eventsRegistry` map, and log strings are interpolated per event even with logs
  off. Correct.
- **nostr_nips** parses into `Event` but does not verify: the harness calls `event.verify()`
  (id + BIP-340). Correct.
- **nostr_tools** (2023): its verifying `Event` constructor body is commented out; the harness
  calls `EventApi().getEventHash` and `verifySignature`. Correct.
- **nostr_dart** (2023): verifies id and signature in its pool. It needs NIP-11 over https and
  NIPs 15+20 listed before it connects, so the harness passes `Relay` a
  `RelayInfoProvider` (its public constructor parameter) returning `[1, 11, 15, 20]`. It hides
  EOSE, but `pool.subscribe()` returns at the relay's ack (the EOSE). That ack wait has a
  hard-coded 1-minute timeout that disconnects the relay, so an `all` run, which takes ~5 min
  to verify in pure Dart, will be cut off. `Relay.connect()` does not await the WebSocket
  handshake (its channel is private), so setup waits 200 ms, untimed, as for nostr_tools and
  nostr_client. Its `bip340 0.0.4` **rejects valid signatures from
  pubkeys with leading zero bytes** (3 events on smoke): `accepted_ok: false`.
- **nostr_client** (2023): no id function, so the id half is harness code: SHA-256 of
  `jsonEncode([0, …])` (what the other Dart libraries do) compared with `id`; the signature
  half is the library's `event.verify()`, called by the harness. Same `bip340 0.0.4`
  leading-zero bug: `accepted_ok: false`.
- **nip01**: verifies the signature only (`EventModel.isValid`) inside its stream listener; the
  id half is the library's own `Event.calculateId`, called by the harness (as go-nostr's
  `CheckID`, so `verify` stays `library`). It **throws on the first `"sig":""` event**
  (`bip340` hex-decodes the empty string), an uncaught error that would kill an app: error
  row.
- **nostr** (ethicnology) is transport-agnostic (no relay client); paired with dart:io
  `WebSocket` as its examples do: a variant. `Message.deserialize` verifies id + signature by
  default, but decodes each EVENT frame twice (`Message.deserialize` reads the type, then
  `Event.deserialize` parses the same string again). It rejects the `created_at: 0` event
  (its validator requires a positive timestamp): `accepted_ok: false`.

## Not included

- **nostr_core_dart** (0xchat, 1.0.1): event model and NIPs, no relay client.
- **nostr_sdk** (0.0.1), **dart_ndk** (0.0.1), **eventstr**, **flutter_nostr**, **ndk_flutter**:
  need Flutter (`dependencies: flutter`), which a CLI harness cannot load.
- **lupine_sdk**, **purplestore**, **ndk_\*** cache/backends: built on ndk (benchmarked).
- **nwc**, **nip04**, **nip19**, **nip47**, **nip06**, **bip340** and other single-NIP packages:
  no relay client.
