import Foundation

public enum TransportKind: String, Sendable, CaseIterable, Codable {
    case serial
    case ethernet
    case audio
    case serialIP

    public var displayName: String {
        switch self {
        case .serial: return "Serial"
        case .ethernet: return "Ethernet"
        case .audio: return "Audio"
        case .serialIP: return "Serial over IP"
        }
    }
}

public enum TransportError: Error, Equatable, CustomStringConvertible {
    /// No byte arrived within the requested time.
    case timeout
    /// The transport has been closed for good.
    case closed
    case openFailed(String)
    case portInUse(String)

    public var description: String {
        switch self {
        case .timeout: return "Timed out"
        case .closed: return "Connection closed"
        case .openFailed(let why): return "Unable to open: \(why)"
        case .portInUse(let port): return "\(port) is in use"
        }
    }
}

/// A byte pipe to an Apple II client.
///
/// Reads come from the protocol engine's thread. Writes are buffered until
/// `flush()`; they may come from the engine or from a bootstrap sender, so
/// implementations must make writing thread-safe.
public protocol Transport: AnyObject, Sendable {
    var kind: TransportKind { get }
    /// Short human-readable description, e.g. "/dev/cu.usbserial at 115200".
    var summary: String { get }

    func open() throws
    func close()

    /// Wait up to `timeout` seconds for a single byte.
    func readByte(timeout: Double) throws -> UInt8

    /// Queue bytes for sending.
    func write(_ bytes: [UInt8])
    /// Send everything queued (one datagram / audio burst for packetised transports).
    func flush()
    /// Drop any received bytes not yet read.
    func discardInput()
    /// Drop any queued bytes not yet flushed.
    func discardOutput()

    /// Called after a bad packet; audio needs a long pause before the client retries.
    func pauseAfterBadPacket()

    /// Whether the user can push bootstrap text/binaries over this transport.
    var supportsBootstrap: Bool { get }

    /// Serial ports only: run at `baud` while bootstrapping, or restore the
    /// configured speed when passed nil.
    func setTemporarySpeed(_ baud: Int?)

    /// Serial ports only: change the configured speed (e.g. after Speediboot the
    /// client runs at 115200 regardless of the original setting).
    func setSpeed(_ baud: Int)
}

public extension Transport {
    func write(_ byte: UInt8) { write([byte]) }
    func write(_ text: String) { write(Array(text.utf8)) }
    func pauseAfterBadPacket() {}
    func setTemporarySpeed(_ baud: Int?) {}
    func setSpeed(_ baud: Int) {}
}

/// A thread-safe FIFO of received bytes with a blocking, timed read. Used by
/// transports whose input arrives on another thread (audio capture, test pipes).
public final class ByteQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var storage: [UInt8] = []
    private var head = 0
    private var closed = false

    public init() {}

    public func append<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        condition.lock()
        storage.append(contentsOf: bytes)
        condition.broadcast()
        condition.unlock()
    }

    public func read(timeout: Double) throws -> UInt8 {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while head >= storage.count {
            if closed { throw TransportError.closed }
            if !condition.wait(until: deadline) {
                if head < storage.count { break }
                if closed { throw TransportError.closed }
                throw TransportError.timeout
            }
        }
        let byte = storage[head]
        head += 1
        if head > 4096 && head * 2 > storage.count {
            storage.removeFirst(head)
            head = 0
        }
        return byte
    }

    public var count: Int {
        condition.lock(); defer { condition.unlock() }
        return storage.count - head
    }

    public func removeAll() {
        condition.lock()
        storage.removeAll()
        head = 0
        condition.unlock()
    }

    public func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    public func reopen() {
        condition.lock()
        closed = false
        storage.removeAll()
        head = 0
        condition.unlock()
    }
}
