import Foundation
import Testing
@testable import ADTProCore
import DiskImage

@Suite struct WireTests {
    @Test func crcMatchesXMODEMCheckValue() {
        // The standard CRC-16/XMODEM check value for "123456789".
        #expect(CRC16.checksum(Array("123456789".utf8)) == 0x31C3)
        #expect(CRC16.checksum([UInt8]()) == 0)
    }

    @Test(arguments: [1, 2, 4, 80])
    func codecRoundTrip(pages: Int) {
        let data = patternedImage(blocks: (pages + 1) / 2, seed: pages)
        let slice = data[0..<pages * 256]
        let encoded = PacketCodec.encode(pages: slice)
        #expect(PacketCodec.decode(encoded, pages: pages) == Array(slice))
    }

    @Test func codecHandlesUniformAndEdgePages() {
        for fill: UInt8 in [0x00, 0xFF, 0x7F] {
            let page = [UInt8](repeating: fill, count: 512)
            let encoded = PacketCodec.encode(pages: page[...])
            #expect(encoded.count <= 6)       // a couple of bytes per page
            #expect(PacketCodec.decode(encoded, pages: 2) == page)
        }
        // A zero byte right at the start of a page, and runs ending exactly at 256.
        var tricky = [UInt8](repeating: 0, count: 256)
        for i in 128..<256 { tricky[i] = 9 }
        #expect(PacketCodec.decode(PacketCodec.encode(pages: tricky[...]), pages: 1) == tricky)
    }

    @Test func knownEncoding() {
        // 00 00 01 01 ... : first byte equals the seed (0) -> run to offset 2, then delta 1, run to 256.
        var page = [UInt8](repeating: 1, count: 256)
        page[0] = 0; page[1] = 0
        #expect(PacketCodec.encode(pages: page[...]) == [0x00, 0x02, 0x01, 0x00, 0x00])
    }

    @Test func envelopeChecks() {
        #expect(Envelope.header(length: 0, command: CommandByte.home) == [0xC1, 0x00, 0x00, 0xD8, 0x19])
        #expect(Envelope.header(length: 1, command: CommandByte.sendFile) == [0xC1, 0x01, 0x00, 0xC6, 0x06])
        #expect(Envelope.packet(command: CommandByte.ping, payload: [0]) == [0xC1, 0x01, 0x00, 0xD9, 0x19, 0x00, 0x00])
    }
}

@Suite(.serialized) struct WideProtocolTests {
    @Test func directoryListingPagesThroughFiles() throws {
        let h = try Harness()
        defer { h.finish() }
        for i in 0..<20 {
            FileManager.default.createFile(atPath: h.directory + String(format: "/DISK%02d.PO", i), contents: Data([0]))
        }
        FileManager.default.createFile(atPath: h.directory + "/.hidden", contents: Data([0]))
        let first = try h.apple.directory(page: 0)
        #expect(first.contains(String((h.directory + "/").suffix(30))))
        #expect(first.contains(String(repeating: "-", count: 40)))
        #expect(first.contains("DISK00.PO\r"))
        #expect(first.contains("DISK17.PO\r"))
        #expect(!first.contains("DISK18.PO"))
        #expect(!first.contains(".hidden"))
        let second = try h.apple.directory(page: 1)
        #expect(second.contains("DISK18.PO\r"))
        #expect(second.contains("DISK19.PO\r"))
        let filtered = try h.apple.directory(page: 0, filespec: "*1?.po")
        #expect(filtered.contains("DISK10.PO"))
        #expect(!filtered.contains("DISK09.PO"))
    }

    @Test func changeDirectoryAcceptsRelativeAndRejectsMissing() throws {
        let h = try Harness()
        defer { h.finish() }
        try FileManager.default.createDirectory(atPath: h.directory + "/Games", withIntermediateDirectories: true)
        #expect(try h.apple.changeDirectory("GAMES") == 0)       // case-insensitive match
        #expect(h.server.fileHost.workingDirectory == h.directory + "/Games/")
        #expect(try h.apple.changeDirectory("NOPE") == 6)
        #expect(try h.apple.changeDirectory("..") == 0)
        #expect(h.server.fileHost.workingDirectory == h.directory + "/")
    }

