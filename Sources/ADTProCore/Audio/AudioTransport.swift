import Foundation

/// Platform audio input/output used by the audio transport.
public protocol AudioIO: AnyObject, Sendable {
    /// Start delivering captured audio as 8-bit signed mono samples at 44.1 kHz.
    func startCapture(_ handler: @escaping @Sendable ([Int8]) -> Void) throws
    func stopCapture()
    /// Play mono samples at 44.1 kHz, returning when playback finishes.
    func play(_ samples: [Float], progress: (@Sendable (Double) -> Void)?, isCancelled: (@Sendable () -> Bool)?)
}

/// The cassette port as a transport: requests are decoded from the capture
/// input, replies are played out as audio.
public final class AudioTransport: Transport, AudioBootstrapping, @unchecked Sendable {
    public let kind = TransportKind.audio
    public let io: AudioIO
    public static let maxPacket = 4000

    private let lock = NSLock()
    private let queue = ByteQueue()
    private var decoder = AudioModem.Decoder()
    private var writeBuffer: [UInt8] = []
    private let log = Log.shared

    public init(io: AudioIO) {
        self.io = io
    }

    public var summary: String { "audio" }
    public var supportsBootstrap: Bool { true }

    private var capturing = false

    public func open() throws {
        guard !lock.withLock({ capturing }) else { return }
        queue.reopen()
        lock.withLock { decoder = AudioModem.Decoder() }
        try io.startCapture { [weak self] samples in
            guard let self else { return }
            let bytes = self.lock.withLock { self.decoder.feed(samples) }
            if !bytes.isEmpty { self.queue.append(bytes) }
        }
        lock.withLock { capturing = true }
    }

    public func close() {
        io.stopCapture()
        queue.close()
        lock.withLock { capturing = false }
    }

    public func readByte(timeout: Double) throws -> UInt8 {
        try queue.read(timeout: timeout)
    }

    public func write(_ bytes: [UInt8]) {
        lock.withLock {
            guard writeBuffer.count + bytes.count <= Self.maxPacket else {
                log.info("Audio packet overflow: dropping \(bytes.count) bytes")
                return
            }
            writeBuffer.append(contentsOf: bytes)
        }
    }

    public func flush() {
        let pending = lock.withLock { () -> [UInt8] in
            defer { writeBuffer.removeAll(keepingCapacity: true) }
            return writeBuffer
        }
        guard !pending.isEmpty else { return }
        io.play(AudioModem.encode(pending, leaderCycles: 300), progress: nil, isCancelled: nil)
        // Whatever was heard while we were talking is our own echo.
        queue.removeAll()
    }

    public func discardInput() { queue.removeAll() }

    public func discardOutput() {
        lock.withLock { writeBuffer.removeAll(keepingCapacity: true) }
    }

    public func pauseAfterBadPacket() {
        // Let the client finish whatever it is sending before asking again.
        Thread.sleep(forTimeInterval: 7)
    }

    public func playBootstrap(_ bytes: [UInt8], progress: @escaping @Sendable (Double) -> Void, isCancelled: @escaping @Sendable () -> Bool) {
        io.play(AudioModem.encode(bytes, leaderCycles: 7000), progress: progress, isCancelled: isCancelled)
    }

    /// The platform's default audio implementation.
    public static func makeDefaultIO(inputDevice: String? = nil, outputDevice: String? = nil) -> AudioIO {
        #if os(macOS)
        return CoreAudioIO(inputDevice: inputDevice.flatMap(UInt32.init), outputDevice: outputDevice.flatMap(UInt32.init))
        #else
        return ALSAProcessIO(inputDevice: inputDevice, outputDevice: outputDevice)
        #endif
    }
}

/// Linux audio through the ALSA command line tools (`arecord`/`aplay`), which
/// also work on PulseAudio and PipeWire systems.
public final class ALSAProcessIO: AudioIO, @unchecked Sendable {
    let inputDevice: String?
    let outputDevice: String?
    private let lock = NSLock()
    private var recorder: Process?

    public init(inputDevice: String? = nil, outputDevice: String? = nil) {
        self.inputDevice = inputDevice
        self.outputDevice = outputDevice
    }

    private static func tool(_ name: String) -> String {
        for dir in ["/usr/bin", "/bin", "/usr/local/bin"] where FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)") {
            return "\(dir)/\(name)"
        }
        return "/usr/bin/\(name)"
    }

    public func startCapture(_ handler: @escaping @Sendable ([Int8]) -> Void) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.tool("arecord"))
        var args = ["-q", "-t", "raw", "-f", "S8", "-r", "\(AudioModem.sampleRate)", "-c", "1"]
        if let inputDevice { args += ["-D", inputDevice] }
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw TransportError.openFailed("arecord: \(error)") }
        lock.withLock { recorder = p }
        let handle = pipe.fileHandleForReading
        let thread = Thread {
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                handler(data.map { Int8(bitPattern: $0) })
            }
        }
        thread.name = "ADTPro audio capture"
        thread.start()
    }

    public func stopCapture() {
        lock.withLock {
            recorder?.terminate()
            recorder = nil
        }
    }

    public func play(_ samples: [Float], progress: (@Sendable (Double) -> Void)?, isCancelled: (@Sendable () -> Bool)?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.tool("aplay"))
        var args = ["-q", "-t", "raw", "-f", "S8", "-r", "\(AudioModem.sampleRate)", "-c", "1"]
        if let outputDevice { args += ["-D", outputDevice] }
        p.arguments = args
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            Log.shared.info("aplay failed: \(error)")
            return
        }
        let bytes = samples.map { UInt8(bitPattern: Int8(clamping: Int(($0 * 127).rounded()))) }
        let chunk = AudioModem.sampleRate / 10
        var offset = 0
        while offset < bytes.count {
            if isCancelled?() == true { p.terminate(); break }
            let end = min(bytes.count, offset + chunk)
            pipe.fileHandleForWriting.write(Data(bytes[offset..<end]))
            offset = end
            progress?(Double(offset) / Double(bytes.count))
        }
        try? pipe.fileHandleForWriting.close()
        p.waitUntilExit()
    }
}
