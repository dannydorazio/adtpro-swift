import ADTProCore
import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct Serve: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Serve an Apple client over serial, Ethernet, audio or serial-over-IP.",
        discussion: """
        While serving, type a command and press Return:
          b, bootstrap [ITEM]   send a bootstrap (lists items when none given)
          cd DIR                change the working directory
          pwd                   show the working directory
          v1 PATH | v2 PATH     serve PATH as virtual drive 1 or 2 ("default" to reset)
          trace                 toggle protocol tracing
          q, quit               stop serving
        """
    )

    enum Mode: String, ExpressibleByArgument, CaseIterable {
        case serial, ethernet, audio, serialip
    }

    @Argument(help: "Transport: serial, ethernet, audio or serialip (e.g. for the Virtual ][ emulator).")
    var mode: Mode = .serial

    @Option(name: [.short, .long], help: "Serial device, e.g. /dev/cu.usbserial-1410 (defaults to the first one found).")
    var port: String?

    @Option(name: .shortAndLong, help: "Serial speed.")
    var speed: Int = 115200

    @Flag(name: .long, help: "Use RTS/CTS hardware handshaking (e.g. Apple IIc with an ImageWriter cable).")
    var hardwareHandshake = false

    @Option(name: .long, help: "UDP port for Ethernet clients.")
    var udpPort: Int = 6502

    @Option(name: .long, help: "Host to connect to for serial over IP.")
    var host: String = "localhost"

    @Option(name: .long, help: "TCP port for serial over IP.")
    var tcpPort: Int = 1977

    @Flag(name: .long, help: "Serial over IP: listen for the emulator to connect (Virtual ][) instead of connecting to it (AppleWin, GSport).")
    var listen = false

    @Option(name: [.short, .customLong("directory")], help: "Working directory for disk images (default: current directory).")
    var directory: String?

    @Option(name: .long, help: "Image to serve as virtual drive 1 (default: Virtual.po in the working directory).")
    var vdrive1: String?

    @Option(name: .long, help: "Image to serve as virtual drive 2 (default: Virtual2.po in the working directory).")
    var vdrive2: String?

    @Option(name: .long, help: "Serial speed for typing bootstrap text into the Apple's monitor.")
    var bootstrapSpeed: Int = 9600

    @Option(name: .long, help: "Milliseconds to pause between bootstrap text lines.")
    var pacing: Int = 250

    @Option(name: .long, help: "Audio input device (macOS: device number from `adtpro ports`; Linux: ALSA device).")
    var audioInput: String?

    @Option(name: .long, help: "Audio output device.")
    var audioOutput: String?

    @Flag(name: .long, help: "Log protocol traffic.")
    var trace = false

    @Option(name: .long, help: "Also write the trace to this file.")
    var traceFile: String?

    @Flag(name: .shortAndLong, help: "Only print results, not progress.")
    var quiet = false

    func makeTransport() throws -> Transport {
        switch mode {
        case .serial:
            guard let device = port ?? SerialTransport.availablePorts().first else {
                throw ValidationError("No serial port found; pass one with --port (see `adtpro ports`).")
            }
            return SerialTransport(path: device, speed: speed, hardwareHandshake: hardwareHandshake)
        case .ethernet:
            return UDPTransport(port: udpPort)
        case .audio:
            return AudioTransport(io: AudioTransport.makeDefaultIO(inputDevice: audioInput, outputDevice: audioOutput))
        case .serialip:
            return SerialIPTransport(host: host, port: tcpPort, role: listen ? .listen : .connect)
        }
    }

    func run() throws {
        let console = Console(quiet: quiet)
        Log.shared.traceEnabled = trace
        Log.shared.setTraceFile(traceFile)
        Log.shared.addSink { console.log($0) }

        let fileHost = FileHost(workingDirectory: directory ?? FileManager.default.currentDirectoryPath)
        let drives = VirtualDrives(fileHost: fileHost, drive1: vdrive1, drive2: vdrive2)
        let transport = try makeTransport()
        let server = ADTProServer(
            transport: transport, fileHost: fileHost, virtualDrives: drives,
            options: ServerOptions(bootstrapSpeed: bootstrapSpeed, bootstrapPacing: pacing),
            onEvent: { console.handle($0) })

        if mode == .ethernet {
            let addresses = UDPTransport.localAddresses().joined(separator: ", ")
            console.say("Ethernet clients should use server address \(addresses.isEmpty ? "(unknown)" : addresses), port \(udpPort).")
        }
        if mode == .serialip {
            if listen {
                console.say("In Virtual ][, give the Super Serial Card a TCP connection to port \(tcpPort) (host empty), then choose Connect.")
            } else {
                console.say("Connecting to the emulator at \(host):\(tcpPort); ADTPro keeps retrying until it answers.")
            }
        }
        console.say("Serving \(transport.summary) from \(fileHost.workingDirectory)")
        console.say("Type 'help' for commands; Ctrl-C or 'q' to quit.")

        let thread = server.start()
        installSignalHandlers(server)

        let interactive = isatty(STDIN_FILENO) != 0
        while let line = readLine() {
            if handle(command: line, server: server, console: console, drives: drives) == false { break }
        }
        if !interactive {
            // Running unattended (no terminal): keep serving until signalled.
            while !thread.isFinished { Thread.sleep(forTimeInterval: 1) }
        }
        server.stop()
        while !thread.isFinished { Thread.sleep(forTimeInterval: 0.05) }
        console.finish()
    }

    /// Returns false to quit.
    func handle(command line: String, server: ADTProServer, console: Console, drives: VirtualDrives) -> Bool {
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = parts.first?.lowercased() else { return true }
        let argument = parts.count > 1 ? parts[1] : nil
        switch verb {
        case "q", "quit", "exit":
            if server.isBusy {
                console.say("A transfer is in progress; type 'quit!' to interrupt it.")
                return true
            }
            return false
        case "quit!":
            return false
        case "help", "?":
            console.say(Self.configuration.discussion)
        case "pwd":
            console.say(server.fileHost.workingDirectory)
        case "cd":
            if let argument, server.fileHost.changeDirectory(argument) {
                console.say("Working directory: \(server.fileHost.workingDirectory)")
            } else {
                console.say("Not a directory.")
            }
        case "v1", "v2":
            let drive = verb == "v1" ? 1 : 2
            let path = argument.map { $0 == "default" ? nil : (($0 as NSString).expandingTildeInPath) } ?? nil
            drives.setImage(path, forDrive: drive)
            console.say("Virtual drive \(drive): \(drives.imagePath(forDrive: drive))")
        case "trace":
            Log.shared.traceEnabled.toggle()
            console.say("Tracing \(Log.shared.traceEnabled ? "on" : "off").")
        case "b", "bootstrap":
            bootstrap(argument, server: server, console: console)
        default:
            console.say("Unknown command '\(verb)'. Type 'help'.")
        }
        return true
    }

    func bootstrap(_ argument: String?, server: ADTProServer, console: Console) {
        let kind = server.transport.kind
        let items = BootstrapItem.available(for: kind)
        guard !items.isEmpty else {
            console.say("Bootstrapping is not available over \(kind.displayName).")
            return
        }
        guard let argument, let item = items.first(where: { $0.rawValue.lowercased() == argument.lowercased() }) else {
            console.say("Bootstrap items:")
            for item in items { console.say("  \(item.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0)) \(item.title)") }
            return
        }
        do {
            console.say(try item.instructions(for: kind, bootstrapSpeed: server.options.bootstrapSpeed))
            console.say("Press Return to send, or type 'cancel'.")
            if let reply = readLine(), reply.lowercased().hasPrefix("c") {
                console.say("Cancelled.")
                return
            }
            try server.startBootstrap(item)
        } catch {
            console.say("Unable to bootstrap: \(error)")
        }
    }

    func installSignalHandlers(_ server: ADTProServer) {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        for sig in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                server.stop()
                FileHandle.standardOutput.write(Data("\n".utf8))
                Foundation.exit(0)
            }
            source.resume()
            SignalSources.keep(source)
        }
    }
}

