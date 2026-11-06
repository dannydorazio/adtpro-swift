#if os(macOS)
import AVFoundation
import CoreAudio
import Foundation
import Synchronization

public struct AudioDevice: Sendable, Hashable, Identifiable {
    public var id: AudioDeviceID
    public var name: String
    public var inputChannels: Int
    public var outputChannels: Int
}

/// macOS audio through AVAudioEngine, resampling to and from 44.1 kHz mono.
public final class CoreAudioIO: AudioIO, @unchecked Sendable {
    let inputDevice: AudioDeviceID?
    let outputDevice: AudioDeviceID?
    private let lock = NSLock()
    private var captureEngine: AVAudioEngine?
    private var playbackEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    static let modemFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioModem.sampleRate),
                                           channels: 1, interleaved: false)!

    public init(inputDevice: AudioDeviceID? = nil, outputDevice: AudioDeviceID? = nil) {
        self.inputDevice = inputDevice
        self.outputDevice = outputDevice
    }

    // MARK: Devices

    public static func devices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            AudioDevice(id: id, name: name(of: id), inputChannels: channels(of: id, scope: kAudioDevicePropertyScopeInput),
                        outputChannels: channels(of: id, scope: kAudioDevicePropertyScopeOutput))
        }
    }

    static func name(of id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let value = name?.takeRetainedValue() else {
            return "Device \(id)"
        }
        return value as String
    }

    static func channels(of id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func select(_ device: AudioDeviceID, on node: AVAudioIONode) {
        guard let unit = node.audioUnit else { return }
        var id = device
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    // MARK: Capture

    static func ensureMicrophoneAccess() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let done = DispatchSemaphore(value: 0)
            let granted = Mutex(false)
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted.withLock { $0 = ok }
                done.signal()
            }
            done.wait()
            if granted.withLock({ $0 }) { return }
            throw TransportError.openFailed("Microphone access was denied")
        default:
            throw TransportError.openFailed("Microphone access is not allowed; enable it in System Settings > Privacy & Security > Microphone")
        }
    }

    public func startCapture(_ handler: @escaping @Sendable ([Int8]) -> Void) throws {
        try Self.ensureMicrophoneAccess()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let inputDevice { Self.select(inputDevice, on: input) }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw TransportError.openFailed("No audio input is available")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.modemFormat) else {
            throw TransportError.openFailed("Unsupported input format \(inputFormat)")
        }
        let ratio = Self.modemFormat.sampleRate / inputFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.modemFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = out.floatChannelData?[0] else { return }
            let n = Int(out.frameLength)
            var samples = [Int8](repeating: 0, count: n)
            for i in 0..<n {
                samples[i] = Int8(clamping: Int((channel[i] * 127).rounded()))
            }
            handler(samples)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw TransportError.openFailed("Audio input: \(error.localizedDescription)")
        }
        lock.withLock { captureEngine = engine }
    }

    public func stopCapture() {
        lock.withLock {
            captureEngine?.inputNode.removeTap(onBus: 0)
            captureEngine?.stop()
            captureEngine = nil
            playbackEngine?.stop()
            playbackEngine = nil
            player = nil
        }
    }

    // MARK: Playback

    private func playbackChain() throws -> (AVAudioEngine, AVAudioPlayerNode) {
        try lock.withLock {
            if let e = playbackEngine, let p = player, e.isRunning { return (e, p) }
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)
            if let outputDevice { Self.select(outputDevice, on: engine.outputNode) }
            engine.connect(node, to: engine.mainMixerNode, format: Self.modemFormat)
            engine.prepare()
            try engine.start()
            playbackEngine = engine
            player = node
            return (engine, node)
        }
    }

    public func play(_ samples: [Float], progress: (@Sendable (Double) -> Void)?, isCancelled: (@Sendable () -> Bool)?) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.modemFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let node: AVAudioPlayerNode
        do {
            (_, node) = try playbackChain()
        } catch {
            Log.shared.info("Audio output unavailable: \(error.localizedDescription)")
            return
        }
        let done = DispatchSemaphore(value: 0)
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in done.signal() }
        node.play()
        let duration = Double(samples.count) / Double(AudioModem.sampleRate)
        let started = Date()
        while done.wait(timeout: .now() + 0.1) == .timedOut {
            if isCancelled?() == true {
                node.stop()
                break
            }
            progress?(min(1, Date().timeIntervalSince(started) / duration))
        }
        progress?(1)
    }
}
#endif
