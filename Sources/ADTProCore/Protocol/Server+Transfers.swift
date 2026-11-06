import DiskImage
import Foundation

extension ADTProServer {
    // MARK: Naming received images

    /// Pick the file a received image is written to. Batch mode appends a
    /// four-digit sequence number, continuing from the last one used for the
    /// same prefix; otherwise a suitable extension is added when missing.
    func outputPath(for requested: String, blocks: Int, generateName: Bool) -> (path: String, number: Int?) {
        let base = fileHost.pathForNewFile(requested)
        let is140K = blocks * 512 == Geometry.size140K
        if generateName {
            if base != lastBatchName {
                lastBatchNumber = 1
                lastBatchName = base
            }
            let ext = is140K ? ".dsk" : ".po"
            var path: String
            repeat {
                path = base + String(format: "%04d", lastBatchNumber) + ext
                lastBatchNumber += 1
            } while FileManager.default.fileExists(atPath: path)
            return (path, lastBatchNumber - 1)
        }
        let upper = base.uppercased()
        if is140K {
            if !upper.hasSuffix(".DSK") && !upper.hasSuffix(".DO") { return (base + ".dsk", nil) }
        } else if !upper.hasSuffix(".PO") && !upper.hasSuffix(".HDV") {
            return (base + ".po", nil)
        }
        return (base, nil)
    }

    func outputNibblePath(for requested: String, extension ext: String, generateName: Bool) -> String {
        let base = fileHost.pathForNewFile(requested)
        if generateName {
            if base != lastNibbleName {
                lastNibbleNumber = 1
                lastNibbleName = base
            }
            var path: String
            repeat {
                path = base + String(format: "%04d", lastNibbleNumber) + "." + ext
                lastNibbleNumber += 1
            } while FileManager.default.fileExists(atPath: path)
            return path
        }
        return base.uppercased().hasSuffix("." + ext.uppercased()) ? base : base + "." + ext
    }

    /// Create (truncate) the output file up front so an unwritable location is
    /// reported to the client before any data moves.
    func createOutputFile(_ path: String) -> Bool {
        FileManager.default.createFile(atPath: path, contents: nil)
    }

    func writeImage(_ data: [UInt8], to path: String) throws {
        if data.count == Geometry.size140K {
            // Images always arrive in ProDOS order; 5.25" images are kept in DOS order.
            try Data(Interleave.prodosToDOS(data)).write(to: URL(fileURLWithPath: path))
        } else {
            try Data(data).write(to: URL(fileURLWithPath: path))
        }
    }

    func elapsedSeconds(since start: Date) -> Int { Int(Date().timeIntervalSince(start)) }

    func abortTransfer(deleting path: String?) {
        log.info(Messages.aborted)
        detail(Messages.aborted)
        clearProgress()
        transport.discardInput()
        transport.discardOutput()
        if let path { try? FileManager.default.removeItem(atPath: path) }
    }

    func reportReceived(_ path: String, report: UInt8, start: Date) {
        let name = (path as NSString).lastPathComponent
        let seconds = elapsedSeconds(since: start)
        let errors = report != 0
        detail(Messages.received(name, seconds, errors: errors))
        log.info("Apple sent disk image \(path)\(errors ? " with errors" : "") in \(seconds) seconds.")
        emit(.transferFinished(TransferResult(direction: .fromApple, fileName: name, succeeded: true, hadErrors: errors, seconds: seconds)))
    }

    func reportSent(_ name: String, report: UInt8, start: Date) {
        let seconds = elapsedSeconds(since: start)
        let errors = report != 0
        detail(Messages.sent(name, seconds, errors: errors))
        log.info("Apple received disk image \(name)\(errors ? " with \(report) errors" : "") in \(seconds) seconds.")
        emit(.transferFinished(TransferResult(direction: .toApple, fileName: name, succeeded: true, hadErrors: errors, seconds: seconds)))
    }

    // MARK: Apple -> host, wide protocol

