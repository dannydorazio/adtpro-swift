import DiskImage
import Foundation

extension ADTProServer {
    /// Service one VSDrive/VEDrive request ('E' already read).
    ///
    /// Commands: $01 read (drive 1), $03/$05 read with date/time (drive 1/2),
    /// $02/$04 write (drive 1/2).
    func virtualDriveCommand() throws {
        let command = try waitForData(5)
        let lo = try waitForData(5)
        let hi = try waitForData(5)
        let check = try waitForData(5)
        guard check == CommandByte.virtualDrive ^ command ^ lo ^ hi else {
            log.trace("Virtual drive envelope check mismatch")
            return
        }
        let block = Int(lo) | Int(hi) << 8

        switch command {
        case 0x01, 0x03, 0x05:
            let drive = command == 0x05 ? 2 : 1
            let data: [UInt8]
            do {
                data = try virtualDrives.readBlock(drive: drive, block: block)
            } catch {
                // Say nothing; the client times out and reports an I/O error.
                log.info("Virtual drive \(drive) read of block \(block) failed: \(error)")
                return
            }
            detail(Messages.readBlock(block))
            emit(.virtualDriveActivity(drive: drive, block: block, write: false))
            var reply: [UInt8] = [CommandByte.virtualDrive, command, lo, hi]
            if command == 0x03 || command == 0x05 {
                let stamp = ProDOSDate.globalPageStamp()
                reply += stamp
                reply.append(Envelope.xor(reply))
            } else {
                reply.append(check)
            }
            transport.write(reply)
            transport.write(data)
            transport.write(Envelope.xor(data))
            transport.flush()

        case 0x02, 0x04:
            let drive = command == 0x04 ? 2 : 1
            var data = [UInt8]()
            data.reserveCapacity(512)
            for _ in 0..<512 { data.append(try waitForData(5)) }
            let dataCheck = try waitForData(5)
            if dataCheck == Envelope.xor(data) {
                do {
                    try virtualDrives.writeBlock(drive: drive, block: block, data: data)
                    detail(Messages.writeBlock(block))
                    emit(.virtualDriveActivity(drive: drive, block: block, write: true))
                } catch {
                    log.info("Virtual drive \(drive) write of block \(block) failed: \(error)")
                }
            } else {
                log.info("Virtual drive block checksum mismatch on block \(block)")
            }
            transport.write([CommandByte.virtualDrive, command, lo, hi, dataCheck])
            transport.flush()

        default:
            log.trace("Unknown virtual drive command \(command.hex)")
        }
    }
}
