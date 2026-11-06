import Foundation

public enum ProDOSError: Error, Equatable, CustomStringConvertible {
    case notProDOS
    case invalidName(String)
    case fileNotFound(String)
    case fileExists(String)
    case diskFull
    case directoryFull
    case fileTooLarge

    public var description: String {
        switch self {
        case .notProDOS: return "Not a ProDOS volume"
        case .invalidName(let n): return "Invalid ProDOS name: \(n)"
        case .fileNotFound(let n): return "File not found: \(n)"
        case .fileExists(let n): return "File already exists: \(n)"
        case .diskFull: return "Disk full"
        case .directoryFull: return "Volume directory full"
        case .fileTooLarge: return "File too large for ProDOS"
        }
    }
}

/// Encoding of ProDOS dates and times.
public enum ProDOSDate {
    /// Four bytes: date (lo, hi) then time (lo, hi), as stored in directory entries.
    public static func directoryStamp(_ date: Date = Date(), calendar: Calendar = .current) -> [UInt8] {
        let (d, t) = words(date, calendar: calendar)
        return [UInt8(d & 0xFF), UInt8(d >> 8), UInt8(t & 0xFF), UInt8(t >> 8)]
    }

    /// Four bytes: time (lo, hi) then date (lo, hi), the order ProDOS keeps at $BF90-$BF93
    /// (and the order the virtual drive protocol sends them in).
    public static func globalPageStamp(_ date: Date = Date(), calendar: Calendar = .current) -> [UInt8] {
        let (d, t) = words(date, calendar: calendar)
        return [UInt8(t & 0xFF), UInt8(t >> 8), UInt8(d & 0xFF), UInt8(d >> 8)]
    }

    static func words(_ date: Date, calendar: Calendar) -> (date: Int, time: Int) {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let year = (c.year ?? 2000) % 100
        let d = (year << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1)
        let t = ((c.hour ?? 0) << 8) | (c.minute ?? 0)
        return (d & 0xFFFF, t & 0xFFFF)
    }
}

public struct ProDOSEntry: Sendable, Equatable {
    public var name: String
    public var storageType: Int
    public var fileType: UInt8
    public var auxType: UInt16
    public var keyPointer: Int
    public var blocksUsed: Int
    public var eof: Int
}

/// Minimal ProDOS volume access: create blank volumes, rename them, and add,
/// read, delete or list files in the volume directory.
public struct ProDOSVolume {
    public let image: DiskImage

    public init(image: DiskImage) throws {
        self.image = image
        guard DiskImage.isProDOSVolume(block2: try image.readBlock(2)) else { throw ProDOSError.notProDOS }
    }

    // MARK: Names

    public static func normalizedName(_ name: String) throws -> String {
        let upper = name.uppercased()
        let chars = Array(upper)
        guard (1...15).contains(chars.count), let first = chars.first, first.isASCII, first.isLetter,
              chars.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") })
        else { throw ProDOSError.invalidName(name) }
        return upper
    }

    // MARK: Creating volumes

    /// Build an empty ProDOS volume of `blocks` blocks in ProDOS order.
    public static func blankImageBytes(volumeName: String, blocks: Int, date: Date = Date()) throws -> [UInt8] {
        let name = try normalizedName(volumeName)
        precondition(blocks >= 16 && blocks <= 65535)
        var image = [UInt8](repeating: 0, count: blocks * 512)

        // Volume directory: key block 2, then 3, 4, 5.
        let dirBlocks = [2, 3, 4, 5]
        for (i, b) in dirBlocks.enumerated() {
            let o = b * 512
            let prev = i == 0 ? 0 : dirBlocks[i - 1]
            let next = i == dirBlocks.count - 1 ? 0 : dirBlocks[i + 1]
            image[o] = UInt8(prev & 0xFF); image[o + 1] = UInt8(prev >> 8)
            image[o + 2] = UInt8(next & 0xFF); image[o + 3] = UInt8(next >> 8)
        }
        let bitmapStart = 6
        let bitmapBlocks = (blocks + 4095) / 4096
        let h = 2 * 512 + 4
        image[h] = 0xF0 | UInt8(name.count)
        for (i, c) in name.utf8.enumerated() { image[h + 1 + i] = c }
        let stamp = ProDOSDate.directoryStamp(date)
        image.replaceSubrange(h + 24..<h + 28, with: stamp)
        image[h + 28] = 0          // version
        image[h + 29] = 0          // min version
        image[h + 30] = 0xC3       // access
        image[h + 31] = 0x27       // entry length
        image[h + 32] = 0x0D       // entries per block
        image[h + 33] = 0; image[h + 34] = 0
        image[h + 35] = UInt8(bitmapStart & 0xFF); image[h + 36] = UInt8(bitmapStart >> 8)
        image[h + 37] = UInt8(blocks & 0xFF); image[h + 38] = UInt8(blocks >> 8)

        // Volume bitmap: 1 = free. Blocks 0 ... end of bitmap are in use.
        let firstFree = bitmapStart + bitmapBlocks
        for block in firstFree..<blocks {
            let byte = bitmapStart * 512 + block / 8
            image[byte] |= UInt8(0x80 >> (block % 8))
        }
        return image
    }