    @Test func sizeQueryReportsStatus() throws {
        let h = try Harness()
        defer { h.finish() }
        try ProDOSVolume.createImage(at: h.directory + "/WORK.PO", volumeName: "WORK", blocks: 1600)
        try ProDOSVolume.createImage(at: h.directory + "/game.dsk", volumeName: "GAME", blocks: 280)
        FileManager.default.createFile(atPath: h.directory + "/notes.txt", contents: Data("hello".utf8))
        #expect(try h.apple.size(of: "WORK.PO") == (1600, 0))
        #expect(try h.apple.size(of: "GAME.DSK") == (280, 0))
        #expect(try h.apple.size(of: "MISSING.PO").status == 2)
        #expect(try h.apple.size(of: "NOTES.TXT").status == 4)
    }

    @Test(arguments: [1, 4, 7, 40])
    func getSendsEveryBlock(blocksAtOnce: Int) throws {
        let h = try Harness()
        defer { h.finish() }
        let image = patternedImage(blocks: 1600, seed: blocksAtOnce)
        try Data(image).write(to: URL(fileURLWithPath: h.directory + "/BIG.PO"))
        let received = try h.apple.get("BIG.PO", blocksAtOnce: blocksAtOnce)
        #expect(received == image)
    }

    @Test func getOf140KDOSOrderImageSendsProDOSBlocks() throws {
        let h = try Harness()
        defer { h.finish() }
        let po = patternedImage(blocks: 280)
        try Data(Interleave.prodosToDOS(po)).write(to: URL(fileURLWithPath: h.directory + "/FLOPPY.DSK"))
        #expect(try h.apple.get("FLOPPY.DSK", blocksAtOnce: 2) == po)
    }

    @Test func getRecoversFromANak() throws {
        let h = try Harness()
        defer { h.finish() }
        let image = patternedImage(blocks: 280, seed: 3)
        try Data(image).write(to: URL(fileURLWithPath: h.directory + "/RETRY.PO"))
        #expect(try h.apple.get("RETRY.PO", blocksAtOnce: 4, nakFirstPacket: true) == image)
    }

    @Test func getOfMissingFileIsRefused() throws {
        let h = try Harness()
        defer { h.finish() }
        h.apple.sendEnvelope(CommandByte.get, SimulatedApple.appleName("NOPE.PO") + [0, 4])
        #expect(try h.apple.read() == 0x02)
    }

    @Test func putWritesImage() throws {
        let h = try Harness()
        defer { h.finish() }
        let image = patternedImage(blocks: 1600, seed: 9)
        #expect(try h.apple.put("UPLOAD", image: image, blocksAtOnce: 40))
        try waitFor { h.recorder.events.contains { if case .transferFinished = $0 { true } else { false } } }
        let written = try Data(contentsOf: URL(fileURLWithPath: h.directory + "/UPLOAD.po"))
        #expect([UInt8](written) == image)
    }

    @Test func putOf140KIsSavedInDOSOrder() throws {
        let h = try Harness()
        defer { h.finish() }
        let po = patternedImage(blocks: 280, seed: 5)
        #expect(try h.apple.put("FLOPPY", image: po, blocksAtOnce: 4))
        try waitFor { h.recorder.events.contains { if case .transferFinished = $0 { true } else { false } } }
        let written = [UInt8](try Data(contentsOf: URL(fileURLWithPath: h.directory + "/FLOPPY.dsk")))
        #expect(written == Interleave.prodosToDOS(po))
    }

    @Test func putRecoversFromBadCRC() throws {
        let h = try Harness()
        defer { h.finish() }
        let image = patternedImage(blocks: 280, seed: 11)
        #expect(try h.apple.put("BAD", image: image, blocksAtOnce: 4, corruptPacket: 3))
        try waitFor { h.recorder.events.contains { if case .transferFinished = $0 { true } else { false } } }
        let written = [UInt8](try Data(contentsOf: URL(fileURLWithPath: h.directory + "/BAD.dsk")))
        #expect(written == Interleave.prodosToDOS(image))
    }

