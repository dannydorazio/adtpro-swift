#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// Ethernet (Uthernet and friends) over UDP. The host listens on a port
/// (6502 by default) and replies to whichever client last sent a datagram.
///
/// Every outgoing datagram starts with a sequence byte the client skips, and a
/// flush sends exactly one datagram.
public final class UDPTransport: Transport, @unchecked Sendable {
    public let kind = TransportKind.ethernet
    public let port: Int
    public static let maxDatagram = 1500

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var peer = sockaddr_storage()
    private var peerLength: socklen_t = 0
    private var readBuffer = ReadBuffer()
    private var writeBuffer: [UInt8] = []
    private var sequence: UInt8 = 1
    private let log = Log.shared

    public init(port: Int = 6502) {
        self.port = port
    }

    public var summary: String { "UDP port \(port)" }
    public var supportsBootstrap: Bool { false }

    /// Local IPv4 addresses, for showing the user what to configure on the Apple.
    public static func localAddresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            if let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) || Int32(addr.pointee.sa_family) == AF_INET {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let s = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if s != "127.0.0.1" { result.append(s) }
                }
            }
            cursor = ifa.pointee.ifa_next
        }
        return result
    }

    public func open() throws {
        try lock.withLock {
            if fd >= 0 { return }
            #if canImport(Darwin)
            let s = socket(AF_INET, SOCK_DGRAM, 0)
            #else
            let s = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
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
            if rc != 0 {
                let err = errno
                _ = Foundation.close(s)
                if err == EADDRINUSE { throw TransportError.portInUse("UDP port \(port)") }
                throw TransportError.openFailed(String(cString: strerror(err)))
            }
            fd = s
        }
    }

    public func close() {
        lock.withLock {
            if fd >= 0 {
                _ = Foundation.close(fd)
                fd = -1
            }
        }
    }

    public func readByte(timeout: Double) throws -> UInt8 {
        lock.lock()
        if let b = readBuffer.next() { lock.unlock(); return b }
        let s = fd
        lock.unlock()
        guard s >= 0 else { throw TransportError.closed }
        guard POSIX.waitReadable(s, timeout: timeout) else { throw TransportError.timeout }

        var datagram = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_storage()
        var fromLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = datagram.withUnsafeMutableBytes { buf in
            withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(s, buf.baseAddress, buf.count, 0, $0, &fromLength)
                }
            }
        }
        guard n > 0 else { throw TransportError.timeout }
        lock.lock()
        defer { lock.unlock() }
        peer = from
        peerLength = fromLength
        readBuffer.replace(with: Array(datagram[0..<n]))
        return readBuffer.next()!
    }

    public func write(_ bytes: [UInt8]) {
        lock.withLock {
            if writeBuffer.isEmpty {
                sequence &+= 1
                writeBuffer.append(sequence)
            }
            if writeBuffer.count + bytes.count > Self.maxDatagram {
                log.info("UDP datagram overflow: dropping \(bytes.count) bytes")
                return
            }
            writeBuffer.append(contentsOf: bytes)
        }
    }

    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard !writeBuffer.isEmpty, fd >= 0, peerLength > 0 else {
            writeBuffer.removeAll(keepingCapacity: true)
            return
        }
        let sent = writeBuffer.withUnsafeBytes { buf in
            withUnsafePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, peerLength)
                }
            }
        }
        if sent < 0 { log.info("UDP send failed: \(POSIX.errnoDescription)") }
        writeBuffer.removeAll(keepingCapacity: true)
    }

    public func discardInput() {
        lock.withLock { readBuffer.clear() }
    }

    public func discardOutput() {
        lock.withLock { writeBuffer.removeAll(keepingCapacity: true) }
    }
}
