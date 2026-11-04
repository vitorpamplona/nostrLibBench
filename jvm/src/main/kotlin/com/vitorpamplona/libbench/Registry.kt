package com.vitorpamplona.libbench

import com.vitorpamplona.libbench.clients.Nostr4jClient
import com.vitorpamplona.libbench.clients.NostrJavaClient
import com.vitorpamplona.libbench.clients.NostrSdkClient
import com.vitorpamplona.libbench.clients.QuartzClient
import com.vitorpamplona.libbench.clients.QuartzFetch
import com.vitorpamplona.libbench.clients.QuartzFetchClient
import com.vitorpamplona.libbench.clients.QuartzStandaloneClient
import com.vitorpamplona.libbench.clients.RhodiumClient

private val V = Versions

private val OKHTTP = "OkHttp ${V["com.squareup.okhttp3:okhttp"]}"
private val NGE_CRYPTO =
    "Bouncy Castle ${V["org.bouncycastle:bcprov-jdk18on"]} secp256k1 (pure Java, ECAlgorithms.sumOfTwoMultiplies) " +
        "via nge-platform-jvm's Schnorr; JDK SHA-256"
private val SECP_KMP = "libsecp256k1 (C, JNI via ACINQ secp256k1-kmp-jni-jvm ${V["fr.acinq.secp256k1:secp256k1-kmp-jni-jvm"]})"

