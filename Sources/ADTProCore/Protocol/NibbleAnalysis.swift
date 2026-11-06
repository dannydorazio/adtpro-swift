// Nibble track analysis.
//
// When an Apple sends a nibble copy of a disk, each track arrives as a raw
// 13312-byte read (about two revolutions) that starts at the beginning of a
// data area. The track is split into Field / Bitslip / Gap areas; because the
// buffer holds more than one revolution, the areas repeat, and the distance
// to the best repeat is the track length. The track is then rotated so the
// longest gap sits at the track's start and padded to 6656 bytes.
//
// Ported from the Java host, with three defects of the original fixed:
//  - field contents were compared from the start of the whole buffer instead
//    of from each field's own start, so only lengths were ever compared;
//  - the gap length ratio used integer division (always 0 or 1);
//  - a type mismatch between areas was immediately overwritten.

public struct NibbleTrack: Sendable, Equatable {
    public static let length = 6656
    public var accuracy: Double = 0
    public var foundLength: Int = 0
    public var data = [UInt8](repeating: 0, count: NibbleTrack.length)
}

public enum NibbleAnalysis {
    static let minimumTrackLength = 4500
    static let bitslipLength = 4

    enum AreaType { case gap, field, bitslip }

    struct Area {
        var type: AreaType
        var start: Int
        var length: Int
    }

    /// Known ways a gap can begin, depending on where the read synchronised.
    /// See Beneath Apple DOS, page 3-9.
    static let gapSequences: [[UInt8]] = [
        [0xFF, 0xFF, 0xFF, 0xFF],
        [0xFE, 0xFF, 0xFF, 0xFF, 0xFF],
        [0xFC, 0xFF, 0xFF, 0xFF, 0xFF],
        [0xF9, 0xFE, 0xFF, 0xFF, 0xFF],
        [0xF3, 0xFC, 0xFF, 0xFF, 0xFF],
        [0xE7, 0xF9, 0xFE, 0xFF, 0xFF],
        [0xCF, 0xF3, 0xFC, 0xFF, 0xFF],
        [0x9F, 0xE7, 0xF9, 0xFE, 0xFF],
    ]

    /// Valid disk nibbles (0xCC included for "Alternate Reality: The Dungeon").
    static let validDiskBytes: [Bool] = {
        var valid = [Bool](repeating: false, count: 256)
        let list: [Int] = [
            0x95, 0x96, 0x97, 0x9A, 0x9B, 0x9D, 0x9E, 0x9F, 0xA5, 0xA6, 0xA7, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD,
            0xAE, 0xAF, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF, 0xCA,
            0xCB, 0xCC, 0xCD, 0xCE, 0xCF, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD,
            0xDE, 0xDF, 0xE5, 0xE6, 0xE7, 0xE9, 0xEA, 0xEB, 0xEC, 0xED, 0xEE, 0xEF, 0xF2, 0xF3, 0xF4, 0xF5,
            0xF6, 0xF7, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF,
        ]
        for v in list { valid[v] = true }
        return valid
    }()

    static func buildMap(_ buffer: [UInt8]) -> [Area] {
        enum Mode { case field, tentativeGap, gap }
        var areas: [Area] = []
        var mode = Mode.field
        var areaStart = 0
        var gapBytesSeen = 0
        var tentativeStart = -1
        var sequence = -1
        var i = 0
        while i < buffer.count {
            let byte = buffer[i]
            switch mode {
            case .field:
                if let s = gapSequences.firstIndex(where: { $0[0] == byte }) {
                    sequence = s
                    mode = .tentativeGap
                    tentativeStart = i
                    gapBytesSeen = 1
                }
            case .tentativeGap:
                if byte == gapSequences[sequence][gapBytesSeen] {
                    gapBytesSeen += 1
                    if gapBytesSeen == gapSequences[sequence].count {
                        var bitslipStart = areaStart
                        let fieldLength = i - areaStart - gapBytesSeen - bitslipLength + 1
                        if fieldLength > 0 {
                            areas.append(Area(type: .field, start: areaStart, length: fieldLength))
                            bitslipStart = areaStart + fieldLength
                        }
                        let bitslipLength = i - bitslipStart - gapBytesSeen + 1
                        if bitslipLength > 0 {
                            areas.append(Area(type: .bitslip, start: bitslipStart, length: bitslipLength))
                        }
                        mode = .gap
                        areaStart = i - gapBytesSeen + 1
                    }
                } else {
                    i = tentativeStart   // re-scan from just after the false start
                    mode = .field
                    sequence = -1
                    gapBytesSeen = 0
                }
            case .gap:
                if byte != 0xFF {
                    let length = i - areaStart
                    if length > 0 { areas.append(Area(type: .gap, start: areaStart, length: length)) }
                    mode = .field
                    areaStart = i
                }
            }
            i += 1
        }
        return areas
    }

