package com.vitorpamplona.libbench

import java.lang.management.ManagementFactory

/** Process CPU time (user + system, every thread), in nanoseconds. */
object Cpu {
    private val os = ManagementFactory.getOperatingSystemMXBean() as com.sun.management.OperatingSystemMXBean

    fun nanos(): Long = os.processCpuTime
}

/**
 * What the app does with each event a library delivers (HARNESS.md "A run", step 2):
 * count it, XOR its id, note the time. Thread-safe: libraries deliver from their own
 * threads, some from several.
 *
 * CPU time is sampled only at EOSE and at events delivered after it, so the run's CPU
 * time is taken at `t_end = max(EOSE, last event)` without a clock call per event.
 */
class EventSink(
    private val ambiguousIds: Set<String>,
    private val expiredIds: Set<String>,
    /** valid_events + every ambiguous id: the set is complete once this many arrived. */
    private val complete: Int,
) {
    private val lock = Object()

    var accepted = 0
        private set
    var ambiguous = 0
        private set
    var expired = 0
        private set
    val xor = LongArray(4)

    /** XOR of the ids of the ambiguous / expired events accepted (to check accepted_xor). */
    val ambiguousXor = LongArray(4)
    val expiredXor = LongArray(4)

    var eoseNanos = 0L
        private set
    var lastEventNanos = 0L
        private set
    private var eoseCpu = 0L
    private var lastEventCpu = 0L
    var eoseSeen = false
        private set
    var badIds = 0
        private set

    /** Every accepted id, in delivery order, when LIBBENCH_DUMP_IDS names a directory (debugging). */
    val dumped: MutableList<String>? = if (System.getenv("LIBBENCH_DUMP_IDS") != null) ArrayList() else null

    /** Set when the run ended: later deliveries are counted here, not in the run. */
    var late = 0
        private set
    private var closed = false

    fun close() = synchronized(lock) { closed = true }

    // Clocks are read inside the lock, so their order is the order the lock was taken in:
    // an event counted after the EOSE always has a later time (and a CPU sample).
    fun event(idHex: String) {
        synchronized(lock) {
            val now = System.nanoTime()
            if (closed) {
                late++
                return
            }
            if (!xorHex(idHex, xor)) {
                badIds++
                return
            }
            accepted++
            dumped?.add(idHex)
            if (ambiguousIds.isNotEmpty() && idHex in ambiguousIds) {
                ambiguous++
                xorHex(idHex, ambiguousXor)
            }
            if (expiredIds.isNotEmpty() && idHex in expiredIds) {
                expired++
                xorHex(idHex, expiredXor)
            }
            lastEventNanos = now
            if (eoseSeen) {
                lastEventCpu = Cpu.nanos()
                if (accepted >= complete) lock.notifyAll()
            }
        }
    }

    fun eose() {
        synchronized(lock) {
            if (eoseSeen || closed) return
            val now = System.nanoTime()
            val cpu = Cpu.nanos()
            eoseSeen = true
            eoseNanos = now
            eoseCpu = cpu
            lock.notifyAll()
        }
    }

    /** End of the timed part: max(EOSE time, time of the last accepted event). */
    fun endNanos() = synchronized(lock) { maxOf(eoseNanos, lastEventNanos) }

    /** CPU time at [endNanos]. */
    fun endCpu() = synchronized(lock) { if (lastEventNanos > eoseNanos) lastEventCpu else eoseCpu }

    enum class Outcome { DONE, TIMEOUT }

    /**
     * Waits until EOSE was seen and either the set is complete or no event arrived for
     * [idleMs]; or until [deadlineNanos] passes without EOSE (a timeout).
     */
    fun await(
        idleMs: Long,
        deadlineNanos: Long,
    ): Outcome {
        val idle = idleMs * 1_000_000L
        synchronized(lock) {
            while (true) {
                val now = System.nanoTime()
                if (eoseSeen) {
                    if (accepted >= complete) return Outcome.DONE
                    if (now - maxOf(eoseNanos, lastEventNanos) >= idle) return Outcome.DONE
                } else if (now >= deadlineNanos) {
                    return Outcome.TIMEOUT
                }
                lock.wait(20)
            }
        }
    }

    companion object {
        private fun nibble(c: Char): Int =
            when (c) {
                in '0'..'9' -> c - '0'
                in 'a'..'f' -> c - 'a' + 10
                in 'A'..'F' -> c - 'A' + 10
                else -> -1
            }

        /** XORs the 32-byte id [hex] into [acc] (4 big-endian longs); false if it is not 64 hex chars. */
        fun xorHex(
            hex: String,
            acc: LongArray,
        ): Boolean {
            if (hex.length != 64) return false
            for (w in 0 until 4) {
                var v = 0L
                val base = w * 16
                for (i in 0 until 16) {
                    val n = nibble(hex[base + i])
                    if (n < 0) return false
                    v = (v shl 4) or n.toLong()
                }
                acc[w] = acc[w] xor v
            }
            return true
        }

        fun toHex(acc: LongArray): String = acc.joinToString("") { java.lang.Long.toUnsignedString(it, 16).padStart(16, '0') }
    }
}
