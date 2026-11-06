import Foundation

public struct TimeoutError: Error, CustomStringConvertible {
    public let what: String
    public init(what: String) { self.what = what }
    public var description: String { "timeout: \(what)" }
}

private final class Box<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// Runs async library code from the (synchronous) harness thread and waits for it, at most
/// `seconds`. The harness thread is never the main thread, so main-actor work in a library
/// keeps running while this waits.
public func blocking<T>(_ what: String, seconds: Double = 30, _ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = Box<T>()
    let sem = DispatchSemaphore(value: 0)
    let task = Task.detached {
        do {
            box.result = .success(try await body())
        } catch {
            box.result = .failure(error)
        }
        sem.signal()
    }
    if sem.wait(timeout: .now() + seconds) == .timedOut {
        task.cancel()
        throw TimeoutError(what: "\(what) took more than \(Int(seconds)) s")
    }
    return try box.result!.get()
}

/// Waits (polling) until `cond` holds, at most `seconds`.
public func waitUntil(_ what: String, seconds: Double = 30, _ cond: () -> Bool) throws {
    let deadline = nowNs() + UInt64(seconds * 1e9)
    while !cond() {
        if nowNs() > deadline { throw TimeoutError(what: "\(what) within \(Int(seconds)) s") }
        usleep(1000)
    }
}

/// A one-shot latch a library callback can open from any thread.
public final class Latch: @unchecked Sendable {
    private let sem = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var opened = false
    public private(set) var message: String?

    public init() {}

    public func open(_ message: String? = nil) {
        lock.lock()
        let first = !opened
        opened = true
        if first { self.message = message }
        lock.unlock()
        if first { sem.signal() }
    }

    /// True if opened within `seconds`.
    public func wait(seconds: Double) -> Bool {
        sem.wait(timeout: .now() + seconds) == .success
    }
}

public struct LibraryError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}
