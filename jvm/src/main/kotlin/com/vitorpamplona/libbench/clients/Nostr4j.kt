package com.vitorpamplona.libbench.clients

import com.vitorpamplona.libbench.BenchClient
import com.vitorpamplona.libbench.EventSink
import org.ngengine.nostr4j.NostrFilter
import org.ngengine.nostr4j.NostrPool
import org.ngengine.nostr4j.NostrRelay
import org.ngengine.nostr4j.NostrSubscription
import org.ngengine.nostr4j.event.tracker.NaiveEventTracker
import org.ngengine.nostr4j.listeners.sub.NostrSubEoseListener
import org.ngengine.nostr4j.listeners.sub.NostrSubEventListener

/**
 * nostr4j (NostrGameEngine): [NostrPool] + [NostrRelay] over nge-platform-jvm's
 * `java.net.http.WebSocket` transport. The relay verifies every EVENT before its listeners
 * see it (`NostrRelay.verifyEvents`, default on): id recomputed with the library's own
 * serializer, BIP-340 in nge-platform-jvm's pure-Java `Schnorr` (BigInteger), run on the
 * common ForkJoinPool (`parallelEvents`, default on).
 */
class Nostr4jClient(
    /** Subscribe with a NaiveEventTracker (dedup by id) instead of the pool's default tracker. */
    private val naiveTracker: Boolean,
) : BenchClient {
    companion object {
        init {
            // nge-platform refuses loopback URIs unless told otherwise (its README).
            System.setProperty("nge-platforms.allowLoopbackInURIs", "true")
        }
    }

    private lateinit var pool: NostrPool
    private var sub: NostrSubscription? = null

    override fun setup(url: String) {
        pool = NostrPool()
        pool.connectRelay(NostrRelay(url)).await()
    }

    override fun subscribe(
        limit: Int,
        sink: EventSink,
    ) {
        val filter = NostrFilter().limit(limit)
        val s = if (naiveTracker) pool.subscribe(filter) { NaiveEventTracker() } else pool.subscribe(filter)
        s.addEventListener(NostrSubEventListener { _, event, _ -> sink.event(event.id) })
        s.addEoseListener(NostrSubEoseListener { _, _, everywhere -> if (everywhere) sink.eose() })
        sub = s
        s.open()
    }

    override fun teardown() {
        sub?.close()
        pool.close()
    }
}
