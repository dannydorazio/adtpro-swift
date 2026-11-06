import Foundation
import Testing
@testable import ADTProCore
import DiskImage

@Suite struct NibbleAnalysisTests {
    /// A raw 13312-byte read of `track`, starting at the beginning of a field.
    func rawRead(of track: [UInt8], startingAt start: Int) -> [UInt8] {
        var raw = [UInt8]()
        var i = start
        while raw.count < 13312 {
            raw.append(track[i % track.count])
            i += 1
        }
        return raw
    }

    @Test func recoversTrackLengthAndContents() throws {
        let dos = Interleave.prodosToDOS(patternedImage(blocks: 280))
        // A realistic track shorter than the 6656-byte maximum.
        let full = GCR.nibblizeTrack(dosOrderTrack: dos[4096..<8192], trackNumber: 1)
        let track = Array(full.prefix(6400))
        // Start at the second sector's address field, as a read would.
        let start = track.indices.filter { track[$0] == 0xD5 && track[$0 + 1] == 0xAA && track[$0 + 2] == 0x96 }[1]
        let result = NibbleAnalysis.analyze(rawRead(of: track, startingAt: start))
        #expect(result.foundLength == 6400)
        #expect(result.accuracy > 0.99)
        #expect(result.data.count == 6656)
        let (decoded, missing) = GCR.denibblizeTrack(result.data[...])
        #expect(missing.isEmpty)
        #expect(decoded == Array(dos[4096..<8192]))
    }

    @Test func garbageGivesZeroAccuracyButRawData() {
        let raw = (0..<13312).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 7) }
        let result = NibbleAnalysis.analyze(raw)
        #expect(result.accuracy == 0)
        #expect(result.data == Array(raw.prefix(6656)))
    }
}

@Suite struct AudioModemTests {
    @Test func encodeDecodeLoopback() {
        let message: [UInt8] = [0xC1, 0x00, 0x00, 0xD8, 0x19] + Array(0...255)
        let samples = AudioModem.encode(message)
        let pcm = samples.map { Int8(clamping: Int(($0 * 127).rounded())) }
        var decoder = AudioModem.Decoder()
        var decoded: [UInt8] = []
        // Feed in uneven chunks as a capture callback would.
        var i = 0
        var chunk = 1000
        while i < pcm.count {
            let end = min(pcm.count, i + chunk)
            decoded += decoder.feed(Array(pcm[i..<end]))
            i = end
            chunk = chunk == 1000 ? 4096 : 1000
        }
        // The decoder hands back the data plus the trailing checksum byte.
        let checksum = message.reduce(UInt8(0xFF), ^)
        #expect(decoded == message + [checksum])
    }

    @Test func toleratesInvertedPolarityAndLowLevel() {
        let message = Array("HELLO APPLE".utf8)
        let pcm = AudioModem.encode(message).map { Int8(clamping: Int((-$0 * 40).rounded())) }
        var decoder = AudioModem.Decoder()
        let decoded = decoder.feed(pcm)
        #expect(Array(decoded.prefix(message.count)) == message)
    }
}

@Suite struct AppleDumpTests {
    @Test func rendersMonitorCommands() {
        let text = AppleDump.render([0x00, 0x0F, 0x10, 0xFF], startAddress: 0x7000, decoration: .both)
        #expect(text == "\r\nCALL -151\r\n25:0 N 7D0:1 4 14 10 12 F A0 N 25:0\r\n7000:0 F 10 FF\r\n7000G\r\n")
    }

    @Test func finalLineAndWrapping() {
        let text = AppleDump.render([UInt8](repeating: 0xAB, count: 200), startAddress: 0x800, decoration: .begin, finalLine: "800G")
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[1] == "CALL -151")
        #expect(lines[3].hasPrefix("800:AB AB"))
        #expect(lines.allSatisfy { $0.count <= 120 })
        #expect(text.hasSuffix("\r\n\r\n800G\r\n"))
        // 200 bytes at 3 characters each: 38 per 114-column line.
        #expect(lines[4].hasPrefix("826:"))
    }

    @Test func bundledPayloadsArePresent() throws {
        for name in ["grub2.bin", "grub_vsdrive.bin", "adtpro.raw", "adtproaud.raw", "adtproeth.raw", "adt.raw",
                     "PD.raw", "PDSpeed.raw", "BSpeed.raw", "SD.raw", "SK.raw", "adtsos.raw", "SOSLoader.raw",
                     "vsdrive_speed.raw", "EsDOS.dmp", "EsDOS1.raw", "EsDOS2.raw"] {
            #expect(try !Payloads.data(named: name).isEmpty, "\(name)")
        }
    }

    @Test func everyBootstrapItemPlans() throws {
        for kind in TransportKind.allCases {
            for item in BootstrapItem.available(for: kind) {
                let plan = try item.plan(for: kind)
                #expect(plan.byteCount > 0)
                #expect(try !item.instructions(for: kind, bootstrapSpeed: 9600).isEmpty)
            }
        }
        #expect(try BootstrapItem.prodos.instructions(for: .serial, bootstrapSpeed: 9600).contains("<ctrl-A>14B"))
    }
}

@Suite struct FileHostTests {
    @Test func wildcards() {
        #expect(FileHost.wildcard("*.PO", matches: "disk.po"))
        #expect(FileHost.wildcard("D?SK*", matches: "DISK1.DSK"))
        #expect(!FileHost.wildcard("*.PO", matches: "disk.dsk"))
        #expect(!FileHost.wildcard("A.B", matches: "AXB"))      // '.' is literal
    }

    @Test func resolvesNamesCaseInsensitively() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/Sub Dir", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/Sub Dir/MyDisk.po", contents: Data())
        let host = FileHost(workingDirectory: dir)
        #expect(host.changeDirectory("SUB DIR"))
        #expect(host.resolveExisting("MYDISK.PO")?.lowercased() == (dir + "/Sub Dir/MyDisk.po").lowercased())
        #expect(host.resolveExisting("OTHER.PO") == nil)
    }
}
