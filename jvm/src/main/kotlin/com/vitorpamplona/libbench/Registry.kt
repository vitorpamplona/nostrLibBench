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
                    "the relay's delivery coroutine. Parser: Kite (KiteReader, Quartz's own). keepConnected() opens the " +
                    "socket in setup.",
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
                    "parallelism 8), which fans Event.verify() out over Dispatchers.Default and delivers in order.",
            variant = true,
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
                    "notification channel also carries every relay message, so two notifications cross JNA per event. " +
                    "ClientBuilder.notificationChannelSize(65536) (default 4096): the broadcast channel drops what a " +
                    "slower reader has not taken yet, and the JNA reader falls behind (see nostr-sdk-subscribe-defaultchannel).",
            variant = false,
            create = { NostrSdkClient(stream = false, channelSize = 65_536) },
        ),
        ClientSpec(
            id = "nostr-sdk-subscribe-defaultchannel",
            library = "rust-nostr nostr-sdk (Kotlin/JVM bindings)",
            version = "${V["org.nostrdevkit:nostr-sdk-jvm"]} (nostr-sdk 0.45.2)",
            license = "MIT",
            api = "Client.subscribe(ReqTarget.single) + Client.notifications().next(), default ClientBuilder",
            websocket = "tokio-tungstenite 0.28 (Rust, via async-wsocket 0.17)",
            crypto = "libsecp256k1 (C, via rust secp256k1 0.30 / secp256k1-sys 0.10)",
            verify = "library",
            notes =
                "nostr-sdk-subscribe with the default notification channel (4096): when the Kotlin reader falls " +
                    "behind, the tokio broadcast channel drops notifications (events and the EOSE alike).",
            variant = true,
            create = { NostrSdkClient(stream = false) },
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
            api = "NostrPool.connectRelay + pool.subscribe(NostrFilter, NaiveEventTracker::new) with event/EOSE listeners, sub.open()",
            websocket = "JDK java.net.http.WebSocket (nge-platform-jvm JVMWebsocketTransport)",
            crypto = NGE_CRYPTO,
            verify = "library",
            notes =
                "NostrRelay verifies every EVENT (id + signature) before listeners see it (verifyEvents, default on), " +
                    "on the common ForkJoinPool (parallelEvents, default on). Subscribes with NaiveEventTracker (dedup by " +
                    "id): the pool's default ForwardSlidingWindowEventTracker treats every event older than ~30 min as " +
                    "already seen once 21 events arrived, so a history sync gets ~22 events (nostr4j-pool-defaulttracker). " +
                    "Parser: Gson (nge-platform). Needs -Dnge-platforms.allowLoopbackInURIs=true for a loopback relay " +
                    "(set by the harness).",
            variant = false,
            create = { Nostr4jClient(naiveTracker = true) },
        ),
        ClientSpec(
            id = "nostr4j-pool-defaulttracker",
            library = "nostr4j",
            version = "${V["org.ngengine:nostr4j"]} (nge-platform-jvm ${V["org.ngengine:nge-platform-jvm"]})",
            license = "BSD-3-Clause",
            api = "NostrPool.connectRelay + pool.subscribe(NostrFilter) (default ForwardSlidingWindowEventTracker)",
            websocket = "JDK java.net.http.WebSocket (nge-platform-jvm JVMWebsocketTransport)",
            crypto = NGE_CRYPTO,
            verify = "library",
            notes =
                "nostr4j-pool with the pool's default event tracker, built for live feeds: after 21 events it moves " +
                    "its cut-off to now - 30 min and drops everything older (and every expired event) as already seen.",
            variant = true,
            create = { Nostr4jClient(naiveTracker = false) },
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
                    "default 10 s announces EOSE on its own).",
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
                    "ignores filters.",
            variant = false,
            create = { RhodiumClient() },
        ),
    )
