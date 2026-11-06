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
 * stream that ends at EOSE. Either way the app reads on the thread that subscribed, until
 * EOSE: the harness adds no thread.
 */
class NostrSdkClient(
    private val stream: Boolean,
    /** ClientBuilder.notificationChannelSize; null keeps the default (4096). */
    private val channelSize: Long? = null,
) : BenchClient {
    private lateinit var client: Client
    private lateinit var relay: RelayUrl
    private var notifications: ClientNotificationStream? = null

    override fun setup(url: String) {
        client =
            ClientBuilder()
                .let { b -> channelSize?.let { b.notificationChannelSize(it.toULong()) } ?: b }
                .build()
        relay = RelayUrl.parse(url)
        runBlocking {
            client.addRelay(relay)
            client.connect(Duration.ofSeconds(30))
        }
        val status = runBlocking { client.relay(relay)?.status() }
        check(status == RelayStatus.CONNECTED) { "nostr-sdk did not connect to $url (status $status)" }
        // Subscribed to the notification channel before the REQ, as the docs require.
        if (!stream) notifications = client.notifications()
    }

    override fun subscribe(
        limit: Int,
        sink: EventSink,
    ) {
        val target = ReqTarget.single(relay, listOf(Filter().limit(limit.toULong())))
        runBlocking {
            if (!stream) {
                val n = notifications!!
                client.subscribe(target)
                var eose = false
                while (!eose) {
                    val item = n.next() ?: break
                    when (item) {
                        is ClientNotification.NewEvent -> {
                            val id = item.event.id()
                            sink.event(id.toHex())
                            id.destroy()
                        }
                        is ClientNotification.Message -> {
                            val e = item.message.asEnum()
                            if (e is RelayMessageEnum.EndOfStoredEvents) {
                                sink.eose()
                                eose = true
                            }
                            e.destroy()
                        }
                        else -> {}
                    }
                    item.destroy()
                }
            } else {
                // The stream ends at EOSE (default exit policy ExitOnEOSE).
                val events = client.streamEvents(target)
                while (true) {
                    val item = events.next() ?: break
                    item.event?.let { ev ->
                        val id = ev.id()
                        sink.event(id.toHex())
                        id.destroy()
                    }
                    item.destroy()
                }
                sink.eose()
                events.destroy()
            }
        }
    }

    override fun teardown() {
        runBlocking {
            client.unsubscribeAll()
            client.shutdown()
        }
        notifications?.destroy()
        relay.destroy()
        client.destroy()
    }
}
