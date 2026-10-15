import Foundation
import Dispatch

/// Errors with a message for the user.
public struct DCError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Thrown when the user stops a run.
public struct CancelledError: Error, CustomStringConvertible, LocalizedError {
    public init() {}
    public var description: String { "Cancelled" }
    public var errorDescription: String? { "Cancelled" }
}

/// Log sink, progress sink and cancellation flag shared by one run.
///
/// Callbacks can come from any thread. The GUI hops to the main actor.
public final class RunContext: @unchecked Sendable {
    public typealias LogHandler = @Sendable (String) -> Void
    public typealias ProgressHandler = @Sendable (_ phase: String, _ current: Int, _ total: Int) -> Void

    private let logHandler: LogHandler
    private let progressHandler: ProgressHandler
    private let lock = NSLock()
    private var cancelled = false

    public init(log: @escaping LogHandler = { print($0) },
                progress: @escaping ProgressHandler = { _, _, _ in }) {
        self.logHandler = log
        self.progressHandler = progress
    }

    /// A context that prints to standard output and ignores progress.
    public static func console() -> RunContext { RunContext() }

    /// A context that discards everything (tests).
    public static func silent() -> RunContext { RunContext(log: { _ in }) }

    public func log(_ line: String) { logHandler(line) }

    public func progress(_ phase: String, _ current: Int, _ total: Int) {
        progressHandler(phase, current, total)
    }

    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    public func checkCancelled() throws { if isCancelled { throw CancelledError() } }
}

public enum Parallel {
    /// Number of worker threads for data-parallel CPU loops.
    public static var workerCount: Int { max(1, ProcessInfo.processInfo.activeProcessorCount) }

    /// Run `body(range)` on disjoint contiguous chunks of `0..<count`.
    public static func forChunks(_ count: Int, minChunk: Int = 4096,
                                 _ body: (Range<Int>) -> Void) {
        if count <= 0 { return }
        let chunks = min(workerCount * 4, max(1, count / max(1, minChunk)))
        if chunks <= 1 { body(0..<count); return }
        let size = (count + chunks - 1) / chunks
        DispatchQueue.concurrentPerform(iterations: chunks) { k in
            let lo = k * size
            let hi = min(count, lo + size)
            if lo < hi { body(lo..<hi) }
        }
    }

    /// Run `body(i)` for every i in `0..<count` on many threads.
    public static func forEach(_ count: Int, _ body: (Int) -> Void) {
        if count <= 0 { return }
        if count == 1 { body(0); return }
        DispatchQueue.concurrentPerform(iterations: count, execute: body)
    }
}

/// Produce items concurrently, consume them in index order on the caller's thread.
///
/// At most `width` items are produced ahead of the consumer, which bounds
/// memory. This overlaps disk reads, GPU work and CPU analysis of several
/// frames while output (TIFF pages, movie frames) stays in order.
public func orderedPipeline<T>(count: Int,
                               width: Int,
                               context: RunContext?,
                               produce: @escaping (Int) throws -> T,
                               consume: (Int, T) throws -> Void) throws {
    if count <= 0 { return }
    let width = max(1, width)
    if width == 1 {
        for i in 0..<count {
            try context?.checkCancelled()
            try consume(i, try produce(i))
        }
        return
    }

    let queue = DispatchQueue(label: "dc.pipeline", qos: .userInitiated, attributes: .concurrent)
    let group = DispatchGroup()
    let condition = NSCondition()
    var results: [Int: Result<T, Error>] = [:]
    var stop = false
    var scheduled = 0

    func schedule(_ i: Int) {
        group.enter()
        queue.async {
            condition.lock()
            let skip = stop
            condition.unlock()
            let r: Result<T, Error>
            if skip {
                r = .failure(CancelledError())
            } else if let c = context, c.isCancelled {
                r = .failure(CancelledError())
            } else {
                r = Result { try produce(i) }
            }
            condition.lock()
            results[i] = r
            condition.broadcast()
            condition.unlock()
            group.leave()
        }
    }

    do {
        for i in 0..<count {
            while scheduled < count && scheduled < i + width {
                schedule(scheduled)
                scheduled += 1
            }
            condition.lock()
            while results[i] == nil { condition.wait() }
            let r = results.removeValue(forKey: i)!
            condition.unlock()
            try consume(i, try r.get())
        }
    } catch {
        condition.lock(); stop = true; condition.unlock()
        group.wait()
        throw error
    }
    group.wait()
}

/// Thread-safe counter for progress reports from concurrent work.
public final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    public init() {}
    @discardableResult
    public func increment() -> Int { lock.lock(); value += 1; let v = value; lock.unlock(); return v }
}
