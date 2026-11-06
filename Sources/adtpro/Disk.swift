import ArgumentParser
import DiskImage
import Foundation

struct Disk: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create and edit ProDOS disk images.",
        subcommands: [Info.self, List.self, Create.self, Put.self, Get.self, Delete.self, Rename.self, Convert.self]
    )

    static func volume(_ path: String) throws -> (DiskImage, ProDOSVolume) {
        let image = try DiskImage.open(path: path)
        return (image, try ProDOSVolume(image: image))
    }

    static func parseNumber(_ s: String) -> Int? {
        if s.lowercased().hasPrefix("0x") { return Int(s.dropFirst(2), radix: 16) }
        if s.hasPrefix("$") { return Int(s.dropFirst(), radix: 16) }
        return Int(s)
    }

    struct Info: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Describe an image.")
        @Argument var image: String

        func run() throws {
            let img = try DiskImage.open(path: image)
            let order: String
            switch img.order {
            case .dos: order = "DOS order"
            case .prodos: order = "ProDOS order"
            case .nibble: order = "nibble"
            }
            print("\(img.fileName): \(img.blockCount) blocks, \(order)\(img.twoIMG != nil ? " (2IMG)" : "")")
            if let vol = try? ProDOSVolume(image: img) {
                print("ProDOS volume /\(try vol.volumeName), \(try vol.freeBlockCount()) blocks free, \(try vol.entries().count) files")
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ls", abstract: "List files in a ProDOS image.")
        @Argument var image: String

        func run() throws {
            let (_, vol) = try Disk.volume(image)
            print("/\(try vol.volumeName)")
            for e in try vol.entries() {
                let name = e.name.padding(toLength: 16, withPad: " ", startingAt: 0)
                print(String(format: "  %@ $%02X %6d bytes  aux $%04X  %4d blocks", name, e.fileType, e.eof, e.auxType, e.blocksUsed))
            }
            print("\(try vol.freeBlockCount()) of \(try vol.totalBlocks) blocks free")
        }
    }

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a blank ProDOS volume (.po, .2mg, .hdv, or a 140K .dsk).")
        @Argument var image: String
        @Option(name: .long, help: "Volume name.") var name: String = "BLANK"
        @Option(name: .long, help: "Size in blocks (280 = 140K, 1600 = 800K, up to 65535).") var blocks: Int = 1600
        @Flag(name: .long, help: "Replace an existing file.") var force = false

        func run() throws {
            guard (16...65535).contains(blocks) else { throw ValidationError("Blocks must be 16...65535") }
            if FileManager.default.fileExists(atPath: image) && !force {
                throw ValidationError("\(image) exists; use --force to replace it")
            }
            try ProDOSVolume.createImage(at: image, volumeName: name, blocks: blocks)
            print("Created \(image)")
        }
    }

    struct Put: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Copy a file into a ProDOS image (replacing any existing one).")
        @Argument var image: String
        @Argument var file: String
        @Option(name: .long, help: "ProDOS file name (default: the file's name).") var name: String?
        @Option(name: .long, help: "File type: BIN, SYS, TXT, BAS, SOS, PCD or $hex.") var type: String = "BIN"
        @Option(name: .long, help: "Aux type (load address), e.g. 0x2000.") var aux: String = "0"

        func run() throws {
            guard let fileType = ProDOSVolume.fileType(named: type) else { throw ValidationError("Unknown file type \(type)") }
            guard let auxType = Disk.parseNumber(aux), (0...0xFFFF).contains(auxType) else { throw ValidationError("Bad aux type \(aux)") }
            guard let data = FileManager.default.contents(atPath: file) else { throw ValidationError("Cannot read \(file)") }
            let (img, vol) = try Disk.volume(image)
            let target = name ?? (file as NSString).lastPathComponent
            try vol.addFile(named: target, contents: [UInt8](data), fileType: fileType, auxType: UInt16(auxType))
            try img.save()
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Copy a file out of a ProDOS image.")
        @Argument var image: String
        @Argument var name: String
        @Argument var output: String?

        func run() throws {
            let (_, vol) = try Disk.volume(image)
            let data = try vol.readFile(named: name)
            try Data(data).write(to: URL(fileURLWithPath: output ?? name))
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete a file from a ProDOS image.")
        @Argument var image: String
        @Argument var name: String
        @Flag(name: .long, help: "Do not fail if the file is missing.") var force = false

        func run() throws {
            let (img, vol) = try Disk.volume(image)
            do {
                try vol.deleteFile(named: name)
            } catch ProDOSError.fileNotFound where force {
                return
            }
            try img.save()
        }
    }

    struct Rename: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a ProDOS volume.")
        @Argument var image: String
        @Argument var volumeName: String

        func run() throws {
            let (img, vol) = try Disk.volume(image)
            try vol.rename(to: volumeName)
            try img.save()
        }
    }

    struct Convert: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Convert between .dsk/.po/.2mg/.nib (the format follows the output extension).")
        @Argument var input: String
        @Argument var output: String

        func run() throws {
            let source = try DiskImage.open(path: input)
            var blocks = [UInt8]()
            for b in 0..<source.blockCount { blocks += try source.readBlock(b) }
            let ext = (output as NSString).pathExtension.lowercased()
            let result: DiskImage
            switch ext {
            case "dsk", "do":
                guard blocks.count == Geometry.size140K else { throw ValidationError("DOS order needs a 140K image") }
                result = DiskImage(bytes: Interleave.prodosToDOS(blocks), order: .dos, path: output)
            case "nib":
                guard blocks.count == Geometry.size140K else { throw ValidationError("Nibble images need a 140K image") }
                result = DiskImage(bytes: GCR.nibblize(dosOrderImage: Interleave.prodosToDOS(blocks)), order: .nibble, path: output)
            case "2mg", "2img":
                result = DiskImage(bytes: blocks, order: .prodos, path: output, twoIMG: .makeProDOS(blocks: blocks.count / 512))
            default:
                result = DiskImage(bytes: blocks, order: .prodos, path: output)
            }
            try result.save()
            print("Wrote \(output)")
        }
    }
}
