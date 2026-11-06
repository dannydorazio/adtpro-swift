import Foundation

struct WideEnvelope: Equatable {
    var lengthLow: UInt8
    var lengthHigh: UInt8
    var command: UInt8
    var length: Int { Int(lengthLow) | Int(lengthHigh) << 8 }
}

enum PacketPreamble {
    /// Legacy DOS ADT: no preamble.
    case none
    /// ProDOS blocks: block number and half-block indicator.
    case prodos
    /// Nibble chunks.
    case nibble
}

enum WidePacketResult: Equatable {
    case data([UInt8])
    /// A packet we already had; it was acknowledged so the client moves on.
    case duplicate
    case failed
}

extension ADTProServer {
    // MARK: Wide envelopes

    /// Read an envelope. With `needWrapper`, first skip input until an 'A'.
    /// Returns nil on a timeout or a bad check byte.
    func pullEnvelopeWide(needWrapper: Bool, initialTimeout: Double = 15) throws -> WideEnvelope? {
        do {
            if needWrapper {
                while try waitForData(initialTimeout) != CommandByte.envelope {}
            }
            let lo = try waitForData(5)
            let hi = try waitForData(5)
            let command = try waitForData(5)
            let check = try waitForData(5)
            if check == CommandByte.envelope ^ lo ^ hi ^ command {
                return WideEnvelope(lengthLow: lo, lengthHigh: hi, command: command)
            }
            log.trace("Ill-formed envelope \(lo.hex) \(hi.hex) \(command.hex) \(check.hex)")
            transport.discardInput()
            return nil
        } catch LinkError.timeout {
            log.trace("Timed out waiting for an envelope")
            detail(Messages.aborted)
            return nil
        }
    }

    /// Read an envelope's payload and check byte. Returns nil when there is no
    /// payload, it times out, or the check byte is wrong.
    func pullPayloadWide(_ envelope: WideEnvelope) throws -> [UInt8]? {
        let length = envelope.length
        guard length > 0 else { return nil }
        var payload = [UInt8]()
        payload.reserveCapacity(length)
        do {
            var check: UInt8 = 0
            for _ in 0..<length {
                let b = try waitForData(1)
                payload.append(b)
                check ^= b
            }
            let received = try waitForData(1)
            guard received == check else {
                log.trace("Payload check byte mismatch: got \(received.hex), computed \(check.hex)")
                return nil
            }
            return payload
        } catch LinkError.timeout {
            log.trace("Timed out reading payload")
            return nil
        }
    }

    // MARK: Wide data packets

    /// Send `count` blocks starting at `block` as one wide packet and wait for
    /// the client's acknowledgement, retrying on NAK.
    func sendPacketWide(_ buffer: [UInt8], block: Int, count: Int, ackTimeout: Double = 15) throws -> Bool {
        let length = count * 512
        let encoded = PacketCodec.encode(pages: buffer[0..<length])
        let crc = CRC16.checksum(buffer[0..<length])
        var retries = 0
        repeat {
            transport.write(Envelope.header(length: length, command: CommandByte.data))
            transport.write([UInt8(block & 0xFF), UInt8((block >> 8) & 0xFF)])
            transport.write(encoded)
            transport.write([UInt8(crc & 0xFF), UInt8(crc >> 8)])
            transport.flush()

            var ack = ControlByte.nak
            if let envelope = try pullEnvelopeWide(needWrapper: true, initialTimeout: ackTimeout) {
                switch envelope.command {
                case CommandByte.ack:
                    if let payload = try pullPayloadWide(envelope), payload.count >= 3 {
                        ack = payload[0]
                        let next = Int(payload[1]) | Int(payload[2]) << 8
                        if next != block + count {
                            log.trace("Ack for block \(next), expected \(block + count)")
                            ack = ControlByte.nak
                        }
                    } else {
                        ack = ControlByte.can
                    }
                case CommandByte.home:
                    log.trace("Client went home; aborting send")
                    ack = ControlByte.can
                default:
                    log.trace("Unexpected envelope \(envelope.command.hex) while waiting for ack")
                    ack = ControlByte.nak
                }
            }
            switch ack {
            case ControlByte.ack:
                return true
            case ControlByte.can:
                return false
            default:
                retries += 1
                log.info("Resending block \(block) (retry \(retries))")
                backoff(retry: retries, base: 250, cap: 1000)
                transport.discardInput()
            }
        } while running && retries < maxRetries
        return false
    }

