import Foundation
import Testing
@testable import DiskImage

private func scratchDirectory() throws -> String {
    let dir = NSTemporaryDirectory() + "adtpro-tests-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// A deterministic 140K image whose bytes encode their own block/offset, in ProDOS order.
private func patternedProDOSOrderImage() -> [UInt8] {
    var po = [UInt8](repeating: 0, count: Geometry.size140K)
    for i in 0..<po.count {
        let block = i / 512
        po[i] = UInt8(truncatingIfNeeded: block &* 7 &+ (i % 512) &* 13)
    }
    return po
}

@Suite struct SectorOrderTests {
    @Test func roundTripsBetweenOrders() {
        let po = patternedProDOSOrderImage()
        let dos = Interleave.prodosToDOS(po)
        #expect(dos != po)
        #expect(Interleave.dosToProDOS(dos) == po)
    }

    @Test func blockZeroMapsToSectorsZeroAndFourteen() {
        let (a, b) = Interleave.dosOffsets(forBlock: 0)
        #expect(a == 0)
        #expect(b == 14 * 256)
        let (c, d) = Interleave.dosOffsets(forBlock: 15)   // track 1, block 7 -> sectors 1, 15
        #expect(c == 4096 + 1 * 256)
        #expect(d == 4096 + 15 * 256)
    }

    @Test func dosOrderedImageReadsTheSameBlocks() throws {
        let po = patternedProDOSOrderImage()
        let poImage = DiskImage(bytes: po, order: .prodos)
        let dosImage = DiskImage(bytes: Interleave.prodosToDOS(po), order: .dos)
        for block in [0, 1, 2, 7, 8, 100, 279] {
            #expect(try poImage.readBlock(block) == dosImage.readBlock(block))
        }
    }

    @Test func physicalAndLogicalTablesAreInverses() {
        for logical in 0..<16 {
            #expect(Interleave.physicalToDOSLogical[Interleave.dosLogicalToPhysical[logical]] == logical)
        }
    }
}

@Suite struct GCRTests {
    @Test func sectorRoundTrip() {
        var sector = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 { sector[i] = UInt8(truncatingIfNeeded: i &* 37 &+ 11) }
        let nibbles = GCR.encodeSector(sector[...])
        #expect(nibbles.count == 343)
        #expect(nibbles.allSatisfy { $0 >= 0x96 })
        #expect(GCR.decodeSector(nibbles) == sector)
    }

    @Test func allZeroSectorEncodesToKnownNibbles() {
        // An all-zero sector produces nothing but $96 (the encoding of 0), DOS 3.3 style.
        let nibbles = GCR.encodeSector([UInt8](repeating: 0, count: 256)[...])
        #expect(nibbles.allSatisfy { $0 == 0x96 })
    }

    @Test func corruptedChecksumIsRejected() {
        var nibbles = GCR.encodeSector([UInt8](repeating: 0x5A, count: 256)[...])
        nibbles[100] = GCR.encodeTable[(Int(GCR.decodeTable[Int(nibbles[100])]) + 1) % 64]
        #expect(GCR.decodeSector(nibbles) == nil)
    }

    @Test func wholeImageNibblizesAndDecodes() throws {
        let dos = Interleave.prodosToDOS(patternedProDOSOrderImage())
        let nib = GCR.nibblize(dosOrderImage: dos)
        #expect(nib.count == Geometry.nibbleImageSize)
        let image = DiskImage(bytes: nib, order: .nibble)
        let reference = DiskImage(bytes: dos, order: .dos)
        for block in 0..<Geometry.blocks140K {
            #expect(try image.readBlock(block) == reference.readBlock(block))
        }
    }

    @Test func trackDecodesWhenSectorStraddlesTheWrap() {
        let dos = Interleave.prodosToDOS(patternedProDOSOrderImage())
        let track = GCR.nibblizeTrack(dosOrderTrack: dos[0..<4096], trackNumber: 0)
        // Rotate so the data field of some sector wraps around the end of the buffer.
        let rotated = Array(track[300...] + track[..<300])
        let (data, missing) = GCR.denibblizeTrack(rotated[...])
        #expect(missing.isEmpty)
        #expect(data == Array(dos[0..<4096]))
    }
}

@Suite struct DiskImageFormatTests {
    @Test func detectsFormatsByExtensionAndSize() throws {
        let po = try ProDOSVolume.blankImageBytes(volumeName: "TEST", blocks: 280)
        #expect(try DiskImage(fileBytes: po, path: "a.po").order == .prodos)
        #expect(try DiskImage(fileBytes: Interleave.prodosToDOS(po), path: "a.dsk").order == .dos)
        #expect(try DiskImage(fileBytes: [UInt8](repeating: 0, count: Geometry.nibbleImageSize), path: "a.nib").order == .nibble)
        #expect(try DiskImage(fileBytes: [UInt8](repeating: 0, count: 819200), path: "a.hdv").blockCount == 1600)
        #expect(throws: DiskImageError.self) { try DiskImage(fileBytes: [1, 2, 3], path: "readme.txt") }
        #expect(throws: DiskImageError.self) { try DiskImage(fileBytes: [UInt8](repeating: 0, count: 100), path: "a.po") }
    }

    @Test func misnamedProDOSOrderDskIsDetected() throws {
        // A ProDOS-ordered volume saved with a .dsk extension.
        let po = try ProDOSVolume.blankImageBytes(volumeName: "MISNAMED", blocks: 280)
        let image = try DiskImage(fileBytes: po, path: "wrong.dsk")
        #expect(image.order == .prodos)
        #expect(try ProDOSVolume(image: image).volumeName == "MISNAMED")
    }

    @Test func twoIMGRoundTrip() throws {
        let dir = try scratchDirectory()
        let path = dir + "/vol.2mg"
        try ProDOSVolume.createImage(at: path, volumeName: "TWOIMG", blocks: 1600)
        let reopened = try DiskImage.open(path: path)
        #expect(reopened.twoIMG != nil)
        #expect(reopened.blockCount == 1600)
        #expect(try ProDOSVolume(image: reopened).volumeName == "TWOIMG")
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int
        #expect(size == 64 + 819200)
    }

    @Test func convertToDOSOrderMatchesInterleave() {
        let po = patternedProDOSOrderImage()
        let image = DiskImage(bytes: po, order: .prodos)
        image.convertToDOSOrder()
        #expect(image.order == .dos)
        #expect(image.bytes == Interleave.prodosToDOS(po))
    }

    @Test func writeBlockThroughPersistsOnlyThatBlock() throws {
        let dir = try scratchDirectory()
        let path = dir + "/drive.dsk"
        try ProDOSVolume.createImage(at: path, volumeName: "DRIVE", blocks: 280)
        let image = try DiskImage.open(path: path)
        #expect(image.order == .dos)
        let payload = [UInt8](repeating: 0xA5, count: 512)
        try image.writeBlockThrough(42, payload)
        let reread = try DiskImage.open(path: path)
        #expect(try reread.readBlock(42) == payload)
        #expect(try ProDOSVolume(image: reread).volumeName == "DRIVE")
    }

    @Test func missingFileThrowsNotFound() {
        #expect(throws: DiskImageError.notFound("/nonexistent/disk.po")) {
            try DiskImage.open(path: "/nonexistent/disk.po")
        }
    }
}

