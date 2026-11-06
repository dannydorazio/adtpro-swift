// Sector ordering for 5.25" (16-sector, 35-track) disk images.
//
// A 140K image stores 560 sectors of 256 bytes. "DOS order" images (.dsk/.do)
// store sectors by DOS 3.3 logical sector number; "ProDOS order" images (.po)
// store them by ProDOS block (two sectors per block). Both describe the same
// physical disk; only the arrangement in the file differs.

public enum SectorOrder: Sendable, Equatable {
    /// DOS 3.3 logical sector order (.dsk, .do).
    case dos
    /// ProDOS block order (.po, .hdv, 3.5" and hard disk images).
    case prodos
    /// Raw nibble track data (.nib); 35 tracks of 6656 bytes.
    case nibble
}

public enum Geometry {
    public static let blockSize = 512
    public static let sectorSize = 256
    public static let sectorsPerTrack = 16
    public static let tracks = 35
    public static let trackSize = sectorsPerTrack * sectorSize          // 4096
    public static let size140K = tracks * trackSize                      // 143360
    public static let blocks140K = size140K / blockSize                  // 280
    public static let size800K = 1600 * blockSize                        // 819200
    public static let nibbleTrackSize = 6656
    public static let nibbleImageSize = tracks * nibbleTrackSize         // 232960
}

public enum Interleave {
    /// For ProDOS block `n` within a track (0...7), the two DOS logical sectors
    /// holding its first and second halves.
    public static let blockToDOSSectors: [(Int, Int)] = [
        (0x0, 0xE), (0xD, 0xC), (0xB, 0xA), (0x9, 0x8),
        (0x7, 0x6), (0x5, 0x4), (0x3, 0x2), (0x1, 0xF),
    ]

    /// DOS 3.3 logical sector -> physical sector (as recorded in the address field).
    public static let dosLogicalToPhysical: [Int] = [
        0x0, 0xD, 0xB, 0x9, 0x7, 0x5, 0x3, 0x1,
        0xE, 0xC, 0xA, 0x8, 0x6, 0x4, 0x2, 0xF,
    ]

    /// Physical sector -> DOS 3.3 logical sector.
    public static let physicalToDOSLogical: [Int] = {
        var table = [Int](repeating: 0, count: 16)
        for (logical, physical) in dosLogicalToPhysical.enumerated() {
            table[physical] = logical
        }
        return table
    }()

    /// Byte offsets, within a DOS-ordered 140K image, of the two 256-byte halves
    /// of ProDOS block `block`.
    public static func dosOffsets(forBlock block: Int) -> (Int, Int) {
        let track = block / 8
        let (s1, s2) = blockToDOSSectors[block % 8]
        let base = track * Geometry.trackSize
        return (base + s1 * Geometry.sectorSize, base + s2 * Geometry.sectorSize)
    }

    /// Rearrange a 140K ProDOS-ordered image into DOS order.
    public static func prodosToDOS(_ po: [UInt8]) -> [UInt8] {
        precondition(po.count == Geometry.size140K)
        var dos = [UInt8](repeating: 0, count: Geometry.size140K)
        for block in 0..<Geometry.blocks140K {
            let (a, b) = dosOffsets(forBlock: block)
            let src = block * Geometry.blockSize
            dos.replaceSubrange(a..<a + 256, with: po[src..<src + 256])
            dos.replaceSubrange(b..<b + 256, with: po[src + 256..<src + 512])
        }
        return dos
    }

    /// Rearrange a 140K DOS-ordered image into ProDOS order.
    public static func dosToProDOS(_ dos: [UInt8]) -> [UInt8] {
        precondition(dos.count == Geometry.size140K)
        var po = [UInt8](repeating: 0, count: Geometry.size140K)
        for block in 0..<Geometry.blocks140K {
            let (a, b) = dosOffsets(forBlock: block)
            let dst = block * Geometry.blockSize
            po.replaceSubrange(dst..<dst + 256, with: dos[a..<a + 256])
            po.replaceSubrange(dst + 256..<dst + 512, with: dos[b..<b + 256])
        }
        return po
    }
}
