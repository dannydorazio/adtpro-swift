import ADTProCore
import ArgumentParser
import DiskImage
import Foundation

@main
struct ADTProCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "adtpro",
        abstract: "Apple Disk Transfer ProDOS: move disks and disk images between Apple II/III computers and this one.",
        version: "3.0.0",
        subcommands: [Serve.self, Ports.self, Disk.self],
        defaultSubcommand: Serve.self
    )
}

struct Ports: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List serial ports, audio devices and network addresses.")

    func run() throws {
        print("Serial ports:")
        let ports = SerialTransport.availablePorts()
        if ports.isEmpty { print("  (none found)") }
        for p in ports { print("  \(p)") }
        print("\nNetwork addresses (for Ethernet clients):")
        for a in UDPTransport.localAddresses() { print("  \(a)") }
        #if os(macOS)
        print("\nAudio devices (use the number with --audio-input / --audio-output):")
        for d in CoreAudioIO.devices() {
            var roles: [String] = []
            if d.inputChannels > 0 { roles.append("input") }
            if d.outputChannels > 0 { roles.append("output") }
            print("  \(d.id): \(d.name) [\(roles.joined(separator: ", "))]")
        }
        #else
        print("\nAudio uses arecord/aplay; list devices with `arecord -L` and pass one with --audio-input / --audio-output.")
        #endif
    }
}
