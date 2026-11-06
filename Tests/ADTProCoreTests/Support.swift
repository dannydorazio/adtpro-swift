import Foundation
import Synchronization
@testable import ADTProCore
import DiskImage

/// One end of an in-memory serial line.
final class PipeEnd: Transport, @unchecked Sendable {
    let kind: TransportKind
    let incoming: ByteQueue
    let outgoing: ByteQueue
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    /// Optional hook to corrupt outgoing flushes (for fault injection).
    var mangle: (([UInt8]) -> [UInt8])?

    init(kind: TransportKind, incoming: ByteQueue, outgoing: ByteQueue) {
        self.kind = kind
        self.incoming = incoming
        self.outgoing = outgoing
    }

    var summary: String { "memory pipe" }
    var supportsBootstrap: Bool { true }
    func open() throws {}
    func close() { incoming.close() }
    func readByte(timeout: Double) throws -> UInt8 { try incoming.read(timeout: timeout) }
    func write(_ bytes: [UInt8]) { lock.withLock { buffer += bytes } }
    func flush() {
        var pending = lock.withLock { () -> [UInt8] in defer { buffer.removeAll() }; return buffer }
        if let mangle { pending = mangle(pending) }
        outgoing.append(pending)
    }
    func discardInput() {}
    func discardOutput() { lock.withLock { buffer.removeAll() } }
}

func makePipe(kind: TransportKind = .serialIP) -> (host: PipeEnd, apple: PipeEnd) {
    let toHost = ByteQueue(), toApple = ByteQueue()
    return (PipeEnd(kind: kind, incoming: toHost, outgoing: toApple),
            PipeEnd(kind: kind, incoming: toApple, outgoing: toHost))
}

final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [ServerEvent] = []
    var events: [ServerEvent] { lock.withLock { _events } }
    func record(_ e: ServerEvent) { lock.withLock { _events.append(e) } }
    var details: [String] { events.compactMap { if case .detail(let d) = $0 { return d } else { return nil } } }
}

func scratchDirectory() throws -> String {
    let dir = NSTemporaryDirectory() + "adtpro-core-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
}

/// A running server on a pipe, torn down with `finish()`.
struct Harness {
    let server: ADTProServer
    let apple: SimulatedApple
    let directory: String
    let recorder: EventRecorder

    init(kind: TransportKind = .serialIP) throws {
        let (hostEnd, appleEnd) = makePipe(kind: kind)
        try self.init(host: hostEnd, apple: appleEnd)
    }

    init(host hostEnd: Transport, apple appleEnd: Transport) throws {
        directory = try scratchDirectory()
        let recorder = EventRecorder()
        self.recorder = recorder
        server = ADTProServer(transport: hostEnd, fileHost: FileHost(workingDirectory: directory),
                              onEvent: { recorder.record($0) })
        apple = SimulatedApple(link: appleEnd)
        server.start()
        // Wait for the command loop to come up.
        let deadline = Date(timeIntervalSinceNow: 2)
        while !server.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
    }

    func finish() {
        server.stop()
        try? FileManager.default.removeItem(atPath: directory)
    }
}

struct SimulatedAppleError: Error, CustomStringConvertible {
    var description: String
}

/// The Apple side of the ADTPro-Wide protocol, written from the protocol
/// documentation, for driving the server in tests.
final class SimulatedApple: @unchecked Sendable {
    let link: Transport
    init(link: Transport) { self.link = link }

    func read(_ timeout: Double = 5) throws -> UInt8 { try link.readByte(timeout: timeout) }
    func read(count: Int, timeout: Double = 5) throws -> [UInt8] { try (0..<count).map { _ in try read(timeout) } }

    func send(_ bytes: [UInt8]) {
        link.write(bytes)
        link.flush()
    }

    func sendEnvelope(_ command: UInt8, _ payload: [UInt8]) {
        send(Envelope.packet(command: command, payload: payload))
    }

    static func appleName(_ s: String) -> [UInt8] { s.utf8.map { $0 | 0x80 } }

    /// Read an envelope, skipping to the next 'A'.
    func readEnvelope() throws -> (length: Int, command: UInt8) {
        while try read() != CommandByte.envelope {}
        let lo = try read(), hi = try read(), cmd = try read(), check = try read()
        guard check == CommandByte.envelope ^ lo ^ hi ^ cmd else { throw SimulatedAppleError(description: "bad envelope check") }
        return (Int(lo) | Int(hi) << 8, cmd)
    }

    /// Read a wide data packet: returns starting block and decoded data.
    func readDataPacket() throws -> (block: Int, data: [UInt8]) {
        let (length, command) = try readEnvelope()
        guard command == CommandByte.data else { throw SimulatedAppleError(description: "expected data packet, got \(command)") }
        let block = Int(try read()) | Int(try read()) << 8
        var decoder = PacketCodec.Decoder(pages: length / 256)
        while !decoder.isComplete { decoder.feed(try read()) }
        let crc = UInt16(try read()) | UInt16(try read()) << 8
        guard crc == CRC16.checksum(decoder.output) else { throw SimulatedAppleError(description: "CRC mismatch") }
        return (block, decoder.output)
    }

    func acknowledge(_ code: UInt8, nextBlock: Int) {
        sendEnvelope(CommandByte.ack, [code, UInt8(nextBlock & 0xFF), UInt8(nextBlock >> 8)])
    }

    // MARK: Operations

