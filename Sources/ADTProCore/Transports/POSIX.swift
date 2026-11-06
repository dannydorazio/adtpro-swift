#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// Small wrappers over POSIX calls shared by the socket and serial transports.
enum POSIX {
    static var errnoDescription: String { String(cString: strerror(errno)) }

    /// Wait until `fd` is readable. Returns false on timeout.
    static func waitReadable(_ fd: Int32, timeout: Double) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ms = Int32(max(0, min(Double(Int32.max), timeout * 1000)))
        while true {
            let rc = poll(&pfd, 1, ms)
            if rc < 0 && errno == EINTR { continue }
            return rc > 0
        }
    }

    static func waitWritable(_ fd: Int32, timeout: Double) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ms = Int32(max(0, timeout * 1000))
        while true {
            let rc = poll(&pfd, 1, ms)
            if rc < 0 && errno == EINTR { continue }
            return rc > 0
        }
    }

    /// Write all bytes, retrying on partial writes. Returns false on error.
    static func writeAll(_ fd: Int32, _ bytes: [UInt8], useSend: Bool = false) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                let p = raw.baseAddress!.advanced(by: offset)
                if useSend {
                    #if canImport(Darwin)
                    return send(fd, p, bytes.count - offset, 0)
                    #else
                    return send(fd, p, bytes.count - offset, Int32(MSG_NOSIGNAL))
                    #endif
                }
                return write(fd, p, bytes.count - offset)
            }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN {
                    _ = waitWritable(fd, timeout: 1)
                    continue
                }
                return false
            }
            offset += n
        }
        return true
    }

    static func setNonBlocking(_ fd: Int32, _ on: Bool) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, on ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK))
    }
}

/// A buffered reader over a file descriptor, so single-byte reads do not each
/// cost a system call.
struct ReadBuffer {
    var bytes: [UInt8] = []
    var position = 0

    var isEmpty: Bool { position >= bytes.count }

    mutating func next() -> UInt8? {
        guard position < bytes.count else { return nil }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func replace(with new: [UInt8]) {
        bytes = new
        position = 0
    }

    mutating func clear() {
        bytes.removeAll(keepingCapacity: true)
        position = 0
    }
}
