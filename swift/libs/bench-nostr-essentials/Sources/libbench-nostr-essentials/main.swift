// NostrEssentials: ConnectionPool -> RelayConnection (URLSessionWebSocketTask, one URLSession
// per connection). The pool hands every text frame to the app's RelayConnectionDelegate on
// the main queue, unparsed; the app parses it with the library's parseRelayMessage
// (JSONDecoder) and verifies with the library's Event.verified() (id + Schnorr), as Nostur
// does. Both happen inside the run, on the main queue where the library delivers.
import BenchCore
import Foundation

#if canImport(NostrEssentials) && canImport(Combine)
import NostrEssentials

final class Delegate: RelayConnectionDelegate, @unchecked Sendable {
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

    func didConnect(_ url: String) {
        connected.open()
    }

    func didReceiveMessage(_ url: String, message: String) {
        let (sink, id) = current()
        guard let sink else { return }
        guard let relayMessage = try? parseRelayMessage(text: message, relay: url) else { return }
        switch relayMessage.type {
        case .EVENT:
            guard relayMessage.subscriptionId == id, let event = relayMessage.event else { return }
            guard (try? event.verified()) == true, let eventId = event.id else { return }
            sink.event(hex: eventId)
        case .EOSE:
            if relayMessage.subscriptionId == id { sink.endOfStoredEvents() }
        default:
            break
        }
    }

    func didDisconnect(_ url: String) {}

    func didDisconnectWithError(_ url: String, error: Error) {
        connected.open("connection error: \(error)")
        current().0?.fail("connection error: \(error)")
    }
}

final class PoolSession: Session {
    let delegate = Delegate()
    let pool: ConnectionPool
    let relayId: String
    let subscriptionId = UUID().uuidString

    init(url: String) throws {
        pool = ConnectionPool(delegate: delegate)
        let connection = pool.addConnection(RelayConfig(url: url, read: true, write: false))
        relayId = connection.relayConfig.id
        pool.connectAll()
        guard delegate.connected.wait(seconds: 15) else { throw TimeoutError(what: "relay did not connect within 15 s") }
        if let msg = delegate.connected.message { throw LibraryError(msg) }
    }

    func subscribe(_ sink: Sink, limit: Int) throws {
        delegate.start(sink, subscriptionId: subscriptionId)
        let req = ClientMessage(type: .REQ, subscriptionId: subscriptionId, filters: [Filters(limit: limit)])
        pool.sendMessage(req, subscriptionId: subscriptionId)
    }

    func close() {
        pool.closeSubscription(subscriptionId)
        // removeConnection disconnects and drops the connection (which holds the pool).
        pool.removeConnection(relayId)
    }
}

childMain(openers: [
    "nostr-essentials-pool": { url in try PoolSession(url: url) },
])
#else
// Not an Apple platform: the library does not build here (Combine, Network, CoreData).
childMain(openers: [:])
#endif
