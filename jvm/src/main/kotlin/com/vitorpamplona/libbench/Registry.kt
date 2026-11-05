package com.vitorpamplona.libbench

import com.vitorpamplona.libbench.clients.Nostr4jClient
import com.vitorpamplona.libbench.clients.NostrJavaClient
import com.vitorpamplona.libbench.clients.NostrSdkClient
import com.vitorpamplona.libbench.clients.QuartzClient
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
            id = "quartz-fetch",
            library = "Quartz",
            version = V.quartz,
            license = "MIT",
            api = "NostrClient.fetch(relay, filter) { event -> } (one REQ, callback per event, returns at EOSE)",
            websocket = OKHTTP,
            crypto = SECP_KMP,
            verify = "explicit",
            notes =
                "Quartz's one-relay read on NostrClient, the pool Amethyst runs on, with one relay. fetch hands each " +
                    "event unverified to its callback on the relay's delivery coroutine, nothing collected, deduped or " +
                    "sorted, and returns at EOSE; the callback verifies with Quartz's Event.verify() (id via " +
                    "EventHasher.hashIdCheck, then Schnorr), as Amethyst verifies in LocalCache. Parser: Kite (KiteReader, " +
                    "Quartz's own). The fetch runs in a coroutine on the client's Dispatchers.IO scope. keepConnected() " +
                    "opens the socket in setup, then 1 s to settle: a REQ sent while the new connection replays its " +
                    "filters can go out twice.",
            variant = false,
            create = { QuartzClient(parallel = false) },
        ),
        ClientSpec(
            id = "quartz-parallelverifier",
            library = "Quartz",
            version = V.quartz,
            license = "MIT",
            api = "NostrClient.fetch + Quartz's ParallelEventVerifier accessory (batched Event.verify() on Dispatchers.Default)",
            websocket = OKHTTP,
            crypto = SECP_KMP,
            verify = "explicit",
            notes =
                "As quartz-fetch, but the callback submits each event to ParallelEventVerifier (default batch 256, " +
                    "parallelism 8), which fans Event.verify() out over Dispatchers.Default and delivers in order. Quartz's " +
                    "documented speed option (an opt-in accessory), so it is a ranked entry of its own, like other " +
                    "libraries' speed options; it verifies on several cores, which the CPU columns show.",
            variant = false,
            create = { QuartzClient(parallel = true) },
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
