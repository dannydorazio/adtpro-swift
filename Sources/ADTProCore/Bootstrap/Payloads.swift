import Foundation

/// Access to the bundled 6502 binaries used for bootstrapping.
public enum Payloads {
    public enum Error: Swift.Error, CustomStringConvertible {
        case missing(String)
        public var description: String {
            switch self {
            case .missing(let name): return "Bootstrap payload \(name) is missing from this build"
            }
        }
    }

    /// Optional override directory, checked before the bundled resources.
    nonisolated(unsafe) public static var searchDirectory: String?

    public static func data(named name: String) throws -> [UInt8] {
        if let dir = searchDirectory, let d = FileManager.default.contents(atPath: dir + "/" + name) {
            return [UInt8](d)
        }
        if let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Payloads"),
           let d = try? Data(contentsOf: url) {
            return [UInt8](d)
        }
        throw Error.missing(name)
    }
}

/// Render a binary as Apple II monitor commands that type it into memory.
///
/// This reproduces the old AppleDump build task, so bootstrap text is generated
/// on the fly from the binaries rather than kept as separate resources. Lines
/// are kept short enough for the monitor's input buffer, and every fifth line
/// ends with "N 25:0" to keep the cursor near the top of the screen.
public enum AppleDump {
    public enum Decoration { case none, begin, end, both }

    public static func render(_ binary: [UInt8], startAddress: Int, decoration: Decoration, finalLine: String? = nil) -> String {
        var s = "\r\n"
        s += (decoration == .begin || decoration == .both) ? "CALL -151\r\n" : "\r\n"
        s += "25:0 N 7D0:1 4 14 10 12 F A0 N 25:0\r\n"

        let bytesPerLine = 114, bytesPerLineShort = 107, linesPerScreen = 5
        var used = 0, line = 1
        var address = startAddress
        for byte in binary {
            let width = byte < 16 ? 2 : 3
            if used + width > bytesPerLineShort && line == linesPerScreen {
                s += " N 25:0\r\n"
                used = 0
                line = 1
            }
            if used + width > bytesPerLine && line < linesPerScreen {
                s += "\r\n"
                used = 0
                line += 1
            }
            if used == 0 { s += String(address, radix: 16, uppercase: true) + ":" }
            address += 1
            if used > 0 { s += " " }
            used += width
            s += String(byte, radix: 16, uppercase: true)
        }
        if decoration == .end || decoration == .both {
            s += "\r\n" + String(startAddress, radix: 16, uppercase: true) + "G\r\n"
        }
        if let finalLine {
            s += "\r\n\r\n" + finalLine + "\r\n"
        }
        return s
    }
}
