// nostr-sdk-ios: Relay / RelayPool over the library's WebSocket class
// (URLSessionWebSocketTask on URLSession.shared). Relay decodes each frame with JSONDecoder
// into a per-kind NostrEvent subclass and publishes it on its Combine `events` subject
// without verifying it, so the harness calls the library's EventVerifying.verifyEvent
// (id + Schnorr) on each delivered event, inside the run. EOSE only reaches the app through
// RelayDelegate.relay(_:didReceive: RelayResponse).
import BenchCore
import Foundation

#if canImport(Combine) && canImport(NostrSDK)
import Combine
import NostrSDK

/// The app's verifier: the library's own EventVerifying protocol extension
/// (verifyEvent = calculatedId == id, then verifySignature with secp256k1.swift).
struct Verifier: EventVerifying {}

/// Receives relay state changes (to wait for the connection) and responses (for the EOSE).
final class Delegate: RelayDelegate, @unchecked Sendable {
    let connected = Latch()
    private let lock = NSLock()
    private var sink: Sink?
    private var subscriptionId = ""

    func start(_ sink: Sink, subscriptionId: String) {
        lock.lock()
        self.sink = sink
        self.subscriptionId = subscriptionId
        lock.unlock()
    }

    private func current() -> (Sink?, String) {
        lock.lock()
        defer { lock.unlock() }
        return (sink, subscriptionId)
    }

    func relayStateDidChange(_ relay: Relay, state: Relay.State) {
        switch state {
        case .connected:
            connected.open()
        case .error(let error):
            connected.open("relay error: \(error)")
            current().0?.fail("relay error: \(error)")
        default:
            break
        }
    }

    func relay(_ relay: Relay, didReceive response: RelayResponse) {
        let (sink, id) = current()
        switch response {
        case .eose(let subscriptionId) where subscriptionId == id:
            sink?.endOfStoredEvents()
        case .closed(let subscriptionId, let message) where subscriptionId == id:
            sink?.fail("CLOSED: \(message.message)")
        default:
            break
        }
    }

    func relay(_ relay: Relay, didReceive event: RelayEvent) {}
}

private func deliver(_ relayEvent: RelayEvent, subscriptionId: String, to sink: Sink) {
    guard relayEvent.subscriptionId == subscriptionId else { return }
    do {
        try Verifier().verifyEvent(relayEvent.event)
    } catch {
        return
    }
    sink.event(hex: relayEvent.event.id)
}

private func connectTimeout(_ delegate: Delegate, _ isConnected: () -> Bool) throws {
    guard delegate.connected.wait(seconds: 15) else { throw TimeoutError(what: "relay did not connect within 15 s") }
    if let msg = delegate.connected.message { throw LibraryError(msg) }
    try waitUntil("relay state .connected", seconds: 5, isConnected)
}

/// One Relay (the library's single-relay client).
final class RelaySession: Session {
    let relay: Relay
    let delegate = Delegate()
    var cancellable: AnyCancellable?
    let subscriptionId = UUID().uuidString

    init(url: String) throws {
        guard let u = URL(string: url) else { throw LibraryError("bad URL \(url)") }
        relay = try Relay(url: u)
        relay.delegate = delegate
        relay.connect()
        let relay = self.relay
        try connectTimeout(delegate) { relay.state == .connected }
    }

    func subscribe(_ sink: Sink, limit: Int) throws {
        let id = subscriptionId
        delegate.start(sink, subscriptionId: id)
        cancellable = relay.events.sink { relayEvent in
            deliver(relayEvent, subscriptionId: id, to: sink)
        }
        guard let filter = Filter(limit: limit) else { throw LibraryError("Filter(limit:) returned nil") }
        try relay.subscribe(with: filter, subscriptionId: id)
    }

    func close() {
        try? relay.closeSubscription(with: subscriptionId)
        cancellable?.cancel()
        relay.disconnect()
    }
}

/// A RelayPool holding one relay.
final class PoolSession: Session {
    let pool: RelayPool
    let delegate = Delegate()
    var cancellable: AnyCancellable?
    let subscriptionId = UUID().uuidString

    init(url: String) throws {
        guard let u = URL(string: url) else { throw LibraryError("bad URL \(url)") }
        pool = try RelayPool(relayURLs: [u], delegate: delegate) // connects its relays
        let pool = self.pool
        try connectTimeout(delegate) { pool.relays.allSatisfy { $0.state == .connected } }
    }

    func subscribe(_ sink: Sink, limit: Int) throws {
        let id = subscriptionId
        delegate.start(sink, subscriptionId: id)
        cancellable = pool.events.sink { relayEvent in
            deliver(relayEvent, subscriptionId: id, to: sink)
        }
        guard let filter = Filter(limit: limit) else { throw LibraryError("Filter(limit:) returned nil") }
        _ = pool.subscribe(with: filter, subscriptionId: id)
    }

    func close() {
        pool.closeSubscription(with: subscriptionId)
        cancellable?.cancel()
        pool.disconnect()
    }
}

childMain(openers: [
    "nostr-sdk-ios-relay": { url in try RelaySession(url: url) },
    "nostr-sdk-ios-pool": { url in try PoolSession(url: url) },
])
#else
// Not an Apple platform: the library does not build here (Combine, os.log, CommonCrypto).
childMain(openers: [:])
#endif