/** Every client of the JVM harness, in report order. Versions come from the resolved classpath. */
val CLIENTS: List<ClientSpec> =
    listOf(
        ClientSpec(
            id = "quartz-nostrclient",
            library = "Quartz",
            version = V["com.vitorpamplona.quartz:quartz-jvm"],
            license = "MIT",
            api = "NostrClient(BasicOkHttpWebSocket.Builder).subscribe(subId, {relay: [filter]}, SubscriptionListener) (Amethyst's relay pool)",
            websocket = OKHTTP,
            crypto = SECP_KMP,
            verify = "explicit",
            notes =
                "Quartz's client delivers events unverified; Amethyst verifies in LocalCache.justVerify with Quartz's " +
                    "Event.verify() (id via EventHasher.hashIdCheck, then Schnorr), and the listener does the same, inline on " +
                    "the relay's delivery coroutine. Parser: Kite (KiteReader, Quartz's own). NostrClient is Quartz's " +
                    "pool, used here with one relay, as Amethyst uses it. keepConnected() opens the socket in setup, " +
                    "then 1 s to settle: a REQ sent while the new connection replays its filters can go out twice.",
            variant = false,
            create = { QuartzClient(parallel = false) },
        ),
        ClientSpec(
            id = "quartz-parallelverifier",
            library = "Quartz",
            version = V["com.vitorpamplona.quartz:quartz-jvm"],
            license = "MIT",
            api = "NostrClient.subscribe + Quartz's ParallelEventVerifier accessory (batched Event.verify() on Dispatchers.Default)",
            websocket = OKHTTP,
            crypto = SECP_KMP,
            verify = "explicit",
            notes =
                "As quartz-nostrclient, but the listener submits each event to ParallelEventVerifier (default batch 256, " +
                    "parallelism 8), which fans Event.verify() out over Dispatchers.Default and delivers in order. Quartz's " +
                    "documented speed option (an opt-in accessory; Amethyst still verifies inline on the per-relay " +
                    "coroutine, quartz-nostrclient), so it is a ranked entry of its own, like other libraries' speed " +
                    "options; it verifies on several cores, which the CPU columns show.",
            variant = false,
            create = { QuartzClient(parallel = true) },
        ),
        ClientSpec(
            id = "quartz-standalone",
            library = "Quartz",
            version = V["com.vitorpamplona.quartz:quartz-jvm"],
            license = "MIT",
            api = "StandaloneRelayClient(url, BasicOkHttpWebSocket.Builder, RelayConnectionListener).sendRequest(subId, [filter])",
            websocket = OKHTTP,
            crypto = SECP_KMP,
            verify = "explicit",
            notes =
                "Quartz's single-relay client, without the pool: EVENT/EOSE messages (decoded by Kite) reach the " +
                    "listener's onIncomingMessage, which runs Event.verify() inline as quartz-nostrclient does. Same 1 s " +
                    "settle after connect.",
            variant = true,
            create = { QuartzStandaloneClient() },
        ),
        ClientSpec(
            id = "quartz-fetchallwithhooks",
            library = "Quartz",
            version = V["com.vitorpamplona.quartz:quartz-jvm"],
            license = "MIT",
            api = "NostrClient.fetchAllWithHooks({relay: [filter]}) { relay, event -> ... } (accessory; returns at EOSE)",
            websocket = OKHTTP,
            crypto = SECP_KMP,
            verify = "explicit",
            notes =
                "Quartz's fetch accessory with a per-event hook, over the same NostrClient and socket as " +
                    "quartz-nostrclient: the listener pushes each event into an UNLIMITED channel, one loop drains it " +
                    "and calls the hook in arrival order; the hook runs Event.verify() and keeps the verified events, " +
                    "which the accessory collects into its result list (returned at EOSE, so every event stays " +
                    "reachable until the run ends). No dedup. idleTimeoutMs 60 s. Run in a coroutine on the client's " +
                    "Dispatchers.IO scope; EOSE = the accessory returning.",
            variant = true,
            create = { QuartzFetchClient(QuartzFetch.WITH_HOOKS) },
        ),
        ClientSpec(
            id = "quartz-fetchall",
            library = "Quartz",
            version = V["com.vitorpamplona.quartz:quartz-jvm"],
            license = "MIT",
            api = "NostrClient.fetchAll(relay, [filter]) (accessory; suspends until EOSE, returns List<Event>)",
            websocket = OKHTTP,
            crypto = SECP_KMP,
            verify = "explicit",
            notes =
                "fetchAll is fetchAllWithHooks with a hook that dedups by id (a HashSet of every id), then sorts the " +
                    "list newest-first (DefaultFeedOrderEvent). It does not verify: the app verifies each event of the " +
                    "returned list with Event.verify(), inside the run, after the accessory returns. The dedup runs " +
                    "before any verification, so a forged copy that arrives first takes the id and the genuine event is " +
                    "dropped as a duplicate: it fails the forged-content and forged-sig checks (98 of 197 delivered). " +
                    "idleTimeoutMs 60 s; same pool, socket and coroutine as quartz-fetchallwithhooks.",
            variant = true,
            create = { QuartzFetchClient(QuartzFetch.FETCH_ALL) },
        ),
        ClientSpec(
            id = "quartz-fetchasflow",
            library = "Quartz",
            version = V["com.vitorpamplona.quartz:quartz-jvm"],
            license = "MIT",
            api = "NostrClient.fetchAsFlow(relay, [filter]).collect { list -> ... } (accessory; completes at EOSE)",
            websocket = OKHTTP,
            crypto = SECP_KMP,
            verify = "explicit",
            notes =
                "fetchAsFlow: a callbackFlow whose listener dedups by id (a HashSet of every id), appends to an " +
                    "EventListAccumulator and sends a snapshot view of the whole list per event, conflated (a slow " +
                    "collector sees only the newest list); it completes at EOSE. The collector verifies the events " +
                    "appended since its previous emission with Event.verify(). The dedup runs before any " +
                    "verification, so a forged copy that arrives first censors the genuine event: it fails the " +
                    "forged-content and forged-sig checks (98 of 197 delivered). Same pool, socket and coroutine as " +
                    "quartz-fetchallwithhooks.",
            variant = true,
            create = { QuartzFetchClient(QuartzFetch.FETCH_AS_FLOW) },
        ),
        ClientSpec(
            id = "quartz-fetch",
            library = "Quartz",
            version = V["com.vitorpamplona.quartz:quartz-jvm"],
            license = "MIT",
            api = "proposed NostrClient.fetch(relay, filters) { event -> } (built in the harness on fetchAllWithHooks; not in Quartz 2.13.0)",
            websocket = OKHTTP,
            crypto = SECP_KMP,
            verify = "explicit",
            notes =
                "A proposed single-relay accessory, prototyped in the harness (quartzproposal/Fetch.kt) on Quartz's " +
                    "public fetchAllWithHooks: one REQ, every event handed to the callback unverified in arrival " +
                    "order, nothing collected, deduped or sorted; returns at EOSE with the delivered count and the " +
                    "relay's end reason. The callback verifies with Event.verify(), as quartz-nostrclient's listener " +
                    "does. Same pool, socket and coroutine as quartz-fetchallwithhooks.",
            variant = true,
            create = { QuartzFetchClient(QuartzFetch.PROPOSED_FETCH) },
        ),
        ClientSpec(
            id = "quartz-fetchevents",
            library = "Quartz",
            version = V["com.vitorpamplona.quartz:quartz-jvm"],
            license = "MIT",
            api = "proposed NostrClient.fetchEvents(relay, filters): Flow<Event> (channelFlow over the proposed fetch; not in Quartz 2.13.0)",
            websocket = OKHTTP,
            crypto = SECP_KMP,
            verify = "explicit",
            notes =
                "The proposed fetch as a cold Flow of single events (a channelFlow, default 64-slot buffer, that " +
                    "completes at EOSE): each event is sent through the channel to the collector, which verifies it " +
                    "with Event.verify(); one more coroutine hop per event than quartz-fetch.",
            variant = true,
            create = { QuartzFetchClient(QuartzFetch.PROPOSED_FETCH_EVENTS) },
        ),
        ClientSpec(
            id = "nostr-sdk-subscribe",
            library = "rust-nostr nostr-sdk (Kotlin/JVM bindings)",
            version = "${V["org.nostrdevkit:nostr-sdk-jvm"]} (nostr-sdk 0.45.2)",
            license = "MIT",
            api = "Client.subscribe(ReqTarget.single) + Client.notifications().next() (UniFFI over JNA)",
            websocket = "tokio-tungstenite 0.28 (Rust, via async-wsocket 0.17)",
            crypto = "libsecp256k1 (C, via rust secp256k1 0.30 / secp256k1-sys 0.10)",
            verify = "library",
            notes =
                "All client work runs in Rust: id (verify_id) + signature checked by the relay task before the event is " +
                    "saved to the default in-memory events tracker and announced; a per-client LRU caches verified " +
                    "(id, sig) pairs, so every run builds a new Client. Drops expired (NIP-40) events by design. The " +
                    "notification channel also carries every relay message, so two notifications cross JNA per event, " +
                    "and the EOSE only arrives as a Message notification: the app calls asEnum() on every Message " +
                    "(a clone of the event plus a JNA call, per event) to spot it. " +
                    "ClientBuilder.notificationChannelSize(65536) (default 4096): the broadcast channel drops what a " +
                    "slower reader has not taken yet, and the JNA reader falls behind (with the default, `all` lost " +
                    "60-65% of its events, a different number every run). alloc_bytes counts only the JVM side " +
                    "(JNA handles, strings); the Rust heap is not counted.",
            variant = false,
            create = { NostrSdkClient(stream = false, channelSize = 65_536) },
        ),
        ClientSpec(
            id = "nostr-sdk-stream",
            library = "rust-nostr nostr-sdk (Kotlin/JVM bindings)",
            version = "${V["org.nostrdevkit:nostr-sdk-jvm"]} (nostr-sdk 0.45.2)",
            license = "MIT",
            api = "Client.streamEvents(ReqTarget.single) read with ClientEventStream.next() until it ends at EOSE",
            websocket = "tokio-tungstenite 0.28 (Rust, via async-wsocket 0.17)",
            crypto = "libsecp256k1 (C, via rust secp256k1 0.30 / secp256k1-sys 0.10)",
            verify = "library",
            notes =
                "The short-lived stream API (default exit policy ExitOnEOSE); EOSE = the stream's end. The stream is " +
                    "fed from the relay's own notification broadcast (2048, not settable from the bindings) through a " +
                    "512-slot channel, so a reader slower than the relay loses events. Otherwise as nostr-sdk-subscribe.",
            variant = true,
            create = { NostrSdkClient(stream = true) },
        ),
        ClientSpec(
            id = "nostr4j-pool",
            library = "nostr4j",
            version = "${V["org.ngengine:nostr4j"]} (nge-platform-jvm ${V["org.ngengine:nge-platform-jvm"]})",
            license = "BSD-3-Clause",
            api =
                "NostrPool.connectRelay + pool.subscribe(NostrFilter, PassthroughEventTracker::new), setVerifyMatchLocally(false), " +
                    "event/EOSE listeners, sub.open()",
            websocket = "JDK java.net.http.WebSocket (nge-platform-jvm JVMWebsocketTransport)",
            crypto = NGE_CRYPTO,
            verify = "library",
            notes =
                "NostrRelay verifies every EVENT (id + signature) before listeners see it (verifyEvents, default on), " +
                    "on the common ForkJoinPool (parallelEvents, default on). Subscribes with the library's " +
                    "PassthroughEventTracker (seen() is always false: no per-event dedup set; the pool's default " +
                    "ForwardSlidingWindowEventTracker treats every event older than ~30 min as already seen once 21 " +
                    "events arrived, so a history sync gets ~22 events) and setVerifyMatchLocally(false) (no local " +
                    "re-match of every event against the filter). The pool drops expired (NIP-40) events. " +
                    "Parser: Gson (nge-platform). Needs -Dnge-platforms.allowLoopbackInURIs=true for a loopback relay " +
                    "(set by the harness).",
            variant = false,
            create = { Nostr4jClient() },
        ),
        ClientSpec(
            id = "nostr-java-relaypool",
            library = "nostr-java",
            version = V["xyz.tcheeric:nostr-java-client"],
            license = "MIT",
            api = "RelayPool.subscribe(filters, SubscriptionListener) (what NostrClient.subscribe delegates to)",
            websocket = "Spring StandardWebSocketClient ${V["org.springframework:spring-websocket"]} on Tomcat JSR-356 client ${V["org.apache.tomcat.embed:tomcat-embed-websocket"]}",
            crypto = "pure-Java BIP-340 on BigInteger (nostr-java-core Schnorr), JDK SHA-256",
            verify = "explicit",
            notes =
                "The pool never verifies and the library has no event verify; the listener checks the id with " +
                    "EventSerializer.serializeAndComputeId (its Jackson NIP-01 serializer) and the signature with " +
                    "nostr.crypto.schnorr.Schnorr.verify. Parser: Jackson. backlogTimeout set to --timeout-ms (the " +
                    "default 10 s announces EOSE on its own). The library logs every event at INFO (EventMessage." +
                    "convertValue: log.info(\"Converting map to GenericEvent: {}\", map)); it costs nothing here only " +
                    "because no SLF4J provider is on the classpath (slf4j-api's no-op logger), as in an app that " +
                    "configures its logger above INFO. The subscription deduplicates by the id field before the " +
                    "listener sees the event (RelaySubscription.deliverIfNotAlreadySeen -> DeliveredEventWindow." +
                    "isFirstSighting) and nothing in the library verifies first, so a forged copy that arrives first " +
                    "is rejected by the listener and the genuine event that follows is dropped as already seen: it " +
                    "fails the forged-content and forged-sig checks (98 of 197 delivered).",
            variant = false,
            create = { NostrJavaClient { Child.timeoutMs } },
        ),
        ClientSpec(
            id = "rhodium-request",
            library = "Rhodium",
            version = V["io.github.kotlingeekdev.rhodium:rhodium-commonjvm"],
            license = "MIT",
            api = "NostrService.request(RequestMessage, onRelayMessage) + deserializedEvent(eventJson)",
            websocket = "Ktor ${V["io.ktor:ktor-client-websockets-jvm"]} WebSockets on the OkHttp engine ($OKHTTP)",
            crypto = SECP_KMP,
            verify = "explicit",
            notes =
                "The relay client hands over the event's raw JSON; the library's deserializedEvent parses it " +
                    "(kotlinx.serialization) and validates it (Event.isValid: id, then Schnorr), throwing on invalid " +
                    "events (and printing a line for each to stdout). Connects lazily inside request(): the connect " +
                    "is in the timed part. Its filter always carries \"kinds\":[] (no way to leave it out); the relay " +
                    "ignores filters. Its Tag holds 2-4 strings and deserialization throws on any other length, so " +
                    "valid events with a 1-element or 5+-element tag (imeta, ...) are rejected.",
            variant = false,
            create = { RhodiumClient() },
        ),
    )
