import DiskImage
import Foundation
import Synchronization

public struct ServerOptions: Sendable, Equatable {
    /// Serial speed for typing bootstrap text into the monitor.
    public var bootstrapSpeed: Int = 9600
    /// Pause between bootstrap text lines, in milliseconds.
    public var bootstrapPacing: Int = 250

    public init(bootstrapSpeed: Int = 9600, bootstrapPacing: Int = 250) {
        self.bootstrapSpeed = bootstrapSpeed
        self.bootstrapPacing = bootstrapPacing
    }
}

/// User-facing status strings.
enum Messages {
    static let directory = "Request: directory contents"
    static let changeDirectory = "Request: change directory"
    static let imageToApple = "Request: image from host to Apple"
    static let imageFromApple = "Request: image from Apple to host"
    static let bootstrap = "Request: send bootstrap data"
    static let halfTrackFromApple = "Request: half tracks from Apple to host"
    static let adtToApple = "Request: ADT from host to Apple"
    static let adtFromApple = "Request: ADT from Apple to host"
    static let nibbleFromApple = "Request: nibbles from Apple to host"
    static let querySize = "Request: query file size"
    static let ping = "Ping received from client."
    static let virtualDrive = "Virtual drive command received."
    static let aborted = "Image transfer aborted."
    static func sent(_ name: String, _ seconds: Int, errors: Bool) -> String {
        errors ? "Image \(name) sent with errors in \(seconds) seconds." : "Image \(name) sent in \(seconds) seconds."
    }
    static func received(_ name: String, _ seconds: Int, errors: Bool) -> String {
        errors ? "Image \(name) received with errors in \(seconds) seconds." : "Image \(name) received in \(seconds) seconds."
    }
    static func fileSent(_ seconds: Int) -> String { "File sent in \(seconds) seconds." }
    static func readBlock(_ n: Int) -> String { "Read block \(n)" }
    static func writeBlock(_ n: Int) -> String { "Write block \(n)" }
}

/// Thrown internally to unwind a request.
enum LinkError: Error {
    /// The client stopped responding.
    case timeout
    /// The server is shutting down.
    case stopped
}

/// The client asked to go back to its home state mid-transfer.
struct GoHome: Error {}

/// The ADTPro host: serves directory listings, disk images, nibble copies,
/// bootstrap files and virtual drives to Apple II and Apple /// clients over
/// one transport.
///
/// `run()` blocks, servicing requests until `stop()` is called; use `start()`
/// to run it on a background thread. Everything that touches the protocol
/// happens on that thread, except user-initiated bootstraps, which send from
/// their own thread while the command loop keeps listening.
public final class ADTProServer: @unchecked Sendable {
    public let transport: Transport
    public let fileHost: FileHost
    public let virtualDrives: VirtualDrives
    let onEvent: ServerEventHandler
    let log = Log.shared

    private let optionsLock = NSLock()
    private var _options: ServerOptions
    public var options: ServerOptions {
        get { optionsLock.withLock { _options } }
        set { optionsLock.withLock { _options = newValue } }
    }

    private let runningFlag = Atomic<Bool>(false)
    private let busyFlag = Atomic<Bool>(false)
    private let bootstrapActive = Atomic<Bool>(false)
    private let bootstrapCancel = Atomic<Bool>(false)

    let maxRetries = 3

    // State owned by the command thread.
    var lastListing: [String] = []
    var lastBatchName = ""
    var lastBatchNumber = 1
    var lastNibbleName = ""
    var lastNibbleNumber = 1
    var audioSignals = 0
    var progressTotal = 0

    public init(transport: Transport, fileHost: FileHost, virtualDrives: VirtualDrives? = nil,
                options: ServerOptions = ServerOptions(), onEvent: @escaping ServerEventHandler = { _ in }) {
        self.transport = transport
        self.fileHost = fileHost
        self.virtualDrives = virtualDrives ?? VirtualDrives(fileHost: fileHost)
        self._options = options
        self.onEvent = onEvent
    }

    public var isRunning: Bool { runningFlag.load(ordering: .relaxed) }

