import ADTProCore
import SwiftUI

/// The main window: a small, fixed-size pane of Liquid Glass.
struct ContentView: View {
    @Environment(ServerModel.self) private var model

    static let size = CGSize(width: 380, height: 380)

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            StatusOrb()
                .padding(.top, 30)
            StatusText()
                .padding(.top, 12)
                .padding(.horizontal, 24)
            Spacer(minLength: 10)
            TransportSelector(selection: $model.settings.transport, isDisabled: model.isBusy)
                .padding(.horizontal, 18)
            LocationChips()
                .padding(.top, 10)
                .padding(.horizontal, 18)
            ActionBar()
                .padding(.top, 12)
                .padding([.horizontal, .bottom], 18)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular, in: .rect)
                .ignoresSafeArea()
        }
        .containerBackground(.clear, for: .window)
        .sheet(item: $model.pendingBootstrap) { request in
            BootstrapSheet(request: request)
        }
        .alert("Next Step", isPresented: Binding(get: { model.nextStepMessage != nil }, set: { if !$0 { model.nextStepMessage = nil } })) {
            Button("OK") { model.nextStepMessage = nil }
        } message: {
            Text(model.nextStepMessage ?? "")
        }
        .alert("ADTPro", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("A transfer is in progress. Disconnect anyway?", isPresented: $model.confirmDisconnect) {
            Button("Disconnect", role: .destructive) { model.disconnect() }
        }
    }
}

// MARK: - Status

extension ServerModel {
    var statusColor: Color {
        guard isConnected else { return .secondary }
        return isBusy ? .orange : .green
    }
}

/// A glass disc showing the transport, ringed by transfer progress.
struct StatusOrb: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        ZStack {
            Circle()
                .fill(.clear)
                .glassEffect(.regular.tint(model.statusColor.opacity(model.isConnected ? 0.18 : 0)), in: .circle)

            Circle()
                .stroke(model.statusColor.opacity(0.25), lineWidth: 4)
                .padding(6)

            Circle()
                .trim(from: 0, to: model.progressFraction ?? (model.isConnected ? 1 : 0))
                .stroke(model.statusColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(6)
                .animation(.easeOut(duration: 0.2), value: model.progressFraction)

            VStack(spacing: 4) {
                Image(systemName: model.settings.transport.symbolName)
                    .font(.system(size: 34, weight: .regular))
                    .symbolEffect(.pulse, options: .repeating, isActive: model.isBusy)
                    .contentTransition(.symbolEffect(.replace))
                if let fraction = model.progressFraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(model.isConnected ? .primary : .secondary)
        }
        .frame(width: 104, height: 104)
        .animation(.smooth, value: model.isConnected)
    }
}

struct StatusText: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        VStack(spacing: 4) {
            Text(model.status)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    var subtitle: String {
        if !model.detail.isEmpty { return model.detail }
        if model.isConnected && model.settings.transport == .ethernet {
            let addresses = UDPTransport.localAddresses().joined(separator: " or ")
            return "Server address \(addresses), port \(model.settings.udpPort)"
        }
        return model.isConnected ? model.connectionSummary : "Choose a connection and press Connect."
    }
}

// MARK: - Transport selector

extension TransportKind {
    var symbolName: String {
        switch self {
        case .serial: return "cable.connector"
        case .ethernet: return "network"
        case .audio: return "waveform"
        case .serialIP: return "desktopcomputer"
        }
    }

    var shortName: String {
        switch self {
        case .serial: return "Serial"
        case .ethernet: return "Ethernet"
        case .audio: return "Audio"
        case .serialIP: return "Emulator"
        }
    }
}

/// A glass track with a selection that slides between transports.
struct TransportSelector: View {
    @Binding var selection: TransportKind
    var isDisabled: Bool
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TransportKind.allCases, id: \.self) { kind in
                Button {
                    withAnimation(.bouncy(duration: 0.35)) { selection = kind }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: kind.symbolName)
                            .font(.system(size: 15, weight: .medium))
                        Text(kind.shortName)
                            .font(.caption2.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(selection == kind ? Color.primary : Color.secondary)
                    .background {
                        if selection == kind {
                            Capsule()
                                .fill(.tint.opacity(0.28))
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .help(kind.displayName)
            }
        }
        .padding(4)
        .glassEffect(.regular.interactive(), in: .capsule)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.6 : 1)
    }
}

