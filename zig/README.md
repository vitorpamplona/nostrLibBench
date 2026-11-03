# Zig harness

Drives every Zig Nostr library that has a relay (WebSocket) client and event verification,
per [`HARNESS.md`](../HARNESS.md).

```bash
zig/run.sh --relay ws://127.0.0.1:7777 --quick --workloads smoke
zig/run.sh --list
```

## Toolchain and dependencies

- **Zig 0.16.0**, the version zig-nostr/nostr pins (`.zigversion`) and libnostr-z supports.
  `run.sh` installs the official tarball from ziglang.org (SHA-256 checked) into the
  git-ignored `.tools/zig/` when missing. Zig's package cache goes to `.tools/zig-cache/`.
- **Dependencies** are pinned in `build.zig.zon` by commit URL and content hash; their own
  dependencies are pinned by their `build.zig.zon` files. `run.sh` pre-fetches every package
  (transitive ones included, listed with their hashes in `run.sh`): it downloads the tarball
  with curl or, when that host is unreachable, rebuilds the identical tarball from the same
  commit with `git archive`; `zig fetch` then checks it against the pinned hash. (Zig's own
  HTTP client cannot get through some proxies, and some sandboxes only let git reach GitHub.)
  The fetched copies land in `zig/zig-pkg/` (git-ignored); nothing from them is committed.
  No dependency is patched. If one ever has to be, the patch must live as a small file in
  `zig/` and be applied by `run.sh`, never as an edit under `zig-pkg/`.
- **System packages** for libnostr-z: OpenSSL (`libssl-dev`) and libsecp256k1 with the
  schnorrsig module (`libsecp256k1-dev`); its noscrypt dependency links both as system
  libraries. On this host libsecp256k1 is Ubuntu's 0.2.0, linked statically.
  The build prints `warning(link): unexpected LLD stderr ... archive member libsecp256k1.so is
  neither ET_REL nor LLVM bitcode` (Zig labels it `error:` and `failure`): noscrypt's
  `build.zig` puts the system `.so` files into its static archive. It is harmless, the build
  exits 0 and links the static `libsecp256k1.a`.

`zig build -Doptimize=ReleaseFast` makes three binaries in `zig/zig-out/bin/`:

| binary | what |
|---|---|
| `libbench` | the driver: flags, manifest, host info; runs each client in a fresh child process and writes `results/zig.json` |
| `libbench-zignostr` | the zig-nostr/nostr clients (libsecp256k1 0.7.1 compiled from source by the package) |
| `libbench-libnostrz` | the libnostr-z clients (system libsecp256k1 0.2.0 via noscrypt) |

The two libraries each bring a libsecp256k1, so they cannot share a binary.

## How it measures

Each (workload, client) runs in a fresh process: `libbench-<lib> --child <client> --workload
<name> ...`, which does the warm-up and measured runs and prints its row as JSON on stdout;
its stderr (per-run progress) passes through. A child that crashes, or outlives its time
budget (`(timeout + 30 s) × (warm-up + max runs + 1)`), gets an `error` row from the driver.

One run, per HARNESS.md:

1. **Setup (untimed):** a new client instance (`nostr.relay.dial`, `Relay.init` + `connect`,
   or a new `Pool` + `connectAll`), connected and upgraded; for zig-nostr also a new
   `keys.Signer` (libsecp256k1 context).