    /// Receive one wide data packet. `expectedBlock` (when given) is the block
    /// the packet should start at; an earlier block is acknowledged and reported
    /// as a duplicate.
    func receivePacketWide(expectedBlock: Int?) throws -> WidePacketResult {
        var retries = 0
        var incomingBlock = 0
        var result = WidePacketResult.failed
        repeat {
            result = .failed
            let envelope = try pullEnvelopeWide(needWrapper: true)
            if let envelope, envelope.command == CommandByte.home {
                log.trace("Client went home")
                throw GoHome()
            }
            if let envelope, envelope.command == CommandByte.data {
                let expectedBytes = envelope.length
                do {
                    incomingBlock = Int(try waitForData(1))
                    incomingBlock |= Int(try waitForData(1)) << 8
                    var decoder = PacketCodec.Decoder(pages: Int(envelope.lengthHigh))
                    while !decoder.isComplete {
                        decoder.feed(try waitForData(1))
                        if !running { throw LinkError.stopped }
                    }
                    let crc = UInt16(try waitForData(1)) | UInt16(try waitForData(1)) << 8
                    if let expectedBlock, incomingBlock != expectedBlock {
                        // Not the packet we want. Acknowledge an old one so the
                        // client moves on; refuse one from the future.
                        result = incomingBlock < expectedBlock ? .duplicate : .failed
                    } else {
                        let data = Array(decoder.output.prefix(expectedBytes))
                        if CRC16.checksum(data) == crc {
                            result = .data(data)
                        } else {
                            log.info("Incorrect CRC on packet at block \(incomingBlock)")
                            transport.pauseAfterBadPacket()
                        }
                    }
                } catch LinkError.timeout {
                    // As in the original, a timeout mid-packet abandons the receive.
                    log.info("Timed out receiving packet")
                    return .failed
                }
            } else if let envelope {
                log.trace("Unexpected envelope \(envelope.command.hex) while waiting for data")
            }

            if result == .failed {
                retries += 1
                log.info("Requesting resend (retry \(retries))")
                backoff(retry: retries, base: 500)
                transport.discardInput()
                transport.write(ControlByte.nak)
                transport.flush()
                transport.discardOutput()
            } else {
                transport.write(ControlByte.ack)
                transport.flush()
                transport.discardInput()
                transport.discardOutput()
            }
        } while result == .failed && running && retries < maxRetries
        return result
    }

    // MARK: Original (v1) packets

    /// Send one 256-byte packet of `buffer` at `offset`, retrying on NAK.
    func sendPacket(_ buffer: [UInt8], block: Int, offset: Int, preamble: PacketPreamble) throws -> Bool {
        let page = buffer[offset..<offset + 256]
        let encoded = PacketCodec.encode(pages: page)
        let crc = CRC16.checksum(page)
        let hostHalf = 2 - offset / 256
        var retries = 0
        var ok = ControlByte.nak
        repeat {
            switch preamble {
            case .prodos:
                transport.write([UInt8(block & 0xFF), UInt8((block >> 8) & 0xFF), UInt8(truncatingIfNeeded: hostHalf)])
            case .nibble:
                transport.write([UInt8(block & 0xFF), UInt8((block >> 8) & 0xFF), 2])
            case .none:
                break
            }
            transport.write(encoded)
            transport.write([UInt8(crc & 0xFF), UInt8(crc >> 8)])
            transport.flush()
            do {
                ok = try waitForData(15, expecting: [ControlByte.ack, ControlByte.nak])
                switch preamble {
                case .prodos:
                    var incomingBlock = Int(try waitForData(1))
                    incomingBlock += Int(try waitForData(1)) * 256
                    let appleHalf = Int(Int8(bitPattern: try waitForData(1)))
                    if ok == ControlByte.nak {
                        // Exactly one half-block off means an acknowledgement went
                        // missing; carry on rather than resend.
                        let halfOff = abs(appleHalf - hostHalf) == 1
                        if halfOff && (incomingBlock == block || incomingBlock == block + 1) {
                            log.trace("Found an old packet; advancing")
                            ok = ControlByte.ack
                        }
                    }
                case .nibble:
                    _ = try waitForData(15)
                    _ = try waitForData(15)
                    _ = try waitForData(15)
                    if ok == ControlByte.nak { ok = ControlByte.ack }
                case .none:
                    break
                }
            } catch LinkError.timeout {
                ok = ControlByte.nak
            }
            if ok == ControlByte.ack { return true }
            retries += 1
            log.info("Resending block \(block) offset \(offset) (retry \(retries))")
            backoff(retry: retries, base: 250, cap: 1000)
            transport.discardInput()
        } while running && retries < maxRetries
        return false
    }