    static func compareFields(_ a: Area, _ b: Area, in buffer: [UInt8]) -> Double {
        let shorter = min(a.length, b.length)
        let longer = max(a.length, b.length)
        guard longer > 0 else { return 1 }
        var sum = 0.0
        for k in 0..<shorter {
            let x = buffer[a.start + k], y = buffer[b.start + k]
            if x == y {
                sum += 1
            } else if !validDiskBytes[Int(x)] || !validDiskBytes[Int(y)] {
                sum += 0.5   // one side is not even a valid nibble: half credit
            }
        }
        sum += Double(longer - shorter) * 0.5
        return sum / Double(longer)
    }

    /// Likelihood that two areas are the same area one revolution apart, and the
    /// weight that judgement deserves.
    static func sameContents(_ a: Area, _ b: Area, in buffer: [UInt8]) -> (likelihood: Double, weight: Double) {
        if a.type != b.type { return (0, 1) }
        switch a.type {
        case .gap:
            guard a.length > 0, b.length > 0 else { return (0, 0.2) }
            var ratio = Double(a.length) / Double(b.length)
            if ratio > 1 { ratio = 1 / ratio }
            return (ratio, 0.2)
        case .field:
            return (compareFields(a, b, in: buffer), 1)
        case .bitslip:
            return (1, 0)
        }
    }

    static func assessRepeat(startingAt candidate: Int, areas: [Area], buffer: [UInt8]) -> Double {
        var sum = 0.0, weights = 0.0
        for i in 0..<candidate {
            let other = i + candidate
            if other >= areas.count { break }
            let (likelihood, weight) = sameContents(areas[i], areas[other], in: buffer)
            weights += weight
            sum += weight * likelihood
        }
        return weights > 0 ? sum / weights : 0.5
    }

    /// Returns (track length, accuracy); length is -1 when no repeat was found.
    static func determineTrackLength(areas: [Area], buffer: [UInt8]) -> (Int, Double) {
        guard var candidate = areas.firstIndex(where: { $0.type == .field && $0.start >= minimumTrackLength }),
              candidate > 0 else { return (-1, 0) }
        var best = 0.0, bestIndex = 0
        while true {
            let match = assessRepeat(startingAt: candidate, areas: areas, buffer: buffer)
            if match > best { best = match; bestIndex = candidate }
            // Next field candidate, stopping once the track would be too long.
            var next: Int? = nil
            var j = candidate + 1
            while j < areas.count {
                if areas[j].start > NibbleTrack.length { break }
                if areas[j].type == .field { next = j; break }
                j += 1
            }
            guard let n = next else { break }
            candidate = n
        }
        return best > 0 ? (areas[bestIndex].start, best) : (-1, 0)
    }

    static func longestGap(before length: Int, areas: [Area]) -> Int {
        var bestStart = 0, bestLength = 0
        for a in areas where a.start + a.length <= length && a.type == .gap && a.length > bestLength {
            bestLength = a.length
            bestStart = a.start
        }
        return bestStart
    }

    /// Analyse one raw track read. When no plausible track length is found, the
    /// first 6656 bytes are returned as-is with zero accuracy.
    public static func analyze(_ raw: [UInt8]) -> NibbleTrack {
        var track = NibbleTrack()
        let areas = buildMap(raw)
        let (length, accuracy) = determineTrackLength(areas: areas, buffer: raw)
        guard length >= minimumTrackLength && length <= NibbleTrack.length else {
            let n = min(raw.count, NibbleTrack.length)
            track.data.replaceSubrange(0..<n, with: raw[0..<n])
            return track
        }
        track.accuracy = accuracy
        track.foundLength = length

        // Lay out: [0, gapStart) as read, then sync padding to fill out the
        // track, then the rest of the revolution starting at the longest gap.
        let gapStart = longestGap(before: length, areas: areas)
        let padding = NibbleTrack.length - length
        var out = [UInt8]()
        out.reserveCapacity(NibbleTrack.length)
        out.append(contentsOf: raw[0..<gapStart])
        out.append(contentsOf: repeatElement(0xFF, count: padding))
        out.append(contentsOf: raw[gapStart..<length])
        track.data = out
        return track
    }
}
