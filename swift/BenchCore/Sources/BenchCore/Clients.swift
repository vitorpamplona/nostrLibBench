import Foundation

/// One client: a library driven through one of its subscription APIs.
public struct ClientInfo {
    public let id: String
    public let library: String
    /// The package under swift/libs/ whose binary (libbench-<package>) runs this client.
    public let package: String
    /// The library's pin in that package's Package.resolved (its identity).
    public let pin: String
    /// The version reported when the pin is a revision rather than a release.
    public let versionLabel: String
    public let license: String
    public let api: String
    public let websocket: String
    public let crypto: String
    public let verify: String
    public let notes: String
    public let variant: Bool
    /// Builds and runs only on Apple platforms (Combine, CommonCrypto, Network, an xcframework…).
    public let appleOnly: Bool
}

/// A client instance connected to the relay (setup is untimed).
public protocol Session: AnyObject {
    /// Called right after t0. Asks the library for the subscription with one filter
    /// {"limit": limit} and arranges for every event the library delivers (verified first if
    /// the client's verify is "explicit") to reach `sink.event` and for the EOSE to reach
    /// `sink.endOfStoredEvents`. Delivery may happen on other threads after this returns.
    func subscribe(_ sink: Sink, limit: Int) throws
    /// Tears the subscription and the client down (untimed).
    func close()
}

/// Creates a new client instance for one run and connects it to `url` (untimed).
public typealias Opener = (_ url: String) throws -> Session

private let urlSessionWS = "URLSessionWebSocketTask (Apple Foundation; on Linux swift-corelibs-foundation over libcurl)"

