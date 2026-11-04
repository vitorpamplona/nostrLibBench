package com.vitorpamplona.libbench.clients

import com.vitorpamplona.libbench.BenchClient
import com.vitorpamplona.libbench.EventSink
import com.vitorpamplona.quartz.nip01Core.core.Event
import com.vitorpamplona.quartz.nip01Core.crypto.verify
import com.vitorpamplona.quartz.nip01Core.relay.client.NostrClient
import com.vitorpamplona.quartz.nip01Core.relay.client.accessories.ParallelEventVerifier
import com.vitorpamplona.quartz.nip01Core.relay.client.accessories.fetch
import com.vitorpamplona.quartz.nip01Core.relay.client.accessories.fetchAll
import com.vitorpamplona.quartz.nip01Core.relay.client.accessories.fetchAllWithHooks
import com.vitorpamplona.quartz.nip01Core.relay.client.accessories.fetchEvents
import com.vitorpamplona.quartz.nip01Core.relay.client.listeners.RelayConnectionListener
import com.vitorpamplona.quartz.nip01Core.relay.client.reqs.SubscriptionListener
import com.vitorpamplona.quartz.nip01Core.relay.client.reqs.fetchAsFlow
import com.vitorpamplona.quartz.nip01Core.relay.client.single.IRelayClient
import com.vitorpamplona.quartz.nip01Core.relay.client.single.basic.BasicRelayClient
import com.vitorpamplona.quartz.nip01Core.relay.client.single.standalone.StandaloneRelayClient
import com.vitorpamplona.quartz.nip01Core.relay.commands.toClient.EoseMessage
import com.vitorpamplona.quartz.nip01Core.relay.commands.toClient.EventMessage
import com.vitorpamplona.quartz.nip01Core.relay.commands.toClient.Message
import com.vitorpamplona.quartz.nip01Core.relay.filters.Filter
import com.vitorpamplona.quartz.nip01Core.relay.normalizer.NormalizedRelayUrl
import com.vitorpamplona.quartz.nip01Core.relay.normalizer.RelayUrlNormalizer
import com.vitorpamplona.quartz.nip01Core.relay.sockets.okhttp.BasicOkHttpWebSocket
import com.vitorpamplona.quartz.nip01Core.relay.sockets.okhttp.TcpNoDelaySocketFactory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient

/**
 * Quartz (Amethyst's Nostr library): [NostrClient] over [BasicOkHttpWebSocket], the relay
 * pool Amethyst (Android, Desktop and the `amy` CLI) runs on.
 *
 * Quartz's client does not verify: Amethyst verifies in its cache (`LocalCache.justVerify`,
 * which calls Quartz's `Event.verify()`: id via `EventHasher.hashIdCheck`, then the BIP-340
 * signature through secp256k1-kmp, i.e. libsecp256k1 over JNI). The listener does the same,
 * inline on the relay's delivery coroutine, as Amethyst does today ([parallel] = false), or
 * through Quartz's own [ParallelEventVerifier] accessory ([parallel] = true).
 */
class QuartzClient(
    private val parallel: Boolean,
) : BenchClient {
    companion object {
        const val SETTLE_MS = 1000L

        /** One OkHttpClient per process, as an app holds one; the same socket factory as amy. */
        val okHttp: OkHttpClient by lazy {
            OkHttpClient.Builder().socketFactory(TcpNoDelaySocketFactory).build()
        }
    }

    private lateinit var scope: CoroutineScope
    private lateinit var client: NostrClient
    private lateinit var relay: NormalizedRelayUrl
    private var verifier: ParallelEventVerifier<Unit>? = null
    private val subId = "bench" + System.nanoTime().toString(36)

    override fun setup(url: String) {
        relay = RelayUrlNormalizer.normalizeOrNull(url) ?: error("Quartz could not normalize $url")
        scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
        client = NostrClient(BasicOkHttpWebSocket.Builder { okHttp }, scope)
        // Opens the socket ahead of the subscription (the app keeps its relays connected).
        client.keepConnected(relay)
        runBlocking { withTimeout(30_000) { client.connectedRelaysFlow().first { relay in it } } }
        // connectedRelaysFlow flips before the connection's filter replay and before the
        // debounced reconnect pass run; a REQ registered inside that window can go out twice
        // (seen here: the relay got the REQ twice on one socket). An app's relays are connected
        // long before a feed opens, so let the client settle first.
        Thread.sleep(SETTLE_MS)
    }

    override fun subscribe(
        limit: Int,
        sink: EventSink,
    ) {
        val v =
            if (parallel) {
                ParallelEventVerifier<Unit>(scope, onVerified = { event, _ -> sink.event(event.id) }).also { verifier = it }
            } else {
                null
            }
        val listener =
            object : SubscriptionListener {
                override suspend fun onEvent(
                    event: Event,
                    isLive: Boolean,
                    relay: NormalizedRelayUrl,
                    forFilters: List<Filter>?,
                ) {
                    if (v != null) {
                        v.submit(event, Unit)
                    } else if (event.verify()) {
                        sink.event(event.id)
                    }
                }

                override fun onEose(
                    relay: NormalizedRelayUrl,
                    forFilters: List<Filter>?,
                ) {
                    sink.eose()
                }
            }
        client.subscribe(subId, mapOf(relay to listOf(Filter(limit = limit))), listener)
    }

    override fun teardown() {
        client.unsubscribe(subId)
        verifier?.close()
        client.releaseConnection(relay)
        client.disconnect()
        client.close()
        scope.cancel()
    }
}

