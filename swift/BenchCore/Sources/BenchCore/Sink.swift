import Foundation

/// The app side of a run: what the library delivers to (HARNESS.md "A run", step 2).
/// Thread-safe: libraries deliver on their own threads / queues / tasks.
public final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private let expect: Expect
    private let doneSem = DispatchSemaphore(value: 0)
    private var signaled = false

    var accepted = 0
    var xor = ID32()
    var ambiguous = 0
    var ambiguousXor = ID32()
    var expired = 0
    var lastNs: UInt64 = 0
    var eoseNs: UInt64 = 0
    var eose = false
    var cpuEndNs: UInt64 = 0
    var error: String?
    /// Events the library handed over whose id the harness could not read (counted as accepted).
    var badIds = 0

    init(expect: Expect) {
        self.expect = expect
    }

    /// One event delivered as valid, by id.
    public func event(_ id: ID32) {
        let now = nowNs()
        lock.lock()
        accepted += 1
        xor.xor(id)
        if expect.ambiguous.contains(id) {
            ambiguous += 1
            ambiguousXor.xor(id)
        }
        if expect.expired.contains(id) { expired += 1 }
        lastNs = now
        if eose {
            // Delivered after the EOSE (verified on another thread): the run ends here,
            // and so does its CPU time.
            cpuEndNs = cpuNs()
        }
        let complete = eose && accepted >= expect.full
        lock.unlock()
        if complete { signal() }
    }

    /// One event delivered as valid, by the hex id the library's event object holds.
    public func event(hex: String) {
        if let id = ID32(hexUTF8: hex.utf8) {
            event(id)
        } else {
            lock.lock(); badIds += 1; lock.unlock()
            event(ID32()) // counted; the XOR will not match
        }
    }

    /// One event delivered as valid, by its 32 raw id bytes.
    public func event<C: Collection>(bytes: C) where C.Element == UInt8 {
        if let id = ID32(bytes: bytes) {
            event(id)
        } else {
            lock.lock(); badIds += 1; lock.unlock()
            event(ID32())
        }
    }

    /// The library delivered the subscription's EOSE.
    public func endOfStoredEvents() {
        let now = nowNs()
        let cpu = cpuNs()
        lock.lock()
        if eose {
            lock.unlock()
            return
        }
        eose = true
        eoseNs = now
        cpuEndNs = cpu
        let complete = accepted >= expect.full
        lock.unlock()
        if complete { signal() }
    }

    /// The library reported an error that ends the run.
    public func fail(_ message: String) {
        lock.lock()
        if error == nil { error = message }
        lock.unlock()
        signal()
    }

    private func signal() {
        lock.lock()
        let first = !signaled
        signaled = true
        lock.unlock()
        if first { doneSem.signal() }
    }

    /// Waits until the run is complete, or for at most `ns`. True when complete.
    func waitDone(ns: UInt64) -> Bool {
        doneSem.wait(timeout: .now() + .nanoseconds(Int(ns))) == .success
    }

    func snapshot<T>(_ body: (Sink) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }
}

public struct RunResult {
    public var ms = 0.0
    public var cpuMs = 0.0
    public var accepted = 0
    public var xor = ID32()
    public var ambiguous = 0
    public var ambiguousXor = ID32()
    public var expired = 0
    /// `base_rss_mb`: the resident set read after this run's setup, before t0 (first run of a
    /// workload only).
    public var baseRssMb: Double?
}