public let allClients: [ClientInfo] = [
    ClientInfo(
        id: "nostr-sdk-ios-relay",
        library: "nostr-sdk-ios",
        package: "nostr-sdk-ios",
        pin: "nostr-sdk-ios",
        versionLabel: "0.3.0+e5855cb",
        license: "MIT",
        api: "Relay(url:) + connect(); relay.events (Combine PassthroughSubject<RelayEvent>) .sink for events, RelayDelegate.relay(_:didReceive: RelayResponse) for EOSE; relay.subscribe(with: Filter(limit:))",
        websocket: "URLSessionWebSocketTask (URLSession.shared, Apple Foundation), via the library's WebSocket class",
        crypto: "libsecp256k1 0.3.2 (C, vendored by GigaBitcoin/secp256k1.swift 0.12.2); SHA-256 by CommonCrypto",
        verify: "explicit",
        notes: "Relay only decodes events (JSONDecoder into a per-kind NostrEvent subclass) and publishes them unverified. The harness calls the library's own EventVerifying.verifyEvent on each one (Relay conforms to it): id = SHA-256 of EventSerializer's JSONEncoder serialization, then Schnorr via secp256k1.swift. Pinned to main (e5855cb, Jan 2026): the 0.3.0 tag predates the fix for the Data.bytes ambiguity that breaks its build with current Xcode. Known gap: its Tag type requires a value, so an event with a one-element tag (NIP-57 [\"anon\"], [\"content-warning\"]) fails to decode and is silently dropped (20 valid events of `all`, none of `smoke`). Defaults kept: Relay logs every received frame at .info through os.Logger (unified logging, not the console; the message text is only formatted when that level is being collected). A new Relay per run.",
        variant: false,
        appleOnly: true
    ),
    ClientInfo(
        id: "nostr-sdk-ios-pool",
        library: "nostr-sdk-ios",
        package: "nostr-sdk-ios",
        pin: "nostr-sdk-ios",
        versionLabel: "0.3.0+e5855cb",
        license: "MIT",
        api: "RelayPool(relayURLs:delegate:) (connects on init); pool.events Combine publisher (Publishers.MergeMany of the relays' events) .sink, RelayDelegate for EOSE; pool.subscribe(with: Filter(limit:))",
        websocket: "URLSessionWebSocketTask (URLSession.shared, Apple Foundation), via the library's WebSocket class",
        crypto: "libsecp256k1 0.3.2 (C, vendored by GigaBitcoin/secp256k1.swift 0.12.2); SHA-256 by CommonCrypto",
        verify: "explicit",
        notes: "Same pipeline as nostr-sdk-ios-relay through the multi-relay RelayPool (one relay): one more Combine hop per event, no dedup. The harness verifies each delivered event with the library's EventVerifying.verifyEvent. A new RelayPool per run.",
        variant: true,
        appleOnly: true
    ),
    ClientInfo(
        id: "nostr-sdk-swift-stream",
        library: "nostr-sdk-swift",
        package: "rust-nostr",
        pin: "nostr-sdk-swift",
        versionLabel: "0.45.1",
        license: "MIT",
        api: "Client() + addRelay + tryConnect, then client.streamEvents(target: .auto(filters:), policy: .exitOnEose) and `await stream.next()` until it ends at EOSE",
        websocket: "tungstenite 0.28 (Rust, via async-wsocket 0.17, compiled into the nostr_sdkFFI xcframework)",
        crypto: "libsecp256k1 (C, via secp256k1-sys 0.10.1, compiled into the nostr_sdkFFI xcframework)",
        verify: "library",
        notes: "rust-nostr's UniFFI Swift bindings (github.com/rust-nostr/nostr-sdk-swift, now nostrdevkit; the xcframework holds nostr-sdk 0.45.2 / nostr 0.45.3): the Rust nostr-sdk does everything (parse with serde_json, id + signature check of every event with a per-Client LRU of verified ids, seen-ids tracker); Swift only receives Event handles across the FFI. Drops events whose NIP-40 expiration has passed (unconditional), so expired_accepted is 0. A new Client per run. The binary target is an Apple-only xcframework.",
        variant: false,
        appleOnly: true
    ),
    ClientInfo(
        id: "nostr-sdk-swift-notifications",
        library: "nostr-sdk-swift",
        package: "rust-nostr",
        pin: "nostr-sdk-swift",
        versionLabel: "0.45.1",
        license: "MIT",
        api: "client.notifications() + client.subscribe(target: .auto(filters:)); ClientNotification.newEvent per event, .message(RelayMessage .endOfStoredEvents) for EOSE",
        websocket: "tungstenite 0.28 (Rust, via async-wsocket 0.17, compiled into the nostr_sdkFFI xcframework)",
        crypto: "libsecp256k1 (C, via secp256k1-sys 0.10.1, compiled into the nostr_sdkFFI xcframework)",
        verify: "library",
        notes: "Same Rust pipeline as nostr-sdk-swift-stream, delivered through the client's broadcast notification channel (a reader that lags behind its capacity loses events). Drops expired events (NIP-40).",
        variant: true,
        appleOnly: true
    ),
    ClientInfo(
        id: "swift-nostr-client",
        library: "swift-nostr",
        package: "swift-nostr",
        pin: "swift-nostr",
        versionLabel: "0.9.0",
        license: "MIT",
        api: "NostrClient() + client.relays.connect(to:), then client.subscriptions.subscribe(filters: [Filter(limit:)]) and `for await` over the SubscriptionSequence (.event / .eose)",
        websocket: urlSessionWS + ", via the library's URLSessionWebSocketFactory",
        crypto: "libsecp256k1 0.7.1 (C, vendored by 21-DOT-DEV/swift-secp256k1 0.24.0, P256K); SHA-256 by swift-crypto (CryptoKit on Apple, BoringSSL on Linux)",
        verify: "explicit",
        notes: "yysskk/swift-nostr: the RelayPool parses (JSONDecoder) and deduplicates per subscription but does not verify; the harness calls the library's own Event.verify() (id recomputed and compared, then Schnorr) on each delivered event. NostrClient is the library's client; it holds one relay here. A new NostrClient per run.",
        variant: false,
        appleOnly: false
    ),
    ClientInfo(
        id: "swift-nostr-websocketkit",
        library: "swift-nostr",
        package: "swift-nostr",
        pin: "swift-nostr",
        versionLabel: "0.9.0",
        license: "MIT",
        api: "NostrClient(webSocketFactory:) with a WebSocketSessionFactory over Vapor's websocket-kit; then as swift-nostr-client",
        websocket: "websocket-kit 2.16.2 (SwiftNIO, one event-loop thread), through the library's WebSocketSessionFactory seam",
        crypto: "libsecp256k1 0.7.1 (C, vendored by 21-DOT-DEV/swift-secp256k1 0.24.0, P256K); SHA-256 by swift-crypto (CryptoKit on Apple, BoringSSL on Linux)",
        verify: "explicit",
        notes: "The transport swift-nostr documents for platforms whose Foundation has no WebSocket client (on Linux, swift-corelibs-foundation needs a libcurl built with WebSockets). The ~80-line adapter from websocket-kit to the library's WebSocketSession protocol is harness code, hence a variant. websocket-kit's 16 KiB maxFrameSize raised to 1 MiB (URLSessionWebSocketTask's default) so large events are not dropped. Everything else as swift-nostr-client.",
        variant: true,
        appleOnly: false
    ),
    ClientInfo(
        id: "nostr-essentials-pool",
        library: "nostr-essentials",
        package: "nostr-essentials",
        pin: "nostr-essentials",
        versionLabel: "1.0.0+50bd46e",
        license: "GPL-3.0-only",
        api: "ConnectionPool(delegate:) + addConnection(RelayConfig) + connect(); sendMessage(ClientMessage(type: .REQ, filters: [Filters(limit:)])); RelayConnectionDelegate.didReceiveMessage (raw text, on the main queue) parsed with parseRelayMessage(text:relay:)",
        websocket: "URLSessionWebSocketTask (own URLSession per connection, Apple Foundation), via the library's RelayConnection",
        crypto: "libsecp256k1 0.3.2 (C, vendored by GigaBitcoin/secp256k1.swift 0.12.2); SHA-256 by the same libsecp256k1 (secp256k1_swift_sha256)",
        verify: "explicit",
        notes: "Nostur's library (nostur-com/nostr-essentials). The pool hands the app raw message text on the main queue; the app parses it with the library's parseRelayMessage (JSONDecoder) and, as Nostur does, verifies with the library's Event.verified() (id recomputed with JSONEncoder + SHA-256, then Schnorr). ConnectionPool is the library's only relay client (RelayConnection cannot be created outside it); it holds one relay here. Pinned to main (50bd46e, Mar 2026; 78 commits after the only tag, 1.0.0). A new ConnectionPool per run.",
        variant: false,
        appleOnly: true
    ),
]
