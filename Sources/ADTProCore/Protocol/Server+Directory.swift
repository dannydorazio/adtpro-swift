import DiskImage
import Foundation

extension ADTProServer {
    // MARK: Change directory

    func changeDirectory() throws {
        let requested = try receiveName()
        guard running else { return }
        finishChangeDirectory(requested)
    }

    func changeDirectoryWide(_ envelope: WideEnvelope) throws {
        guard let payload = try pullPayloadWide(envelope) else { return }
        finishChangeDirectory(payload.appleString(stopAtNull: false))
    }

    private func finishChangeDirectory(_ requested: String) {
        let ok = fileHost.changeDirectory(requested)
        log.trace("CD \(requested): \(ok ? "ok" : "failed")")
        transport.write(ok ? 0x00 : 0x06)
        transport.flush()
        if ok { emit(.workingDirectoryChanged(fileHost.workingDirectory)) }
    }

    // MARK: Directory listing

    /// Original protocol: stream the listing as 40-column text, pausing every
    /// screenful for the client to ask for more.
    func sendDirectory() throws {
        let cwd = fileHost.workingDirectory
        let cwdBytes = cwd.appleBytes
        transport.write("DIRECTORY OF ")
        transport.write(cwdBytes)
        if (cwdBytes.count + 13) % 40 != 0 { transport.write(0x0D) }
        transport.write(String(repeating: "-", count: 40))

        let files = (fileHost.listing() ?? []).map(\.appleBytes)
        lastListing = fileHost.listing() ?? []
        do {
            if !files.isEmpty {
                var i = 0, j = 0
                var line = (cwdBytes.count + 13) / 40 + 2
                while running {
                    if i > 0 && i + files[j].count > 40 {
                        while i < 40 { transport.write(0x20); i += 1 }
                        i = 0
                        line += 1
                    }
                    if line > 20 {
                        line = 0
                        transport.write([0x00, 0x01])
                        transport.flush()
                        if try waitForData(15) == 0 { break }
                    }
                    line += files[j].count / 40
                    i += files[j].count % 40
                    transport.write(files[j])
                    j += 1
                    if j + 1 > files.count { break }
                    // Pad to the next 14-column tab stop.
                    repeat {
                        if i == 40 { i = 0; line += 1; break }
                        transport.write(0x20)
                        i += 1
                    } while i % 14 > 0
                }
            } else {
                transport.write("NO FILES")
            }
        } catch LinkError.timeout {
            transport.write("NO FILES")
        }
        transport.write([0x00, 0x00])
        transport.flush()
    }

    /// Wide protocol: one 1K screen per request, 18 names per page.
    func sendDirectoryWide(_ envelope: WideEnvelope) throws {
        guard let payload = try pullPayloadWide(envelope), !payload.isEmpty else { return }
        let filespec = Array(payload.prefix(max(0, payload.count - 2))).appleString(stopAtNull: false)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        let page = Int(payload[payload.count - 1])
        let pageLength = 18

        guard let files = filespec.isEmpty ? fileHost.listing() : fileHost.listing(matching: filespec) else {
            transport.write([0x00, 0x00])
            transport.flush()
            return
        }
        lastListing = files

        var directory = fileHost.workingDirectory
        if directory.count <= 66 { directory = "DIRECTORY OF: " + directory }
        if directory.count > 80 {
            directory = String(directory.suffix(80))
        } else if directory.count < 80 {
            directory += "\r"
        }
        if directory.count <= 40 { directory += "\r" }

        var screen = [UInt8]()
        screen += directory.appleBytes
        screen += Array(repeating: UInt8(ascii: "-"), count: 40)
        if !files.isEmpty {
            let start = page * pageLength
            var end = start + pageLength
            var continuation: UInt8 = 1
            if end >= files.count {
                continuation = 0
                end = files.count
            }
            if start < end {
                for name in files[start..<end] {
                    var bytes = name.appleBytes
                    if bytes.count > 40 { bytes = Array(bytes.prefix(38)) + Array("..".utf8) }
                    screen += bytes
                    if bytes.count < 40 { screen.append(0x0D) }
                }
            }
            screen += [0x00, continuation]
        } else {
            screen += Array("NO FILES".utf8) + [0x00, 0x00]
        }
        var packet = [UInt8](repeating: 0, count: 1024)
        packet.replaceSubrange(0..<min(screen.count, 1024), with: screen.prefix(1024))
        _ = try sendPacketWide(packet, block: page, count: 2, ackTimeout: 1)
    }

    // MARK: Opening images

    enum ImageOpenResult {
        case opened(DiskImage)
        case notFound
        case unrecognized
    }

    func openImage(named name: String) -> ImageOpenResult {
        guard let path = fileHost.resolveExisting(name) else {
            log.trace("Can't find \(name)")
            return .notFound
        }
        do {
            return .opened(try DiskImage.open(path: path))
        } catch DiskImageError.unrecognizedFormat {
            return .unrecognized
        } catch {
            log.trace("Can't read \(path): \(error)")
            return .notFound
        }
    }

    /// A requested name from a wide payload. A name starting with $01 picks an
    /// entry from the last directory listing by page and line.
    func requestedName(from payload: [UInt8]) -> String? {
        let name = payload.appleString()
        if name.first == "\u{01}", payload.count >= 3 {
            let index = 18 * (Int(payload[1]) - 1) + (Int(payload[2]) - 3)
            guard lastListing.indices.contains(index) else { return nil }
            return lastListing[index].trimmingCharacters(in: .whitespaces)
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    }

    // MARK: File size

    func queryFileSize() throws {
        let name = try receiveName()
        replyFileSize(for: name)
    }

    func queryFileSizeWide(_ envelope: WideEnvelope) throws {
        guard let payload = try pullPayloadWide(envelope) else { return }
        replyFileSize(for: requestedName(from: payload) ?? "")
    }

    /// Reply with the size in blocks and a status: 0 ok, 2 not found, 4 not a disk image.
    private func replyFileSize(for name: String) {
        var blocks = 0
        let rc: UInt8
        switch openImage(named: name) {
        case .opened(let image):
            blocks = image.isNibble ? 455 : image.blockCount
            rc = 0
            detail(image.fileName)
        case .notFound:
            rc = 0x02
            detail(name)
        case .unrecognized:
            rc = 0x04
            detail(name)
        }
        log.trace("Size of \(name): \(blocks) blocks, rc \(rc)")
        transport.write([UInt8(blocks & 0xFF), UInt8((blocks >> 8) & 0xFF), rc])
        transport.flush()
    }
}
