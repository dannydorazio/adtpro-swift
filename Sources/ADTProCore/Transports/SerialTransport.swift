#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// A local serial port (USB serial adapters, built-in ports), via termios.
/// Runs 8N1 with optional RTS/CTS hardware handshaking.
public final class SerialTransport: Transport, @unchecked Sendable {
    public let kind = TransportKind.serial
    public let path: String
    public static let standardSpeeds = [300, 600, 1200, 1800, 2400, 4800, 9600, 19200, 38400, 57600, 115200]

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var speed: Int
    private var activeSpeed: Int
    private var hardwareHandshake: Bool
    private var readBuffer = ReadBuffer()
    private var writeBuffer: [UInt8] = []
    private let log = Log.shared

    public init(path: String, speed: Int = 115200, hardwareHandshake: Bool = false) {
        self.path = path
        self.speed = speed
        self.activeSpeed = speed
        self.hardwareHandshake = hardwareHandshake
    }

    public var summary: String { lock.withLock { "\(path) at \(activeSpeed) baud" } }
    public var supportsBootstrap: Bool { true }
    public var configuredSpeed: Int { lock.withLock { speed } }

    /// Serial devices worth offering to the user.
    public static func availablePorts() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: "/dev") else { return [] }
        #if os(macOS)
        let wanted = names.filter { $0.hasPrefix("cu.") && !$0.contains("Bluetooth") && !$0.contains("debug-console") }
        #else
        let prefixes = ["ttyUSB", "ttyACM", "ttyS", "ttyAMA", "rfcomm"]
        var wanted = names.filter { n in prefixes.contains { n.hasPrefix($0) } }
        // Keep only ttyS ports backed by real hardware (most are phantom).
        wanted = wanted.filter { n in
            !n.hasPrefix("ttyS") || fm.fileExists(atPath: "/sys/class/tty/\(n)/device/driver")
        }
        #endif
        return wanted.sorted().map { "/dev/" + $0 }
    }

    public func open() throws {
        try lock.withLock {
            if fd >= 0 { return }
            let f = Foundation.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard f >= 0 else {
                if errno == EBUSY { throw TransportError.portInUse(path) }
                throw TransportError.openFailed("\(path): \(POSIX.errnoDescription)")
            }
            // Exclusive access, so a second ADTPro (or anything else) cannot share the port.
            if ioctl(f, UInt(TIOCEXCL)) != 0 && errno == EBUSY {
                _ = Foundation.close(f)
                throw TransportError.portInUse(path)
            }
            fd = f
            do {
                try configureLocked(speed: speed)
            } catch {
                _ = Foundation.close(f)
                fd = -1
                throw error
            }
            POSIX.setNonBlocking(fd, false)
            tcflush(fd, TCIOFLUSH)
            log.info("Opened \(path) at \(speed) baud\(hardwareHandshake ? " with hardware handshaking" : "")")
        }
    }

    public func close() {
        lock.withLock {
            if fd >= 0 {
                _ = Foundation.close(fd)
                fd = -1
            }
            readBuffer.clear()
        }
    }

    private static func speedConstant(_ baud: Int) -> speed_t? {
        switch baud {
        case 300: return speed_t(B300)
        case 600: return speed_t(B600)
        case 1200: return speed_t(B1200)
        case 1800: return speed_t(B1800)
        case 2400: return speed_t(B2400)
        case 4800: return speed_t(B4800)
        case 9600: return speed_t(B9600)
        case 19200: return speed_t(B19200)
        case 38400: return speed_t(B38400)
        case 57600: return speed_t(B57600)
        case 115200: return speed_t(B115200)
        case 230400: return speed_t(B230400)
        default: return nil
        }
    }

    private func configureLocked(speed baud: Int) throws {
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { throw TransportError.openFailed(POSIX.errnoDescription) }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CSTOPB | PARENB)
        t.c_cflag = (t.c_cflag & ~tcflag_t(CSIZE)) | tcflag_t(CS8)
        #if canImport(Darwin)
        let rtscts = tcflag_t(CCTS_OFLOW | CRTS_IFLOW)
        #else
        let rtscts = tcflag_t(CRTSCTS)
        #endif
        if hardwareHandshake { t.c_cflag |= rtscts } else { t.c_cflag &= ~rtscts }
        t.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        withUnsafeMutableBytes(of: &t.c_cc) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 0
        }
        if let constant = Self.speedConstant(baud) {
            cfsetispeed(&t, constant)
            cfsetospeed(&t, constant)
            guard tcsetattr(fd, TCSANOW, &t) == 0 else { throw TransportError.openFailed(POSIX.errnoDescription) }
        } else {
            guard tcsetattr(fd, TCSANOW, &t) == 0 else { throw TransportError.openFailed(POSIX.errnoDescription) }
            #if os(macOS)
            // Non-standard rate: IOSSIOSPEED = _IOW('T', 2, speed_t)
            var s = speed_t(baud)
            let IOSSIOSPEED: UInt = 0x8008_5402
            guard ioctl(fd, IOSSIOSPEED, &s) == 0 else { throw TransportError.openFailed("Unsupported speed \(baud)") }
            #else
            throw TransportError.openFailed("Unsupported speed \(baud)")
            #endif
        }
        activeSpeed = baud
    }

    public func setHardwareHandshake(_ on: Bool) {
        lock.withLock {
            hardwareHandshake = on
            if fd >= 0 { try? configureLocked(speed: activeSpeed) }
        }
    }

    public func setSpeed(_ baud: Int) {
        lock.withLock {
            speed = baud
            if fd >= 0 && activeSpeed != baud {
                readBuffer.clear()
                writeBuffer.removeAll()
                try? configureLocked(speed: baud)
            }
        }
    }

    public func setTemporarySpeed(_ baud: Int?) {
        lock.withLock {
            let target = baud ?? speed
            if fd >= 0 && activeSpeed != target {
                tcdrain(fd)
                try? configureLocked(speed: target)
            }
        }
    }

    public func readByte(timeout: Double) throws -> UInt8 {
        lock.lock()
        if let b = readBuffer.next() { lock.unlock(); return b }
        let port = fd
        lock.unlock()
        guard port >= 0 else { throw TransportError.closed }
        guard POSIX.waitReadable(port, timeout: timeout) else { throw TransportError.timeout }
        var chunk = [UInt8](repeating: 0, count: 1024)
        let n = chunk.withUnsafeMutableBytes { Foundation.read(port, $0.baseAddress, 1024) }
        if n < 0 {
            if errno == EAGAIN || errno == EINTR { throw TransportError.timeout }
            throw TransportError.closed
        }
        if n == 0 {
            // A USB adapter that has gone away reads as end-of-file.
            throw TransportError.timeout
        }
        lock.lock()
        defer { lock.unlock() }
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
        let port = fd
        lock.unlock()
        guard !pending.isEmpty, port >= 0 else { return }
        if !POSIX.writeAll(port, pending) {
            log.info("Serial write failed: \(POSIX.errnoDescription)")
        }
        tcdrain(port)
    }

    public func discardInput() {
        lock.withLock {
            readBuffer.clear()
            if fd >= 0 { tcflush(fd, TCIFLUSH) }
        }
    }

    public func discardOutput() {
        // Only what has not been flushed yet: bytes already handed to the driver
        // (such as an ACK just sent) must still go out.
        lock.withLock { writeBuffer.removeAll(keepingCapacity: true) }
    }
}