    @Test func batchPutNumbersFiles() throws {
        let h = try Harness()
        defer { h.finish() }
        let image = patternedImage(blocks: 280)
        for _ in 0..<3 { #expect(try h.apple.put("BATCH", image: image, batch: true)) }
        try waitFor {
            h.recorder.events.filter { if case .transferFinished = $0 { true } else { false } }.count == 3
        }
        for n in 1...3 {
            #expect(FileManager.default.fileExists(atPath: h.directory + String(format: "/BATCH%04d.dsk", n)))
        }
    }

    @Test func bootstrapFileRequestSendsPayload() throws {
        let h = try Harness()
        defer { h.finish() }
        let expected = try Payloads.data(named: "adtpro.raw")
        #expect(try h.apple.requestBootstrapFile(0xB6) == expected)
    }

    @Test func homeEnvelopeIsIgnoredAndStrayAckGetsHome() throws {
        let h = try Harness()
        defer { h.finish() }
        h.apple.sendEnvelope(CommandByte.home, [])
        h.apple.sendEnvelope(CommandByte.ack, [ControlByte.ack, 0, 0])
        let (length, command) = try h.apple.readEnvelope()
        #expect(length == 0)
        #expect(command == CommandByte.home)
    }
}

@Suite(.serialized) struct VirtualDriveTests {
    @Test func readsCreateDefaultVolumeAndWritesPersist() throws {
        let h = try Harness()
        defer { h.finish() }
        let (stamp, block2) = try h.apple.vdriveRead(command: 0x03, block: 2)
        #expect(stamp.count == 4)
        #expect(block2[4] == 0xF0 | 14)       // "HOSTED.VDRIVE1"
        #expect(FileManager.default.fileExists(atPath: h.directory + "/Virtual.po"))

        let data = (0..<512).map { UInt8(truncatingIfNeeded: $0 * 3) }
        let reply = try h.apple.vdriveWrite(command: 0x02, block: 100, data: data)
        #expect(reply == [0xC5, 0x02, 100, 0, Envelope.xor(data)])
        #expect(try h.apple.vdriveRead(command: 0x01, block: 100).data == data)
        let onDisk = try DiskImage.open(path: h.directory + "/Virtual.po")
        #expect(try onDisk.readBlock(100) == data)
    }

    @Test func driveTwoIsSeparate() throws {
        let h = try Harness()
        defer { h.finish() }
        let data = [UInt8](repeating: 0x42, count: 512)
        _ = try h.apple.vdriveWrite(command: 0x04, block: 7, data: data)
        #expect(try h.apple.vdriveRead(command: 0x05, block: 7).data == data)
        #expect(try h.apple.vdriveRead(command: 0x03, block: 7).data != data)
        #expect(FileManager.default.fileExists(atPath: h.directory + "/Virtual2.po"))
    }

    @Test func externalEditsAreNoticed() throws {
        let h = try Harness()
        defer { h.finish() }
        _ = try h.apple.vdriveRead(block: 0)
        // Edit the image behind the server's back.
        let path = h.directory + "/Virtual.po"
        let image = try DiskImage.open(path: path)
        let data = [UInt8](repeating: 0x99, count: 512)
        try image.writeBlock(50, data)
        Thread.sleep(forTimeInterval: 1.1)    // ensure a distinct modification time
        try image.save()
        #expect(try h.apple.vdriveRead(block: 50).data == data)
    }

    @Test func badChecksumWriteIsNotApplied() throws {
        let h = try Harness()
        defer { h.finish() }
        _ = try h.apple.vdriveRead(block: 0)
        let lo: UInt8 = 9, hi: UInt8 = 0
        let data = [UInt8](repeating: 0x11, count: 511) + [0x22]
        h.apple.send([0xC5, 0x02, lo, hi, 0xC5 ^ 0x02 ^ lo ^ hi] + data + [Envelope.xor(data) ^ 0xFF])   // wrong checksum
        _ = try h.apple.read(count: 5)
        #expect(try h.apple.vdriveRead(block: 9).data != data)
    }
}

@Suite(.serialized) struct OriginalProtocolTests {
    @Test func sizeQueryWithVersionHandshake() throws {
        let h = try Harness()
        defer { h.finish() }
        try ProDOSVolume.createImage(at: h.directory + "/V1.PO", volumeName: "V1", blocks: 800)
        // 'Z', protocol version 01 01 00 (acknowledged), then the name.
        h.apple.send([CommandByte.size, 0x01, 0x01, 0x00])
        #expect(try h.apple.read() == ControlByte.ack)
        h.apple.send(SimulatedApple.appleName("V1.PO") + [0])
        #expect(try h.apple.read(count: 3) == [0x20, 0x03, 0x00])
    }

