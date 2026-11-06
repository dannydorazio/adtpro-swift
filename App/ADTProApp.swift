import ADTProCore
import AppKit
import SwiftUI

@main
struct ADTProApp: App {
    @State private var model = ServerModel()
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("ADTPro", id: "main") {
            ContentView()
                .environment(model)
                .modifier(LaunchOptions(model: model, delegate: delegate))
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {}
            ConnectionCommands(model: model)
            BootstrapCommands(model: model)
            CommandGroup(replacing: .help) {
                Link("ADTPro Website", destination: URL(string: "https://adtpro.com")!)
            }
        }

        Window("Activity Log", id: "log") {
            LogWindow()
                .environment(model)
        }
        .defaultSize(width: 560, height: 360)
        .keyboardShortcut("l", modifiers: [.command, .option])

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: ServerModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A transfer is in progress."
        alert.informativeText = "Quitting now will interrupt it."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        model?.disconnect()
    }
}

struct ConnectionCommands: Commands {
    let model: ServerModel

    var body: some Commands {
        CommandMenu("Connection") {
            Button(model.isConnected ? "Disconnect" : "Connect") { model.toggleConnection() }
                .keyboardShortcut("k")
            Divider()
            Picker("Connection Type", selection: Binding(get: { model.settings.transport }, set: { model.settings.transport = $0 })) {
                ForEach(TransportKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Divider()
            Button("Choose Disk Images Folder…") { model.chooseWorkingDirectory() }
                .keyboardShortcut("o")
            Button("Show Disk Images Folder in Finder") { model.revealWorkingDirectory() }
        }
    }
}

struct BootstrapCommands: Commands {
    let model: ServerModel

    var body: some Commands {
        CommandMenu("Bootstrap") {
            let items = model.bootstrapItems
            if items.isEmpty {
                Text(model.isConnected ? "Not available over \(model.settings.transport.displayName)" : "Connect first")
            }
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
                    .keyboardShortcut(".")
            }
        }
    }
}

extension BootstrapItem.Group {
    static let allGroups: [BootstrapItem.Group] = [.prodos, .dos, .sos]
}

/// Launch options: `-connect <transport>` starts serving, `-settings YES` opens Settings.
struct LaunchOptions: ViewModifier {
    let model: ServerModel
    let delegate: AppDelegate
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onAppear {
            delegate.model = model
            model.handleLaunchArguments()
            if UserDefaults.standard.bool(forKey: "settings") { openSettings() }
        }
    }
}