    func receiveDiskWide(generateName: Bool, envelope: WideEnvelope) throws {
        let start = Date()
        guard let payload = try pullPayloadWide(envelope), payload.count >= 3 else { return }
        let requested = payload.appleString().trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        let blocks = Int(payload[payload.count - 2]) | Int(payload[payload.count - 1]) << 8
        log.trace("Receiving \(requested), \(blocks) blocks")
        let (path, number) = outputPath(for: requested, blocks: blocks, generateName: generateName)
        guard createOutputFile(path) else {
            transport.write(0x02)
            transport.flush()
            return
        }
        transport.write(0x00)
        transport.flush()
        setProgressTotal(blocks)
        detail((path as NSString).lastPathComponent)

        var image = [UInt8]()
        image.reserveCapacity(blocks * 512)
        var failed = false
        do {
            while image.count / 512 < blocks {
                switch try receivePacketWide(expectedBlock: image.count / 512) {
                case .data(let bytes):
                    image += bytes
                    setProgress(image.count / 512)
                case .duplicate:
                    log.trace("Acknowledged an earlier packet at block \(image.count / 512)")
                case .failed:
                    failed = true
                }
                if failed || !running { break }
            }
        } catch is GoHome {
            failed = true
        }
        guard !failed, running else {
            abortTransfer(deleting: path)
            if number != nil { lastBatchNumber -= 1 }
            return
        }
        try writeImage(Array(image.prefix(blocks * 512)), to: path)
        var report = ControlByte.nak
        if let summary = try pullEnvelopeWide(needWrapper: true), let p = try pullPayloadWide(summary), p.count == 1 {
            report = p[0]
        }
        reportReceived(path, report: report, start: start)
    }

    // MARK: Host -> Apple, wide protocol

    func sendDiskWide(_ envelope: WideEnvelope) throws {
        let start = Date()
        guard let payload = try pullPayloadWide(envelope) else { return }
        guard let requested = requestedName(from: payload) else {
            transport.write(0x02)
            transport.flush()
            return
        }
        // The byte after the name's terminator is the client's preferred blocks per packet.
        var blocksAtOnce = 1
        if let nul = payload.firstIndex(of: 0), nul + 1 < payload.count {
            blocksAtOnce = max(1, Int(payload[nul + 1]))
        }
        log.trace("Sending \(requested), \(blocksAtOnce) blocks per packet")

        guard case .opened(let image) = openImage(named: requested) else {
            transport.write(0x02)
            transport.flush()
            return
        }
        transport.write(0x00)
        transport.flush()

        var ack = ControlByte.can
        if let reply = try pullEnvelopeWide(needWrapper: true), reply.command == CommandByte.ack,
           let p = try pullPayloadWide(reply), !p.isEmpty {
            ack = p[0]
        }
        guard ack == ControlByte.ack else {
            abortTransfer(deleting: nil)
            return
        }

        let length = image.blockCount
        setProgressTotal(length)
        detail(image.fileName)
        var block = 0
        var sinceBufferStart = 0
        var ok = true
        while block < length && running {
            // Never send past the end, or more than the client's 40-block buffer holds.
            let count = min(blocksAtOnce, length - block, 40 - sinceBufferStart)
            var buffer = [UInt8]()
            buffer.reserveCapacity(count * 512)
            for b in block..<block + count { buffer += try image.readBlock(b) }
            ok = try sendPacketWide(buffer, block: block, count: count)
            guard ok else { break }
            sinceBufferStart += count
            if sinceBufferStart == 40 { sinceBufferStart = 0 }
            block += count
            setProgress(block)
        }
        if ok && running {
            // The client's summary packet arrives as a separate command and is ignored.
            reportSent(requested, report: 0, start: start)
        } else {
            abortTransfer(deleting: nil)
        }
    }

    // MARK: Apple -> host, original protocol

    func receiveDisk(generateName: Bool) throws {
        let start = Date()
        let requested = try receiveName()
        let lo = try waitForData(15)
        let hi = try waitForData(15)
        let blocks = Int(lo) | Int(hi) << 8
        let (path, number) = outputPath(for: requested, blocks: blocks, generateName: generateName)
        guard createOutputFile(path) else {
            transport.write(0x02)
            transport.flush()
            return
        }
        transport.write(0x00)
        transport.flush()

        var ok = false
        var image = [UInt8]()
        if try waitForData(15) == ControlByte.ack {
            setProgressTotal(blocks * 2)
            detail((path as NSString).lastPathComponent)
            var buffer = [UInt8](repeating: 0, count: 40 * 512)
            var halvesDone = 0
            ok = true
            let parts = blocks / 40, remainder = blocks % 40
            for part in 0..<parts where ok {
                for half in 0..<80 {
                    ok = try receivePacket(into: &buffer, offset: half * 256, bufferNumber: part * 80 + half, preamble: .prodos)
                    if !ok { break }
                    halvesDone += 1
                    setProgress(halvesDone)
                }
                if ok { image += buffer }
            }
            if ok && remainder > 0 {
                for half in 0..<remainder * 2 {
                    ok = try receivePacket(into: &buffer, offset: half * 256, bufferNumber: parts * 80 + half, preamble: .prodos)
                    if !ok { break }
                    halvesDone += 1
                    setProgress(halvesDone)
                }
                if ok { image += buffer[0..<remainder * 512] }
            }
        }
        guard ok else {
            abortTransfer(deleting: path)
            if number != nil { lastBatchNumber -= 1 }
            return
        }
        try writeImage(image, to: path)
        let report = try waitForData(60)
        reportReceived(path, report: report, start: start)
    }

