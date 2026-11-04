package com.vitorpamplona.libbench.quartzproposal

import com.vitorpamplona.quartz.nip01Core.core.Event
import com.vitorpamplona.quartz.nip01Core.relay.client.INostrClient
import com.vitorpamplona.quartz.nip01Core.relay.client.accessories.DONE_REASON_EOSE
import com.vitorpamplona.quartz.nip01Core.relay.client.accessories.fetchAllWithHooks
import com.vitorpamplona.quartz.nip01Core.relay.client.single.newSubId
import com.vitorpamplona.quartz.nip01Core.relay.filters.Filter
import com.vitorpamplona.quartz.nip01Core.relay.normalizer.NormalizedRelayUrl
import com.vitorpamplona.quartz.nip01Core.relay.normalizer.RelayUrlNormalizer
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow

/*
 * A proposed single-relay accessory for Quartz, prototyped here on Quartz's public API so the
 * benchmark can measure it (rows quartz-fetch and quartz-fetchevents). Not part of Quartz 2.13.0.
 *
 * The job: one REQ to one relay, every event handed to the caller as it arrives, done at EOSE.
 * No subscription id to manage, no listener, no unsubscribe. Like every NostrClient method, it
 * does not verify: the caller verifies (Event.verify()) if it needs to. Nothing is collected,
 * deduped or sorted: events reach the caller in the relay's order, duplicates included (a relay
 * that sends an event twice is shown sending it twice; so is the replay after a reconnect, when
 * the pool re-sends the REQ). Merging relays into one distinct, ordered stream is another job.
 */

/** How a [fetch] ended. */
class FetchResult(
    /** Events handed to `onEvent`. */
    val delivered: Int,
    /**
     * Why the relay stopped: `"eose"`, `"closed:<msg>"`, `"cannot:<msg>"` or `"auth-refused:<msg>"`
     * (the reasons [fetchAllWithHooks] reports), or null when the relay went silent for the idle
     * window without one.
     */
    val reason: String?,
) {
    /** The relay answered the REQ to its end: zero [delivered] then means it had nothing. */
    val served: Boolean get() = reason == DONE_REASON_EOSE

    /** The relay went silent for the idle window before finishing. */
    val stalled: Boolean get() = reason == null
}

/**
 * Sends one REQ with [filters] to [relay] and hands every event the relay sends to [onEvent],
 * unverified, in arrival order, one at a time (the next event waits for [onEvent] to return).
 * Returns when the relay ends the subscription (EOSE, CLOSED, cannot connect, or an AUTH it
 * required failed) or sends nothing for [idleTimeoutMs]. Nothing is kept: memory does not grow
 * with the number of events.
 *
 * Built on [fetchAllWithHooks], so it inherits its handling of NIP-42 AUTH (a refusal waits for
 * this client's responder) and of a relay that refuses the `limit` (asked again lower).
 */
suspend fun INostrClient.fetch(
    relay: NormalizedRelayUrl,
    filters: List<Filter>,
    idleTimeoutMs: Long = 30_000L,
    subscriptionId: String = newSubId(),
    onEvent: suspend (Event) -> Unit,
): FetchResult {
    var delivered = 0
    val result =
        fetchAllWithHooks(
            filters = mapOf(relay to filters),
            idleTimeoutMs = idleTimeoutMs,
            subscriptionId = subscriptionId,
        ) { _, event ->
            delivered++
            onEvent(event)
            false // the caller has the event: don't let fetchAllWithHooks collect it
        }
    return FetchResult(delivered, result.doneReasons[relay])
}

suspend fun INostrClient.fetch(
    relay: NormalizedRelayUrl,
    filter: Filter,
    idleTimeoutMs: Long = 30_000L,
    subscriptionId: String = newSubId(),
    onEvent: suspend (Event) -> Unit,
) = fetch(relay, listOf(filter), idleTimeoutMs, subscriptionId, onEvent)

suspend fun INostrClient.fetch(
    relay: String,
    filters: List<Filter>,
    idleTimeoutMs: Long = 30_000L,
    subscriptionId: String = newSubId(),
    onEvent: suspend (Event) -> Unit,
) = fetch(RelayUrlNormalizer.normalize(relay), filters, idleTimeoutMs, subscriptionId, onEvent)

suspend fun INostrClient.fetch(
    relay: String,
    filter: Filter,
    idleTimeoutMs: Long = 30_000L,
    subscriptionId: String = newSubId(),
    onEvent: suspend (Event) -> Unit,
) = fetch(RelayUrlNormalizer.normalize(relay), listOf(filter), idleTimeoutMs, subscriptionId, onEvent)

/**
 * [fetch] as a cold [Flow]: each collection sends one REQ, emits every event the relay sends,
 * unverified, one at a time in arrival order, and completes when the relay ends the subscription
 * or goes silent for [idleTimeoutMs]. Cancelling the collector closes the REQ. The flow does not
 * say why it completed; call [fetch] when that matters.
 */
fun INostrClient.fetchEvents(
    relay: NormalizedRelayUrl,
    filters: List<Filter>,
    idleTimeoutMs: Long = 30_000L,
    subscriptionId: String = newSubId(),
): Flow<Event> =
    channelFlow {
        fetch(relay, filters, idleTimeoutMs, subscriptionId) { send(it) }
    }

fun INostrClient.fetchEvents(
    relay: NormalizedRelayUrl,
    filter: Filter,
    idleTimeoutMs: Long = 30_000L,
    subscriptionId: String = newSubId(),
) = fetchEvents(relay, listOf(filter), idleTimeoutMs, subscriptionId)

fun INostrClient.fetchEvents(
    relay: String,
    filters: List<Filter>,
    idleTimeoutMs: Long = 30_000L,
    subscriptionId: String = newSubId(),
) = fetchEvents(RelayUrlNormalizer.normalize(relay), filters, idleTimeoutMs, subscriptionId)

fun INostrClient.fetchEvents(
    relay: String,
    filter: Filter,
    idleTimeoutMs: Long = 30_000L,
    subscriptionId: String = newSubId(),
) = fetchEvents(RelayUrlNormalizer.normalize(relay), listOf(filter), idleTimeoutMs, subscriptionId)
