import ADTProCore
import Foundation

/// Everything the user configures, persisted in UserDefaults as one JSON blob.
struct AppSettings: Codable, Equatable {
    var transport: TransportKind = .serial

    // Serial
    var serialPort: String = ""
    var serialSpeed: Int = 115200
    var hardwareHandshake = false
    var bootstrapSpeed: Int = 9600
    var bootstrapPacing: Int = 250

    // Ethernet
    var udpPort: Int = 6502

    // Serial over IP
    var serialIPHost: String = "localhost"
    var serialIPPort: Int = 1977
    var serialIPRole: SerialIPTransport.Role = .listen

    // Audio (device identifiers as strings; empty = system default)
    var audioInput: String = ""
    var audioOutput: String = ""

    // Files
    var workingDirectory: String = AppSettings.defaultWorkingDirectory
    var virtualDrive1: String = ""
    var virtualDrive2: String = ""

    var traceEnabled = false

    static var defaultWorkingDirectory: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("ADTPro").path
    }

    static let pacingChoices = [15, 25, 50, 75, 100, 150, 250, 500, 1000]
    static let bootstrapSpeedChoices = [300, 1200, 2400, 9600, 19200]
    static let serialSpeedChoices = [9600, 19200, 115200]

    private static let key = "ADTProSettings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

// Tolerate settings saved by older builds that lack newer keys.
extension AppSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        transport = (try? c.decode(TransportKind.self, forKey: .transport)) ?? d.transport
        serialPort = (try? c.decode(String.self, forKey: .serialPort)) ?? d.serialPort
        serialSpeed = (try? c.decode(Int.self, forKey: .serialSpeed)) ?? d.serialSpeed
        hardwareHandshake = (try? c.decode(Bool.self, forKey: .hardwareHandshake)) ?? d.hardwareHandshake
        bootstrapSpeed = (try? c.decode(Int.self, forKey: .bootstrapSpeed)) ?? d.bootstrapSpeed
        bootstrapPacing = (try? c.decode(Int.self, forKey: .bootstrapPacing)) ?? d.bootstrapPacing
        udpPort = (try? c.decode(Int.self, forKey: .udpPort)) ?? d.udpPort
        serialIPHost = (try? c.decode(String.self, forKey: .serialIPHost)) ?? d.serialIPHost
        serialIPPort = (try? c.decode(Int.self, forKey: .serialIPPort)) ?? d.serialIPPort
        serialIPRole = (try? c.decode(SerialIPTransport.Role.self, forKey: .serialIPRole)) ?? d.serialIPRole
        audioInput = (try? c.decode(String.self, forKey: .audioInput)) ?? d.audioInput
        audioOutput = (try? c.decode(String.self, forKey: .audioOutput)) ?? d.audioOutput
        workingDirectory = (try? c.decode(String.self, forKey: .workingDirectory)) ?? d.workingDirectory
        virtualDrive1 = (try? c.decode(String.self, forKey: .virtualDrive1)) ?? d.virtualDrive1
        virtualDrive2 = (try? c.decode(String.self, forKey: .virtualDrive2)) ?? d.virtualDrive2
        traceEnabled = (try? c.decode(Bool.self, forKey: .traceEnabled)) ?? d.traceEnabled
    }
}