    /// Create a blank ProDOS volume file. `.2mg` paths get a 2IMG wrapper; a 140K
    /// `.dsk`/`.do` path is written in DOS order; anything else in ProDOS order.
    @discardableResult
    public static func createImage(at path: String, volumeName: String, blocks: Int) throws -> DiskImage {
        let raw = try blankImageBytes(volumeName: volumeName, blocks: blocks)
        let ext = (path as NSString).pathExtension.lowercased()
        let image: DiskImage
        if ext == "2mg" || ext == "2img" {
            image = DiskImage(bytes: raw, order: .prodos, path: path, twoIMG: .makeProDOS(blocks: blocks))
        } else {
            image = DiskImage(bytes: raw, order: .prodos, path: path)
            if (ext == "dsk" || ext == "do") && raw.count == Geometry.size140K {
                image.convertToDOSOrder()
            }
        }
        try image.save()
        return image
    }

    // MARK: Volume header

    public var volumeName: String {
        get throws {
            let b = try image.readBlock(2)
            let len = Int(b[4] & 0x0F)
            return String(decoding: b[5..<5 + len], as: UTF8.self)
        }
    }

    public var totalBlocks: Int {
        get throws {
            let b = try image.readBlock(2)
            return Int(b[4 + 37]) | Int(b[4 + 38]) << 8
        }
    }

    public func rename(to newName: String) throws {
        let name = try Self.normalizedName(newName)
        var b = try image.readBlock(2)
        b[4] = 0xF0 | UInt8(name.count)
        for i in 0..<15 { b[5 + i] = 0 }
        for (i, c) in name.utf8.enumerated() { b[5 + i] = c }
        try image.writeBlock(2, b)
    }

    // MARK: Bitmap

    private func bitmapLocation() throws -> (start: Int, total: Int) {
        let b = try image.readBlock(2)
        let start = Int(b[4 + 35]) | Int(b[4 + 36]) << 8
        let total = Int(b[4 + 37]) | Int(b[4 + 38]) << 8
        return (start, total)
    }

    private func isFree(_ block: Int) throws -> Bool {
        let (start, _) = try bitmapLocation()
        let bitmap = try image.readBlock(start + block / 4096)
        let within = block % 4096
        return bitmap[within / 8] & UInt8(0x80 >> (within % 8)) != 0
    }

    private func setFree(_ block: Int, _ free: Bool) throws {
        let (start, _) = try bitmapLocation()
        let bitmapBlock = start + block / 4096
        var bitmap = try image.readBlock(bitmapBlock)
        let within = block % 4096
        let mask = UInt8(0x80 >> (within % 8))
        if free { bitmap[within / 8] |= mask } else { bitmap[within / 8] &= ~mask }
        try image.writeBlock(bitmapBlock, bitmap)
    }

    public func freeBlockCount() throws -> Int {
        let (_, total) = try bitmapLocation()
        var count = 0
        for b in 0..<total where try isFree(b) { count += 1 }
        return count
    }

    private func allocate(_ count: Int) throws -> [Int] {
        let (_, total) = try bitmapLocation()
        var result: [Int] = []
        var block = 0
        while result.count < count && block < total {
            if try isFree(block) { result.append(block) }
            block += 1
        }
        guard result.count == count else { throw ProDOSError.diskFull }
        for b in result { try setFree(b, false) }
        return result
    }

