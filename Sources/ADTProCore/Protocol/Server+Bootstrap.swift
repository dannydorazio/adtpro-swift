import Foundation

/// Transports that can play a bootstrap as cassette audio.
public protocol AudioBootstrapping: Transport {
    func playBootstrap(_ bytes: [UInt8], progress: @escaping @Sendable (Double) -> Void, isCancelled: @escaping @Sendable () -> Bool)
}

extension ADTProServer {
    /// A client asked for a bootstrap file ('F' envelope). Sent synchronously:
    /// the client does nothing else until it has the whole file.
    func sendBootstrapFileWide(_ envelope: WideEnvelope) throws {
        guard let payload = try pullPayloadWide(envelope), let first = payload.first else { return }
        guard let request = BootstrapFileRequest(rawValue: first) else {
            log.trace("Unknown bootstrap file request \(first.hex)")
            return
        }
        status(Messages.bootstrap)
        detail("")
        let plan = try request.plan()
        log.trace("Client requested bootstrap file \(plan.name)")
        send(plan, isCancelled: { [self] in !running })
    }

    /// Start a user-requested bootstrap on its own thread. Throws if a payload is
    /// missing or the item makes no sense for this transport.
    public func startBootstrap(_ item: BootstrapItem) throws {
        let plan = try item.plan(for: transport.kind)
        cancelBootstrap()
        while bootstrapActiveFlag { Thread.sleep(forTimeInterval: 0.01) }
        setBootstrapActive(true)
        resetBootstrapCancel()
        let thread = Thread { [self] in
            status(Messages.bootstrap)
            detail(plan.name)
            send(plan, isCancelled: { [self] in bootstrapCancelled || !running })
            setBootstrapActive(false)
        }
        thread.name = "ADTPro bootstrap"
        thread.start()
    }

    public func cancelBootstrap() {
        setBootstrapCancelled()
    }

    /// Send a bootstrap plan over the transport.
    func send(_ plan: BootstrapPlan, isCancelled: @escaping @Sendable () -> Bool) {
        let start = Date()
        let total = plan.byteCount
        emit(.progress(done: 0, total: total))
        let reportEvery = max(1, total / 200)

        switch plan.content {
        case .audio(let bytes):
            guard let audio = transport as? AudioBootstrapping else {
                log.info("Transport cannot play audio bootstraps")
                return
            }
            audio.playBootstrap(bytes, progress: { [self] fraction in
                emit(.progress(done: Int(fraction * Double(total)), total: total))
            }, isCancelled: isCancelled)

        case .binary(let bytes, let trigger, let sendLength, let settle, let slowStart):
            transport.setTemporarySpeed(plan.serialSpeed ?? options.bootstrapSpeed)
            if let trigger {
                transport.write(trigger)
                if settle {
                    // Give SOS a moment to put up its message.
                    transport.flush()
                    sleep(milliseconds: 20)
                }
            }
            if sendLength {
                transport.write([UInt8(bytes.count & 0xFF), UInt8((bytes.count >> 8) & 0xFF)])
            }
            var i = 0
            while i < bytes.count && !isCancelled() {
                if slowStart && i < 2 {
                    // Sent unthrottled, SOS was seen to miss the first byte.
                    transport.write(bytes[i])
                    transport.flush()
                    sleep(milliseconds: 1)
                    i += 1
                    continue
                }
                let end = min(bytes.count, i + 64)
                transport.write(Array(bytes[i..<end]))
                transport.flush()
                i = end
                if i % reportEvery < 64 || i == bytes.count { emit(.progress(done: i, total: total)) }
            }
            transport.flush()

        case .text(let text, let slowFirst, let slowLast):
            transport.setTemporarySpeed(plan.serialSpeed ?? options.bootstrapSpeed)
            let bytes = Array(text.utf8)
            let lines = bytes.filter { $0 == 0x0D }.count
            let pacing = options.bootstrapPacing
            let slowPacing = max(500, pacing)
            var line = 0
            for (i, b) in bytes.enumerated() {
                if isCancelled() { break }
                if b == 0x0D {
                    transport.write(0x8D)
                    transport.flush()
                    let slow = slowFirst > line || line > lines - slowLast
                    sleep(milliseconds: slow ? slowPacing : pacing)
                    line += 1
                } else if b != 0x0A {
                    transport.write(b)
                }
                if i % reportEvery == 0 || i == bytes.count - 1 { emit(.progress(done: i + 1, total: total)) }
            }
            transport.flush()
        }

        let cancelled = isCancelled()
        if !cancelled {
            let seconds = elapsedSeconds(since: start)
            detail(Messages.fileSent(seconds))
            log.info("\(plan.name) sent in \(seconds) seconds.")
            transport.discardInput()
        }
        transport.setTemporarySpeed(nil)
        if !cancelled, let speed = plan.speedAfterwards, transport.kind == .serial {
            transport.setSpeed(speed)
            emit(.serialSpeedChanged(speed))
        }
        if !cancelled { emit(.bootstrapFinished(nextStep: plan.nextStep)) }
    }
}