/**
 * Quartz's single-relay client, [StandaloneRelayClient] (a [BasicRelayClient] plus the REQs
 * to replay on reconnect), over the same [BasicOkHttpWebSocket]. Events reach the app as
 * decoded relay messages through its [RelayConnectionListener]; verified as in [QuartzClient].
 */
class QuartzStandaloneClient : BenchClient {
    private lateinit var client: StandaloneRelayClient
    private val subId = "bench" + System.nanoTime().toString(36)

    @Volatile private var sink: EventSink? = null

    override fun setup(url: String) {
        val relay = RelayUrlNormalizer.normalizeOrNull(url) ?: error("Quartz could not normalize $url")
        val listener =
            object : RelayConnectionListener {
                override suspend fun onIncomingMessage(
                    relay: IRelayClient,
                    msgStr: String,
                    msg: Message,
                ) {
                    val s = sink ?: return
                    when (msg) {
                        is EventMessage -> if (msg.subId == subId && msg.event.verify()) s.event(msg.event.id)
                        is EoseMessage -> if (msg.subId == subId) s.eose()
                        else -> {}
                    }
                }
            }
        client = StandaloneRelayClient(relay, BasicOkHttpWebSocket.Builder { QuartzClient.okHttp }, listener)
        client.connect()
        val deadline = System.nanoTime() + 30_000_000_000L
        while (!client.isConnected()) {
            check(System.nanoTime() < deadline) { "Quartz did not connect to $url" }
            Thread.sleep(5)
        }
        Thread.sleep(QuartzClient.SETTLE_MS)
    }

    override fun subscribe(
        limit: Int,
        sink: EventSink,
    ) {
        this.sink = sink
        client.sendRequest(subId, listOf(Filter(limit = limit)))
    }

    override fun teardown() {
        client.close(subId)
        client.disconnect()
    }
}

/** Which of Quartz's fetch accessories [QuartzFetchClient] drives. */
enum class QuartzFetch { WITH_HOOKS, FETCH_ALL, FETCH_AS_FLOW, FETCH, FETCH_EVENTS }

/**
 * Quartz's fetch accessories (extension functions on [NostrClient]) over the same pool and
 * socket as [QuartzClient]: one REQ to one relay, completed at EOSE. They deliver events
 * unverified, so each event goes through Quartz's `Event.verify()`, at the point the API
 * hands it to the app:
 *  - [QuartzFetch.WITH_HOOKS]: `fetchAllWithHooks`, verified inside its per-event hook (the
 *    hook's documented "verify / persist" use); the accessory keeps the accepted events in its
 *    result list.
 *  - [QuartzFetch.FETCH_ALL]: `fetchAll`, which dedups by id, returns the list at EOSE sorted
 *    newest-first; every event of the list is verified after it returns (inside the run).
 *  - [QuartzFetch.FETCH_AS_FLOW]: `fetchAsFlow`, a conflated flow of the growing list that
 *    completes at EOSE; the collector verifies the events appended since its last emission.
 * The fetch runs in a coroutine on the client's scope (Dispatchers.IO), as an app launches it.
 */
class QuartzFetchClient(
    private val mode: QuartzFetch,
) : BenchClient {
    private lateinit var scope: CoroutineScope
    private lateinit var client: NostrClient
    private lateinit var relay: NormalizedRelayUrl

    override fun setup(url: String) {
        relay = RelayUrlNormalizer.normalizeOrNull(url) ?: error("Quartz could not normalize $url")
        scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
        client = NostrClient(BasicOkHttpWebSocket.Builder { QuartzClient.okHttp }, scope)
        client.keepConnected(relay)
        runBlocking { withTimeout(30_000) { client.connectedRelaysFlow().first { relay in it } } }
        Thread.sleep(QuartzClient.SETTLE_MS)
    }

    override fun subscribe(
        limit: Int,
        sink: EventSink,
    ) {
        val filters = listOf(Filter(limit = limit))
        scope.launch {
            when (mode) {
                QuartzFetch.WITH_HOOKS -> {
                    client.fetchAllWithHooks(mapOf(relay to filters), idleTimeoutMs = IDLE_MS) { _, event ->
                        if (event.verify()) {
                            sink.event(event.id)
                            true
                        } else {
                            false
                        }
                    }
                }
                QuartzFetch.FETCH_ALL -> {
                    for (event in client.fetchAll(relay, filters, IDLE_MS)) {
                        if (event.verify()) sink.event(event.id)
                    }
                }
                QuartzFetch.FETCH -> {
                    client.fetch(relay, filters) { event -> if (event.verify()) sink.event(event.id) }
                }
                QuartzFetch.FETCH_EVENTS -> {
                    client.fetchEvents(relay, filters).collect { event -> if (event.verify()) sink.event(event.id) }
                }
                QuartzFetch.FETCH_AS_FLOW -> {
                    var done = 0
                    client.fetchAsFlow(relay, filters).collect { list ->
                        for (i in done until list.size) {
                            val event = list[i]
                            if (event.verify()) sink.event(event.id)
                        }
                        done = list.size
                    }
                }
            }
            sink.eose()
        }
    }

    override fun teardown() {
        client.releaseConnection(relay)
        client.disconnect()
        client.close()
        scope.cancel()
    }

    private companion object {
        /** The accessories' idle window (no event for this long ends the fetch); far above any gap here. */
        const val IDLE_MS = 60_000L
    }
}
