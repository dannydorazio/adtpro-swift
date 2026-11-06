import ADTProCore
import SwiftUI

/// Settings, in the same Liquid Glass style as the main window.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Serial", systemImage: "cable.connector") { SerialSettings() }
            Tab("Ethernet", systemImage: "network") { EthernetSettings() }
            Tab("Emulator", systemImage: "desktopcomputer") { SerialIPSettings() }
            Tab("Audio", systemImage: "waveform") { AudioSettings() }
        }
        .frame(width: 420)
        .background {
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular, in: .rect)
                .ignoresSafeArea()
        }
        .containerBackground(.clear, for: .window)
    }
}

// MARK: - Building blocks

/// A rounded glass panel holding a group of related settings.
struct GlassCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

/// A label on the left and its control on the right.
struct SettingRow<Control: View>: View {
    /// Shared width for pickers, so a column of them lines up.
    static var pickerWidth: CGFloat { 200 }

    let title: String
    let width: CGFloat?
    @ViewBuilder var control: Control

    init(_ title: String, width: CGFloat? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.width = width
        self.control = control()
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            if let width {
                control
                    .labelsHidden()
                    .frame(width: width, alignment: .trailing)
            } else {
                control
                    .labelsHidden()
                    .fixedSize()
            }
        }
    }
}

struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
    }
}

/// A numeric field for port numbers.
struct PortField: View {
    @Binding var value: Int

    var body: some View {
        TextField("Port", value: $value, format: .number.grouping(.never))
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
    }
}

/// The content of each settings tab.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(18)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Tabs

struct SerialSettings: View {
    @Environment(ServerModel.self) private var model
    @State private var ports = SerialTransport.availablePorts()

    var body: some View {
        @Bindable var model = model
        SettingsPage {
            GlassCard(title: "Port", systemImage: "cable.connector") {
                SettingRow("Device") {
                    HStack(spacing: 6) {
                        Picker("Device", selection: $model.settings.serialPort) {
                            Text("First available").tag("")
                            ForEach(ports, id: \.self) { Text(($0 as NSString).lastPathComponent).tag($0) }
                            if !model.settings.serialPort.isEmpty && !ports.contains(model.settings.serialPort) {
                                Text("\((model.settings.serialPort as NSString).lastPathComponent) (missing)")
                                    .tag(model.settings.serialPort)
                            }
                        }
                        Button {
                            ports = SerialTransport.availablePorts()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.glass)
                        .help("Look for serial ports again")
                    }
                }
                SettingRow("Speed", width: SettingRow<EmptyView>.pickerWidth) {
                    Picker("Speed", selection: $model.settings.serialSpeed) {
                        ForEach(AppSettings.serialSpeedChoices, id: \.self) { Text("\($0) baud").tag($0) }
                    }
                }
                SettingRow("Hardware handshaking") {
                    Toggle("Hardware handshaking", isOn: $model.settings.hardwareHandshake)
                        .toggleStyle(.switch)
                }
            }
            GlassCard(title: "Bootstrapping", systemImage: "bolt.fill") {
                SettingRow("Speed", width: SettingRow<EmptyView>.pickerWidth) {
                    Picker("Bootstrap speed", selection: $model.settings.bootstrapSpeed) {
                        ForEach(AppSettings.bootstrapSpeedChoices, id: \.self) { Text("\($0) baud").tag($0) }
                    }
                }
                SettingRow("Pacing", width: SettingRow<EmptyView>.pickerWidth) {
                    Picker("Pacing", selection: $model.settings.bootstrapPacing) {
                        ForEach(AppSettings.pacingChoices, id: \.self) { Text("\($0) ms per line").tag($0) }
                    }
                }
            }
            Footnote("Hardware handshaking is for an Apple IIc with an ImageWriter cable. Bootstrap text is typed into the Apple's monitor; slow it down if lines get dropped.")
        }
    }
}

struct EthernetSettings: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsPage {
            GlassCard(title: "UDP", systemImage: "network") {
                SettingRow("Port") { PortField(value: $model.settings.udpPort) }
            }
            GlassCard(title: "This Mac", systemImage: "desktopcomputer") {
                let addresses = UDPTransport.localAddresses()
                if addresses.isEmpty {
                    Text("No network connection").foregroundStyle(.secondary)
                }
                ForEach(addresses, id: \.self) { address in
                    Text(address)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }
            Footnote("Enter one of these addresses as the server in the ADTPro Ethernet client's configuration.")
        }
    }
}

struct SerialIPSettings: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsPage {
            GlassCard(title: "Serial over IP", systemImage: "desktopcomputer") {
                SettingRow("Emulator", width: SettingRow<EmptyView>.pickerWidth) {
                    Picker("Emulator", selection: $model.settings.serialIPRole) {
                        Text("Virtual ][").tag(SerialIPTransport.Role.listen)
                        Text("AppleWin, GSport, KEGS").tag(SerialIPTransport.Role.connect)
                    }
                }
                if model.settings.serialIPRole == .connect {
                    SettingRow("Host") {
                        TextField("Host", text: $model.settings.serialIPHost)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                    }
                }
                SettingRow("Port") { PortField(value: $model.settings.serialIPPort) }
            }
            switch model.settings.serialIPRole {
            case .listen:
                Footnote("ADTPro waits for the emulator. In Virtual ][, give the Super Serial Card in slot 2 a TCP connection to this port with an empty host, then choose Connect from its RS-232 panel.")
            case .connect:
                Footnote("ADTPro connects to the emulator and keeps retrying until it answers. Usual ports: AppleWin 1977, GSport and KEGS 6502.")
            }
        }
        .animation(.smooth, value: model.settings.serialIPRole)
    }
}

struct AudioSettings: View {
    @Environment(ServerModel.self) private var model
    @State private var devices = CoreAudioIO.devices()

    var body: some View {
        @Bindable var model = model
        SettingsPage {
            GlassCard(title: "Devices", systemImage: "waveform") {
                SettingRow("Input", width: SettingRow<EmptyView>.pickerWidth) {
                    Picker("Input", selection: $model.settings.audioInput) {
                        Text("System default").tag("")
                        ForEach(devices.filter { $0.inputChannels > 0 }) { Text($0.name).tag(String($0.id)) }
                    }
                }
                SettingRow("Output", width: SettingRow<EmptyView>.pickerWidth) {
                    Picker("Output", selection: $model.settings.audioOutput) {
                        Text("System default").tag("")
                        ForEach(devices.filter { $0.outputChannels > 0 }) { Text($0.name).tag(String($0.id)) }
                    }
                }
                HStack {
                    Spacer()
                    Button("Refresh Devices", systemImage: "arrow.clockwise") { devices = CoreAudioIO.devices() }
                        .buttonStyle(.glass)
                }
            }
            Footnote("Connect the input to the Apple's cassette output and the output to its cassette input, with the volume about halfway. Each bad packet costs a pause of several seconds.")
        }
    }
}
