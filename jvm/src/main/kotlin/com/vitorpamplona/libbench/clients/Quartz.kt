package com.vitorpamplona.libbench.clients

import com.vitorpamplona.libbench.BenchClient
import com.vitorpamplona.libbench.EventSink
import com.vitorpamplona.quartz.nip01Core.crypto.verify
import com.vitorpamplona.quartz.nip01Core.relay.client.NostrClient
import com.vitorpamplona.quartz.nip01Core.relay.client.accessories.ParallelEventVerifier
import com.vitorpamplona.quartz.nip01Core.relay.client.accessories.fetch
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
 * Quartz (Amethyst's Nostr library): its one-relay read, [fetch], on a [NostrClient] over
 * [BasicOkHttpWebSocket], the relay pool Amethyst (Android, Desktop and the `amy` CLI) runs on.
 *
 * [fetch] sends one REQ and hands each event, unverified, to its callback on the relay's
 * delivery coroutine until EOSE. The callback verifies with Quartz's `Event.verify()` (id via
 * `EventHasher.hashIdCheck`, then the BIP-340 signature through secp256k1-kmp, i.e. libsecp256k1
 * over JNI), inline ([parallel] = false), or submits the event to Quartz's own
 * [ParallelEventVerifier] accessory, which verifies batches on Dispatchers.Default ([parallel] =
 * true). The fetch runs in a coroutine on the client's Dispatchers.IO scope, as an app launches it.
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

    override fun setup(url: String) {
        relay = RelayUrlNormalizer.normalizeOrNull(url) ?: error("Quartz could not normalize $url")
        scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
        client = NostrClient(BasicOkHttpWebSocket.Builder { okHttp }, scope)
        // Opens the socket ahead of the fetch (the app keeps its relays connected).
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
        scope.launch {
            client.fetch(relay, Filter(limit = limit)) { event ->
                if (v != null) {
                    v.submit(event, Unit)
                } else if (event.verify()) {
                    sink.event(event.id)
                }
            }
            sink.eose()
        }
    }

    override fun teardown() {
        verifier?.close()
        client.releaseConnection(relay)
        client.disconnect()
        client.close()
        scope.cancel()
    }
}