    // MARK: Directory

    private struct Slot { var block: Int; var offset: Int }

    private func directorySlots() throws -> [(Slot, [UInt8])] {
        var result: [(Slot, [UInt8])] = []
        var block = 2
        var first = true
        var visited = Set<Int>()
        while block != 0 && !visited.contains(block) {
            visited.insert(block)
            let b = try image.readBlock(block)
            for i in (first ? 1 : 0)..<13 {
                let o = 4 + i * 0x27
                result.append((Slot(block: block, offset: o), Array(b[o..<o + 0x27])))
            }
            first = false
            block = Int(b[2]) | Int(b[3]) << 8
        }
        return result
    }

    private static func parse(_ e: [UInt8]) -> ProDOSEntry? {
        let storage = Int(e[0] >> 4)
        guard storage != 0 else { return nil }
        let len = Int(e[0] & 0x0F)
        return ProDOSEntry(
            name: String(decoding: e[1..<1 + len], as: UTF8.self),
            storageType: storage,
            fileType: e[16],
            auxType: UInt16(e[31]) | UInt16(e[32]) << 8,
            keyPointer: Int(e[17]) | Int(e[18]) << 8,
            blocksUsed: Int(e[19]) | Int(e[20]) << 8,
            eof: Int(e[21]) | Int(e[22]) << 8 | Int(e[23]) << 16
        )
    }

    public func entries() throws -> [ProDOSEntry] {
        try directorySlots().compactMap { Self.parse($0.1) }
    }

    public func entry(named name: String) throws -> ProDOSEntry? {
        let upper = name.uppercased()
        return try entries().first { $0.name.uppercased() == upper }
    }

    private func adjustFileCount(by delta: Int) throws {
        var b = try image.readBlock(2)
        let count = (Int(b[4 + 33]) | Int(b[4 + 34]) << 8) + delta
        b[4 + 33] = UInt8(count & 0xFF); b[4 + 34] = UInt8((count >> 8) & 0xFF)
        try image.writeBlock(2, b)
    }

    // MARK: Files

    /// Blocks holding file data for an entry, plus its index blocks.
    private func fileBlocks(_ e: ProDOSEntry) throws -> (data: [Int], index: [Int]) {
        func indexPointers(_ block: Int) throws -> [Int] {
            let b = try image.readBlock(block)
            return (0..<256).map { Int(b[$0]) | Int(b[256 + $0]) << 8 }
        }
        switch e.storageType {
        case 1:
            return ([e.keyPointer], [])
        case 2:
            return (try indexPointers(e.keyPointer).filter { $0 != 0 }, [e.keyPointer])
        case 3:
            var data: [Int] = [], index: [Int] = [e.keyPointer]
            for sub in try indexPointers(e.keyPointer) where sub != 0 {
                index.append(sub)
                data.append(contentsOf: try indexPointers(sub).filter { $0 != 0 })
            }
            return (data, index)
        default:
            return ([], [])
        }
    }

    public func readFile(named name: String) throws -> [UInt8] {
        guard let e = try entry(named: name) else { throw ProDOSError.fileNotFound(name) }
        var out: [UInt8] = []
        for b in try fileBlocks(e).data { out.append(contentsOf: try image.readBlock(b)) }
        return Array(out.prefix(e.eof))
    }

    public func deleteFile(named name: String) throws {
        let upper = name.uppercased()
        for (slot, raw) in try directorySlots() {
            guard let e = Self.parse(raw), e.name.uppercased() == upper else { continue }
            let (data, index) = try fileBlocks(e)
            for b in data + index { try setFree(b, true) }
            var block = try image.readBlock(slot.block)
            block[slot.offset] = 0
            try image.writeBlock(slot.block, block)
            try adjustFileCount(by: -1)
            return
        }
        throw ProDOSError.fileNotFound(name)
    }

