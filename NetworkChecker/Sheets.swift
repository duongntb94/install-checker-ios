import os
import SwiftUI

/// Quy tắc setup chuẩn mà model đã được train (khớp với data/labels.jsonl).
struct ChecklistSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let items: [(icon: String, title: String, detail: String)] = [
        ("powerplug", "Socket 1", "Power adapter plugged in"),
        ("circle.dashed", "Socket 2", "Empty"),
        ("powerplug.fill", "Socket 3", "Power cord plugged in"),
        ("powerplug.fill", "Socket 4", "Power cord plugged in"),
        ("cable.connector", "Left data port", "Yellow LAN cable"),
        ("circle.dashed", "Right data port", "Empty — no other cable"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items, id: \.title) { item in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.headline)
                                Text(item.detail).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: item.icon).foregroundStyle(Theme.accent)
                        }
                    }
                } footer: {
                    Text("Every photo is checked against this standard setup. A photo can have several issues.")
                }
            }
            .navigationTitle("Install Checklist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct InfoSheet: View {
    @Environment(InspectionViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRedownload = false

    var body: some View {
        NavigationStack {
            List {
                Section("Model") {
                    row("Name", "Gemma 4 E2B · fine-tuned")
                    row("Runtime", "LiteRT-LM · on-device")
                    row("Version", ModelConfig.version)
                    if let url = ModelStore.locate() {
                        row("Size", InspectionViewModel.format(bytes: ModelStore.fileSize(url)))
                        row("Source", url == ModelStore.sideloadedURL ? "Copied via Finder"
                            : url == ModelStore.installedURL ? "Downloaded" : "Bundled in app")
                    }
                    if vm.modelState == .ready {
                        row("Load time", String(format: "%.1fs", vm.modelLoadTime))
                    }
                    // Không có entitlement increased-memory-limit thì con số này thấp hơn hẳn (~1–2 GB sau khi load model)
                    row("Free app memory", InspectionViewModel.format(bytes: Int64(os_proc_available_memory())))
                }
                Section {
                    Button("Re-download model", role: .destructive) { confirmRedownload = true }
                        .disabled(vm.isAnalyzing)
                } footer: {
                    Text("Photos never leave this device. The model only evaluates photos — notes are kept in the history but not sent to the model.")
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .confirmationDialog("Delete the downloaded model and download it again?",
                                isPresented: $confirmRedownload, titleVisibility: .visible) {
                Button("Re-download", role: .destructive) {
                    dismiss()
                    Task { await vm.redownloadModel() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }
}
