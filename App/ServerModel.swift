import ADTProCore
import AppKit
import Foundation
import Observation

struct LogLine: Identifiable {
    let id: Int
    let text: String
}

struct BootstrapRequest: Identifiable {
    let item: BootstrapItem
    let instructions: String
    var id: String { item.id }
}

/// Bridges the protocol server (running on its own threads) to SwiftUI.
@MainActor
@Observable
final class ServerModel {
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            Log.shared.traceEnabled = settings.traceEnabled
            applyLiveSettings(from: oldValue)
        }
    }

    private(set) var isConnected = false
    private(set) var status = "Not connected."
    private(set) var detail = ""
    private(set) var progressDone = 0
    private(set) var progressTotal = 0
    private(set) var workingDirectory: String
    private(set) var log: [LogLine] = []
    private(set) var lastActivity: [Int: Date] = [:]
    private(set) var connectionSummary = ""
    private(set) var recentTransfers: [TransferResult] = []

    var pendingBootstrap: BootstrapRequest?
    var nextStepMessage: String?
    var errorMessage: String?
    var confirmDisconnect = false

    private var server: ADTProServer?
    private var fileHost: FileHost
    private var drives: VirtualDrives
    private var logCounter = 0

    init() {
        let settings = AppSettings.load()
        self.settings = settings
        try? FileManager.default.createDirectory(atPath: settings.workingDirectory, withIntermediateDirectories: true)
        let host = FileHost(workingDirectory: settings.workingDirectory)
        fileHost = host
        workingDirectory = host.workingDirectory
        drives = VirtualDrives(fileHost: host,
                               drive1: settings.virtualDrive1.isEmpty ? nil : settings.virtualDrive1,
                               drive2: settings.virtualDrive2.isEmpty ? nil : settings.virtualDrive2)
        Log.shared.traceEnabled = settings.traceEnabled
        Log.shared.addSink { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
    }

    var isBusy: Bool { server?.isBusy ?? false }

    var progressFraction: Double? {
        progressTotal > 0 ? min(1, Double(progressDone) / Double(progressTotal)) : nil
    }

    var bootstrapItems: [BootstrapItem] {
        isConnected ? BootstrapItem.available(for: settings.transport) : []
    }

    // MARK: Connection

    func makeTransport() throws -> Transport {
        switch settings.transport {
        case .serial:
            let port = settings.serialPort.isEmpty ? (SerialTransport.availablePorts().first ?? "") : settings.serialPort
            guard !port.isEmpty else {
                throw TransportError.openFailed("No serial port is available. Connect a USB serial adapter or choose a port in Settings.")
            }
            return SerialTransport(path: port, speed: settings.serialSpeed, hardwareHandshake: settings.hardwareHandshake)
        case .ethernet:
            return UDPTransport(port: settings.udpPort)
        case .audio:
            return AudioTransport(io: AudioTransport.makeDefaultIO(
                inputDevice: settings.audioInput.isEmpty ? nil : settings.audioInput,
                outputDevice: settings.audioOutput.isEmpty ? nil : settings.audioOutput))
        case .serialIP:
            return SerialIPTransport(host: settings.serialIPHost, port: settings.serialIPPort, role: settings.serialIPRole)
        }
    }

    func connect() {
        guard server == nil else { return }
        let transport: Transport
        do {
            transport = try makeTransport()
            // Open here so failures can be reported immediately.
            try transport.open()
        } catch {
            errorMessage = "\(error)"
            return
        }
        let server = ADTProServer(
            transport: transport, fileHost: fileHost, virtualDrives: drives,
            options: ServerOptions(bootstrapSpeed: settings.bootstrapSpeed, bootstrapPacing: settings.bootstrapPacing),
            onEvent: { [weak self] event in
                Task { @MainActor in self?.apply(event) }
            })
        self.server = server
        isConnected = true
        connectionSummary = transport.summary
        status = "Ready"
        detail = ""
        server.start()
    }

    func requestDisconnect() {
        if isBusy { confirmDisconnect = true } else { disconnect() }
    }

    func disconnect() {
        server?.stop()
        server = nil
        isConnected = false
        progressTotal = 0
        progressDone = 0
        status = "Not connected."
        detail = ""
        connectionSummary = ""
    }

    func toggleConnection() {
        if isConnected { requestDisconnect() } else { connect() }
    }

    /// Changes that need a reconnect are applied by reconnecting when idle.
    private func applyLiveSettings(from old: AppSettings) {
        server?.options = ServerOptions(bootstrapSpeed: settings.bootstrapSpeed, bootstrapPacing: settings.bootstrapPacing)
        if settings.virtualDrive1 != old.virtualDrive1 {
            drives.setImage(settings.virtualDrive1.isEmpty ? nil : settings.virtualDrive1, forDrive: 1)
        }
        if settings.virtualDrive2 != old.virtualDrive2 {
            drives.setImage(settings.virtualDrive2.isEmpty ? nil : settings.virtualDrive2, forDrive: 2)
        }
        var reconnect = settings.transport != old.transport
        switch settings.transport {
        case .serial:
            reconnect = reconnect || settings.serialPort != old.serialPort || settings.serialSpeed != old.serialSpeed
                || settings.hardwareHandshake != old.hardwareHandshake
        case .ethernet:
            reconnect = reconnect || settings.udpPort != old.udpPort
        case .serialIP:
            reconnect = reconnect || settings.serialIPHost != old.serialIPHost || settings.serialIPPort != old.serialIPPort
                || settings.serialIPRole != old.serialIPRole
        case .audio:
            reconnect = reconnect || settings.audioInput != old.audioInput || settings.audioOutput != old.audioOutput
        }
        if reconnect && isConnected && !isBusy {
            disconnect()
            connect()
        }
    }

    /// As with the original host, a transport can be chosen at launch:
    /// `open ADTPro.app --args -connect serial|ethernet|audio|serialip`.
    /// (A bare argument would be taken as a document to open.)
    func handleLaunchArguments() {
        let kinds: [String: TransportKind] = [
            "serial": .serial, "ethernet": .ethernet, "audio": .audio,
            "serialip": .serialIP, "localhost": .serialIP,
        ]
        guard !isConnected, let requested = UserDefaults.standard.string(forKey: "connect"),
              let kind = kinds[requested.lowercased()] else { return }
        settings.transport = kind
        connect()
    }

    // MARK: Files

    func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: workingDirectory)
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder of disk images the Apple will see."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setWorkingDirectory(url.path)
    }

    func setWorkingDirectory(_ path: String) {
        if fileHost.changeDirectory(path) {
            workingDirectory = fileHost.workingDirectory
            settings.workingDirectory = workingDirectory
        }
    }

    func revealWorkingDirectory() {
        NSWorkspace.shared.open(URL(fileURLWithPath: workingDirectory))
    }

    func virtualDrivePath(_ drive: Int) -> String {
        drives.imagePath(forDrive: drive)
    }

    func chooseVirtualDrive(_ drive: Int) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        panel.message = "Choose a ProDOS disk image to serve as virtual drive \(drive)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if drive == 1 { settings.virtualDrive1 = url.path } else { settings.virtualDrive2 = url.path }
    }

    func resetVirtualDrive(_ drive: Int) {
        if drive == 1 { settings.virtualDrive1 = "" } else { settings.virtualDrive2 = "" }
    }

    // MARK: Bootstrapping

    func prepareBootstrap(_ item: BootstrapItem) {
        do {
            pendingBootstrap = BootstrapRequest(item: item, instructions: try item.instructions(for: settings.transport, bootstrapSpeed: settings.bootstrapSpeed))
        } catch {
            errorMessage = "\(error)"
        }
    }

    func startBootstrap(_ item: BootstrapItem) {
        pendingBootstrap = nil
        do {
            try server?.startBootstrap(item)
        } catch {
            errorMessage = "\(error)"
        }
    }

    func cancelBootstrap() {
        server?.cancelBootstrap()
    }

    // MARK: Events

    private func apply(_ event: ServerEvent) {
        switch event {
        case .status(let s): status = s
        case .detail(let d): detail = d
        case .progress(let done, let total):
            progressDone = done
            progressTotal = total
        case .workingDirectoryChanged(let dir):
            workingDirectory = dir
            settings.workingDirectory = dir
        case .transferFinished(let result):
            status = "Ready"
            recentTransfers.insert(result, at: 0)
            if recentTransfers.count > 20 { recentTransfers.removeLast() }
            progressTotal = 0
        case .bootstrapFinished(let next):
            status = "Ready"
            progressTotal = 0
            if let next { nextStepMessage = next }
        case .serialSpeedChanged(let speed):
            status = "Serial speed is now \(speed) baud"
        case .virtualDriveActivity(let drive, _, _):
            lastActivity[drive] = Date()
        case .connectionFailed(let why):
            errorMessage = why
            disconnect()
        }
    }

    private func appendLog(_ line: String) {
        logCounter += 1
        log.append(LogLine(id: logCounter, text: line))
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    func clearLog() { log.removeAll() }
}