    @Test func pingIsAccepted() throws {
        let h = try Harness()
        defer { h.finish() }
        h.apple.send([CommandByte.ping])
        try waitFor { h.recorder.events.contains(.status(Messages.ping)) }
    }
}

func waitFor(timeout: Double = 5, _ condition: () -> Bool) throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition() {
        if Date() > deadline { throw SimulatedAppleError(description: "timed out waiting for condition") }
        Thread.sleep(forTimeInterval: 0.01)
    }
}

@Suite(.serialized) struct SerialIPTransportTests {
    /// The host listens (as for Virtual ][) and a connecting transport plays the
    /// emulator, so both roles run over real TCP sockets.
    @Test func transferOverRealSockets() throws {
        let port = Int.random(in: 40000...60000)
        let host = SerialIPTransport(port: port, role: .listen)
        let emulator = SerialIPTransport(host: "127.0.0.1", port: port, role: .connect)
        try emulator.open()
        let h = try Harness(host: host, apple: emulator)
        defer { h.finish(); emulator.close() }

        // The emulator side retries until the host's listener is up.
        try waitFor(timeout: 5) {
            emulator.write([CommandByte.ping]); emulator.flush()
            return emulator.isConnected && host.isConnected
        }
        let image = patternedImage(blocks: 280, seed: 21)
        try Data(image).write(to: URL(fileURLWithPath: h.directory + "/NET.PO"))
        #expect(try h.apple.get("NET.PO", blocksAtOnce: 8) == image)
        #expect(try h.apple.put("BACK", image: image, blocksAtOnce: 8))
        try waitFor { h.recorder.events.contains { if case .transferFinished(let r) = $0 { r.direction == .fromApple } else { false } } }
        #expect([UInt8](try Data(contentsOf: URL(fileURLWithPath: h.directory + "/BACK.dsk"))) == Interleave.prodosToDOS(image))
    }

    @Test func reconnectsAfterTheEmulatorRestarts() throws {
        let port = Int.random(in: 40000...60000)
        let host = SerialIPTransport(port: port, role: .listen)
        try host.open()
        defer { host.close() }
        for round in 0..<2 {
            let emulator = SerialIPTransport(host: "127.0.0.1", port: port, role: .connect)
            try emulator.open()
            try waitFor { emulator.isConnected }
            emulator.write([UInt8(round)]); emulator.flush()
            #expect(try host.readByte(timeout: 2) == UInt8(round))
            host.write([0x42 + UInt8(round)]); host.flush()
            #expect(try emulator.readByte(timeout: 2) == 0x42 + UInt8(round))
            emulator.close()
            // The host notices the hang-up on its next read.
            #expect(throws: TransportError.timeout) { try host.readByte(timeout: 0.5) }
        }
    }
}

@Suite(.serialized) struct SerialIPDualStackTests {
    /// Virtual ][ resolves "localhost" to ::1 first, so the listener must accept IPv6 as well as IPv4.
    @Test(arguments: ["::1", "127.0.0.1"])
    func listenerAcceptsBothAddressFamilies(address: String) throws {
        let port = Int.random(in: 40000...60000)
        let host = SerialIPTransport(port: port, role: .listen)
        try host.open()
        defer { host.close() }
        let emulator = SerialIPTransport(host: address, port: port, role: .connect)
        try emulator.open()
        defer { emulator.close() }
        try waitFor { emulator.isConnected }
        emulator.write([0x5A]); emulator.flush()
        #expect(try host.readByte(timeout: 2) == 0x5A)
    }
}
