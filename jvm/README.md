# nostrLibBench: JVM harness

The JVM side of [nostrLibBench](../HARNESS.md): every Kotlin/Java Nostr library with a relay
client, driven through its own WebSocket client, parser and verification on one job:
subscribe, receive every event of the workload, verify it, hand it to the app, until EOSE.

```bash
./jvm/run.sh --relay ws://127.0.0.1:7777                      # every client -> results/jvm.json
./jvm/run.sh --relay ws://127.0.0.1:7777 --quick --workloads smoke
./jvm/run.sh --clients quartz-fetch,nostr4j-pool --workloads all,notes
./jvm/run.sh --list
```

`run.sh` builds this directory's standalone Gradle project (`./gradlew installDist`, Gradle
wrapper 9.8, Kotlin 2.4.21, JDK 21: `JAVA_HOME`, else `/usr/lib/jvm/java-21-openjdk-*`) and
runs `build/install/libbench/bin/libbench` from the repo root. It takes every HARNESS.md flag.
`BENCH_JAVA_HOME=<jdk>` runs the benchmark on another JDK; extra JVM flags go through
`JAVA_OPTS`.

Versions: the libraries are pinned in `gradle/libs.versions.toml`, and `gradle.lockfile`
pins every transitive module (`./gradlew dependencies --write-locks` after changing one).
The build writes the resolved version of every module into a resource
(`libbench-versions.properties`), and each row's `version`, `websocket` and `crypto` are
filled from it, so they always say what actually ran.

## How it measures

The harness follows HARNESS.md "A run"; the JVM specifics:

- **One JVM per client.** The process the launcher starts only orchestrates: for each
  client it forks a child with the same `java`, classpath and flags (`-Xmx2g
  -XX:+UseG1GC`, what Amethyst Desktop runs with and what nostrJsonBench's JVM harness
  uses; recorded in `runtime`). The child runs that client on every selected workload and
  writes its rows to a temp file. A child that dies still gets rows with `error` set. All
  libraries share one classpath (one Gradle resolution): where two libraries ask for
  different versions of a shared module, Gradle picks the newest (OkHttp 5.5.1, Bouncy
  Castle 1.84, kotlinx-serialization 1.12, secp256k1-kmp 0.24); these are all patch or
  minor bumps.
- **Stdout.** What a library prints (Rhodium prints a line per invalid event) goes to
  `jvm/build/logs/<client>.stdout.log`, not the terminal; progress goes to stderr.