@Suite struct ProDOSTests {
    @Test func blankVolumeLayout() throws {
        let image = DiskImage(bytes: try ProDOSVolume.blankImageBytes(volumeName: "Hosted.VDrive1", blocks: 1600), order: .prodos)
        let vol = try ProDOSVolume(image: image)
        #expect(try vol.volumeName == "HOSTED.VDRIVE1")
        #expect(try vol.totalBlocks == 1600)
        #expect(try vol.entries().isEmpty)
        // Blocks 0-6 used (boot, directory, bitmap).
        #expect(try vol.freeBlockCount() == 1600 - 7)
    }

    @Test func addReadAndDeleteFiles() throws {
        let image = DiskImage(bytes: try ProDOSVolume.blankImageBytes(volumeName: "FILES", blocks: 1600), order: .prodos)
        let vol = try ProDOSVolume(image: image)
        let freeBefore = try vol.freeBlockCount()

        let small = [UInt8](repeating: 1, count: 100)
        let medium = (0..<20_000).map { UInt8(truncatingIfNeeded: $0) }
        let large = (0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 3) }

        try vol.addFile(named: "seed", contents: small, fileType: 0x06, auxType: 0x2000)
        try vol.addFile(named: "SAPLING.BIN", contents: medium, fileType: 0x06, auxType: 0x0800)
        try vol.addFile(named: "TREE", contents: large, fileType: 0xFF, auxType: 0x2000)

        let names = try vol.entries().map(\.name)
        #expect(names == ["SEED", "SAPLING.BIN", "TREE"])
        #expect(try vol.readFile(named: "seed") == small)
        #expect(try vol.readFile(named: "sapling.bin") == medium)
        #expect(try vol.readFile(named: "TREE") == large)
        #expect(try vol.entry(named: "SAPLING.BIN")?.storageType == 2)
        #expect(try vol.entry(named: "TREE")?.storageType == 3)
        #expect(try vol.entry(named: "SAPLING.BIN")?.auxType == 0x0800)

        // Replacing reuses space; deleting frees it all.
        try vol.addFile(named: "SEED", contents: medium, fileType: 0x06, auxType: 0)
        #expect(try vol.readFile(named: "SEED") == medium)
        for name in ["SEED", "SAPLING.BIN", "TREE"] { try vol.deleteFile(named: name) }
        #expect(try vol.entries().isEmpty)
        #expect(try vol.freeBlockCount() == freeBefore)
    }

    @Test func fillingTheVolumeDirectorySpillsAcrossBlocks() throws {
        let image = DiskImage(bytes: try ProDOSVolume.blankImageBytes(volumeName: "MANY", blocks: 280), order: .prodos)
        let vol = try ProDOSVolume(image: image)
        // 12 entries in the key block + 13 in each of three more blocks = 51.
        for i in 0..<51 { try vol.addFile(named: "F\(i)", contents: [UInt8(i)], fileType: 4, auxType: 0) }
        #expect(throws: ProDOSError.directoryFull) {
            try vol.addFile(named: "ONEMORE", contents: [], fileType: 4, auxType: 0)
        }
        #expect(try vol.readFile(named: "F50") == [50])
    }

    @Test func renameAndNameValidation() throws {
        let image = DiskImage(bytes: try ProDOSVolume.blankImageBytes(volumeName: "OLD", blocks: 280), order: .prodos)
        let vol = try ProDOSVolume(image: image)
        try vol.rename(to: "ADTPro.2.1.0")
        #expect(try vol.volumeName == "ADTPRO.2.1.0")
        #expect(throws: ProDOSError.self) { try vol.rename(to: "1BAD") }
        #expect(throws: ProDOSError.self) { try vol.rename(to: "WAY.TOO.LONG.FOR.PRODOS") }
    }

    @Test func dateEncoding() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 20, minute: 30))!
        // date = 26<<9 | 11<<5 | 5 = 0x3565 ; time = 20<<8 | 30 = 0x141E
        #expect(ProDOSDate.directoryStamp(date, calendar: cal) == [0x65, 0x35, 0x1E, 0x14])
        #expect(ProDOSDate.globalPageStamp(date, calendar: cal) == [0x1E, 0x14, 0x65, 0x35])
    }
}
