package com.vitorpamplona.libbench.clients

import com.vitorpamplona.libbench.BenchClient
import com.vitorpamplona.libbench.EventSink
import kotlinx.coroutines.runBlocking
import org.nostrdevkit.sdk.Client
import org.nostrdevkit.sdk.ClientBuilder
import org.nostrdevkit.sdk.ClientNotification
import org.nostrdevkit.sdk.ClientNotificationStream
import org.nostrdevkit.sdk.Filter
import org.nostrdevkit.sdk.RelayMessageEnum
import org.nostrdevkit.sdk.RelayStatus
import org.nostrdevkit.sdk.RelayUrl
import org.nostrdevkit.sdk.ReqTarget
import java.time.Duration

/**
 * rust-nostr's nostr-sdk through its UniFFI Kotlin/JVM bindings (`org.nostrdevkit:nostr-sdk-jvm`):
 * the whole client (tokio-tungstenite WebSocket, serde parsing, id + signature check with
 * libsecp256k1, dedup in its events tracker) runs in Rust; Kotlin only pulls results over
 * JNA.
 *
 * [stream] = false: `Client.subscribe` + `Client.notifications()` (the long-lived feed API,
 * read with `ClientNotificationStream.next()`); true: `Client.streamEvents`, the short-lived
 * stream that ends at EOSE.
 */
class NostrSdkClient(
    private val stream: Boolean,
) : BenchClient {
    private lateinit var client: Client
    private lateinit var relay: RelayUrl
    private var notifications: ClientNotificationStream? = null
    private var consumer: Thread? = null

    @Volatile private var sink: EventSink? = null

    override fun setup(url: String) {
        client = ClientBuilder().build()
        relay = RelayUrl.parse(url)
        runBlocking {
            client.addRelay(relay)
            client.connect(Duration.ofSeconds(30))
        }
        val status = runBlocking { client.relay(relay)?.status() }
        check(status == RelayStatus.CONNECTED) { "nostr-sdk did not connect to $url (status $status)" }
        if (!stream) {
            // Subscribed to the notification channel before the REQ, as the docs require.
            val n = client.notifications()
            notifications = n
            consumer =
                Thread({
                    runBlocking {
                        while (true) {
                            val item = n.next() ?: break
                            handle(item)
                        }
                    }
                }, "nostr-sdk-notifications").apply {
                    isDaemon = true
                    start()
                }
        }
    }

    private fun handle(item: ClientNotification) {
        val s = sink
        when (item) {
            is ClientNotification.NewEvent -> {
                if (s != null) {
                    val id = item.event.id()
                    s.event(id.toHex())
                    id.destroy()
                }
            }
            is ClientNotification.Message -> {
                val e = item.message.asEnum()
                if (e is RelayMessageEnum.EndOfStoredEvents) s?.eose()
                e.destroy()
            }
            else -> {}
        }
        item.destroy()
    }

    override fun subscribe(
        limit: Int,
        sink: EventSink,
    ) {
        this.sink = sink
        val target = ReqTarget.single(relay, listOf(Filter().limit(limit.toULong())))
        if (!stream) {
            runBlocking { client.subscribe(target) }
        } else {
            val events = runBlocking { client.streamEvents(target) }
            // The stream ends at EOSE (default exit policy); read it on its own thread so the
            // call returns as soon as the REQ is out, like subscribe.
            consumer =
                Thread({
                    runBlocking {
                        while (true) {
                            val item = events.next() ?: break
                            item.event?.let { ev ->
                                val id = ev.id()
                                sink.event(id.toHex())
                                id.destroy()
                            }
                            item.destroy()
                        }
                    }
                    sink.eose()
                    events.destroy()
                }, "nostr-sdk-stream").apply {
                    isDaemon = true
                    start()
                }
        }
    }

    override fun teardown() {
        runBlocking {
            client.unsubscribeAll()
            client.shutdown()
        }
        consumer?.join(5_000)
        notifications?.destroy()
        relay.destroy()
        client.destroy()
    }
}
