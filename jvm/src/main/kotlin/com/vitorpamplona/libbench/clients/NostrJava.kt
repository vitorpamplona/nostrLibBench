package com.vitorpamplona.libbench.clients

import com.vitorpamplona.libbench.BenchClient
import com.vitorpamplona.libbench.EventSink
import nostr.client.relay.RelayConnection
import nostr.client.relay.RelayPool
import nostr.client.relay.RelaySubscription
import nostr.client.relay.SubscriptionListener
import nostr.client.springwebsocket.NostrRelayClient
import nostr.crypto.schnorr.Schnorr
import nostr.event.filter.EventFilter
import nostr.event.impl.GenericEvent
import nostr.event.serializer.EventSerializer
import nostr.util.NostrUtil
import java.time.Duration

/**
 * nostr-java (tcheeric): [RelayPool] (what `NostrClient.subscribe` delegates to) over
 * [NostrRelayClient], a Spring `StandardWebSocketClient` on Tomcat's JSR-356 client.
 *
 * The pool decodes events (Jackson) and dedups them, but never verifies. nostr-java has no
 * event-level verify; [verify] composes the library's own pieces: the id from
 * `EventSerializer.serializeAndComputeId` (its NIP-01 serializer + SHA-256), then
 * `nostr.crypto.schnorr.Schnorr.verify` (pure-Java BIP-340 on BigInteger).
 */
class NostrJavaClient(
    private val timeoutMs: () -> Long,
) : BenchClient {
    private lateinit var pool: RelayPool
    private var sub: RelaySubscription? = null

    override fun setup(url: String) {
        pool =
            RelayPool(
                listOf(url),
                { uri -> NostrRelayClient(uri, 60_000L) as RelayConnection },
                RelayPool.DEFAULT_PUBLISH_TIMEOUT,
                RelayPool.DEFAULT_RECONNECT_INTERVAL,
                // The default (10 s) announces EOSE on its own once it passes, backlog or not.
                Duration.ofMillis(timeoutMs()),
            )
        check(pool.connectedRelays.isNotEmpty()) { "nostr-java did not connect to $url: ${pool.unreachableRelays}" }
    }

    override fun subscribe(
        limit: Int,
        sink: EventSink,
    ) {
        sub =
            pool.subscribe(
                listOf(EventFilter.builder().limit(limit).build()),
                object : SubscriptionListener {
                    override fun onEvent(event: GenericEvent) {
                        if (verify(event)) sink.event(event.id)
                    }

                    override fun onEndOfStoredEvents() {
                        sink.eose()
                    }
                },
            )
    }

    override fun teardown() {
        sub?.close()
        pool.close()
    }

    companion object {
        fun verify(e: GenericEvent): Boolean =
            try {
                val id = e.id
                val computed = EventSerializer.serializeAndComputeId(e.pubKey, e.createdAt, e.kind, e.tags, e.content)
                id == computed &&
                    Schnorr.verify(NostrUtil.hexToBytes(id), e.pubKey.rawData, e.signature.rawData)
            } catch (_: Exception) {
                false
            }
    }
}
