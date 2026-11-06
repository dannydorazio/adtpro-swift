import Foundation

/// Bootstraps the user can start from the host ("Bootstrapping" menu).
public enum BootstrapItem: String, CaseIterable, Sendable, Identifiable {
    case speediboot
    case vsdriveSpeediboot
    case prodos
    case adtproSerial
    case adtproAudio
    case adtproEthernet
    case esdos1
    case esdos2
    case adt
    case sos

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .speediboot: return "Speediboot"
        case .vsdriveSpeediboot: return "VSDrive + Speediboot"
        case .prodos: return "Send ProDOS"
        case .adtproSerial: return "Send ADTPro Serial Client"
        case .adtproAudio: return "Send ADTPro Audio Client"
        case .adtproEthernet: return "Send ADTPro Ethernet Client"
        case .esdos1: return "Send EsDOS ][ Part 1"
        case .esdos2: return "Send EsDOS ][ Part 2"
        case .adt: return "Send DOS ADT Client"
        case .sos: return "SOS"
        }
    }

    public enum Group: String, Sendable { case prodos = "ProDOS", dos = "EsDOS ][", sos = "SOS" }

    public var group: Group {
        switch self {
        case .speediboot, .vsdriveSpeediboot, .prodos, .adtproSerial, .adtproAudio, .adtproEthernet: return .prodos
        case .esdos1, .esdos2, .adt: return .dos
        case .sos: return .sos
        }
    }

    /// Items offered for a transport.
    public static func available(for kind: TransportKind) -> [BootstrapItem] {
        switch kind {
        case .serial, .serialIP:
            return [.speediboot, .vsdriveSpeediboot, .prodos, .adtproSerial, .adtproAudio, .adtproEthernet, .esdos1, .adt, .sos]
        case .audio:
            return [.prodos, .adtproSerial, .adtproAudio, .adtproEthernet, .esdos1, .esdos2, .adt]
        case .ethernet:
            return []
        }
    }
}

/// What actually gets sent for a bootstrap request.
public struct BootstrapPlan: Sendable {
    public enum Content: Sendable {
        /// Monitor text, sent line by line with pacing.
        case text(String, slowFirstLines: Int, slowLastLines: Int)
        /// Raw bytes, optionally preceded by a trigger byte and a 16-bit length.
        case binary([UInt8], trigger: UInt8?, sendLength: Bool, settleAfterTrigger: Bool, slowStart: Bool)
        /// Raw bytes encoded as cassette audio with a long leader.
        case audio([UInt8])
    }

    public var name: String
    public var content: Content
    /// Serial speed to use while sending (nil: leave as configured).
    public var serialSpeed: Int?
    /// Speed the serial port should run at afterwards (Speediboot switches to 115200).
    public var speedAfterwards: Int?
    public var nextStep: String?

    public var byteCount: Int {
        switch content {
        case .text(let t, _, _): return t.utf8.count
        case .binary(let b, _, _, _, _), .audio(let b): return b.count
        }
    }
}

/// File numbers the client asks for with an 'F' (send file) request.
public enum BootstrapFileRequest: UInt8, Sendable {
    case prodos = 0xB2            // '2'
    case sosKernel = 0xB3         // '3'
    case sosInterpreter = 0xB4    // '4' serial ADTPro for SOS
    case sosDriver = 0xB5         // '5'
    case adtpro = 0xB6            // '6' serial ADTPro for ProDOS
    case vsdrive = 0xB7           // '7'
    case basic = 0xB8             // '8'

