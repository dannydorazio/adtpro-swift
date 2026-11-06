// 6-and-2 GCR encoding as used by DOS 3.3 and ProDOS on 16-sector 5.25" disks.
//
// This lets nibble images (.nib) be read block-by-block like any other image,
// and lets sector images be turned into nibble images (handy for tests).

public enum GCR {
    /// 6-bit value -> valid disk nibble.
    public static let encodeTable: [UInt8] = [
        0x96, 0x97, 0x9A, 0x9B, 0x9D, 0x9E, 0x9F, 0xA6, 0xA7, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF, 0xB2, 0xB3,
        0xB4, 0xB5, 0xB6, 0xB7, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF, 0xCB, 0xCD, 0xCE, 0xCF, 0xD3,
        0xD6, 0xD7, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF, 0xE5, 0xE6, 0xE7, 0xE9, 0xEA, 0xEB, 0xEC,
        0xED, 0xEE, 0xEF, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF,
    ]

    /// Disk nibble -> 6-bit value, or 0xFF when the nibble is not a valid data nibble.
    public static let decodeTable: [UInt8] = {
        var table = [UInt8](repeating: 0xFF, count: 256)
        for (value, nibble) in encodeTable.enumerated() {
            table[Int(nibble)] = UInt8(value)
        }
        return table
    }()

    @inline(__always)
    static func swapLowBits(_ b: UInt8) -> UInt8 {
        ((b & 0x01) << 1) | ((b & 0x02) >> 1)
    }

    /// Encode a 256-byte sector into the 343 data-field nibbles (342 + checksum),
    /// laid out exactly as DOS 3.3 RWTS writes them.
    public static func encodeSector(_ data: ArraySlice<UInt8>) -> [UInt8] {
        precondition(data.count == 256)
        let d = Array(data)
        var twos = [UInt8](repeating: 0, count: 86)
        for x in 0..<86 {
            let round3 = swapLowBits(d[85 - x] & 3)
            let round2 = swapLowBits(d[171 - x] & 3)
            let round1Index = (257 - x) & 0xFF   // x = 0,1 wrap around to bytes 1,0
            let round1 = swapLowBits(d[round1Index] & 3)
            twos[x] = ((round1 << 4) | (round2 << 2) | round3) & 0x3F
        }
        // Logical stream: twos[85] ... twos[0], then the high six bits of every byte.
        var stream = [UInt8]()
        stream.reserveCapacity(342)
        for x in stride(from: 85, through: 0, by: -1) { stream.append(twos[x]) }
        for byte in d { stream.append(byte >> 2) }

        var out = [UInt8]()
        out.reserveCapacity(343)
        var previous: UInt8 = 0
        for value in stream {
            out.append(encodeTable[Int(value ^ previous)])
            previous = value
        }
        out.append(encodeTable[Int(previous)])
        return out
    }

    /// Decode 343 data-field nibbles back into a 256-byte sector.
    /// Returns nil on an invalid nibble or checksum mismatch.
    public static func decodeSector(_ nibbles: [UInt8]) -> [UInt8]? {
        guard nibbles.count >= 343 else { return nil }
        var stream = [UInt8](repeating: 0, count: 342)
        var previous: UInt8 = 0
        for i in 0..<342 {
            let v = decodeTable[Int(nibbles[i])]
            if v == 0xFF { return nil }
            previous ^= v
            stream[i] = previous
        }
        let check = decodeTable[Int(nibbles[342])]
        if check == 0xFF || check != previous { return nil }

        var out = [UInt8](repeating: 0, count: 256)
        for y in 0..<256 {
            let x = 85 - (y % 86)
            let twos = stream[85 - x]            // twos[x] sits at stream position 85 - x
            let shift = UInt8((y / 86) * 2)
            let low = (twos >> shift) & 3
            out[y] = (stream[86 + y] << 2) | swapLowBits(low)
        }
        return out
    }

    static func encode44(_ value: UInt8) -> [UInt8] {
        [(value >> 1) | 0xAA, value | 0xAA]
    }

    static func decode44(_ a: UInt8, _ b: UInt8) -> UInt8 {
        ((a << 1) | 0x01) & b
    }

