# nostrLibBench: Swift harness

The Swift side of [nostrLibBench](../HARNESS.md): every Swift Nostr client library, driven
through its own relay client, WebSocket stack, JSON decoder and signature check, on one
job: subscribe, receive every event of the workload, verify it, hand it to the app, until
EOSE.

**macOS is the primary target.** Most Swift Nostr libraries are written for Apple
platforms (Combine, CommonCrypto, `Network`, an `.xcframework`), so on Linux only
swift-nostr runs. See [What was and was not validated on Linux](#what-was-and-was-not-validated-on-linux):
start there on your Mac.

```bash
./swift/run.sh --relay ws://127.0.0.1:7777 --quick --workloads smoke   # check first
./swift/run.sh --relay ws://127.0.0.1:7777                             # every client -> results/swift.json
./swift/run.sh --clients nostr-sdk-ios-relay,nostr-sdk-swift-stream --workloads all,notes
./swift/run.sh --list
```

`run.sh` takes every HARNESS.md flag and runs from the repo root, so relative
`--corpus`/`--out` paths are relative to it.

## Toolchain

- **macOS:** `swift` from `PATH` (Xcode or its command line tools; or a swift.org
  toolchain). swift-nostr 0.9.0 declares `swift-tools-version: 6.3`, so it needs Swift 6.3+
  (Xcode 26.4+); with an older Xcode its rows report "not built" and the rest still run.
- **Linux:** `.tools/swift/` in the repo (git-ignored). If neither it nor a `swift` on
  `PATH` exists, `run.sh` downloads Swift `$SWIFT_PIN` (default 6.4.2) for this
  Ubuntu/Debian release from download.swift.org, checks its GPG signature against
  swift.org's keys, and unpacks it there. Developed with Swift 6.4.2 on Ubuntu 24.04 x86_64.

## Layout: one package per library

```
swift/
  run.sh                 build everything that builds here, then run swift/.build/bin/libbench
  Package.swift          libbench: the parent; runs each client in a fresh child process
  BenchCore/             the harness (flags, manifest, run loop, accepted-set check,
                         CPU/RSS, JSON rows, parent); no dependencies
  libs/bench-nostr-sdk-ios/      -> binary libbench-nostr-sdk-ios
  libs/bench-rust-nostr/         -> binary libbench-rust-nostr
  libs/bench-swift-nostr/        -> binary libbench-swift-nostr
  libs/bench-nostr-essentials/   -> binary libbench-nostr-essentials
```

Each `libs/bench-*` directory is **a small wrapper package holding only the harness's
client code for one library** (one `main.swift`), with the library as an ordinary
upstream SwiftPM dependency pinned in that package's own `Package.resolved`. None of them
is a copy of a library, vendored or patched. They are separate packages because the Swift
Nostr libraries cannot share one dependency graph:

- nostr-sdk-ios and rust-nostr's Swift bindings both export a module named `NostrSDK`
  (SwiftPM rejects two modules of one name in a graph; module aliasing does not apply to
  the rust-nostr target, which wraps a binary `.xcframework`);
- they pin incompatible versions of the secp256k1 Swift wrapper (nostr-sdk-ios: exactly
  GigaBitcoin/secp256k1.swift 0.12.2; swift-nostr: 21-DOT-DEV/swift-secp256k1 ≥ 0.24.0),
  whose vendored libsecp256k1 C symbols would also collide at link time;
- one library that fails to build (likely with a future Xcode) then costs only its own
  rows.

The directories are named `bench-<x>` because a root package named like its dependency
(`swift-nostr` depending on `swift-nostr`) is a cyclic dependency to SwiftPM.

`run.sh` builds each package with `swift build -c release --only-use-versions-from-resolved-file`,
logging to `swift/.build/logs/<package>.log`, and links the binary into `swift/.build/bin/`.
A package that fails to build prints its last log lines and its clients report
`error: "not built (build log: ...)"`. On Linux only `bench-swift-nostr` is built; the
other clients are listed (`--list` is the same everywhere) and report
`error: "macOS only"`. With `--clients`, only the packages those clients need are built.
The first build fetches the dependencies; swift-crypto's BoringSSL and SwiftNIO make
`bench-swift-nostr` take ~6 minutes from scratch on 4 cores.

## How it measures

HARNESS.md "A run", with these Swift specifics:

- **Isolation.** The parent (`libbench`) starts the client's library binary with
  `--child --clients <id> --child-out <file>`, one client at a time. The child writes one
  JSON row per workload to that file (so nothing a library prints can corrupt it; its
  stdout goes to stderr). A child that crashes, or exceeds a watchdog of
  (warm-up + max runs) × (timeout + 40 s) per workload, still gets rows with `error` set.
  The parent reads the library version from the package's `Package.resolved` and passes it
  to the child (`LIBBENCH_VERSION`).
- **Threads, as in an app.** In the child, the harness runs on one background thread
  while the main thread runs the main run loop (which also drains the main dispatch
  queue), as an app's does: NostrEssentials delivers on the main queue, Combine and
  swift-nostr use their own queues and tasks. The harness adds no threads to a library's
  pipeline: an `explicit` verification runs inside the library's own delivery callback
  (queue, task or main thread). For an async API, the harness consumes the library's
  `AsyncSequence` in one task, as an app's `for await` loop does.
- **Clock:** `DispatchTime.now()` (monotonic: `mach_absolute_time` on macOS,
  `CLOCK_MONOTONIC` on Linux). `t0` is read right before the subscription call; each
  accepted event and the EOSE are timestamped where the library delivers them; the run
  ends at max(EOSE, last accepted event). The harness waits for EOSE plus either every
  valid + ambiguous event or 1 s of silence (untimed), else `--timeout-ms` (an error; the
  child then stops, since a wedged library may never return).
- **CPU:** `getrusage(RUSAGE_SELF)` user + system (all threads), from `t0` to the EOSE, or
  to the last event when events arrive after it. **Peak RSS:** `ru_maxrss` at the end of
  the workload (bytes on macOS, KiB on Linux; reported in MiB).
- **Setup/teardown** (untimed): a new client object per run, connected before `t0`;
  teardown closes the subscription and the connection, bounded to 5 s.
- **Accepted set:** each delivered event's id is read from the library's event object
  (hex string, or the 32 bytes for rust-nostr), XORed, and checked against the manifest
  exactly as HARNESS.md "Correctness" says.

## Clients

| client | library | version | license | verify | variant | runs on |
|---|---|---|---|---|---|---|
| `nostr-sdk-ios-relay` | [nostr-sdk-ios](https://github.com/nostr-sdk/nostr-sdk-ios) (`NostrSDK`) | 0.3.0+e5855cb (main) | MIT | explicit | no | macOS |
| `nostr-sdk-ios-pool` | nostr-sdk-ios | 0.3.0+e5855cb | MIT | explicit | yes (pool) | macOS |
| `nostr-sdk-swift-stream` | [rust-nostr Swift bindings](https://github.com/rust-nostr/nostr-sdk-swift) (`NostrSDK`) | 0.45.1 | MIT | library | no | macOS |
| `nostr-sdk-swift-notifications` | rust-nostr Swift bindings | 0.45.1 | MIT | library | yes | macOS |
| `swift-nostr-client` | [swift-nostr](https://github.com/yysskk/swift-nostr) (`NostrClient`) | 0.9.0 | MIT | explicit | no | macOS (Linux: see below) |
| `swift-nostr-websocketkit` | swift-nostr + websocket-kit transport | 0.9.0 | MIT | explicit | yes | macOS, Linux |
| `nostr-essentials-pool` | [NostrEssentials](https://github.com/nostur-com/nostr-essentials) (Nostur) | 1.0.0+50bd46e (main) | GPL-3.0-only | explicit | no | macOS |

### nostr-sdk-ios (`nostr-sdk-ios-relay`, `nostr-sdk-ios-pool`)

The SDK many iOS apps use. Pinned to `main` at e5855cb (2026-01-10) rather than the 0.3.0
tag (2025-02): the five commits after the tag include #216, the fix for the `Data.bytes`
ambiguity (Foundation vs CryptoSwift) that breaks its build with current Apple SDKs.

- **API.** `Relay(url:)` + `connect()`, waiting (untimed) for `RelayDelegate`
  `relayStateDidChange(.connected)`. Timed: `relay.events.sink { … }` (the Combine
  `PassthroughSubject<RelayEvent, Never>`) and `relay.subscribe(with: Filter(limit:)!, subscriptionId:)`.
  The EOSE only reaches the app through `RelayDelegate.relay(_:didReceive: RelayResponse)`
  (`.eose`). The pool variant does the same through `RelayPool(relayURLs:delegate:)`, whose
  `events` merges the relays' publishers (`Publishers.MergeMany`): one more Combine hop.
- **WebSocket:** its own `WebSocket` class over `URLSessionWebSocketTask` on
  `URLSession.shared` (per-task delegate), a recursive `receive` loop; frames arrive on
  URLSession's delegate queue (one serial queue). Default 1 MiB maximum message size; the
  largest corpus event is 48 KB.
- **Parsing:** `JSONDecoder` decodes each frame into `RelayResponse`, first peeking at
  `kind` and then decoding into the `NostrEvent` subclass for that kind (`TextNoteEvent`,
  `ReactionEvent`, …). A frame that fails to decode is logged and dropped.
- **Verification: none on receive.** `Relay` publishes decoded events unverified (it only
  verifies events you publish). The harness calls the library's own
  `EventVerifying.verifyEvent(_:)` (a public protocol extension; `Relay` conforms to it) on
  every delivered event, on the delivery queue: it recomputes the id
  (`EventSerializer`: `JSONEncoder` with `.withoutEscapingSlashes`, SHA-256 by
  CommonCrypto `CC_SHA256`), compares it, rejects `sig == nil`, then checks the BIP-340
  signature with GigaBitcoin/secp256k1.swift 0.12.2 (libsecp256k1 0.3.2, C). No cache, no
  sampling.
- **Caveats found:** its `Tag` type requires a value, so an event with a one-element tag
  (`["anon"]` in NIP-57 zap requests, a bare `["content-warning"]`) fails to decode and is
  silently dropped: on `all` that is **20 valid events** (19 kind 9734, 1 kind 42), so
  `nostr-sdk-ios-*` should be `accepted_ok: false` on `all` (29,594 accepted, the ambiguous
  one included) and `true` on `smoke` (no such event). Every invalid event is rejected
  (the `"sig":""` rumors by the length check, the others by the id check). It accepts the
  ambiguous U+0000 event (`JSONEncoder` writes `\u0000`). Expired events are delivered.
- **Defaults kept:** `Relay` logs every received frame at `.info` through `os.Logger`
  (`"Received message: …"`). That is unified logging, not the console, and the message is
  only formatted when that level is collected; left as shipped.

### rust-nostr Swift bindings (`nostr-sdk-swift-stream`, `nostr-sdk-swift-notifications`)

UniFFI bindings over the Rust `nostr-sdk` (the xcframework of 0.45.1 contains nostr-sdk
0.45.2, nostr 0.45.3, tungstenite 0.28 via async-wsocket 0.17, secp256k1-sys 0.10.1). The
Swift package is `nostr-sdk-swift` (repo now at nostrdevkit/nostr-sdk-swift); its module
is also `NostrSDK`, hence its own package here.

- **API.** `Client()`, `addRelay(url: RelayUrl.parse(url:))`, `tryConnect(timeout: 10)`
  (untimed). Headline: `client.streamEvents(target: ReqTarget.auto(filters: [Filter().limit(limit:)]), policy: .exitOnEose)`
  and `await stream.next()` until it returns nil (the stream ends at EOSE), as the Rust
  harness's `nostr-sdk-stream`. Variant: `client.notifications()` +
  `client.subscribe(target:id:)`, events as `ClientNotification.newEvent`, EOSE as
  `.message(RelayMessage)` whose `asEnum()` is `.endOfStoredEvents` (every relay message
  crosses the FFI there, and the broadcast channel drops events for a slow reader).
- **Everything happens in Rust:** frame parsing (serde_json), NIP-40 expiration check,
  id + signature verification (always on; a per-`Client` LRU of verified ids, empty for each
  new `Client`), seen-ids tracking. Swift receives `Event` handles across the FFI and reads
  `event.id().asBytes()`.
- **Expected:** drops the 66 expired events (unconditional in rust-nostr), so
  `expired_accepted: 0`; accepts the ambiguous event (serde_json writes `\u0000`).
- The binary target is an Apple-only `.xcframework` (macOS arm64/x86_64, iOS): no Linux.
  `Package.resolved` pins 0.45.1; the 233 MB xcframework zip is fetched on the first build.

### swift-nostr (`swift-nostr-client`, `swift-nostr-websocketkit`)

yysskk/swift-nostr 0.9.0 (MIT, actively developed, Swift 6 concurrency, actors).

- **API.** `NostrClient()` + `client.relays.connect(to: [RelayURL])` (untimed; the
  connection is confirmed with a ping). Timed: `client.subscriptions.subscribe(filters: [Filter(limit:)])`
  and `for await` over the returned `SubscriptionSequence` (`.event(relayURL:event:)`,
  `.eose(relayURL:)`). The `NostrClient` is the library's client (a `RelayPool` actor with
  one relay here, as rust-nostr's `Client`), so this is the headline row.
- **Pipeline:** `RelayConnection` actor receive loop → `RelayMessage.parse`
  (`JSONDecoder`) → `RelayPool` actor (per-subscription dedup cache, new per client) →
  `AsyncStream` (unbounded buffer) → app.
- **Verification: none on receive.** The harness calls the library's `Event.verify()` on
  each delivered event in the consuming task: SHA-256 (swift-crypto: CryptoKit on Apple,
  BoringSSL on Linux) of the NIP-01 serialization compared with `id`, `missingSignature`
  for rumors, then BIP-340 via 21-DOT-DEV/swift-secp256k1 0.24.0 `P256K` (libsecp256k1
  0.7.1, C). Accepts the ambiguous event; delivers expired events.
- **WebSocket:** `swift-nostr-client` uses the library's default
  `URLSessionWebSocketFactory` (`URLSessionWebSocketTask`). On Linux that needs
  swift-corelibs-foundation's libcurl to have WebSocket support, which Ubuntu 24.04's
  libcurl 8.5 does not, so on Linux this row reports
  `setup: allConnectionsFailed (URLSessionWebSocketTask on Linux needs a libcurl built with WebSocket support)`.
  (`run.sh` puts `.tools/curl-ws/lib` on `LD_LIBRARY_PATH` if you build such a libcurl
  there; not done here.)
- **`swift-nostr-websocketkit` (variant):** the same client built with
  `NostrClient(webSocketFactory:)`, the seam swift-nostr documents for platforms whose
  Foundation has no WebSocket client, with a factory over Vapor's websocket-kit 2.16.2
  (SwiftNIO, one event-loop thread for the process). The ~80-line adapter to the library's
  `WebSocketSession` protocol is harness code (hence a variant). websocket-kit's 16 KiB
  default `maxFrameSize` would drop the larger events; it is raised to 1 MiB, the
  URLSessionWebSocketTask default. It is the one client that runs on Linux.

### NostrEssentials (`nostr-essentials-pool`)

The library of the Nostur app (GPL-3.0). Pinned to `main` at 50bd46e (2026-03-28): its
only tag, 1.0.0, is from 2024-02 and 78 commits behind.

- **API.** `ConnectionPool(delegate:)`, `addConnection(RelayConfig(url:read:true,write:false))`,
  `connectAll()`, waiting (untimed) for `RelayConnectionDelegate.didConnect`. Timed:
  `pool.sendMessage(ClientMessage(type: .REQ, subscriptionId:, filters: [Filters(limit:)]), subscriptionId:)`.
  `ConnectionPool` is the library's only relay client (`RelayConnection`'s initializer is
  internal), with one relay here, so it is the headline row.
- **Delivery:** the pool hands every text frame, unparsed, to
  `RelayConnectionDelegate.didReceiveMessage(_:message:)` **on the main queue**. The app
  parses it with the library's `parseRelayMessage(text:relay:)` (`JSONDecoder`) and, as
  Nostur does, verifies with the library's `Event.verified()`: SHA-256 (secp256k1.swift's
  `SHA256`, libsecp256k1's own hash) of `JSONEncoder` output compared with `id`, then BIP-340
  via GigaBitcoin/secp256k1.swift 0.12.2 (libsecp256k1 0.3.2). Both run on the main queue,
  where the library delivers. (Nostur itself parses on a background queue it adds; the
  harness does not add threads.)
- **WebSocket:** `URLSessionWebSocketTask`, one `URLSession` per connection; the
  connection also observes `NWPathMonitor` (Network) through Combine.
- **Teardown:** `closeSubscription` + `removeConnection` (a `RelayConnection` holds its
  pool strongly; removing it breaks the cycle).

## What was and was not validated on Linux

Validated here (Swift 6.4.2, Ubuntu 24.04 x86_64):

- **BenchCore and the parent** build and run: flags, `--list`, the child-process protocol,
  the watchdog, the timeout path (a run past `--timeout-ms` gives an error row and the
  remaining workloads get "child exited … before this workload"), "not built" and "macOS
  only" rows, the JSON output.
- **swift-nostr** end to end through `swift-nostr-websocketkit`: `accepted_ok: true` on
  `smoke` (995 = 994 valid + the ambiguous one, all 66 expired), `notes` and `lists`
  (results/swift.json is that `--quick --workloads smoke` run). `swift-nostr-client`
  builds; its URLSession transport cannot connect on this Linux (no WebSocket in libcurl).
- **Compile checks of the Apple-only clients' harness code** (not shipped):
  - rust-nostr: `libs/bench-rust-nostr/Sources/.../main.swift` type-checks against the
    real generated bindings (`NostrSDK.swift` of 0.45.1 plus the `nostr_sdkFFI.h` header
    from the xcframework).
  - nostr-sdk-ios and NostrEssentials: the harness code compiles against copies of the
    pinned library sources with Linux stand-ins for the Apple-only parts (Combine →
    OpenCombine, `os.Logger`, CommonCrypto, `NWPathMonitor` stubbed). That found one real
    bug (a missing public initializer in BenchCore), now fixed.
  - With those same copies, an offline pass decoded every corpus event the way each
    library's receive path does and ran the library's verify function (swift-foundation's
    `JSONEncoder`/`JSONDecoder`, the same implementation as macOS 14+ Foundation):
    nostr-sdk-ios accepts the correct set on `smoke` but drops 20 valid events of `all`
    (one-element tags, above); NostrEssentials accepts the correct set on both.

**Not validated (check these first on the Mac):**

1. That each Apple-only package builds with your Xcode: `./swift/run.sh --list` builds
   nothing but the parent; `./swift/run.sh --quick --workloads smoke` builds all four
   packages and prints the log tail of any that fails (logs in `swift/.build/logs/`).
   The pins were resolved on Linux (`Package.resolved` v3).
2. The runtime behaviour of everything on top of `URLSessionWebSocketTask` (nostr-sdk-ios,
   swift-nostr-client, NostrEssentials) and of the rust-nostr xcframework: connection,
   EOSE delivery, teardown, and that every correct client reports `accepted_ok: true` on
   `smoke` (expected: all seven rows).
3. The macOS paths of BenchCore: `ru_maxrss` in bytes, `sysctl` CPU name, `os` string.

## Not included

- **damus-io/nostrdb** (C, used by Damus): no SwiftPM package (Damus vendors the C sources
  and its own Swift wrappers into the app); its relay pool is Damus app code, not a library.
  The C library itself is measured in the Rust harness (`nostrdb-tungstenite`).
- **cnixbtc/NostrKit** (MIT, last commit 2022): data types only. No WebSocket client
  (its example uses a bare `URLSessionWebSocketTask`), no EOSE message type, and no
  function to verify a received event (only signing). Unmaintained.
- **tannerdsilva/nostr-kit** (SwiftNIO, last commit 2023, "extremely early infancy"):
  its relay client can publish but has no subscription (REQ) API.
- **nostur-com, planetary-social/nos, Primal, bitchat, Damus apps:** app code, not
  libraries (Nostur's library is NostrEssentials, included).
- **yysskk/swift-nostr-client:** the same code base and tags as swift-nostr (included).