    /// Receive one 256-byte packet into `buffer` at `offset`. `bufferNumber` is
    /// the half-block index (ProDOS) used to check the preamble. Returns true on
    /// success.
    func receivePacket(into buffer: inout [UInt8], offset: Int, bufferNumber: Int, preamble: PacketPreamble) throws -> Bool {
        var retries = 0
        // Ethernet and audio clients always send a preamble, even for legacy ADT.
        let hasPreamble = preamble != .none || transport.kind == .ethernet || transport.kind == .audio
        var rc = 0
        repeat {
            rc = 0
            if hasPreamble {
                do {
                    let blockNum = bufferNumber / 2
                    let halfNum = bufferNumber % 2
                    var incomingBlock = Int(try waitForData(15, expecting: [UInt8(truncatingIfNeeded: blockNum)]))
                    incomingBlock += Int(try waitForData(1, expecting: [UInt8(truncatingIfNeeded: blockNum >> 8)])) * 256
                    let data = try waitForData(1)
                    let incomingHalf = abs(2 - Int(Int8(bitPattern: data)))
                    switch preamble {
                    case .prodos:
                        if incomingBlock != blockNum || incomingHalf != halfNum {
                            let previousHalf = incomingBlock == blockNum - 1 && incomingHalf == 1 - halfNum
                            let otherHalf = incomingBlock == blockNum && incomingHalf == 1 - halfNum
                            rc = (previousHalf || otherHalf) ? -2 : -1
                            transport.pauseAfterBadPacket()
                        }
                    case .nibble:
                        if data != 2 {
                            rc = -1
                            transport.pauseAfterBadPacket()
                        }
                        if bufferNumber == Int(Int8(bitPattern: UInt8(incomingBlock & 0xFF))) + 1 {
                            rc = -1
                            transport.pauseAfterBadPacket()
                        }
                    case .none:
                        break
                    }
                } catch LinkError.timeout {
                    rc = -1
                    log.info("Timed out waiting for packet preamble")
                }
            }
            if rc == 0 {
                do {
                    var decoder = PacketCodec.Decoder(pages: 1)
                    while !decoder.isComplete {
                        decoder.feed(try waitForData(15))
                        if !running { throw LinkError.stopped }
                    }
                    buffer.replaceSubrange(offset..<offset + 256, with: decoder.output)
                    let crc = UInt16(try waitForData(1)) | UInt16(try waitForData(1)) << 8
                    if crc != CRC16.checksum(buffer[offset..<offset + 256]) {
                        rc = -1
                        log.info("Incorrect CRC")
                        transport.pauseAfterBadPacket()
                    }
                } catch LinkError.timeout {
                    rc = -1
                    log.info("Timed out receiving packet")
                }
            }
            switch rc {
            case 0, -2:
                // -2: an out-of-sync duplicate; acknowledge it and go round again.
                transport.write(ControlByte.ack)
                transport.flush()
                transport.discardInput()
                transport.discardOutput()
                if rc == -2 { retries += 1 }
            default:
                retries += 1
                log.info("Requesting resend (retry \(retries))")
                backoff(retry: retries, base: 500)
                transport.write(ControlByte.nak)
                transport.flush()
                transport.discardInput()
                transport.discardOutput()
            }
        } while rc != 0 && running && retries < maxRetries
        return rc == 0
    }

    // MARK: Names (v1)

    /// Read a null-terminated name. A leading byte under $80 introduces a
    /// two-byte protocol version and a zero, which is acknowledged.
    func receiveName() throws -> String {
        var name = ""
        var index = 0
        while index < 256 && running {
            var byte = try waitForData(15)
            if index == 0 && byte <= 0x7F {
                let msb = byte
                let lsb = try waitForData(15)
                guard try waitForData(15) == 0 else {
                    throw ProtocolVersionMismatch()
                }
                log.trace("Client protocol version \(msb.hex)\(lsb.hex)")
                transport.write(ControlByte.ack)
                transport.flush()
                byte = try waitForData(15)
            }
            if byte == 0 { break }
            name.append(Character(UnicodeScalar(byte & 0x7F)))
            index += 1
        }
        log.trace("Received name [\(name)]")
        return name
    }
}

struct ProtocolVersionMismatch: Error {}

extension String {
    /// Bytes as the Apple will display them: ASCII, with anything else as '?'.
    var appleBytes: [UInt8] {
        unicodeScalars.map { $0.isASCII ? UInt8($0.value) : 0x3F }
    }
}

extension Array where Element == UInt8 {
    /// Characters from Apple bytes up to (not including) the first zero, high bit stripped.
    func appleString(stopAtNull: Bool = true) -> String {
        var s = ""
        for b in self {
            if stopAtNull && b == 0 { break }
            s.append(Character(UnicodeScalar(b & 0x7F)))
        }
        return s
    }
}