    /// Build a 6656-byte nibble track from a DOS-ordered 4096-byte track.
    public static func nibblizeTrack(dosOrderTrack track: ArraySlice<UInt8>, trackNumber: Int, volume: UInt8 = 254) -> [UInt8] {
        precondition(track.count == Geometry.trackSize)
        let base = track.startIndex
        var out = [UInt8]()
        out.reserveCapacity(Geometry.nibbleTrackSize)
        let gap1 = 48, gap2 = 6, gap3 = 27
        out.append(contentsOf: repeatElement(0xFF, count: gap1))
        for physical in 0..<16 {
            let logical = Interleave.physicalToDOSLogical[physical]
            let t = UInt8(trackNumber), s = UInt8(physical)
            out.append(contentsOf: [0xD5, 0xAA, 0x96])
            out.append(contentsOf: encode44(volume))
            out.append(contentsOf: encode44(t))
            out.append(contentsOf: encode44(s))
            out.append(contentsOf: encode44(volume ^ t ^ s))
            out.append(contentsOf: [0xDE, 0xAA, 0xEB])
            out.append(contentsOf: repeatElement(0xFF, count: gap2))
            out.append(contentsOf: [0xD5, 0xAA, 0xAD])
            let start = base + logical * Geometry.sectorSize
            out.append(contentsOf: encodeSector(track[start..<start + Geometry.sectorSize]))
            out.append(contentsOf: [0xDE, 0xAA, 0xEB])
            out.append(contentsOf: repeatElement(0xFF, count: gap3))
        }
        if out.count < Geometry.nibbleTrackSize {
            out.append(contentsOf: repeatElement(0xFF, count: Geometry.nibbleTrackSize - out.count))
        }
        return Array(out.prefix(Geometry.nibbleTrackSize))
    }

    /// Decode a nibble track into a DOS-ordered 4096-byte track.
    /// Sectors that cannot be found or fail their checksum are left zeroed and
    /// reported in `missing` (DOS logical sector numbers).
    public static func denibblizeTrack(_ nib: ArraySlice<UInt8>) -> (data: [UInt8], missing: [Int]) {
        let track = Array(nib)
        let n = track.count
        var data = [UInt8](repeating: 0, count: Geometry.trackSize)
        var found = Set<Int>()
        guard n > 0 else { return (data, Array(0..<16)) }

        @inline(__always) func at(_ i: Int) -> UInt8 { track[i % n] }

        // Scan one full revolution plus enough to catch a sector straddling the wrap.
        var i = 0
        while i < n {
            if at(i) == 0xD5 && at(i + 1) == 0xAA && at(i + 2) == 0x96 {
                let sector = Int(decode44(at(i + 7), at(i + 8)))
                // Look for the data field shortly after the address field.
                var j = i + 11
                let limit = i + 11 + 64
                while j < limit {
                    if at(j) == 0xD5 && at(j + 1) == 0xAA && at(j + 2) == 0xAD { break }
                    j += 1
                }
                if j < limit && sector < 16 {
                    var nibbles = [UInt8](repeating: 0, count: 343)
                    for k in 0..<343 { nibbles[k] = at(j + 3 + k) }
                    if let decoded = GCR.decodeSector(nibbles) {
                        let logical = Interleave.physicalToDOSLogical[sector]
                        if !found.contains(logical) {
                            data.replaceSubrange(logical * 256..<(logical + 1) * 256, with: decoded)
                            found.insert(logical)
                        }
                    }
                    i = j + 3
                    continue
                }
            }
            i += 1
        }
        let missing = (0..<16).filter { !found.contains($0) }
        return (data, missing)
    }

    /// Convert a full DOS-ordered 140K image to a .nib image.
    public static func nibblize(dosOrderImage image: [UInt8], volume: UInt8 = 254) -> [UInt8] {
        precondition(image.count == Geometry.size140K)
        var out = [UInt8]()
        out.reserveCapacity(Geometry.nibbleImageSize)
        for t in 0..<Geometry.tracks {
            let start = t * Geometry.trackSize
            out.append(contentsOf: nibblizeTrack(dosOrderTrack: image[start..<start + Geometry.trackSize], trackNumber: t, volume: volume))
        }
        return out
    }
}