enum SignalSources {
    nonisolated(unsafe) static var sources: [DispatchSourceSignal] = []
    static func keep(_ s: DispatchSourceSignal) { sources.append(s) }
}

/// Serialises output from the server thread, the bootstrap thread and the
/// command prompt, drawing progress on one line when attached to a terminal.
final class Console: @unchecked Sendable {
    private let lock = NSLock()
    private let quiet: Bool
    private let isTTY = isatty(STDOUT_FILENO) != 0
    private var progressShown = false
    private var lastPercent = -1
    private var currentDetail = ""

    init(quiet: Bool) { self.quiet = quiet }

    /// Unbuffered output: stdio buffering would need flushing, and flushing all
    /// streams can deadlock against a pending readLine() on stdin.
    private func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private func clearProgressLine() {
        if progressShown {
            write("\r\u{1B}[2K")
            progressShown = false
        }
    }

    func say(_ text: String) {
        lock.withLock {
            clearProgressLine()
            write(text + "\n")
        }
    }

    func log(_ line: String) { say(line) }

    func handle(_ event: ServerEvent) {
        switch event {
        case .status(let s):
            if !quiet { say(s) }
        case .detail(let d):
            lock.withLock { currentDetail = d }
        case .progress(let done, let total):
            guard !quiet, total > 0 else {
                lock.withLock { clearProgressLine(); lastPercent = -1 }
                return
            }
            let percent = min(100, done * 100 / total)
            lock.withLock {
                guard percent != lastPercent else { return }
                lastPercent = percent
                if isTTY {
                    let width = 30
                    let filled = width * percent / 100
                    let bar = String(repeating: "#", count: filled) + String(repeating: ".", count: width - filled)
                    write("\r\u{1B}[2K[\(bar)] \(percent)% \(currentDetail)")
                    progressShown = true
                }
            }
        case .transferFinished(let result):
            say(result.hadErrors ? "Finished with errors: \(result.fileName)" : "Done: \(result.fileName) in \(result.seconds) s")
        case .bootstrapFinished(let next):
            say("Bootstrap sent.")
            if let next { say(next) }
        case .serialSpeedChanged(let speed):
            say("Serial speed is now \(speed).")
        case .workingDirectoryChanged(let dir):
            say("Working directory: \(dir)")
        case .connectionFailed(let why):
            say("Connection failed: \(why)")
        case .virtualDriveActivity:
            break
        }
    }

    func finish() {
        lock.withLock { clearProgressLine() }
    }
}