    func changeDirectory(_ path: String) throws -> UInt8 {
        sendEnvelope(CommandByte.cd, Self.appleName(path) + [0])
        return try read()
    }

    func directory(page: Int = 0, filespec: String = "") throws -> String {
        sendEnvelope(CommandByte.dir, Self.appleName(filespec) + [0, UInt8(page)])
        let (block, data) = try readDataPacket()
        acknowledge(ControlByte.ack, nextBlock: block + 2)
        return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
    }

    func size(of name: String) throws -> (blocks: Int, status: UInt8) {
        sendEnvelope(CommandByte.size, Self.appleName(name) + [0])
        let r = try read(count: 3)
        return (Int(r[0]) | Int(r[1]) << 8, r[2])
    }

    /// Get an image from the host. Returns nil if the host refused it.
    func get(_ name: String, blocksAtOnce: Int = 4, nakFirstPacket: Bool = false) throws -> [UInt8]? {
        let (blocks, status) = try size(of: name)
        guard status == 0 else { return nil }
        sendEnvelope(CommandByte.get, Self.appleName(name) + [0, UInt8(blocksAtOnce)])
        guard try read() == 0 else { return nil }
        acknowledge(ControlByte.ack, nextBlock: 0)
        var image = [UInt8]()
        var naked = !nakFirstPacket
        while image.count / 512 < blocks {
            let (block, data) = try readDataPacket()
            if !naked {
                naked = true
                acknowledge(ControlByte.nak, nextBlock: block)
                continue
            }
            guard block == image.count / 512 else { throw SimulatedAppleError(description: "out of order block \(block)") }
            image += data
            acknowledge(ControlByte.ack, nextBlock: block + data.count / 512)
        }
        sendEnvelope(CommandByte.ping, [0])   // summary: zero errors
        return image
    }

    /// Put an image to the host. `corruptPacket` sends a bad CRC the first time
    /// that packet goes out.
    func put(_ name: String, image: [UInt8], blocksAtOnce: Int = 4, batch: Bool = false, corruptPacket: Int? = nil) throws -> Bool {
        let blocks = image.count / 512
        sendEnvelope(batch ? CommandByte.batch : CommandByte.put,
                     Self.appleName(name) + [0, UInt8(blocks & 0xFF), UInt8(blocks >> 8)])
        guard try read() == 0 else { return false }
        var block = 0
        var packetNumber = 0
        var corrupted = false
        while block < blocks {
            let count = min(blocksAtOnce, blocks - block)
            let data = Array(image[block * 512..<(block + count) * 512])
            var crc = CRC16.checksum(data)
            if packetNumber == corruptPacket && !corrupted {
                crc ^= 0xFFFF
                corrupted = true
            }
            send(Envelope.header(length: count * 512, command: CommandByte.data)
                 + [UInt8(block & 0xFF), UInt8(block >> 8)]
                 + PacketCodec.encode(pages: data[...])
                 + [UInt8(crc & 0xFF), UInt8(crc >> 8)])
            let reply = try read(15)
            if reply == ControlByte.ack {
                block += count
                packetNumber += 1
            } else if reply != ControlByte.nak {
                throw SimulatedAppleError(description: "unexpected reply \(reply)")
            }
        }
        sendEnvelope(CommandByte.ping, [0])
        return true
    }

    func requestBootstrapFile(_ number: UInt8) throws -> [UInt8] {
        sendEnvelope(CommandByte.sendFile, [number])
        let trigger = try read()
        _ = trigger
        let length = Int(try read()) | Int(try read()) << 8
        return try read(count: length)
    }

    // MARK: Virtual drive

    func vdriveRead(command: UInt8 = 0x03, block: Int) throws -> (stamp: [UInt8], data: [UInt8]) {
        let lo = UInt8(block & 0xFF), hi = UInt8(block >> 8)
        send([CommandByte.virtualDrive, command, lo, hi, CommandByte.virtualDrive ^ command ^ lo ^ hi])
        let header = try read(count: 4)
        guard header == [CommandByte.virtualDrive, command, lo, hi] else { throw SimulatedAppleError(description: "bad vdrive header") }
        var stamp: [UInt8] = []
        if command != 0x01 {
            stamp = try read(count: 4)
            let check = try read()
            guard check == Envelope.xor(header + stamp) else { throw SimulatedAppleError(description: "bad vdrive envelope check") }
        } else {
            _ = try read()
        }
        let data = try read(count: 512)
        guard try read() == Envelope.xor(data) else { throw SimulatedAppleError(description: "bad block checksum") }
        return (stamp, data)
    }

    func vdriveWrite(command: UInt8 = 0x02, block: Int, data: [UInt8]) throws -> [UInt8] {
        let lo = UInt8(block & 0xFF), hi = UInt8(block >> 8)
        send([CommandByte.virtualDrive, command, lo, hi, CommandByte.virtualDrive ^ command ^ lo ^ hi] + data + [Envelope.xor(data)])
        return try read(count: 5)
    }
}

func patternedImage(blocks: Int, seed: Int = 1) -> [UInt8] {
    var image = [UInt8](repeating: 0, count: blocks * 512)
    for i in 0..<image.count {
        // Mix runs (to exercise run-length encoding) with varying data.
        let block = i / 512
        image[i] = (i % 512) < 100 ? UInt8(truncatingIfNeeded: block) : UInt8(truncatingIfNeeded: (i &* 31 &+ seed &* 7) >> 3)
    }
    return image
}
