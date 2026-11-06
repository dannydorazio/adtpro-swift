// The cassette-port audio modem shared with the ADTPro audio client.
//
// Bytes go out MSB first as square waves: a 1000 Hz cycle for a 1 bit and a
// 2000 Hz cycle for a 0 bit, after a 770 Hz leader and a 2200 Hz sync cycle,
// followed by an XOR checksum (seeded with $FF) and a 200 Hz end cycle.
// Received audio is decoded by timing zero crossings.

public enum AudioModem {
    public static let sampleRate = 44100

    /// Sample levels, matching the original 8-bit unsigned output where the
    /// "high" half-cycle was written as 1 and the "low" one as 255.
    static let firstHalf: Float = -127.0 / 128.0
    static let secondHalf: Float = 127.0 / 128.0
    static let silenceLevel: Float = -1.0

    /// Encode `bytes` as cassette audio. `leaderCycles` is 300 for protocol
    /// packets and 7000 for bootstraps (to give the user time to hit Return).
    public static func encode(_ bytes: [UInt8], leaderCycles: Int = 300) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(bytes.count * 8 * 30 + leaderCycles * 58 + 16000)
        for _ in 0..<leaderCycles { _ = onePeriod(&out, frequency: 770, remainder: 0) }
        _ = onePeriod(&out, frequency: 2200, remainder: 0)
        var checksum: UInt8 = 0xFF
        var remainder = 0.0
        for b in bytes {
            checksum ^= b
            remainder = encodeByte(&out, b, remainder: remainder)
        }
        _ = encodeByte(&out, checksum, remainder: 0)
        _ = onePeriod(&out, frequency: 200, remainder: 0)
        out.append(contentsOf: repeatElement(silenceLevel, count: 15000))
        return out
    }

    /// One full cycle. Fractional samples accumulate (scaled down by 20, as in
    /// the original) and occasionally lengthen a cycle by one sample per half.
    static func onePeriod(_ out: inout [Float], frequency: Int, remainder inRemainder: Double) -> Double {
        let samples = sampleRate / (2 * frequency)
        var remainder = inRemainder + (Double(sampleRate) / Double(2 * frequency) - Double(samples)) / 20
        out.append(contentsOf: repeatElement(firstHalf, count: samples))
        if remainder > 1 { out.append(firstHalf) }
        out.append(contentsOf: repeatElement(secondHalf, count: samples))
        if remainder > 1 {
            out.append(secondHalf)
            remainder -= 1
        }
        return remainder
    }

    static func encodeByte(_ out: inout [Float], _ byte: UInt8, remainder inRemainder: Double) -> Double {
        var remainder = inRemainder
        var b = byte
        for _ in 0..<8 {
            remainder = onePeriod(&out, frequency: (b & 0x80) != 0 ? 1000 : 2000, remainder: remainder)
            b <<= 1
        }
        return remainder
    }

    /// Zero-crossing decoder for 8-bit signed samples at 44.1 kHz.
    public struct Decoder {
        var hysteresis = 3
        var threshold = 0
        var period = 0
        var state = 0
        var lastBit = -1
        var training = true
        var register = 0
        var bits = 0

        public init() {}

        /// Feed samples; returns any bytes completed.
        public mutating func feed(_ samples: UnsafeBufferPointer<Int8>) -> [UInt8] {
            var out: [UInt8] = []
            for s in samples {
                let sample = Int(s)
                let transition: Bool
                if threshold >= 0 && sample >= threshold {
                    threshold = -hysteresis
                    transition = true
                } else if threshold < 0 && sample <= threshold {
                    threshold = hysteresis
                    transition = true
                } else {
                    transition = false
                }
                period += 1
                guard transition else { continue }

                switch period {
                case 8...12:            // 2000-2200 Hz half cycle: a 0 bit (or sync)
                    if state == 1 && lastBit == 0 {
                        if training {
                            training = false
                            break
                        }
                        push(0, into: &out)
                        state = 0
                    } else {
                        state = 1
                    }
                    lastBit = 0
                case 20...23:           // 1000 Hz half cycle: a 1 bit
                    if training { break }
                    if state == 1 && lastBit == 1 {
                        push(1, into: &out)
                        state = 0
                    } else {
                        state = 1
                    }
                    lastBit = 1
                case 16...19, 26...30:  // 1200 Hz or 770 Hz leader: resynchronise
                    training = true
                    state = 0
                    bits = 0
                default:
                    break
                }
                period = 0
            }
            return out
        }

        public mutating func feed(_ samples: [Int8]) -> [UInt8] {
            samples.withUnsafeBufferPointer { feed($0) }
        }

        mutating func push(_ bit: Int, into out: inout [UInt8]) {
            register = ((register << 1) | bit) & 0xFF
            bits += 1
            if bits == 8 {
                out.append(UInt8(register))
                bits = 0
            }
        }
    }
}
