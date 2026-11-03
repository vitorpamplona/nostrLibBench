// yysskk/swift-nostr: NostrClient -> RelayPool -> RelayConnection (URLSessionWebSocketTask).
// The pool parses each frame (RelayMessage.parse, JSONDecoder) and deduplicates per
// subscription but does not verify, so the harness calls Event.verify() (id + Schnorr) on
// every delivered event, inside the run.
import BenchCore
import Foundation
import NostrClient
import NostrCore

final class SwiftNostrSession: Session, @unchecked Sendable {
    let client: NostrClient
    var consumer: Task<Void, Never>?
    var subscription: SubscriptionSequence?

    init(url: String) throws {
        let relay = try RelayURL(string: url)
        let client = NostrClient()
        self.client = client
        try blocking("connect") {
            try await client.relays.connect(to: [relay])
        }
    }

    func subscribe(_ sink: Sink, limit: Int) throws {
        let client = self.client
        let sub = try blocking("subscribe") {
            try await client.subscriptions.subscribe(filters: [Filter(limit: limit)])
        }
        subscription = sub
        consumer = Task.detached {
            for await item in sub {
                switch item {
                case .event(_, let event):
                    if (try? event.verify()) != nil {
                        sink.event(hex: event.id.description)
                    }
                case .eose:
                    sink.endOfStoredEvents()
                case .closed(_, let message):
                    sink.fail("CLOSED: \(message)")
                default:
                    break
                }
            }
        }
    }

    func close() {
        consumer?.cancel()
        let client = self.client
        let sub = subscription
        _ = try? blocking("teardown", seconds: 5) {
            await sub?.close()
            await client.relays.disconnect()
        }
    }
}

childMain(openers: [
    "swift-nostr-client": { url in try SwiftNostrSession(url: url) },
])
