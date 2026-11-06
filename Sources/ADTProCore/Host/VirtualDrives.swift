import DiskImage
import Foundation

/// The two disk images served to VSDrive/VEDrive clients.
///
/// By default drive 1 is `Virtual.po` and drive 2 is `Virtual2.po` in the
/// current working directory (so they follow the working directory as it
/// changes), created as blank 800K ProDOS volumes when missing. Either drive
/// can instead be pointed at a specific image. Images are reloaded when they
/// change on disk, so they can be edited on the host between accesses.
public final class VirtualDrives: @unchecked Sendable {
    public static let defaultNames = ["Virtual.po", "Virtual2.po"]
    public static let defaultVolumeNames = ["Hosted.VDrive1", "Hosted.VDrive2"]

    private struct Mounted {
        var path: String
        var image: DiskImage
        var modified: Date?
    }

    private let lock = NSLock()
    private let fileHost: FileHost
    private var overrides: [String?] = [nil, nil]
    private var mounted: [Mounted?] = [nil, nil]

    public init(fileHost: FileHost, drive1: String? = nil, drive2: String? = nil) {
        self.fileHost = fileHost
        overrides = [drive1, drive2]
    }

    /// Point a drive (1 or 2) at an image, or nil for the working-directory default.
    public func setImage(_ path: String?, forDrive drive: Int) {
        lock.withLock {
            overrides[drive - 1] = path
            mounted[drive - 1] = nil
        }
    }

    public func imagePath(forDrive drive: Int) -> String {
        lock.withLock { resolvedPath(drive) }
    }

    private func resolvedPath(_ drive: Int) -> String {
        if let explicit = overrides[drive - 1] { return explicit }
        return fileHost.workingDirectory + Self.defaultNames[drive - 1]
    }

    private static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func image(_ drive: Int) throws -> DiskImage {
        let path = resolvedPath(drive)
        let modified = Self.modificationDate(path)
        if let m = mounted[drive - 1], m.path == path, m.modified == modified, modified != nil {
            return m.image
        }
        if !FileManager.default.fileExists(atPath: path) {
            Log.shared.info("Creating virtual drive image \(path)")
            try ProDOSVolume.createImage(at: path, volumeName: Self.defaultVolumeNames[drive - 1], blocks: 1600)
        }
        let image = try DiskImage.open(path: path)
        mounted[drive - 1] = Mounted(path: path, image: image, modified: Self.modificationDate(path))
        return image
    }

    public func readBlock(drive: Int, block: Int) throws -> [UInt8] {
        try lock.withLock { try image(drive).readBlock(block) }
    }

    public func writeBlock(drive: Int, block: Int, data: [UInt8]) throws {
        try lock.withLock {
            let img = try image(drive)
            try img.writeBlockThrough(block, data)
            mounted[drive - 1]?.modified = Self.modificationDate(img.path)
        }
    }
}
