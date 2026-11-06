import SwiftUI

/// Protocol activity, in its own window so the main window can stay small.
struct LogWindow: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.log) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .onChange(of: model.log.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .frame(minWidth: 460, minHeight: 280)
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $model.settings.traceEnabled) {
                    Label("Trace Protocol", systemImage: "waveform.path.ecg")
                }
                .help("Log every protocol exchange")
            }
            ToolbarItem {
                Button("Clear", systemImage: "trash") { model.clearLog() }
            }
        }
    }
}