    /// Add a file to the volume directory, replacing any file of the same name
    /// when `replace` is true.
    public func addFile(named rawName: String, contents: [UInt8], fileType: UInt8, auxType: UInt16,
                        replace: Bool = true, date: Date = Date()) throws {
        let name = try Self.normalizedName(rawName)
        if try entry(named: name) != nil {
            guard replace else { throw ProDOSError.fileExists(name) }
            try deleteFile(named: name)
        }
        guard contents.count <= 0xFFFFFF else { throw ProDOSError.fileTooLarge }

        let dataBlockCount = max(1, (contents.count + 511) / 512)
        let storageType: Int
        let indexBlockCount: Int
        switch dataBlockCount {
        case 1: storageType = 1; indexBlockCount = 0
        case 2...256: storageType = 2; indexBlockCount = 1
        default: storageType = 3; indexBlockCount = 1 + (dataBlockCount + 255) / 256
        }

        guard let freeSlot = try directorySlots().first(where: { Self.parse($0.1) == nil })?.0 else {
            throw ProDOSError.directoryFull
        }
        let blocks = try allocate(dataBlockCount + indexBlockCount)
        let indexBlocks = Array(blocks.prefix(indexBlockCount))
        let dataBlocks = Array(blocks.dropFirst(indexBlockCount))

        for (i, b) in dataBlocks.enumerated() {
            var chunk = [UInt8](repeating: 0, count: 512)
            let start = i * 512
            if start < contents.count {
                let end = min(start + 512, contents.count)
                chunk.replaceSubrange(0..<end - start, with: contents[start..<end])
            }
            try image.writeBlock(b, chunk)
        }

        func indexBlock(_ pointers: ArraySlice<Int>) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: 512)
            for (i, p) in pointers.enumerated() {
                b[i] = UInt8(p & 0xFF); b[256 + i] = UInt8(p >> 8)
            }
            return b
        }

        let keyBlock: Int
        switch storageType {
        case 1:
            keyBlock = dataBlocks[0]
        case 2:
            keyBlock = indexBlocks[0]
            try image.writeBlock(keyBlock, indexBlock(dataBlocks[...]))
        default:
            keyBlock = indexBlocks[0]
            let subIndexes = Array(indexBlocks.dropFirst())
            for (i, sub) in subIndexes.enumerated() {
                let slice = dataBlocks[(i * 256)..<min((i + 1) * 256, dataBlocks.count)]
                try image.writeBlock(sub, indexBlock(slice))
            }
            try image.writeBlock(keyBlock, indexBlock(subIndexes[...]))
        }

        var entry = [UInt8](repeating: 0, count: 0x27)
        entry[0] = UInt8(storageType << 4) | UInt8(name.count)
        for (i, c) in name.utf8.enumerated() { entry[1 + i] = c }
        entry[16] = fileType
        entry[17] = UInt8(keyBlock & 0xFF); entry[18] = UInt8(keyBlock >> 8)
        let used = dataBlockCount + indexBlockCount
        entry[19] = UInt8(used & 0xFF); entry[20] = UInt8(used >> 8)
        entry[21] = UInt8(contents.count & 0xFF)
        entry[22] = UInt8((contents.count >> 8) & 0xFF)
        entry[23] = UInt8((contents.count >> 16) & 0xFF)
        let stamp = ProDOSDate.directoryStamp(date)
        entry.replaceSubrange(24..<28, with: stamp)
        entry[28] = 0; entry[29] = 0
        entry[30] = 0xE3
        entry[31] = UInt8(auxType & 0xFF); entry[32] = UInt8(auxType >> 8)
        entry.replaceSubrange(33..<37, with: stamp)
        entry[37] = 2; entry[38] = 0   // header pointer: volume directory key block

        var dirBlock = try image.readBlock(freeSlot.block)
        dirBlock.replaceSubrange(freeSlot.offset..<freeSlot.offset + 0x27, with: entry)
        try image.writeBlock(freeSlot.block, dirBlock)
        try adjustFileCount(by: 1)
    }
}

public extension ProDOSVolume {
    /// Common ProDOS file types by their conventional abbreviations.
    static func fileType(named abbreviation: String) -> UInt8? {
        switch abbreviation.uppercased() {
        case "TXT": return 0x04
        case "BIN": return 0x06
        case "DIR": return 0x0F
        case "PCD": return 0x02   // Apple /// Pascal code (used for SOS driver files)
        case "BAS": return 0xFC
        case "VAR": return 0xFD
        case "REL": return 0xFE
        case "SYS": return 0xFF
        case "SOS": return 0x0C
        default:
            if abbreviation.hasPrefix("$"), let v = UInt8(abbreviation.dropFirst(), radix: 16) { return v }
            return nil
        }
    }
}
