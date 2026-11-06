package com.vitorpamplona.libbench

/**
 * One library driven through its public API. A new instance is created for every run
 * (HARNESS.md "A run"): [setup] untimed, [subscribe] timed (t0 is read right before it),
 * [teardown] untimed.
 */
interface BenchClient {
    /** Creates the library's client and, where the API allows it, connects to [url] and waits until it is open. */
    fun setup(url: String)

    /**
     * Asks the library for one subscription with the filter `{"limit": limit}` over its
     * streaming API and returns; every event the library delivers (verified, when the
     * row's `verify` is `explicit`) goes to [EventSink.event], the EOSE to [EventSink.eose].
     */
    fun subscribe(
        limit: Int,
        sink: EventSink,
    )

    /** Closes the subscription and the client. */
    fun teardown()
}

class ClientSpec(
    val id: String,
    val library: String,
    val version: String,
    val license: String,
    val api: String,
    val websocket: String,
    val crypto: String,
    /** library | explicit | harness (HARNESS.md "Verification: whose code"). */
    val verify: String,
    val notes: String,
    val variant: Boolean,
    val create: () -> BenchClient,
)
