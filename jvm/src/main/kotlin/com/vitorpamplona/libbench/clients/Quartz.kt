package com.vitorpamplona.libbench.clients

import com.vitorpamplona.libbench.BenchClient
import com.vitorpamplona.libbench.EventSink
import com.vitorpamplona.quartz.nip01Core.core.Event
import com.vitorpamplona.quartz.nip01Core.crypto.verify
import com.vitorpamplona.quartz.nip01Core.relay.client.NostrClient
import com.vitorpamplona.quartz.nip01Core.relay.client.accessories.ParallelEventVerifier
import com.vitorpamplona.quartz.nip01Core.relay.client.reqs.SubscriptionListener
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
        /** One OkHttpClient per process, as an app holds one; the same socket factory as amy. */
        private val okHttp: OkHttpClient by lazy {
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
