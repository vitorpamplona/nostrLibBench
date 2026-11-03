// yysskk/swift-nostr: NostrClient -> RelayPool -> RelayConnection -> WebSocketSession.
// The pool parses each frame (RelayMessage.parse, JSONDecoder) and deduplicates per
// subscription but does not verify, so the harness calls the library's Event.verify()
// (id recomputed and compared, then Schnorr) on every delivered event, inside the run.
//
// Two transports, both through the library's own WebSocketSessionFactory seam:
//   swift-nostr-client          the default URLSessionWebSocketFactory (URLSessionWebSocketTask)
//   swift-nostr-websocketkit    NostrClient(webSocketFactory:) with a factory over Vapor's
//                               websocket-kit (SwiftNIO): what the library documents for a
//                               platform whose Foundation has no WebSocket client (Linux with a
//                               libcurl built without WebSockets). A variant: the transport
//                               adapter below is harness code.
import BenchCore
import Foundation
import NIOCore
import NIOPosix
import NostrClient
import NostrCore
import WebSocketKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SwiftNostrSession: Session, @unchecked Sendable {
    let client: NostrClient
    var consumer: Task<Void, Never>?
    var subscription: SubscriptionSequence?

    init(url: String, client: NostrClient) throws {
        let relay = try RelayURL(string: url)
        self.client = client
        do {
            try blocking("connect") {
                try await client.relays.connect(to: [relay])
            }
        } catch {
            #if os(Linux)
            throw LibraryError("\(error) (URLSessionWebSocketTask on Linux needs a libcurl built with WebSocket support)")
            #else
            throw error
            #endif
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

// MARK: - websocket-kit transport (swift-nostr-websocketkit)

/// One event-loop thread for the whole process, created before the first run (untimed):
/// the same single network thread URLSession uses.
let nioGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

struct WebSocketKitFactory: WebSocketSessionFactory {
    func makeWebSocket(with request: URLRequest) -> any WebSocketSession {
        WebSocketKitSession(url: request.url!)
    }
}

/// swift-nostr's WebSocketSession over a websocket-kit WebSocket.
final class WebSocketKitSession: WebSocketSession, @unchecked Sendable {
    private let url: URL
    private let socket: EventLoopPromise<WebSocket>
    private let incoming: AsyncThrowingStream<WebSocketMessage, Error>
    private let continuation: AsyncThrowingStream<WebSocketMessage, Error>.Continuation
    private var iterator: AsyncThrowingStream<WebSocketMessage, Error>.AsyncIterator
    private let lock = NSLock()
    private var pongHandlers: [@Sendable ((any Error)?) -> Void] = []

    struct Closed: Error {}

    init(url: URL) {
        self.url = url
        socket = nioGroup.next().makePromise(of: WebSocket.self)
        (incoming, continuation) = AsyncThrowingStream.makeStream(of: WebSocketMessage.self)
        iterator = incoming.makeAsyncIterator()
    }

    func resume() {
        // websocket-kit's 16 KiB default frame limit would drop the larger events (up to 48 KB
        // in the corpus): raised to 1 MiB, URLSessionWebSocketTask's default.
        let config = WebSocketClient.Configuration(maxFrameSize: 1 << 20)
        let continuation = self.continuation
        let socket = self.socket
        WebSocket.connect(to: url, configuration: config, on: nioGroup) { [weak self] ws in
            ws.onText { _, text in continuation.yield(.string(text)) }
            ws.onBinary { _, buf in continuation.yield(.data(Data(buf.readableBytesView))) }
            ws.onPong { [weak self] _, _ in self?.pong(nil) }
            ws.onClose.whenComplete { _ in continuation.finish(throwing: Closed()) }
            socket.succeed(ws)
        }.whenFailure { [weak self] error in
            socket.fail(error)
            continuation.finish(throwing: error)
            self?.pong(error)
        }
    }

    private func pong(_ error: (any Error)?) {
        lock.lock()
        let handlers: [@Sendable ((any Error)?) -> Void]
        if error != nil {
            handlers = pongHandlers
            pongHandlers = []
        } else {
            handlers = pongHandlers.isEmpty ? [] : [pongHandlers.removeFirst()]
        }
        lock.unlock()
        for h in handlers { h(error) }
    }

    func cancel(with closeCode: WebSocketCloseCode, reason: Data?) {
        socket.futureResult.whenSuccess { ws in _ = ws.close(code: .normalClosure) }
        continuation.finish()
    }

    func send(_ message: WebSocketMessage) async throws {
        let ws = try await socket.futureResult.get()
        switch message {
        case .string(let text): try await ws.send(text)
        case .data(let data): try await ws.send([UInt8](data))
        }
    }

    func receive() async throws -> WebSocketMessage {
        // RelayConnection calls this from one receive loop at a time.
        guard let message = try await iterator.next() else { throw Closed() }
        return message
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable ((any Error)?) -> Void) {
        socket.futureResult.whenComplete { [weak self] result in
            switch result {
            case .success(let ws):
                self?.lock.lock()
                self?.pongHandlers.append(pongReceiveHandler)
                self?.lock.unlock()
                ws.sendPing()
            case .failure(let error):
                pongReceiveHandler(error)
            }
        }
    }
}

childMain(openers: [
    "swift-nostr-client": { url in try SwiftNostrSession(url: url, client: NostrClient()) },
    "swift-nostr-websocketkit": { url in
        try SwiftNostrSession(url: url, client: NostrClient(webSocketFactory: WebSocketKitFactory()))
    },
])
