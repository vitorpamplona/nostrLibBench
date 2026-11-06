// rust-nostr (nostr-sdk 0.45 in Rust) through its UniFFI Swift bindings. The Rust relay pool
// parses every frame, drops expired events (NIP-40), verifies id + signature (always on) and
// tracks seen ids; Swift receives `Event` objects (handles into Rust) across the FFI.
import BenchCore
import Foundation

#if canImport(NostrSDK)
import NostrSDK

private func connectedClient(_ url: String) throws -> Client {
    let client = Client()
    let relayUrl = try RelayUrl.parse(url: url)
    try blocking("connect") {
        _ = try await client.addRelay(url: relayUrl)
        let out = await client.tryConnect(timeout: 10)
        if !out.failed.isEmpty {
            throw LibraryError("connect: \(out.failed.values.joined(separator: "; "))")
        }
    }
    return client
}

private func shutdown(_ client: Client, _ consumer: Task<Void, Never>?) {
    consumer?.cancel()
    _ = try? blocking("shutdown", seconds: 5) {
        await client.shutdown()
    }
}

/// client.streamEvents(..., policy: .exitOnEose): the stream ends at EOSE.
final class StreamSession: Session {
    let client: Client
    var consumer: Task<Void, Never>?

    init(url: String) throws {
        client = try connectedClient(url)
    }

    func subscribe(_ sink: Sink, limit: Int) throws {
        let client = self.client
        let filter = Filter().limit(limit: UInt64(limit))
        let stream = try blocking("streamEvents") {
            try await client.streamEvents(target: ReqTarget.auto(filters: [filter]), policy: .exitOnEose)
        }
        consumer = Task.detached {
            var error: String?
            while let item = await stream.next() {
                if let event = item.event {
                    sink.event(bytes: event.id().asBytes())
                } else if let e = item.error {
                    error = e
                }
            }
            // ExitOnEOSE: the stream has ended because the EOSE arrived (or on an error).
            if let error {
                sink.fail("stream error: \(error)")
            } else {
                sink.endOfStoredEvents()
            }
        }
    }

    func close() {
        shutdown(client, consumer)
    }
}

/// client.notifications() + client.subscribe(...).
final class NotificationsSession: Session {
    let client: Client
    var consumer: Task<Void, Never>?
    let subscriptionId = "libbench-\(UUID().uuidString.prefix(8))"

    init(url: String) throws {
        client = try connectedClient(url)
    }

    func subscribe(_ sink: Sink, limit: Int) throws {
        let client = self.client
        let id = subscriptionId
        let notifications = client.notifications()
        consumer = Task.detached {
            while let n = await notifications.next() {
                switch n {
                case .newEvent(_, let subscriptionId, let event):
                    if subscriptionId == id { sink.event(bytes: event.id().asBytes()) }
                case .message(_, let message):
                    if case .endOfStoredEvents(let subscriptionId) = message.asEnum(), subscriptionId == id {
                        sink.endOfStoredEvents()
                    }
                case .shutdown:
                    return
                }
            }
        }
        let filter = Filter().limit(limit: UInt64(limit))
        _ = try blocking("subscribe") {
            try await client.subscribe(target: ReqTarget.auto(filters: [filter]), id: id)
        }
    }

    func close() {
        let client = self.client
        let id = subscriptionId
        _ = try? blocking("unsubscribe", seconds: 5) { try await client.unsubscribe(subscriptionId: id) }
        shutdown(client, consumer)
    }
}

childMain(openers: [
    "nostr-sdk-swift-stream": { url in try StreamSession(url: url) },
    "nostr-sdk-swift-notifications": { url in try NotificationsSession(url: url) },
])
#else
// Not an Apple platform: the nostr_sdkFFI binary target is an xcframework.
childMain(openers: [:])
#endif
