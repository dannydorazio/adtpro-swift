// 2IMG ("2MG") universal disk image header.

public struct TwoIMGHeader: Sendable, Equatable {
    public static let magic: [UInt8] = Array("2IMG".utf8)
    public static let standardHeaderSize = 64

    public var creator: [UInt8]
    public var headerSize: Int
    public var version: Int
    /// 0 = DOS order, 1 = ProDOS order, 2 = nibble.
    public var format: Int
    public var flags: UInt32
    public var prodosBlocks: Int
    public var dataOffset: Int
    public var dataLength: Int
    /// Everything from byte 0 up to `dataOffset` (header plus any comment/creator chunks
    /// that precede the data), preserved verbatim when the image is saved.
    public var leadingBytes: [UInt8]
    /// Anything following the data (comments, creator data), preserved verbatim.
    public var trailingBytes: [UInt8]

    public var sectorOrder: SectorOrder? {
        switch format {
        case 0: return .dos
        case 1: return .prodos
        case 2: return .nibble
        default: return nil
        }
    }

    static func le16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
    static func le32(_ b: [UInt8], _ o: Int) -> Int {
        Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }

    /// Parse a 2IMG file. Returns nil when the magic is absent or the header is inconsistent.
    public static func parse(_ file: [UInt8]) -> (header: TwoIMGHeader, data: [UInt8])? {
        guard file.count >= standardHeaderSize, Array(file[0..<4]) == magic else { return nil }
        let headerSize = le16(file, 8)
        let format = le32(file, 12)
        let flags = UInt32(truncatingIfNeeded: le32(file, 16))
        let blocks = le32(file, 20)
        var offset = le32(file, 24)
        var length = le32(file, 28)
        if offset == 0 { offset = headerSize }
        if length == 0 && format == 1 { length = blocks * Geometry.blockSize }
        guard offset >= 16, offset <= file.count else { return nil }
        if offset + length > file.count { length = file.count - offset }
        let header = TwoIMGHeader(
            creator: Array(file[4..<8]),
            headerSize: headerSize,
            version: le16(file, 10),
            format: format,
            flags: flags,
            prodosBlocks: blocks,
            dataOffset: offset,
            dataLength: length,
            leadingBytes: Array(file[0..<offset]),
            trailingBytes: Array(file[(offset + length)...])
        )
        return (header, Array(file[offset..<offset + length]))
    }

    /// Build a fresh header for a ProDOS-ordered image of `blocks` blocks.
    public static func makeProDOS(blocks: Int) -> TwoIMGHeader {
        var bytes = [UInt8](repeating: 0, count: standardHeaderSize)
        bytes.replaceSubrange(0..<4, with: magic)
        bytes.replaceSubrange(4..<8, with: Array("ADTP".utf8))
        func put16(_ v: Int, _ o: Int) { bytes[o] = UInt8(v & 0xFF); bytes[o + 1] = UInt8((v >> 8) & 0xFF) }
        func put32(_ v: Int, _ o: Int) { put16(v & 0xFFFF, o); put16((v >> 16) & 0xFFFF, o + 2) }
        put16(standardHeaderSize, 8)
        put16(1, 10)
        put32(1, 12)
        put32(blocks, 20)
        put32(standardHeaderSize, 24)
        put32(blocks * Geometry.blockSize, 28)
        return TwoIMGHeader(
            creator: Array("ADTP".utf8), headerSize: standardHeaderSize, version: 1, format: 1, flags: 0,
            prodosBlocks: blocks, dataOffset: standardHeaderSize, dataLength: blocks * Geometry.blockSize,
            leadingBytes: bytes, trailingBytes: []
        )
    }
}
