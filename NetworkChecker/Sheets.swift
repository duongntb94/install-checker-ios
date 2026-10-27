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
                Section {
                    Picker("Engine", selection: Binding(
                        get: { vm.engine },
                        set: { new in Task { await vm.switchEngine(to: new) } })) {
                        ForEach(InspectionEngine.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(vm.isAnalyzing)
                } footer: {
                    Text(vm.engine == .yolo
                         ? "YOLO detects each socket and port, then fixed rules compare them with the checklist. 5 MB one-time download, runs in milliseconds."
                         : "Gemma looks at the whole photo and writes the result itself. 3.9 GB one-time download.")
                }
                if vm.engine == .yolo {
                    Section("Model") {
                        row("Name", "YOLO26n · fine-tuned · 6 classes")
                        row("Runtime", "Core ML · Vision · on-device")
                        row("Release", ModelConfig.tag(.yolo))
                        if let url = ModelStore.locate(.yolo) {
                            row("Size", InspectionViewModel.format(bytes: ModelStore.fileSize(url)))
                        }
                        if vm.modelState == .ready {
                            row("Load time", String(format: "%.2fs", vm.modelLoadTime))
                        }
                    }
                } else {
                Section("Model") {
                    row("Name", "Gemma 4 E2B · fine-tuned")
                    row("Runtime", "LiteRT-LM · on-device")
                    row("Release", ModelConfig.tag(.gemma))
                    if let url = ModelStore.locate(.gemma) {
                        row("Size", InspectionViewModel.format(bytes: ModelStore.fileSize(url)))
                        row("Source", url == ModelStore.sideloadedURL ? "Copied via Finder" : "GitHub release")
                    }
                    if vm.modelState == .ready {
                        row("Load time", String(format: "%.1fs", vm.modelLoadTime))
                    }
                    // Không có entitlement increased-memory-limit thì con số này thấp hơn hẳn (~1–2 GB sau khi load model)
                    row("Free app memory", InspectionViewModel.format(bytes: Int64(os_proc_available_memory())))
                }
                }
                Section {
                    Button("Re-download model", role: .destructive) { confirmRedownload = true }
                        .disabled(vm.isAnalyzing)
                } footer: {
                    Text("Models are downloaded from the project's GitHub releases. Photos never leave this device — notes are kept in the history but not sent to the model.")
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