    // MARK: Host -> Apple, original protocol

    func sendDisk() throws {
        let start = Date()
        let name = try receiveName()
        guard case .opened(let image) = openImage(named: name) else {
            transport.write(0x02)
            transport.flush()
            return
        }
        transport.write(0x00)
        transport.flush()
        guard try waitForData(15) == ControlByte.ack else {
            abortTransfer(deleting: nil)
            return
        }
        // The rest of the client's first acknowledgement: block number and half.
        _ = try waitForData(15)
        _ = try waitForData(1)
        _ = try waitForData(1)

        let length = image.blockCount
        setProgressTotal(length * 2)
        detail(image.fileName)
        var ok = true
        var halvesDone = 0
        blocks: for block in 0..<length {
            let buffer = try image.readBlock(block)
            for half in 0..<2 {
                ok = try sendPacket(buffer, block: block, offset: half * 256, preamble: .prodos)
                if !ok { break blocks }
                halvesDone += 1
                setProgress(halvesDone)
            }
        }
        guard ok else {
            abortTransfer(deleting: nil)
            return
        }
        let report = try waitForData(15)
        reportSent(name, report: report, start: start)
    }

    // MARK: Legacy DOS ADT

    /// ADT 'R': send a 140K DOS-order image, a sector at a time, high sectors first.
    func send140kDisk() throws {
        let start = Date()
        let name = try receiveName()
        var path = name
        var isDir: ObjCBool = false
        if !(FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue) {
            path = fileHost.resolveExisting(name) ?? fileHost.workingDirectory + name
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            transport.write(26)          // ADT: unable to open
            transport.flush()
            return
        }
        guard data.count == Geometry.size140K else {
            log.trace("Not a 140K image for legacy ADT")
            transport.write(30)          // ADT: not a 140K image
            transport.flush()
            return
        }
        detail(name)
        transport.write(0x00)
        transport.flush()
        guard try waitForData(15) == ControlByte.ack else { return }

        let image = [UInt8](data)
        setProgressTotal(560)
        var sectorsDone = 0
        var ok = true
        sending: for part in 0..<5 {
            let buffer = Array(image[part * 28672..<(part + 1) * 28672])
            for track in 0..<7 {
                for sector in stride(from: 15, through: 0, by: -1) {
                    ok = try sendPacket(buffer, block: 0, offset: track * 4096 + sector * 256, preamble: .none)
                    if !ok { break sending }
                    sectorsDone += 1
                    setProgress(sectorsDone)
                }
            }
        }
        guard ok else {
            abortTransfer(deleting: nil)
            return
        }
        let report = try waitForData(15)
        reportSent((path as NSString).lastPathComponent, report: report, start: start)
    }

