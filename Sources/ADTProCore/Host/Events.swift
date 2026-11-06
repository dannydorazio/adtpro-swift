import Foundation

/// Notifications from the server to whatever is presenting it (GUI or CLI).
public enum ServerEvent: Sendable, Equatable {
    /// The current activity, e.g. "Request: image from Apple to host".
    case status(String)
    /// Supporting detail: a file name, a result, an error.
    case detail(String)
    /// Progress through the current transfer. A total of zero means indeterminate/idle.
    case progress(done: Int, total: Int)
    /// The working directory changed (from the Apple or the host).
    case workingDirectoryChanged(String)
    /// A transfer finished.
    case transferFinished(TransferResult)
    /// A user-initiated bootstrap finished sending; `nextStep` holds follow-up instructions.
    case bootstrapFinished(nextStep: String?)
    /// The serial speed was changed by the protocol (e.g. after Speediboot).
    case serialSpeedChanged(Int)
    /// A virtual drive block was read or written.
    case virtualDriveActivity(drive: Int, block: Int, write: Bool)
    /// The connection could not be opened or was lost.
    case connectionFailed(String)
}

public struct TransferResult: Sendable, Equatable {
    public enum Direction: String, Sendable { case toApple, fromApple }
    public var direction: Direction
    public var fileName: String
    public var succeeded: Bool
    public var hadErrors: Bool
    public var seconds: Int
}

public typealias ServerEventHandler = @Sendable (ServerEvent) -> Void

/// Diagnostic logging. "Important" lines are always emitted; trace lines only
/// when tracing is turned on (the equivalent of the old ADTProTrace.txt).
public final class Log: @unchecked Sendable {
    public typealias Sink = @Sendable (_ line: String) -> Void

    private let lock = NSLock()
    private var sinks: [Sink] = []
    private var _traceEnabled = false
    private var traceFile: FileHandle?

    public static let shared = Log()

    public init() {}

    public var traceEnabled: Bool {
        get { lock.withLock { _traceEnabled } }
        set { lock.withLock { _traceEnabled = newValue } }
    }

    public func addSink(_ sink: @escaping Sink) {
        lock.withLock { sinks.append(sink) }
    }

    public func removeAllSinks() {
        lock.withLock { sinks.removeAll() }
    }

    /// Mirror trace output to a file (nil stops).
    public func setTraceFile(_ path: String?) {
        lock.withLock {
            try? traceFile?.close()
            traceFile = nil
            if let path {
                if !FileManager.default.fileExists(atPath: path) {
                    _ = FileManager.default.createFile(atPath: path, contents: nil)
                }
                traceFile = FileHandle(forWritingAtPath: path)
                _ = try? traceFile?.seekToEnd()
            }
        }
    }

    public func info(_ message: @autoclosure () -> String) { emit(message(), important: true) }

    public func trace(_ message: @autoclosure () -> String) {
        guard traceEnabled else { return }
        emit(message(), important: false)
    }

    private func emit(_ message: String, important: Bool) {
        let (targets, file, tracing) = lock.withLock { (sinks, traceFile, _traceEnabled) }
        let stamped = Self.timestamp() + " " + message
        if important || tracing {
            for sink in targets { sink(stamped) }
        }
        if tracing, let file {
            file.write(Data((stamped + "\n").utf8))
        }
    }

    private static func timestamp() -> String {
        let now = Date()
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: now)
        return String(format: "%02d:%02d:%02d.%03d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0, (c.nanosecond ?? 0) / 1_000_000)
    }
}

extension UInt8 {
    var hex: String { String(format: "%02X", self) }
}