- **A run.** Setup (untimed, on a worker thread with `--timeout-ms`): a new client
  instance, connected and open where the API allows it. Then, on that same worker thread,
  `System.nanoTime()` and the process CPU time are read and the library's subscribe call
  is made; the main thread waits on the sink. The sink (`Sink.kt`) is the whole per-event
  app: count, XOR the id (parsed from the event object's hex id) and note the time, under a
  lock; libraries deliver from their own threads. The run ends at `max(EOSE, last
  accepted event)`; the wait for completeness (`valid + ambiguous` accepted, or 1 s
  without an event after EOSE) is untimed, and the sink is closed when it ends: later
  deliveries are reported on stderr ("delivered after the run had ended") and not
  counted. Teardown (untimed): close the subscription and the client.
- **CPU.** `com.sun.management.OperatingSystemMXBean.getProcessCpuTime` (user + system,
  every thread) at t0 and at `t_end`: sampled at the EOSE and at each event delivered
  after it, so `t_end`'s value is exact without a clock call per event. On Linux the JDK
  reads it from `times()`, so it moves in 10 ms ticks: fine for `all`, coarse for `smoke`.
- **Peak RSS** is `VmHWM` from `/proc/self/status` when the row is written: the child's
  peak over every run so far (with several workloads, the later rows include the earlier
  workloads' peak).
- **Base RSS and allocation.** `base_rss_mb` is `VmRSS` from `/proc/self/status`, read
  after `System.gc()` at the end of the first setup of each workload (client connected,
  before the first REQ; one child JVM runs every workload of a client, so later workloads
  start from what the earlier ones left). `alloc_bytes` is the growth of
  `com.sun.management.ThreadMXBean.getTotalThreadAllocatedBytes()` (heap bytes, live and
  terminated threads) read on the worker thread right before t0 and on the main thread
  when the wait ends (immediately once `valid + ambiguous` arrived, else after the 1 s
  idle wait), so the counter covers every library thread; null if
  the JVM reports -1. The row reports the median run's value, the mean of the two middle
  runs (by ms) when the number of runs is even. Native memory (direct ByteBuffers,
  secp256k1 JNI) is not counted.
- **Timeouts.** A run with no EOSE within `--timeout-ms` is an error; the child then
  writes its rows and stops (a library that timed out may be wedged), and the parent marks
  the remaining workloads "not run". Set comparison, warm-up, `min-runs`/`min-time-ms`/
  `max-runs`, medians and p90 (nearest rank) are as in HARNESS.md and the other harnesses.
- **No added threads.** Callback libraries deliver on their own threads; for nostr-sdk,
  whose API is a pull stream, the app reads on the thread that subscribed.
- **Debugging.** `LIBBENCH_DUMP_IDS=<dir>` writes every run's accepted ids, in delivery
  order, to `<dir>/<client>-<workload>-*.ids`.

## Clients

| client | library | API | verify | variant |
|---|---|---|---|---|
| `quartz-fetch` | Quartz 2.15.0 | `NostrClient.fetch(relay, filter) { event -> }` | explicit | |
| `quartz-parallelverifier` | Quartz | same + Quartz's `ParallelEventVerifier` | explicit | |
| `nostr-sdk-subscribe` | rust-nostr nostr-sdk 0.45 (UniFFI JVM bindings) | `Client.subscribe` + `notifications()` | library | |
| `nostr-sdk-stream` | same | `Client.streamEvents` | library | yes |
| `nostr4j-pool` | nostr4j 0.4.1 | `NostrPool.subscribe(filter, PassthroughEventTracker)` | library | |
| `nostr-java-relaypool` | nostr-java 2.4.2 | `RelayPool.subscribe` | explicit | |
| `rhodium-request` | Rhodium 1.0-rc | `NostrService.request` + `deserializedEvent` | explicit | |

### Quartz (Amethyst's library), `com.vitorpamplona.quartz:quartz` 2.15.0, MIT

- **API.** `NostrClient(BasicOkHttpWebSocket.Builder { okHttp })`, the pool Amethyst
  (Android, Desktop, the `amy` CLI) runs on, used with one relay, and its one-relay read
  `fetch(relay, Filter(limit = n)) { event -> }`: one REQ, each event handed to the callback
  on the relay's delivery coroutine as it arrives (nothing collected, deduped or sorted),
  returning at EOSE. It runs in a coroutine on the client's `Dispatchers.IO` scope. One
  `OkHttpClient` per process (with Quartz's `TcpNoDelaySocketFactory`, as amy), a new
  `NostrClient` per run. `keepConnected(relay)` opens the socket in setup.
- **WebSocket.** OkHttp 5.5.1; messages go from OkHttp's reader thread through an
  unbounded channel to one delivery coroutine per relay (`Dispatchers.IO`), which decodes
  each frame with Kite (`KiteReader`, Quartz's own reader) and calls `fetch`'s callback.
- **Verification.** `fetch` doesn't verify, like every `NostrClient` read. Amethyst verifies
  in its cache (`LocalCache.justVerify` -> Quartz's `Event.verify()`:
  `EventHasher.hashIdCheck`, then BIP-340 through secp256k1-kmp, i.e. libsecp256k1 over
  JNI). The callback does exactly that, inline on the delivery coroutine: `verify: explicit`.
- **Results.** Accepts the ambiguous U+0000 event (Kite writes `\u0000`) and delivers
  expired events (expiry is the app's business). `"sig":""` events fail `verifySignature`
  on the length check.
- **Duplicate REQ (a Quartz bug).** `connectedRelaysFlow()` reports the relay before the
  new connection has replayed its filters (`onConnected` -> `syncFilters`). A REQ made in
  that window went out twice on one socket (seen in the relay's `--verbose` log: two REQs
  for one connection), so every event came twice. The harness waits 1 s after the
  connection opens before fetching (setup, untimed; an app's relays are connected long
  before a feed opens), and the duplicates stopped.
- `quartz-parallelverifier` (speed option, ranked): the callback submits each event to
  Quartz's own `ParallelEventVerifier` accessory (batches of up to 256, `Event.verify()`
  fanned out on `Dispatchers.Default`, delivered in order). It is opt-in, like other
  libraries' documented speed options (a libsecp256k1 build tag, a wasm verifier), so it is
  a ranked entry of its own; it verifies on several cores, which the CPU columns show.

### rust-nostr nostr-sdk, Kotlin/JVM bindings, `org.nostrdevkit:nostr-sdk-jvm` 0.45.1, MIT

The bindings moved from `org.rust-nostr:nostr-sdk-jvm` (last 0.44.x) to `org.nostrdevkit`.
0.45.1 bundles `libnostr_sdk_ffi.so` built from nostr-sdk 0.45.2 / nostr 0.45.3 (read from
the library's strings).

- **API.** `ClientBuilder().notificationChannelSize(65536).build()`, `addRelay` +
  `connect(andWait)` in setup, `client.notifications()` taken before the REQ (as the docs
  require), then `client.subscribe(ReqTarget.single(relay, [Filter().limit(n)]))` and
  `notifications.next()` until the relay's EOSE message. Every call is a UniFFI future
  over JNA; Event, EventId and notification objects are destroyed explicitly after use.
- **Everything runs in Rust:** tokio-tungstenite 0.28 (async-wsocket 0.17), serde, the
  relay task's checks, then `ClientNotification.NewEvent`. Kotlin pays one JNA round trip
  per notification, and the channel carries two per event (`NewEvent` and the raw
  `Message`). The EOSE only arrives as a `Message`, so the app calls `asEnum()` on every
  `Message` notification (a clone of the relay message, event included, plus a JNA call,
  per event) to recognise it; named in `notes`.
- **Verification (library).** The relay task checks `verify_id()` and the signature
  (libsecp256k1 via rust secp256k1 0.30) before saving the event to its default in-memory
  events tracker and announcing it. A per-client LRU caches verified `(id, sig)` pairs;
  every run builds a new `Client`, so nothing carries over.
- **Results.** Drops the 66 expired events (unconditionally, before verifying) and
  accepts the ambiguous one.
- **Channel size.** The client's notification channel is a tokio broadcast channel: a
  reader that falls behind loses the oldest notifications, events and EOSE alike. The JNA
  reader is far slower than Rust's writer, so with the default 4096 the `all` workload
  lost 60-65% of its events, a different number every run (measured with a
  default-channel variant, since dropped: it only showed that the default is wrong for
  this job). The row raises it to 65536 (HARNESS.md: raise limits that drop events),
  named in `notes`.
- `nostr-sdk-stream` (variant): `Client.streamEvents`, which the Rust harness ranks. From
  the JVM it loses events on `all` (1,574 and 2,051 of 29,548 in two runs): the stream is
  fed from the relay's own broadcast channel (2048) through a 512-slot channel, and the
  bindings expose neither size. Correct on `smoke`.

### nostr4j (NostrGameEngine), `org.ngengine:nostr4j` 0.4.1 + `nge-platform-jvm` 0.2.6, BSD-3-Clause

- **API.** `NostrPool().connectRelay(NostrRelay(url)).await()` in setup, then
  `pool.subscribe(filter) { PassthroughEventTracker() }`, `setVerifyMatchLocally(false)`,
  event and EOSE listeners, `sub.open()`.
  The platform layer is a separate artifact the README asks for (`nge-platform-jvm`,
  needs Java 21); it refuses loopback URIs unless
  `-Dnge-platforms.allowLoopbackInURIs=true` (the client sets the property).
- **WebSocket.** `java.net.http.WebSocket` (JDK 21 HttpClient) in
  `JVMWebsocketTransport`; JSON through Gson.
- **Verification (library, default on).** `NostrRelay` verifies every EVENT before its
  listeners see it: id recomputed with its own serializer, then BIP-340 in
  nge-platform-jvm's `Schnorr`, which calls Bouncy Castle's secp256k1 curve
  (`ECAlgorithms.sumOfTwoMultiplies`, pure Java). With `parallelEvents` (default on) each
  verify runs on the common ForkJoinPool: the CPU time is about 2x the wall time.
- **Event tracker and filter re-matching.** The pool's default
  `ForwardSlidingWindowEventTracker` is built for live feeds: after 21 events it moves its
  cut-off to "now - 30 min" and treats anything older (and anything expired) as already
  seen, so a history sync gets 22 events. The row passes the library's
  `PassthroughEventTracker` (`seen()` returns false: no dedup set, which a single relay
  and a single REQ do not need; `NaiveEventTracker` would add a synchronized `HashSet`
  insert per event), and turns off `setVerifyMatchLocally` (default on: every event is
  matched again against the filter the relay already applied). Both named in `notes`.
- **Results.** Drops the expired events (the pool does, unconditionally), accepts the
  ambiguous one.

### nostr-java (tcheeric), `xyz.tcheeric:nostr-java-client`/`-api` 2.4.2, MIT

- **API.** `RelayPool(listOf(url), { NostrRelayClient(it, 60_000) }, …, backlogTimeout)`,
  `pool.subscribe([EventFilter.builder().limit(n).build()], SubscriptionListener)`: what
  `NostrClient.subscribe` delegates to (`NostrClient` itself needs a signing identity).
  The pool's `backlogTimeout` (default 10 s) announces EOSE on its own when it passes,
  backlog or not; it is raised to `--timeout-ms`, named in `notes`.
- **WebSocket.** Spring `StandardWebSocketClient` 6.2 over Tomcat's JSR-356 client
  10.1; frames are dispatched on a virtual thread; Jackson decodes `GenericEvent`.
- **Verification (explicit).** The pool never verifies and the library has no event-level
  verify. The listener composes the library's own pieces: the id from
  `EventSerializer.serializeAndComputeId` (its Jackson NIP-01 serializer + SHA-256), then
  `nostr.crypto.schnorr.Schnorr.verify`.
- **Speed.** That Schnorr is affine BigInteger arithmetic with a `modPow` inversion per
  point addition (thread dumps sit in `nostr.crypto.Point.add` -> `BigInteger.modPow`):
  about 12-14 ms per event, so `smoke` takes ~17 s and `all` does not finish in the
  default 300 s timeout (17,294 events accepted when it hit it). The `all` row is a
  timeout error unless `--timeout-ms` is raised to ~600 000.
- **Logging.** `EventMessage.convertValue` logs every event at INFO
  (`log.info("Converting map to GenericEvent: {}", map)`). It costs nothing here only
  because no SLF4J provider is on the classpath, so slf4j-api binds its no-op logger (an
  app that configures its logger above INFO gets the same); named in `notes`.
- **Results.** Correct: delivers expired events and accepts the ambiguous one.

### Rhodium (KotlinGeekDev), `io.github.kotlingeekdev.rhodium:rhodium` 1.0-rc, MIT

- **API.** `NostrService(RelayPool(listOf(Relay(url))), http).request(RequestMessage
  .singleFilterRequest(filter = NostrFilter.newFilter().limit(n).build()), onRequestError,
  onRelayMessage)`. There is no connect call: `request` opens the Ktor WebSocket session
  itself, so the connect is in the timed part (named in `notes`). `stopService()` does
  not end the session (it cancels a dispatcher that has no Job), so the harness passes
  the same `HttpClient(OkHttp) { install(WebSockets) }` the service builds by default
  and closes it in teardown.
- **WebSocket.** Ktor 3.5 WebSockets on the OkHttp engine (OkHttp 5.5.1). OkHttp's
  default 10 s read timeout ends each idle session afterwards ("Read timed out" on
  stderr, after the run).
- **Verification (explicit).** The relay client hands the app the event's raw JSON
  (`RelayEventMessage.eventJson`, re-serialized from a `JsonObject`); the library's
  `deserializedEvent` parses it (kotlinx.serialization) and validates it (`isValid`: id,
  then Schnorr through secp256k1-kmp, libsecp256k1 JNI), throwing on an invalid event and
  `println`-ing a line for each (the println is not a logger and cannot be silenced; it
  goes to the stdout log).
- **Results: not correct.** Rhodium's `Tag` holds 2 to 4 strings and its deserializer
  throws on any other length, so every event with a 1-element tag or a 5+-element tag
  (`imeta`, zap `amount` lists, …) is rejected: 33 valid events on `smoke`, 1,533 on
  `all`. Its filter type always serializes `"kinds":[]` (there is no way to leave it
  out; the relay ignores filters), and the default subscription id comes from random
  bytes decoded as UTF-8 (`singleFilterRequest` uses hex, which the harness uses).

## Not included

- **NostrPostr** (KotlinGeekDev): JitPack-only commit builds, unmaintained, superseded by
  Rhodium from the same author.
- **nostrj** (bitkarrot): a 2026 repository with no published artifact (not on Maven
  Central or JitPack).
- **rust-nostr's older `org.rust-nostr:nostr-sdk-jvm`** (0.44.x): replaced by the
  `org.nostrdevkit` artifact above; `nostr-sdk-kmp` is the same Rust core.
- Searched Maven Central and the web for other JVM libraries with a relay client
  (kostr, Primal, Krossbow-based code): none published with a relay client and
  verification.

## Smoke results (`--quick --workloads smoke`, noisy shared machine)

| client | accepted | ambiguous | expired | ok | median ms | cpu ms |
|---|---|---|---|---|---|---|
| quartz-fetch | 995 | 1 | 66 | true | 74 | 205 |
| quartz-parallelverifier | 995 | 1 | 66 | true | 51 | 170 |
| nostr-sdk-subscribe | 929 | 1 | 0 | true | 255 | 465 |
| nostr-sdk-stream | 929 | 1 | 0 | true | 478 | 360 |
| nostr4j-pool | 929 | 1 | 0 | true | 211 | 565 |
| nostr-java-relaypool | 995 | 1 | 66 | true | 15 752 | 16 195 |
| rhodium-request | 962 | 1 | 66 | false | 386 | 415 |

`results/jvm.json` holds the latest run.