    /// True while a request or bootstrap is in progress.
    public var isBusy: Bool { busyFlag.load(ordering: .relaxed) || bootstrapActive.load(ordering: .relaxed) }

    var running: Bool { runningFlag.load(ordering: .relaxed) }

    var bootstrapActiveFlag: Bool { bootstrapActive.load(ordering: .relaxed) }
    func setBootstrapActive(_ active: Bool) { bootstrapActive.store(active, ordering: .relaxed) }
    var bootstrapCancelled: Bool { bootstrapCancel.load(ordering: .relaxed) }
    func setBootstrapCancelled() { bootstrapCancel.store(true, ordering: .relaxed) }
    func resetBootstrapCancel() { bootstrapCancel.store(false, ordering: .relaxed) }

    // MARK: Lifecycle

    /// Open the transport and service requests until `stop()`.
    public func run() {
        do {
            try transport.open()
        } catch {
            log.info("Unable to open \(transport.summary): \(error)")
            emit(.connectionFailed("\(error)"))
            return
        }
        runningFlag.store(true, ordering: .relaxed)
        log.info("Serving \(transport.summary); working directory \(fileHost.workingDirectory)")
        commandLoop()
        transport.close()
        log.trace("Server stopped.")
    }

    /// Run the server on a new background thread.
    @discardableResult
    public func start() -> Thread {
        let thread = Thread { [self] in run() }
        thread.name = "ADTPro server"
        thread.stackSize = 1 << 20
        thread.start()
        return thread
    }

    public func stop() {
        runningFlag.store(false, ordering: .relaxed)
        bootstrapCancel.store(true, ordering: .relaxed)
        transport.close()
    }

    func emit(_ event: ServerEvent) { onEvent(event) }
    func status(_ text: String) { emit(.status(text)) }
    func detail(_ text: String) { emit(.detail(text)) }

    func setProgressTotal(_ total: Int) {
        progressTotal = total
        emit(.progress(done: 0, total: total))
    }

    func setProgress(_ done: Int) { emit(.progress(done: done, total: progressTotal)) }

    func clearProgress() {
        progressTotal = 0
        emit(.progress(done: 0, total: 0))
    }

    // MARK: Reading from the link