2. **Timed:** `t0` (CLOCK_MONOTONIC, via `std.Io` `.awake`) right before the subscription call
   with one filter `{"limit": <events>}`. For each event the library delivers, the harness
   calls the library's own verify (see `verify` below) and, if it passes, counts it, XORs its
   id (the event object's own id bytes) and reads the clock. EOSE time is recorded.
   `t_end = max(EOSE, last event)`. All the streaming clients are synchronous (the read loop
   runs on the app's thread), so nothing arrives after EOSE and no 1 s idle wait is needed.
   Each run is bounded by `--timeout-ms` (zig-nostr: `receiveTimeout` deadline; libnostr-z:
   SO_RCVTIMEO plus a deadline check per message).
3. **Teardown (untimed):** `CLOSE`, close the connection, free the client.

CPU is `getrusage(RUSAGE_SELF)` user + system over the timed part (all threads); peak RSS is
`ru_maxrss` at the end of the child process. The accepted ids are also appended to a
pre-sized array (one 32-byte copy per event) so that the ambiguous and expired counts can be
worked out after the run, untimed. Every run must deliver the same set as the first.

## Libraries and clients

| client | library | verify | crypto | websocket |
|---|---|---|---|---|
| `zig-nostr-relay` | [zig-nostr/nostr](https://github.com/zig-nostr/nostr) 0.16.0 (MIT) | explicit | libsecp256k1 0.7.1, C, compiled from source | its own RFC 6455 client over `std.Io.net` |
| `libnostr-z-relay` | [privkeyio/libnostr-z](https://github.com/privkeyio/libnostr-z) 0.5.0 (MIT) | explicit | system libsecp256k1 0.2.0 via noscrypt 0.1.14; SHA-256 from StringZilla | its own RFC 6455 client (`src/ws`), blocking reads |
| `libnostr-z-pool-query` (variant) | same | explicit | same | same, on a pool reader thread |

### zig-nostr/nostr 0.16.0 (headline)

The Zig Nostr library the user meant: github.com/zig-nostr/nostr, by Sepehr Safari, last
release v0.16.0 on 2026-10-11, pinned at its tag commit `dfa0e4b3`. Requires Zig 0.16.0.

- **API:** `nostr.relay.dial(gpa, io, url)` returns a connected `*Relay`;
  `relay.subscribe(id, &.{filter})`; then `relay.receiveTimeout(timeout)` in a loop, which
  returns one parsed `message.RelayMessage` (`.event`, `.eose`, …) per call. This is the loop
  the README and the library's agent skill (`skills/zig-nostr/SKILL.md`, "Relays") show, and
  what its CLI `deed` and app Plaza build on. There is no callback/pool layer; the read loop
  is the streaming API.
- **Verification:** none by default. Parsing does not verify (ARCHITECTURE.md: "Parsing does
  not verify. A caller decides where to verify"), and the docs tell apps to call
  `nostr.event.verify(allocator, signer, ev)`, which recomputes the id from the decoded fields
  (`event.computeId`, the canonical NIP-01 serialization streamed into SHA-256) and then checks
  the BIP-340 signature (`keys.Signer.verifyId`, `secp256k1_schnorrsig_verify`). The harness
  calls it on every event: `verify: explicit`, covering both id and signature.
- **crypto:** bitcoin-core libsecp256k1 at commit `1a53f496` (v0.7.1), compiled by the package's
  `build.zig` from source with the schnorrsig/extrakeys/ECDH modules; SHA-256 is Zig std.
- **WebSocket:** its own client (`relay.Connection`, `websocket.zig`) over `std.Io.net` TCP,
  `std.crypto.tls` for wss. Reads 4 KiB at a time into a growable buffer; 1 MiB message cap.
- **Behaviour on the corpus:** the 422 `"sig":""` events fail to parse and are skipped inside
  `receive` (counted by `Relay.unreadable()`), never reaching the app. It accepts the ambiguous
  U+0000 event (its serializer writes `\u0000`) and delivers all 66 expired events.
  `accepted_ok: true`.

### privkeyio/libnostr-z 0.5.0

github.com/privkeyio/libnostr-z, by PrivKey LLC, v0.5.0 (2026-10-06), pinned at the tag commit
`5accad27`. Used by the wisp relay, nostr-bench and the noz CLI.

- **API:** `nostr.relay.Relay.init(gpa, url, config)`, `connect()`, `subscribe(id, filters)`,
  then `receive()` in a loop returning a `RelayMessage` (`msg_type`, `event: ?Event`). This is
  what `noz req` does. Config: `auto_reconnect = false`, `read_timeout_ms` raised from 60 s to
  `--timeout-ms`.
- **Verification:** none in `receive`; `Event.validate()` checks the id, then the signature
  (noscrypt `NCVerifyDigest` → libsecp256k1), and rejects `created_at > now + 900`. The harness
  calls it on every event (`verify: explicit`), as noz does for `noz verify`.
- **Bug: valid events rejected.** `Event.validate` does not re-serialize: it hashes the raw
  JSON text of the `tags` and `content` values exactly as the relay sent them. Any event whose
  JSON uses escapes the canonical serialization does not (`🇺` surrogate pairs,
  `’`, `\/`) gets `IdMismatch`: 82 of the 994 valid events of `smoke` are dropped, so its
  rows are `accepted_ok: false`. The same shortcut makes it accept the ambiguous U+0000 event
  (the relay's bytes contain `\u0000`).
- **Event model:** lazy. `Event` keeps the raw JSON plus parsed id/pubkey/sig/created_at/kind
  and a tag index; `content()` and tag values are extracted on access. `Relay.receive` also
  parses every message twice into a `std.json.Value` tree (message type, subscription id)
  before the event scanner runs.
- **`"sig":""`:** `Event.parse` fails (`InvalidSig`), the message arrives with `event = null`
  and is dropped.
- **WebSocket:** its own client (`src/ws/client.zig`): blocking `posix.read` straight from the
  socket, three reads per frame (header, extended length, payload), one allocation per
  message; OpenSSL for wss. Expired events are delivered (all 66).
- **Pool (`libnostr-z-pool-query`, variant):** `Pool.queryParallel` is the library's
  multi-relay fetch-all: a reader thread per relay parses each event for dedup and queues the
  raw text; `queryParallel` pops (polling with 1 ms sleeps), parses again and returns `[]Event`
  after EOSE; the harness validates each one. Two caveats, named in `notes`:
  `PoolOptions.queue_size` is raised from 10000 to the workload size (a full queue silently
  drops its oldest message), and setup gives the pool's socket a 200 ms `SO_RCVTIMEO` through
  the public `RelayHandle.client.setReadTimeout`: with the default (no timeout) the reader
  thread stays blocked in `read()` once the relay is quiet after EOSE, and `queryParallel`'s
  `stopReceiving` and `Pool.deinit` join it forever (checked: the run hangs). The dedup cache
  evicts by a linear scan once it holds 10000 ids.

## Not included

Found by searching GitHub (`language:zig nostr`, `topic:nostr language:zig`, "nostr zig"),
the web and awesome-nostr:

| project | why not |
|---|---|
| [zignosis/noztr-core](https://github.com/zignosis/noztr-core) + [noztr-sdk](https://github.com/zignosis/noztr-sdk) (0.1.0-rc.7 / rc.3, 2026-03) | protocol kernel + SDK with event parse/verify, but no WebSocket client: the SDK deliberately has none ("does not currently promise a generic public websocket framework"; transport is caller-provided) and its examples use none, so there is nothing real users pair it with. Needs Zig 0.15.2. No LICENSE file. |
| [futurepaul/nostr_zig](https://github.com/futurepaul/nostr_zig) | experimental (MLS / NIP-EE focus), last commit 2025-09-03, Zig 0.14.1, websocket.zig and libsecp256k1 pinned to moving branch tarballs, no LICENSE; its `Client` never verifies events. Not maintained or notable (4 stars). |
| [justinmoon/nostr-zig](https://github.com/justinmoon/nostr-zig) | 2025-09 experiment: Zig bindings to nostrdb (C) plus an example CLI feed; not a library release, no license. |
| [tudorbotezan/zigchat](https://github.com/tudorbotezan/zigchat), [zig-nostr/plaza](https://github.com/zig-nostr/plaza), [zig-nostr/deed](https://github.com/zig-nostr/deed), [privkeyio/noz](https://github.com/privkeyio/noz) | applications; plaza and deed run on zig-nostr/nostr, noz on libnostr-z, so they are covered by those rows. |
| [mattn/zig-nostr-relay](https://github.com/mattn/zig-nostr-relay), [privkeyio/wisp](https://github.com/privkeyio/wisp) | relays (server side), no client. |
