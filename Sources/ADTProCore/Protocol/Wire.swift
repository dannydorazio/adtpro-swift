// Low-level pieces of the ADTPro wire protocol: control characters, the CRC
// used on data packets, and the run-length/delta encoding of packet payloads.

public enum ControlByte {
    public static let ack: UInt8 = 0x06
    public static let nak: UInt8 = 0x15
    public static let enq: UInt8 = 0x05
    public static let can: UInt8 = 0x18
    public static let timeout: UInt8 = 0x08
}

/// Command bytes. Clients send Apple "high ASCII", so 'A' arrives as $C1.
public enum CommandByte {
    public static let envelope: UInt8 = 0xC1     // 'A' ADTPro-Wide envelope
    public static let batch: UInt8 = 0xC2        // 'B'
    public static let cd: UInt8 = 0xC3           // 'C'
    public static let dir: UInt8 = 0xC4          // 'D'
    public static let virtualDrive: UInt8 = 0xC5 // 'E'
    public static let sendFile: UInt8 = 0xC6     // 'F' bootstrap file request
    public static let get: UInt8 = 0xC7          // 'G'
    public static let ack: UInt8 = 0xCB          // 'K'
    public static let multiNibble: UInt8 = 0xCD  // 'M'
    public static let nibble: UInt8 = 0xCE       // 'N'
    public static let put: UInt8 = 0xD0          // 'P'
    public static let adtReceive: UInt8 = 0xD2   // 'R' legacy DOS ADT
    public static let data: UInt8 = 0xD3         // 'S' wide data packet / legacy ADT send
    public static let halfTrack: UInt8 = 0xD6    // 'V'
    public static let home: UInt8 = 0xD8         // 'X'
    public static let ping: UInt8 = 0xD9         // 'Y' (ping in v1, summary in wide)
    public static let size: UInt8 = 0xDA         // 'Z'
}

/// CRC-16/XMODEM (polynomial $1021, initial value 0), as computed by the clients.
public enum CRC16 {
    static let table: [UInt16] = (0..<256).map { byte in
        var crc = UInt16(byte) << 8
        for _ in 0..<8 {
            crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
        }
        return crc
    }

    public static func checksum<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0
        for b in bytes {
            crc = (crc << 8) ^ table[Int(UInt8(crc >> 8) ^ b)]
        }
        return crc
    }
}

/// The page-oriented delta/run-length encoding ADTPro uses for disk data.
///
/// Each byte is sent as the difference from the previous byte. A difference of
/// zero is followed by the page offset at which the run of identical bytes
/// ends (0 meaning the end of the page). Runs never cross a 256-byte page
/// boundary, but the "previous byte" carries over from page to page within a
/// packet.
public enum PacketCodec {
    public static func encode(pages data: ArraySlice<UInt8>) -> [UInt8] {
        precondition(data.count % 256 == 0)
        var out: [UInt8] = []
        out.reserveCapacity(data.count + data.count / 8)
        var prev: UInt8 = 0
        var pageStart = data.startIndex
        while pageStart < data.endIndex {
            var i = 0
            while i < 256 {
                let current = data[pageStart + i]
                let delta = current &- prev
                prev = current
                out.append(delta)
                if delta != 0 {
                    i += 1
                } else {
                    while i < 256 && data[pageStart + i] == current { i += 1 }
                    out.append(UInt8(i & 0xFF))
                }
            }
            pageStart += 256
        }
        return out
    }

    /// Incremental decoder fed one byte at a time, so it can run directly off a
    /// transport without knowing the encoded length in advance.
    public struct Decoder {
        public private(set) var output: [UInt8]
        private var prev: UInt8 = 0
        private var pageOffset = 0
        private var awaitingRunEnd = false
        public let pages: Int

        public init(pages: Int) {
            self.pages = pages
            output = []
            output.reserveCapacity(pages * 256)
        }

        public var isComplete: Bool { output.count >= pages * 256 }

        public mutating func feed(_ byte: UInt8) {
            guard !isComplete else { return }
            if awaitingRunEnd {
                awaitingRunEnd = false
                let end = Int(byte)
                repeat {
                    output.append(prev)
                    pageOffset += 1
                } while pageOffset < 256 && pageOffset != end
            } else if byte != 0 {
                prev = prev &+ byte
                output.append(prev)
                pageOffset += 1
            } else {
                awaitingRunEnd = true
                return
            }
            if pageOffset == 256 { pageOffset = 0 }
        }
    }

    public static func decode(_ encoded: [UInt8], pages: Int) -> [UInt8] {
        var decoder = Decoder(pages: pages)
        for b in encoded where !decoder.isComplete { decoder.feed(b) }
        return decoder.output
    }
}

/// Helpers for the ADTPro-Wide envelope: 'A', length (lo, hi), command, check byte.
public enum Envelope {
    public static func header(length: Int, command: UInt8) -> [UInt8] {
        let lo = UInt8(length & 0xFF), hi = UInt8((length >> 8) & 0xFF)
        return [CommandByte.envelope, lo, hi, command, CommandByte.envelope ^ lo ^ hi ^ command]
    }

    public static func xor<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        bytes.reduce(0, ^)
    }

    /// A complete envelope with payload and payload check byte.
    public static func packet(command: UInt8, payload: [UInt8]) -> [UInt8] {
        var out = header(length: payload.count, command: command)
        if !payload.isEmpty {
            out += payload
            out.append(xor(payload))
        }
        return out
    }
}
