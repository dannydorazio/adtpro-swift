#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// A serial line carried over TCP, for emulators with a virtualised Super
/// Serial Card.
///
/// Emulators disagree about who listens: AppleWin and GSport/KEGS listen and
/// expect the host to connect (`.connect`, the original ADTPro behaviour);
/// Virtual ][ connects out to a listening program (`.listen`). Either way the
/// link is re-established automatically if the emulator restarts.
public final class SerialIPTransport: Transport, @unchecked Sendable {
    public enum Role: String, Sendable, Codable, CaseIterable {
        /// The emulator listens; the host connects (AppleWin, GSport, KEGS).
        case connect
        /// The host listens; the emulator connects (Virtual ][).
        case listen
    }

    public let kind = TransportKind.serialIP
    public let host: String
    public let port: Int
    public let role: Role

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var listenFD: Int32 = -1
    private var closed = false
    private var lastAttempt = Date.distantPast
    private var readBuffer = ReadBuffer()
    private var writeBuffer: [UInt8] = []
    private let log = Log.shared

    public init(host: String = "localhost", port: Int = 1977, role: Role = .connect) {
        self.host = host
        self.port = port
        self.role = role
    }

    public var summary: String {
        switch role {
        case .connect: return "\(host):\(port) (serial over IP)"
        case .listen: return "TCP port \(port) (serial over IP, waiting for the emulator)"
        }
    }

    public var supportsBootstrap: Bool { true }

    public var isConnected: Bool { lock.withLock { fd >= 0 } }

    public func open() throws {
        try lock.withLock {
            closed = false
            if role == .listen && listenFD < 0 {
                listenFD = try Self.makeListener(port: port)
                log.info("Listening for the emulator on TCP port \(port)")
            }
            _ = establishLocked(wait: 0)
        }
    }

    public func close() {
        lock.withLock {
            closed = true
            disconnectLocked()
            if listenFD >= 0 {
                Self.closeSocket(listenFD)
                listenFD = -1
            }
        }
    }

    static func closeSocket(_ s: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(s)
        #else
        _ = Glibc.close(s)
        #endif
    }

    private func disconnectLocked() {
        if fd >= 0 {
            Self.closeSocket(fd)
            fd = -1
            log.info("Emulator disconnected")
        }
        readBuffer.clear()
    }

    private static func configure(_ s: Int32) {
        var one: Int32 = 1
        setsockopt(s, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// Listen on both IPv6 and IPv4: emulators told to use "localhost" often try ::1 first.
    private static func makeListener(port: Int) throws -> Int32 {
        if let s = try makeDualStackListener(port: port) { return s }
        return try makeIPv4Listener(port: port)
    }

    private static func makeDualStackListener(port: Int) throws -> Int32? {
        #if canImport(Darwin)
        let s = socket(AF_INET6, SOCK_STREAM, 0)
        #else
        let s = socket(AF_INET6, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard s >= 0 else { return nil }
        var one: Int32 = 1, zero: Int32 = 0
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &zero, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = in_port_t(UInt16(port).bigEndian)
        addr.sin6_addr = in6addr_any
        #if canImport(Darwin)
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        #endif
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard rc == 0, listen(s, 1) == 0 else {
            let err = errno
            closeSocket(s)
            if err == EADDRINUSE { throw TransportError.portInUse("TCP port \(port)") }
            return nil
        }
        return s
    }

    private static func makeIPv4Listener(port: Int) throws -> Int32 {
        #if canImport(Darwin)
        let s = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let s = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard s >= 0 else { throw TransportError.openFailed(POSIX.errnoDescription) }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0, listen(s, 1) == 0 else {
            let err = errno
            closeSocket(s)
            if err == EADDRINUSE { throw TransportError.portInUse("TCP port \(port)") }
            throw TransportError.openFailed(String(cString: strerror(err)))
        }
        return s
    }

    /// Make sure there is a connection, waiting up to `wait` seconds for an
    /// incoming one in listen mode. Connect mode retries at most once a second.
    private func establishLocked(wait: Double) -> Bool {
        if fd >= 0 { return true }
        switch role {
        case .listen:
            guard listenFD >= 0, POSIX.waitReadable(listenFD, timeout: wait) else { return false }
            let s = accept(listenFD, nil, nil)
            guard s >= 0 else { return false }
            Self.configure(s)
            fd = s
            log.info("Emulator connected on TCP port \(port)")
            return true
        case .connect:
            guard Date().timeIntervalSince(lastAttempt) >= 1 else { return false }
            lastAttempt = Date()
            if let s = Self.connect(host: host, port: port) {
                fd = s
                log.info("Connected to \(host):\(port)")
                return true
            }
            return false
        }
    }

    private static func connect(host: String, port: Int) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }

        var info: UnsafeMutablePointer<addrinfo>? = first
        while let ai = info {
            let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if s >= 0 {
                POSIX.setNonBlocking(s, true)
                #if canImport(Darwin)
                var ok = Darwin.connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0
                #else
                var ok = Glibc.connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0
                #endif
                if !ok && errno == EINPROGRESS && POSIX.waitWritable(s, timeout: 2) {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
                    ok = err == 0
                }
                if ok {
                    POSIX.setNonBlocking(s, false)
                    configure(s)
                    return s
                }
                closeSocket(s)
            }
            info = ai.pointee.ai_next
        }
        return nil
    }

    public func readByte(timeout: Double) throws -> UInt8 {
        lock.lock()
        if closed { lock.unlock(); throw TransportError.closed }
        if let b = readBuffer.next() { lock.unlock(); return b }
        let connected = establishLocked(wait: role == .listen ? min(timeout, 0.5) : 0)
        let socket = fd
        lock.unlock()

        guard connected else {
            if role == .connect { Thread.sleep(forTimeInterval: min(timeout, 0.5)) }
            throw TransportError.timeout
        }
        guard POSIX.waitReadable(socket, timeout: timeout) else { throw TransportError.timeout }

        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = chunk.withUnsafeMutableBytes { recv(socket, $0.baseAddress, 4096, 0) }
        lock.lock()
        defer { lock.unlock() }
        if closed { throw TransportError.closed }
        if n <= 0 {
            if fd == socket { disconnectLocked() }
            throw TransportError.timeout
        }
        readBuffer.replace(with: Array(chunk[0..<n]))
        return readBuffer.next()!
    }

    public func write(_ bytes: [UInt8]) {
        lock.withLock { writeBuffer.append(contentsOf: bytes) }
    }

    public func flush() {
        lock.lock()
        let pending = writeBuffer
        writeBuffer.removeAll(keepingCapacity: true)
        let connected = establishLocked(wait: 0)
        let socket = fd
        lock.unlock()
        guard !pending.isEmpty else { return }
        guard connected else {
            log.trace("Not connected; dropped \(pending.count) bytes")
            return
        }
        if !POSIX.writeAll(socket, pending, useSend: true) {
            lock.withLock { if fd == socket { disconnectLocked() } }
        }
    }

    public func discardInput() {
        lock.withLock { readBuffer.clear() }
    }

    public func discardOutput() {
        lock.withLock { writeBuffer.removeAll(keepingCapacity: true) }
    }
}
