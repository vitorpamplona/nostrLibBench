# nostrLibBench: Rust harness

Times Rust Nostr client libraries on one job (subscribe, receive every event over the
library's own WebSocket client, parse, verify id + signature, deliver until EOSE), following
[`../HARNESS.md`](../HARNESS.md).

```bash
rust/run.sh --relay ws://127.0.0.1:7777            # every client on `all` -> results/rust.json
rust/run.sh --quick --clients nostr-sdk-stream     # smoke test
rust/run.sh --list                                 # client ids
```

`run.sh` builds from the pinned `Cargo.lock` (`cargo build --release --locked`) with
`RUSTFLAGS="-C target-cpu=native"` and the release profile (`lto = "fat"`, `codegen-units = 1`,
`opt-level = 3`), recorded in the output's `runtime`. RUSTFLAGS reach Rust code only: the C
code some libraries bundle (libsecp256k1 in `secp256k1-sys` and in nostrdb, LMDB) is built by
the `cc` crate with its own default flags. Versions and licenses come from `cargo metadata`,
read at build time (`build.rs`).

## How it measures

- **Isolation.** The parent process re-executes its own binary (`--child <client>
  --workloads <w>`) once per client and workload, so every library runs in a fresh process
  (its own tokio runtime, allocator state, global caches). Clients run one after another. The
  child prints one JSON line with its runs; the parent computes the row. A child that crashes
  gets a row with `error` = `crashed (exit status / signal): <last stderr line>`.
- **A run.** Setup (untimed): a new client instance, connected where the API connects
  explicitly. `t0` and the CPU counter are read right before the library's subscription call
  with the filter `{"limit": <events in the workload>}`. Every event the library delivers as
  valid is counted and its 32-byte id (from the library's own event object) XORed in
  (`src/sink.rs`); for `explicit` rows the library's own verify function runs first, inside
  the timed part. The run ends at `max(EOSE delivered, last accepted event)`. Clients whose
  delivery can continue after EOSE (nostr-sdk notifications, nostrdb) keep reading until the
  accepted set is complete (valid + ambiguous) or nothing arrived for 1 s; that wait is not
  timed. Teardown (untimed): close the subscription and the client.
- **Timeout.** A watchdog thread in the child ends the process with an error line when a
  run exceeds `--timeout-ms` (a blocking library call cannot be interrupted otherwise).
- **Runs.** `--warmup-runs` (first one reported as `first_run_ms`), then measured runs until
  `--min-runs` and `--min-time-ms` (wall time of the measured phase), at most `--max-runs`.
  Every run must deliver the same (count, XOR) as the first, else the row is an error.
- **CPU.** `getrusage(RUSAGE_SELF)` user + system (all threads) at `t0` and at `t_end`: at
  EOSE, or at the last event after it (for nostrdb, whose notes arrive in batches, once per
  batch). `cpu_ms` is the median over measured runs. `peak_rss_mb` is `ru_maxrss` at the end
  of the child.
- **Correctness.** `accepted_ok` per HARNESS.md: expired events (NIP-40, `expired_ids`)
  may be all delivered or all dropped, the ambiguous event (U+0000) either way.
- **Async runtime.** Async libraries run on a multi-threaded tokio runtime built once per
  child process (what `#[tokio::main]` builds: one worker per core); the client is new per run.

Diagnostics: `LIBBENCH_DUMP_IDS=<file>` writes the ids a run accepted, one per line.

## Clients

| client | library | verify | crypto | websocket | variant |
|---|---|---|---|---|---|
| `nostr-sdk-stream` | nostr-sdk 0.45.6 (rust-nostr) | library | libsecp256k1 0.4.1 (secp256k1-sys 0.10.1) | tokio-tungstenite 0.28 via async-wsocket 0.17 | no |
| `nostr-sdk-notifications` | nostr-sdk 0.45.6 | library | same | same | yes |
| `nostr-sdk-fetch` | nostr-sdk 0.45.6 | library | same | same | yes |
| `nostro2-relay` | nostro2-relay 0.10.0 (+ nostro2 0.9.0) | library | k256 0.14 (pure Rust) | own blocking RFC 6455 codec (coyoquil handshake) | no |
| `nostro2-relay-default` | nostro2-relay 0.10.0 | library | same | same | yes |
| `nostr_rust-next_data` | nostr_rust 0.20.3 | explicit | libsecp256k1 0.2.0 (secp256k1-sys 0.8.2) | tungstenite 0.18 (sync) | no |
| `nostr_rust-get_events_of` | nostr_rust 0.20.3 | explicit | same | same | yes |
| `nostr-types-client` | nostr-types 0.8.0-unstable (git 0ada3e4) | explicit | libsecp256k1 0.6.0 (secp256k1-sys 0.11.0) | tokio-tungstenite 0.28 | no |
| `nostrdb-tungstenite` | nostrdb 0.9.0 (GPL-3.0-or-later) | library | libsecp256k1 0.6.0 (bundled C) | tokio-tungstenite 0.28 (harness-paired) | yes |

### nostr-sdk (rust-nostr, `nostrdevkit/nostr`)

- **API.** `Client::default()`, `add_relay(url)`, `try_connect().timeout(10 s)` (waits for the
  socket), then:
  - `stream_events(filter)` (headline): a `Stream` of `(RelayUrl, Result<Event>)`; with the
    default `ReqExitPolicy::ExitOnEOSE` it ends when EOSE arrives.
  - `notifications()` + `subscribe(filter)`: `ClientNotification::Event` per new event,
    `ClientNotification::Message(RelayMessage::EndOfStoredEvents)` for EOSE. The notification
    channel is a tokio `broadcast` (2048 slots per client by default): a reader that lags
    loses events (`Lagged`), which did not happen here.
  - `fetch_events(filter)`: returns a `BTreeSet<Event>` after EOSE. Its default
    `max_events` is 10,000 and a larger result fails the whole call ("too many fetched
    events"), so the row sets `max_events(<workload size>)`.
- **Pipeline** (relay task, `relay/inner.rs`): trim, size checks (5 MB message, 2,000 tags,
  10,000 for kind 3: none of the corpus hits them), `RelayMessage::from_json` (serde_json
  straight into the event type), subscription/filter check (stream API), **drop expired events
  (NIP-40), unconditionally, before verification**, `EventVerifier::verify_and_cache`
  (recompute id + compare, then BIP-340 with libsecp256k1 through `secp256k1` 0.30's global
  context), events-tracker check/save (a per-client 35,000-entry LRU of seen ids, the default
  "database"), then the notification. Both LRUs (verified ids, seen ids) belong to the
  `Client`; a new `Client` per run starts with them empty. No process-global cache.
- **Behaviour on this corpus.** Drops all 66 expired events (`expired_accepted` 0), accepts
  the ambiguous U+0000 event (serde_json writes `\u0000`), drops every `"sig":""` rumor
  (signature parse fails, the frame is logged and skipped).
- `nostr-relay-pool` is no longer a separate crate in 0.45 (merged into nostr-sdk); see Not
  included.

### nostro2-relay (+ nostro2)

- **API.** `NostrRelay::connect_blocking_config(DriverConfig::new(url).with_capacities(256,
  65536))`, `relay.send(NostrSubscription { limit, .. })`, then `recv_blocking()` until
  `NostrRelayEvent::EndOfSubscription`. No async runtime: one driver thread per relay owns
  the socket and talks to the app through lock-free rings (quetzalcoatl).
- **Verification.** On by default (`VerifyPolicy::Reject`): the driver thread recomputes the
  id, compares it, and checks the signature with k256 (RustCrypto, the default `k256`
  feature; a `secp256k1` feature exists but cannot be enabled alongside k256 in one build).
- **Caveat.** The driver never blocks the socket: when the inbound ring (default 1,024
  slots) is full it drops the event and logs a warning. On this shared 4-core machine one
  `all` run at the default size lost 957 events (3%), so the headline row raises the ring to
  65,536 (`DriverConfig::with_capacities`, a documented option); `nostro2-relay-default`
  keeps the default and turns into an error row when a run loses events.

### nostr_rust (0xtlt; last release January 2023)

- **API.** `Client::new(vec![url])` (synchronous; connects), `subscribe(vec![ReqFilter])`,
  then `next_data()` (one blocking read per relay, returns raw `tungstenite::Message`s) and
  `events::extract_events_ws(&msg)` (serde_json `Value`, then `from_value::<Event>`). The
  library has no EOSE helper on this path; the harness recognises the `["EOSE",<sub>]` frame.
  `get_events_of` (variant) buffers raw messages until EOSE (de-duplicating each one by a
  linear scan of the buffer, O(n²)) and parses them afterwards.
- **Verification.** None on receive. `Event::verify()` checks only the signature, over the
  hash of its own serialization, and never compares it with the event's `id`; so the harness
  calls `Event::verify()` **and** compares `Event::get_content_id()` (the library's id hash)
  with `id` (`verify: explicit`). secp256k1 0.26 / libsecp256k1 0.2.0 (C).

### nostr-types (Mike Dilger, gossip's event model)

- **Version.** crates.io has only 0.4.0 (2023); gossip uses the git repository. The harness
  pins master `0ada3e4` (Feb 2026, `0.8.0-unstable`; gossip pins `e431110`) with the
  `client` feature.
- **API.** `nostr_types::client::Client::new(url)`, `subscribe(filter, timeout)` (connects
  lazily on first use, so the ~1 ms loopback connect is inside the timed part), then
  `wait_for_subscribed_event_or_eose(sub, timeout)` until `None` (EOSE). A listener task
  parses every frame (serde) into a `RelayMessage` and appends it to a shared
  `Vec<RelayMessage>`; each wait scans that Vec and `remove`s the match (O(backlog)).
- **Verification.** None on receive; the harness calls `Event::verify(None)` (recomputes
  the id, compares it, verifies the signature; libsecp256k1 0.6.0 via secp256k1 0.31).
- gossip itself does not use this `client` module (it has its own relay code on
  tokio-tungstenite); the row measures the crate's own client.

### nostrdb (Damus / notedeck core) — variant

- No WebSocket client: notedeck's `enostr` reads relays with tokio-tungstenite and hands
  frames to nostrdb, so the harness does the same: a tokio-tungstenite reader task calls
  `Ndb::process_event(frame)` for each `EVENT`; the app side waits on
  `SubscriptionStream` (nostrdb's async subscription on `Ndb::subscribe(filter)`) and reads
  each note with `Transaction` + `get_note_by_key` -> `Note::id()`.
- Ingester threads (default: one per core) parse with nostrdb's own JSON parser, verify id +
  signature (bundled libsecp256k1 0.6.0) and pass notes to the LMDB writer thread (with
  full-text and content-block indexes, the defaults). A fresh database directory per run (in
  the temp dir, removed after the run), since a stored note skips verification. EOSE comes
  off the socket before the ingesters finish, so a run ends at the last note after it.
- **Bug found:** nostrdb cannot parse `\uXXXX` escapes in strings (`nostrdb.c`:
  `case 'u': // these aren't handled yet; return 0`). Every event whose JSON has one is
  dropped: 2,381 valid events of `all` (non-BMP characters written as `🚀`
  surrogate pairs, control characters, ...), and the ambiguous `\u0000` event. Its rows are
  therefore `accepted_ok: false`.
- License GPL-3.0-or-later (the harness binary links it; nothing is distributed).

## Not included

- **nostr-relay-pool** 0.44.3: the relay pool was merged into `nostr-sdk` in 0.45 and the
  separate crate stopped at 0.44 (built on `nostr` 0.44). The current pool is measured
  through nostr-sdk.
- **enostr** (notedeck's relay crate): git-only, a member of the notedeck workspace (egui
  app dependencies); its transport (tokio-tungstenite) + nostrdb ingest is what
  `nostrdb-tungstenite` reproduces.
- **nk / nula** (qntx, 2026): new SDKs with a relay client, under 300 downloads each; nk
  0.15 needs rustc 1.99. Not notable yet.
- **iris-nostr** 0.5.0: a CLI/agent query tool (social-graph filtering over `nostr-pubsub`),
  not a client library; needs rustc 1.99.
- **nostr-commander**, **nostcat**, **vector-core**, **mostro** and similar: applications or
  CLIs built on nostr-sdk or on a bare WebSocket, not libraries of their own.
- **rusted-nostr-tools** (2023), **guilospanck-nostr-sdk** (2023), **nostr-nostd** (no_std,
  no WebSocket client): unmaintained or without a relay subscription API.
- **nostr-parse / nostr-verify** (VectorPrivacy, 2026): a parser and a batch verifier, no
  WebSocket client.