    /// Wait for one byte. Transport hiccups other than timeouts are retried, as the
    /// Java host did, until the server is stopped.
    func waitForData(_ timeout: Double) throws -> UInt8 {
        while running {
            do {
                return try transport.readByte(timeout: timeout)
            } catch TransportError.timeout {
                throw LinkError.timeout
            } catch {
                if !running { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        throw LinkError.stopped
    }

    /// Audio links pick up junk before a packet; skip up to six bytes that are
    /// not what we expect. Other transports take the first byte as-is.
    func waitForData(_ timeout: Double, expecting expected: Set<UInt8>) throws -> UInt8 {
        var byte = try waitForData(timeout)
        if transport.kind == .audio {
            var skipped = 0
            while !expected.contains(byte) && skipped < 6 {
                byte = try waitForData(timeout)
                skipped += 1
            }
        }
        return byte
    }

    func sleep(milliseconds: Int) {
        Thread.sleep(forTimeInterval: Double(milliseconds) / 1000)
    }

    /// Backoff before a retry; audio needs much longer.
    func backoff(retry: Int, base: Int, cap: Int? = nil) {
        let unit = transport.kind == .audio ? 2000 : base
        var ms = retry * unit
        if let cap { ms = min(cap, ms) }
        sleep(milliseconds: ms)
    }

    // MARK: Command loop

    func commandLoop() {
        while running {
            busyFlag.store(false, ordering: .relaxed)
            let command: UInt8
            do {
                command = try transport.readByte(timeout: 1)
            } catch TransportError.timeout {
                continue
            } catch {
                if !running { break }
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            guard running else { break }
            busyFlag.store(true, ordering: .relaxed)
            log.trace("Command byte \(command.hex)")
            clearProgress()
            do {
                try dispatch(command)
            } catch LinkError.stopped {
                break
            } catch LinkError.timeout {
                log.trace("Request timed out.")
                detail(Messages.aborted)
            } catch {
                log.info("Request failed: \(error)")
            }
        }
        busyFlag.store(false, ordering: .relaxed)
    }

    func dispatch(_ command: UInt8) throws {
        switch command {
        case CommandByte.envelope:
            log.trace("Wide protocol request")
            if let envelope = try pullEnvelopeWide(needWrapper: false) {
                try dispatchWide(envelope)
            }
        case CommandByte.cd:
            status(Messages.changeDirectory); detail("")
            try changeDirectory()
            detail(fileHost.workingDirectory)
        case CommandByte.dir:
            status(Messages.directory); detail(fileHost.workingDirectory)
            try sendDirectory()
            detail(fileHost.workingDirectory)
        case CommandByte.virtualDrive:
            status(Messages.virtualDrive); detail("")
            try virtualDriveCommand()
        case CommandByte.put:
            status(Messages.imageFromApple); detail("")
            try receiveDisk(generateName: false)
        case CommandByte.get:
            status(Messages.imageToApple); detail("")
            try sendDisk()
        case CommandByte.batch:
            status(Messages.imageFromApple); detail("")
            try receiveDisk(generateName: true)
        case CommandByte.multiNibble:
            status(Messages.nibbleFromApple); detail("")
            try receiveNibbleDisk(generateName: true, tracks: 35)
        case CommandByte.ping:
            status(Messages.ping); detail("")
            transport.flush()
            transport.discardInput()
        case CommandByte.size:
            status(Messages.querySize); detail("")
            try queryFileSize()
        case CommandByte.adtReceive:
            status(Messages.adtToApple); detail("")
            try send140kDisk()
        case CommandByte.data:
            status(Messages.adtFromApple); detail("")
            try receive140kDisk()
        case CommandByte.nibble:
            status(Messages.nibbleFromApple); detail("")
            try receiveNibbleDisk(generateName: false, tracks: 35)
        case CommandByte.halfTrack:
            status(Messages.halfTrackFromApple); detail("")
            try receiveNibbleDisk(generateName: false, tracks: 70)
        default:
            log.trace("Unknown command \(command.hex)")
        }
    }

    func dispatchWide(_ envelope: WideEnvelope) throws {
        switch envelope.command {
        case CommandByte.batch:
            status(Messages.imageFromApple); detail("")
            try receiveDiskWide(generateName: true, envelope: envelope)
        case CommandByte.cd:
            status(Messages.changeDirectory); detail("")
            try changeDirectoryWide(envelope)
            detail(fileHost.workingDirectory)
        case CommandByte.dir:
            status(Messages.directory); detail(fileHost.workingDirectory)
            try sendDirectoryWide(envelope)
            detail(fileHost.workingDirectory)
        case CommandByte.put:
            status(Messages.imageFromApple); detail("")
            try receiveDiskWide(generateName: false, envelope: envelope)
        case CommandByte.multiNibble:
            status(Messages.nibbleFromApple); detail("")
            try receiveNibbleDiskWide(generateName: true, envelope: envelope)
        case CommandByte.nibble:
            status(Messages.nibbleFromApple); detail("")
            try receiveNibbleDiskWide(generateName: false, envelope: envelope)
        case CommandByte.get:
            status(Messages.imageToApple); detail("")
            try sendDiskWide(envelope)
        case CommandByte.size:
            status(Messages.querySize); detail("")
            try queryFileSizeWide(envelope)
        case CommandByte.sendFile:
            try sendBootstrapFileWide(envelope)
        case CommandByte.home:
            log.trace("Client sent Home.")
            if transport.kind == .audio {
                audioSignals += 1
                detail("Heard audio signal #\(audioSignals)")
            }
        case CommandByte.ack:
            log.trace("Stray acknowledgement; sending Home.")
            _ = try pullPayloadWide(envelope)
            sendHome()
        default:
            // Includes a late summary ('Y') after a send; consume the payload so it
            // is not mistaken for commands.
            log.trace("Wide command \(envelope.command.hex) ignored")
            _ = try pullPayloadWide(envelope)
        }
    }

    func sendHome() {
        transport.write(Envelope.header(length: 0, command: CommandByte.home))
        transport.flush()
    }
}