    /// ADT 'S': receive a 140K DOS-order image.
    func receive140kDisk() throws {
        let start = Date()
        var path = fileHost.pathForNewFile(try receiveName())
        let upper = path.uppercased()
        if !upper.hasSuffix(".DSK") && !upper.hasSuffix(".DO") { path += ".dsk" }
        if FileManager.default.fileExists(atPath: path) {
            transport.write(0x1C)       // ADT: file exists
            transport.flush()
            return
        }
        guard createOutputFile(path) else {
            transport.write(0x1A)       // ADT: unable to write
            transport.flush()
            return
        }
        detail(path)
        transport.write(0x00)
        transport.flush()
        while try waitForData(15) != ControlByte.ack {
            log.info("Waiting for the Apple to acknowledge...")
        }
        setProgressTotal(560)
        var image = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 28672)
        var sectorsDone = 0
        var ok = true
        receiving: for _ in 0..<5 {
            for track in 0..<7 {
                for sector in stride(from: 15, through: 0, by: -1) {
                    ok = try receivePacket(into: &buffer, offset: track * 4096 + sector * 256, bufferNumber: -1, preamble: .none)
                    if !ok { image += buffer; break receiving }
                    sectorsDone += 1
                    setProgress(sectorsDone)
                }
            }
            image += buffer
        }
        // As before, whatever arrived is kept (already in DOS order).
        try Data(image).write(to: URL(fileURLWithPath: path))
        guard ok else {
            abortTransfer(deleting: nil)
            return
        }
        let report = try waitForData(15)
        reportReceived(path, report: report, start: start)
    }

    // MARK: Nibble copies

    /// Pick the better of a track's first read and an optional re-read.
    private func analyzeTrack(firstRead: [UInt8], reread: () throws -> [UInt8]?) throws -> NibbleTrack? {
        var best = NibbleAnalysis.analyze(firstRead)
        if best.accuracy < 0.9 {
            log.trace("Track accuracy \(best.accuracy); asking for a re-read")
            transport.write(ControlByte.enq)
            transport.flush()
            guard let second = try reread() else { return nil }
            let again = NibbleAnalysis.analyze(second)
            if again.accuracy > best.accuracy { best = again }
        }
        return best
    }

    func receiveNibbleDiskWide(generateName: Bool, envelope: WideEnvelope) throws {
        let start = Date()
        guard let payload = try pullPayloadWide(envelope) else { return }
        let requested = payload.appleString().trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        let path = outputNibblePath(for: requested, extension: "nib", generateName: generateName)
        detail((path as NSString).lastPathComponent)
        guard createOutputFile(path) else {
            transport.write(0x02)
            transport.flush()
            return
        }
        transport.write(0x00)
        transport.flush()
        setProgressTotal(35)

        var output = [UInt8]()
        var failed = false
        do {
            for trackNumber in 0..<35 {
                guard let raw = try receiveNibbleTrackWide(),
                      let track = try analyzeTrack(firstRead: raw, reread: { try self.receiveNibbleTrackWide() })
                else { failed = true; break }
                transport.write(ControlByte.ack)
                transport.flush()
                output += track.data
                setProgress(trackNumber + 1)
            }
        } catch is GoHome {
            failed = true
        }
        guard !failed, running else {
            abortTransfer(deleting: path)
            return
        }
        try Data(output).write(to: URL(fileURLWithPath: path))
        // Final error count from the client; not used.
        if let summary = try pullEnvelopeWide(needWrapper: true) { _ = try pullPayloadWide(summary) }
        reportReceived(path, report: 0, start: start)
    }

    /// One raw track read (13312 bytes) as a series of wide packets.
    func receiveNibbleTrackWide() throws -> [UInt8]? {
        var track = [UInt8]()
        track.reserveCapacity(13312)
        while track.count < 13312 {
            switch try receivePacketWide(expectedBlock: track.count / 512) {
            case .data(let bytes): track += bytes
            case .duplicate: log.trace("Skipping duplicate nibble packet")
            case .failed: return nil
            }
        }
        return Array(track.prefix(13312))
    }

    func receiveNibbleDisk(generateName: Bool, tracks: Int) throws {
        let start = Date()
        let requested = try receiveName()
        let path = outputNibblePath(for: requested, extension: tracks == 35 ? "nib" : "v2d", generateName: generateName)
        guard createOutputFile(path) else {
            transport.write(0x02)
            transport.flush()
            return
        }
        transport.write(0x00)
        transport.flush()
        if generateName {
            // File size; not needed.
            _ = try waitForData(1)
            _ = try waitForData(1)
        }
        guard try waitForData(15) == ControlByte.ack else {
            abortTransfer(deleting: path)
            return
        }
        setProgressTotal(tracks * 52)
        detail((path as NSString).lastPathComponent)

        var output = [UInt8]()
        var ok = true
        for trackNumber in 0..<tracks {
            func readTrack() throws -> [UInt8]? {
                var raw = [UInt8](repeating: 0, count: 13312)
                for part in 0..<52 {
                    guard try receivePacket(into: &raw, offset: part * 256, bufferNumber: -1, preamble: .nibble) else { return nil }
                    setProgress(trackNumber * 52 + part + 1)
                }
                return raw
            }
            guard let raw = try readTrack(), let track = try analyzeTrack(firstRead: raw, reread: readTrack) else {
                ok = false
                break
            }
            transport.write(ControlByte.ack)
            transport.flush()
            output += track.data
        }
        try Data(output).write(to: URL(fileURLWithPath: path))
        guard ok else {
            abortTransfer(deleting: nil)
            return
        }
        let report = try waitForData(15)
        reportReceived(path, report: report, start: start)
    }
}