    public func plan() throws -> BootstrapPlan {
        func bin(_ name: String, trigger: UInt8?, settle: Bool = false, slow: Bool = false) throws -> BootstrapPlan {
            BootstrapPlan(
                name: name,
                content: .binary(try Payloads.data(named: name), trigger: trigger, sendLength: trigger != nil,
                                 settleAfterTrigger: settle, slowStart: slow),
                serialSpeed: 115200, speedAfterwards: nil, nextStep: nil)
        }
        switch self {
        case .prodos: return try bin("PDSpeed.raw", trigger: 0x50)                         // 'P'
        case .sosKernel: return try bin("SK.raw", trigger: nil, slow: true)
        case .sosInterpreter: return try bin("adtsos.raw", trigger: 0x53, settle: true, slow: true)  // 'S'
        case .sosDriver: return try bin("SD.raw", trigger: 0x53, settle: true, slow: true)       // 'S'
        case .adtpro: return try bin("adtpro.raw", trigger: 0x41)                          // 'A'
        case .vsdrive: return try bin("vsdrive_speed.raw", trigger: 0x56)                  // 'V'
        case .basic: return try bin("BSpeed.raw", trigger: 0x42)                           // 'B'
        }
    }
}

public extension BootstrapItem {
    /// Build the send plan for this item over the given transport.
    func plan(for kind: TransportKind) throws -> BootstrapPlan {
        if kind == .audio { return try audioPlan() }
        switch self {
        case .speediboot:
            let text = AppleDump.render(try Payloads.data(named: "grub2.bin"), startAddress: 0x7000, decoration: .both)
            return BootstrapPlan(name: "grub2", content: .text(text, slowFirstLines: 4, slowLastLines: 0),
                                 serialSpeed: nil, speedAfterwards: 115200, nextStep: nil)
        case .vsdriveSpeediboot:
            let text = AppleDump.render(try Payloads.data(named: "grub_vsdrive.bin"), startAddress: 0x7000, decoration: .both)
            return BootstrapPlan(name: "grub_vsdrive", content: .text(text, slowFirstLines: 4, slowLastLines: 0),
                                 serialSpeed: nil, speedAfterwards: 115200, nextStep: nil)
        case .prodos:
            let text = AppleDump.render(try Payloads.data(named: "PD.raw"), startAddress: 0x2000, decoration: .begin,
                                        finalLine: "2003G E000G")
            return BootstrapPlan(name: "PD", content: .text(text, slowFirstLines: 4, slowLastLines: 0),
                                 serialSpeed: nil, speedAfterwards: nil,
                                 nextStep: "All done.\n\nNext, send the ADTPro serial client.")
        case .esdos1, .esdos2:
            let text = String(decoding: try Payloads.data(named: "EsDOS.dmp"), as: UTF8.self)
            return BootstrapPlan(name: "EsDOS", content: .text(text, slowFirstLines: 3, slowLastLines: 0),
                                 serialSpeed: nil, speedAfterwards: nil,
                                 nextStep: "All done.\n\nNow, INIT some disks or send the DOS ADT client.")
        case .adt:
            let text = AppleDump.render(try Payloads.data(named: "adt.raw"), startAddress: 0x803, decoration: .both)
            return BootstrapPlan(name: "adt", content: .text(text, slowFirstLines: 5, slowLastLines: 4),
                                 serialSpeed: nil, speedAfterwards: nil, nextStep: nil)
        case .adtproSerial, .adtproAudio, .adtproEthernet:
            let file = clientFileName
            let text = AppleDump.render(try Payloads.data(named: file), startAddress: 0x800, decoration: .begin, finalLine: "800G")
            return BootstrapPlan(name: file, content: .text(text, slowFirstLines: 5, slowLastLines: 4),
                                 serialSpeed: nil, speedAfterwards: nil, nextStep: nil)
        case .sos:
            return BootstrapPlan(
                name: "SOSLoader",
                content: .binary(try Payloads.data(named: "SOSLoader.raw"), trigger: nil, sendLength: false,
                                 settleAfterTrigger: false, slowStart: false),
                serialSpeed: 115200, speedAfterwards: nil, nextStep: nil)
        }
    }

    private var clientFileName: String {
        switch self {
        case .adtproAudio: return "adtproaud.raw"
        case .adtproEthernet: return "adtproeth.raw"
        default: return "adtpro.raw"
        }
    }