// MARK: - Folder and virtual drives

struct LocationChips: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    Button("Choose Folder…") { model.chooseWorkingDirectory() }
                    Button("Show in Finder") { model.revealWorkingDirectory() }
                } label: {
                    Label(folderName, systemImage: "folder.fill")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity)
                }
                .help("Disk images folder: \(model.workingDirectory)")

                DriveChip(drive: 1)
                DriveChip(drive: 2)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }

    var folderName: String {
        let name = (model.workingDirectory as NSString).lastPathComponent
        return name.isEmpty ? "/" : name
    }
}

struct DriveChip: View {
    @Environment(ServerModel.self) private var model
    let drive: Int

    var isDefault: Bool {
        (drive == 1 ? model.settings.virtualDrive1 : model.settings.virtualDrive2).isEmpty
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let active = model.lastActivity[drive].map { context.date.timeIntervalSince($0) < 0.5 } ?? false
            Menu {
                Text((model.virtualDrivePath(drive) as NSString).lastPathComponent)
                Button("Choose Image…") { model.chooseVirtualDrive(drive) }
                Button("Use Default (Virtual\(drive == 1 ? "" : "2").po)") { model.resetVirtualDrive(drive) }
                    .disabled(isDefault)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.virtualDrivePath(drive))])
                }
            } label: {
                Label("\(drive)", systemImage: active ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill")
                    .foregroundStyle(active ? Color.orange : Color.primary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .fixedSize()
            .help("Virtual drive \(drive): \(model.virtualDrivePath(drive))")
        }
    }
}

// MARK: - Actions

struct ActionBar: View {
    @Environment(ServerModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                SettingsLink {
                    Image(systemName: "gearshape")
                        .frame(width: 18, height: 18)
                }
                .help("Settings")

                Menu {
                    let items = model.bootstrapItems
                    ForEach(BootstrapItem.Group.allGroups, id: \.self) { group in
                        let inGroup = items.filter { $0.group == group }
                        if !inGroup.isEmpty {
                            Section(group.rawValue) {
                                ForEach(inGroup) { item in
                                    Button(item.title + "…") { model.prepareBootstrap(item) }
                                }
                            }
                        }
                    }
                    if !items.isEmpty {
                        Divider()
                        Button("Stop Sending") { model.cancelBootstrap() }
                    }
                } label: {
                    Image(systemName: "bolt.fill")
                        .frame(width: 18, height: 18)
                }
                .menuIndicator(.hidden)
                .disabled(model.bootstrapItems.isEmpty)
                .help(model.isConnected ? "Bootstrap the Apple" : "Connect to bootstrap")

                Button {
                    openWindow(id: "log")
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .frame(width: 18, height: 18)
                }
                .help("Activity log")

                Spacer(minLength: 0)

                Button {
                    model.toggleConnection()
                } label: {
                    Label(model.isConnected ? "Disconnect" : "Connect",
                          systemImage: model.isConnected ? "stop.fill" : "play.fill")
                        .frame(minWidth: 110)
                }
                .buttonStyle(.glassProminent)
                .tint(model.isConnected ? .red : .accentColor)
                .keyboardShortcut("k")
            }
            .buttonStyle(.glass)
            .menuStyle(.button)
            .controlSize(.large)
        }
    }
}

// MARK: - Bootstrap instructions

struct BootstrapSheet: View {
    @Environment(ServerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: BootstrapRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(request.item.title, systemImage: "bolt.fill")
                .font(.title3.bold())
            ScrollView {
                Text(request.instructions)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 260)
            if model.settings.transport == .serial {
                Text("Bootstrap speed \(model.settings.bootstrapSpeed) baud, \(model.settings.bootstrapPacing) ms per line")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.pendingBootstrap = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                Button("Send") { model.startBootstrap(request.item); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 360)
    }
}
