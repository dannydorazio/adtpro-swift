import Foundation

public enum DiskImageError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case unreadable(String)
    case unrecognizedFormat(String)
    case blockOutOfRange(Int)
    case readOnly(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .notFound(let p): return "File not found: \(p)"
        case .unreadable(let p): return "Unable to read: \(p)"
        case .unrecognizedFormat(let p): return "Not a recognized disk image: \(p)"
        case .blockOutOfRange(let b): return "Block \(b) is out of range"
        case .readOnly(let p): return "Image cannot be written: \(p)"
        case .writeFailed(let p): return "Unable to write: \(p)"
        }
    }
}

/// An Apple II disk image held in memory, addressed by ProDOS block.
///
/// Supports DOS-order and ProDOS-order sector images (.dsk/.do/.po/.hdv), 2IMG
/// containers (.2mg/.2img) and nibble images (.nib, read-only).
public final class DiskImage {
    public let path: String
    public private(set) var order: SectorOrder
    public private(set) var twoIMG: TwoIMGHeader?
    /// The image payload (excluding any 2IMG header).
    public private(set) var bytes: [UInt8]
    private var decodedNibbleTracks: [Int: [UInt8]] = [:]

    public init(bytes: [UInt8], order: SectorOrder, path: String = "", twoIMG: TwoIMGHeader? = nil) {
        self.bytes = bytes
        self.order = order
        self.path = path
        self.twoIMG = twoIMG
    }

    public var fileName: String { (path as NSString).lastPathComponent }

    public var isNibble: Bool { order == .nibble }

    /// Number of 512-byte ProDOS blocks the image presents.
    public var blockCount: Int {
        switch order {
        case .nibble: return Geometry.blocks140K
        case .dos, .prodos: return bytes.count / Geometry.blockSize
        }
    }

    // MARK: Opening