    private func audioPlan() throws -> BootstrapPlan {
        let file: String
        let next: String?
        switch self {
        case .prodos:
            file = "PD.raw"
            next = "If the send succeeded, then on the Apple, enter:\n  2003G\n(those are zeroes, not 'O' letters)\n\nNext, send the ADTPro audio client."
        case .esdos1:
            file = "EsDOS1.raw"
            next = "If the send succeeded, then send EsDOS ][ part 2 now."
        case .esdos2:
            file = "EsDOS2.raw"
            next = "If the send succeeded, then on the Apple, enter:\n  9D84G\n\nAfter entering 9D84G, you may also wish to INIT a floppy disk or two."
        case .adt:
            file = "adt.raw"
            next = "If the send succeeded, then on the Apple, enter:\n  803G\n(that is a zero, not the letter 'O')"
        case .adtproSerial, .adtproAudio, .adtproEthernet:
            file = clientFileName
            next = "If the send succeeded, then on the Apple, enter:\n  800G\n(that is a zero, not the letter 'O')"
        default:
            throw Payloads.Error.missing("\(title) is not available over audio")
        }
        return BootstrapPlan(name: file, content: .audio(try Payloads.data(named: file)),
                             serialSpeed: nil, speedAfterwards: nil, nextStep: next)
    }

    /// Instructions to show before sending.
    func instructions(for kind: TransportKind, bootstrapSpeed: Int) throws -> String {
        if kind == .audio {
            let size = try plan(for: .audio).byteCount
            func end(_ base: Int) -> String { String(format: "%04X", size - 1 + base) }
            let cable = "Be sure your audio cable is connected, volume 1/2 up.\n\nOn the Apple, enter:\n"
            let tail = "\n\nClick OK after pressing Return on the Apple..."
            switch self {
            case .prodos: return cable + "  CALL -151\n  2000.\(end(0x2000))R" + tail
            case .esdos1:
                let e = String(format: "%X", size - 1 + 976)
                return cable + "  HOME\n  CALL -151\n  3D0.\(e)R" + tail
            case .esdos2: return cable + "  9D00.BFFFR" + tail
            case .adt: return cable + "  CALL -151\n  803.\(end(0x803))R" + tail
            default: return cable + "  CALL -151\n  800.\(end(0x800))R" + tail
            }
        }
        let baud = Self.baudCommand(for: bootstrapSpeed)
        let serialSteps = "On the Apple, enter:\n  IN#2          (number depends on card slot)\n  <ctrl-A>\(baud)B     (may be <ctrl-I> (the letter 'I'))\n\nClick OK when ready..."
        switch self {
        case .esdos1, .esdos2: return "You must have a floppy diskette in the drive!\n\n" + serialSteps
        case .adt: return "You must have a DOS formatted floppy in the drive!\n*** Have you slowed down the pacing and baud rate? ***\n\n" + serialSteps
        case .sos:
            return """
            1. Start the Apple /// monitor with Ctrl-OpenApple-Reset.
            2. Type in this program exactly as shown:
               A000:AD DF FF 09 F2 8D DF FF
               A008:A9 0B 8D F2 C0 A9 10 8D
               A010:F3 C0 A9 00 A8 85 7E A9
               A018:A1 85 7F A2 48 8E 24 04
               A020:E8 8E 25 04 20 40 A0 C9
               A028:47 D0 F9 A2 03 20 40 A0
               A030:91 7E 8D 27 04 C8 D0 F5
               A038:E6 7F CA D0 F0 4C 00 A1
               A040:AD F1 C0 29 68 C9 08 D0
               A048:F7 AD F0 C0 60
            3. Enter this command to run it:  A000G
            4. If you get the inverse "HI" message on the ///, click OK.
               If not, restart at step 1 and re-check your work.
            """
        default: return serialSteps
        }
    }

    /// The Super Serial Card baud rate command number for a speed.
    static func baudCommand(for speed: Int) -> String {
        switch speed {
        case 300: return "6"
        case 600: return "7"
        case 1200: return "8"
        case 1800: return "9"
        case 2400: return "10"
        case 3600: return "11"
        case 4800: return "12"
        case 7200: return "13"
        case 9600: return "14"
        case 19200: return "15"
        default: return "6"
        }
    }
}
