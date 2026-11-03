package com.vitorpamplona.libbench.clients

import com.vitorpamplona.libbench.BenchClient
import com.vitorpamplona.libbench.EventSink
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.websocket.WebSockets
import rhodium.net.NostrService
import rhodium.nostr.NostrFilter
import rhodium.nostr.client.RequestMessage
import rhodium.nostr.deserializedEvent
import rhodium.nostr.relay.Relay
import rhodium.nostr.relay.RelayEose
import rhodium.nostr.relay.RelayEventMessage
import rhodium.nostr.relay.RelayPool

/**
 * Rhodium (KotlinGeekDev): `NostrService.request`, a callback per relay message over a Ktor
 * WebSocket session (OkHttp engine). The relay client hands the app the event's raw JSON
 * (`RelayEventMessage.eventJson`); the app turns it into an `Event` with the library's
 * `deserializedEvent`, which parses (kotlinx.serialization) and validates (`Event.isValid`:
 * id, then BIP-340 through secp256k1-kmp/libsecp256k1) and throws on an invalid event.
 */
class RhodiumClient : BenchClient {
    private lateinit var http: HttpClient
    private lateinit var service: NostrService

    override fun setup(url: String) {
        // The same client NostrService builds by default (HttpClient(OkHttp) + WebSockets),
        // made here so teardown can close it: stopService() does not end the session.
        http = HttpClient(OkHttp) { install(WebSockets) {} }
        service = NostrService(RelayPool(listOf(Relay(url))), http)
    }

    override fun subscribe(
        limit: Int,
        sink: EventSink,
    ) {
        val filter = NostrFilter.newFilter().limit(limit).build()
        service.request(
            RequestMessage.singleFilterRequest(filter = filter),
            onRequestError = { _, t -> System.err.println("   rhodium: request error: $t") },
            onRelayMessage = { _, msg ->
                when (msg) {
                    is RelayEventMessage -> {
                        val event =
                            try {
                                deserializedEvent(msg.eventJson)
                            } catch (_: Throwable) {
                                null
                            }
                        if (event != null) sink.event(event.id)
                    }
                    is RelayEose -> sink.eose()
                    else -> {}
                }
            },
        )
    }

    override fun teardown() {
        service.stopService()
        http.close()
    }
}