    /// Open an image from disk, detecting its format from the extension, size and contents.
    public static func open(path: String) throws -> DiskImage {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw DiskImageError.notFound(path)
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw DiskImageError.unreadable(path)
        }
        return try DiskImage(fileBytes: [UInt8](data), path: path)
    }

    /// Interpret raw file contents as a disk image.
    public convenience init(fileBytes file: [UInt8], path: String) throws {
        let ext = (path as NSString).pathExtension.lowercased()

        if let (header, payload) = TwoIMGHeader.parse(file) {
            guard let order = header.sectorOrder else { throw DiskImageError.unrecognizedFormat(path) }
            if order == .nibble && payload.count != Geometry.nibbleImageSize {
                throw DiskImageError.unrecognizedFormat(path)
            }
            self.init(bytes: payload, order: order, path: path, twoIMG: header)
            return
        }

        let size = file.count
        let order: SectorOrder
        switch ext {
        case "2mg", "2img":
            throw DiskImageError.unrecognizedFormat(path)
        case "nib":
            guard size == Geometry.nibbleImageSize else { throw DiskImageError.unrecognizedFormat(path) }
            order = .nibble
        case "po", "hdv":
            guard size > 0, size % Geometry.blockSize == 0 else { throw DiskImageError.unrecognizedFormat(path) }
            order = size == Geometry.size140K ? DiskImage.detectOrder(file, preferred: .prodos) : .prodos
        case "dsk", "do":
            if size == Geometry.size140K {
                order = DiskImage.detectOrder(file, preferred: .dos)
            } else if size > 0 && size % Geometry.blockSize == 0 {
                order = .prodos
            } else {
                throw DiskImageError.unrecognizedFormat(path)
            }
        default:
            if size == Geometry.size140K {
                order = DiskImage.detectOrder(file, preferred: .dos)
            } else if size == Geometry.nibbleImageSize {
                order = .nibble
            } else if size > Geometry.size140K && size % Geometry.blockSize == 0 {
                order = .prodos
            } else {
                throw DiskImageError.unrecognizedFormat(path)
            }
        }
        self.init(bytes: file, order: order, path: path)
    }

    // MARK: Order detection (140K images only)

    /// Some images carry the "wrong" extension for their sector order. Check the
    /// file system structures under the preferred order first, then the other.
    static func detectOrder(_ image: [UInt8], preferred: SectorOrder) -> SectorOrder {
        let alternate: SectorOrder = preferred == .dos ? .prodos : .dos
        if looksValid(image, order: preferred) { return preferred }
        if looksValid(image, order: alternate) { return alternate }
        return preferred
    }

    static func looksValid(_ image: [UInt8], order: SectorOrder) -> Bool {
        isProDOSVolume(block2: block(2, of: image, order: order)) || isDOS33(vtoc: dosSector(track: 17, sector: 0, of: image, order: order))
    }

    static func isProDOSVolume(block2 b: [UInt8]) -> Bool {
        guard b.count == 512 else { return false }
        return b[0] == 0 && b[1] == 0 && (b[4] >> 4) == 0xF && (b[4] & 0x0F) > 0 && b[0x23] == 0x27 && b[0x24] == 0x0D
    }

    static func isDOS33(vtoc v: [UInt8]) -> Bool {
        guard v.count == 256 else { return false }
        return v[1] == 17 && v[2] < 16 && v[0x27] == 122 && v[0x34] == 35 && v[0x35] == 16
    }

    static func block(_ n: Int, of image: [UInt8], order: SectorOrder) -> [UInt8] {
        switch order {
        case .prodos:
            let o = n * 512
            guard o + 512 <= image.count else { return [] }
            return Array(image[o..<o + 512])
        case .dos:
            guard image.count == Geometry.size140K, n < Geometry.blocks140K else { return [] }
            let (a, b) = Interleave.dosOffsets(forBlock: n)
            return Array(image[a..<a + 256]) + Array(image[b..<b + 256])
        case .nibble:
            return []
        }
    }

    static func dosSector(track: Int, sector: Int, of image: [UInt8], order: SectorOrder) -> [UInt8] {
        guard image.count == Geometry.size140K else { return [] }
        switch order {
        case .dos:
            let o = track * Geometry.trackSize + sector * 256
            return Array(image[o..<o + 256])
        case .prodos:
            for (k, pair) in Interleave.blockToDOSSectors.enumerated() {
                if pair.0 == sector || pair.1 == sector {
                    let o = (track * 8 + k) * 512 + (pair.0 == sector ? 0 : 256)
                    return Array(image[o..<o + 256])
                }
            }
            return []
        case .nibble:
            return []
        }
    }

    // MARK: Block access

    public func readBlock(_ n: Int) throws -> [UInt8] {
        guard n >= 0 && n < blockCount else { throw DiskImageError.blockOutOfRange(n) }
        switch order {
        case .prodos:
            let o = n * 512
            return Array(bytes[o..<o + 512])
        case .dos:
            let (a, b) = Interleave.dosOffsets(forBlock: n)
            return Array(bytes[a..<a + 256]) + Array(bytes[b..<b + 256])
        case .nibble:
            let track = n / 8
            let data = decodedTrack(track)
            let (s1, s2) = Interleave.blockToDOSSectors[n % 8]
            return Array(data[s1 * 256..<s1 * 256 + 256]) + Array(data[s2 * 256..<s2 * 256 + 256])
        }
    }

    private func decodedTrack(_ track: Int) -> [UInt8] {
        if let cached = decodedNibbleTracks[track] { return cached }
        let start = track * Geometry.nibbleTrackSize
        let decoded = GCR.denibblizeTrack(bytes[start..<start + Geometry.nibbleTrackSize]).data
        decodedNibbleTracks[track] = decoded
        return decoded
    }

    /// File offsets (within the payload) of the 512 bytes making up block `n`, as
    /// one or two contiguous runs.
    private func payloadRuns(forBlock n: Int) -> [(offset: Int, length: Int)] {
        switch order {
        case .prodos: return [(n * 512, 512)]
        case .dos:
            let (a, b) = Interleave.dosOffsets(forBlock: n)
            return [(a, 256), (b, 256)]
        case .nibble: return []
        }
    }

    /// Update a block in memory.
    public func writeBlock(_ n: Int, _ data: [UInt8]) throws {
        guard order != .nibble else { throw DiskImageError.readOnly(path) }
        guard n >= 0 && n < blockCount else { throw DiskImageError.blockOutOfRange(n) }
        precondition(data.count == 512)
        var cursor = 0
        for run in payloadRuns(forBlock: n) {
            bytes.replaceSubrange(run.offset..<run.offset + run.length, with: data[cursor..<cursor + run.length])
            cursor += run.length
        }
    }

    /// Update a block in memory and write just that block back to the file.
    /// Used by the virtual drive server so each write is durable without
    /// rewriting the whole image.
    public func writeBlockThrough(_ n: Int, _ data: [UInt8]) throws {
        try writeBlock(n, data)
        guard let handle = FileHandle(forWritingAtPath: path) else { throw DiskImageError.writeFailed(path) }
        defer { try? handle.close() }
        let base = twoIMG?.dataOffset ?? 0
        do {
            for run in payloadRuns(forBlock: n) {
                try handle.seek(toOffset: UInt64(base + run.offset))
                try handle.write(contentsOf: bytes[run.offset..<run.offset + run.length])
            }
            try handle.synchronize()
        } catch {
            throw DiskImageError.writeFailed(path)
        }
    }

    // MARK: Conversions and saving

    /// Rearrange a 140K image into DOS order (no-op if already DOS order).
    public func convertToDOSOrder() {
        guard order == .prodos, bytes.count == Geometry.size140K else { return }
        bytes = Interleave.prodosToDOS(bytes)
        order = .dos
    }

    /// The complete file contents, including any 2IMG wrapper.
    public var fileBytes: [UInt8] {
        guard var header = twoIMG else { return bytes }
        // Keep the recorded data length in sync with the payload.
        var leading = header.leadingBytes
        if leading.count >= 32 {
            let len = bytes.count
            leading[28] = UInt8(len & 0xFF); leading[29] = UInt8((len >> 8) & 0xFF)
            leading[30] = UInt8((len >> 16) & 0xFF); leading[31] = UInt8((len >> 24) & 0xFF)
        }
        header.leadingBytes = leading
        return header.leadingBytes + bytes + header.trailingBytes
    }

    public func save() throws {
        try save(to: path)
    }

    public func save(to destination: String) throws {
        do {
            try Data(fileBytes).write(to: URL(fileURLWithPath: destination), options: .atomic)
        } catch {
            throw DiskImageError.writeFailed(destination)
        }
    }
}
