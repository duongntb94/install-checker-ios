import PhotosUI
import SwiftUI

struct ContentView: View {
    @Environment(InspectionViewModel.self) private var vm
    @State private var showChecklist = false
    @State private var showInfo = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ComposerView()
            }
        }
        .sheet(isPresented: $showChecklist) { ChecklistSheet() }
        .sheet(isPresented: $showInfo) { InfoSheet() }
    }

    private var header: some View {
        HStack {
            Text("Install Checker")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            HStack(spacing: 28) {
                Button { showChecklist = true } label: {
                    Image(systemName: "checklist")
                }
                Button { showInfo = true } label: {
                    Image(systemName: "info.circle")
                }
            }
            .font(.title2)
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(Capsule().fill(Theme.chrome))
            .overlay(Capsule().stroke(.white.opacity(0.12)))
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var content: some View {
        if vm.modelState != .ready {
            ModelStatusView()
        } else if vm.turns.isEmpty {
            EmptyStateView()
        } else {
            ChatListView()
        }
    }
}

// MARK: - Theme

enum Theme {
    static let background = LinearGradient(
        colors: [Color(red: 0.05, green: 0.07, blue: 0.15), Color(red: 0.13, green: 0.08, blue: 0.24)],
        startPoint: .top, endPoint: .bottom)
    static let chrome = Color(red: 0.10, green: 0.12, blue: 0.20)
    static let composer = Color(red: 0.18, green: 0.15, blue: 0.24)
    static let field = Color.white.opacity(0.12)
    static let card = Color.white.opacity(0.07)
    static let accent = Color(red: 0.16, green: 0.52, blue: 1.0)
    static let pass = Color(red: 0.20, green: 0.80, blue: 0.45)
    static let fail = Color(red: 1.0, green: 0.30, blue: 0.30)
}

// MARK: - Empty state

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "network")
                .font(.system(size: 56, weight: .light))
            Text("Add an install photo with the + button.\nI'll check it against your checklist.")
                .font(.title3)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.55))
        .padding(.horizontal, 32)
    }
}

// MARK: - Model download / load

struct ModelStatusView: View {
    @Environment(InspectionViewModel.self) private var vm

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.white.opacity(0.6))
                .symbolEffect(.pulse, isActive: isBusy)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            detail
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 420)
    }

    private var isBusy: Bool {
        if case .downloading = vm.modelState { return true }
        return vm.modelState == .loading
    }

    private var icon: String {
        switch vm.modelState {
        case .downloading, .paused: "arrow.down.circle"
        case .loading, .ready: "cpu"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch vm.modelState {
        case .downloading: "Downloading on-device model"
        case .paused: "Download paused"
        case .loading, .ready: "Loading model…"
        case .failed: "Model unavailable"
        }
    }

    @ViewBuilder private var detail: some View {
        switch vm.modelState {
        case let .downloading(received, total):
            let fraction = total > 0 ? Double(received) / Double(total) : 0
            VStack(spacing: 10) {
                ProgressView(value: min(fraction, 1))
                    .tint(Theme.accent)
                HStack {
                    Text("\(InspectionViewModel.format(bytes: received)) of \(InspectionViewModel.format(bytes: total))")
                    Spacer()
                    Text(eta(received: received, total: total))
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                Text("One-time download. Checks then run fully offline on this iPhone. You can leave the app — the download continues in the background.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 6)
                Button("Pause") { vm.pauseDownload() }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .padding(.top, 4)
            }
        case .paused:
            Button("Resume download") { vm.startDownload() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        case .loading, .ready:
            ProgressView().tint(.white)
        case .failed(let msg):
            VStack(spacing: 14) {
                Text(msg)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.6))
                Button("Try again") { vm.startDownload() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
    }

    private func eta(received: Int64, total: Int64) -> String {
        guard vm.downloadSpeed > 0 else { return "" }
        let speed = InspectionViewModel.format(bytes: Int64(vm.downloadSpeed)) + "/s"
        let secs = Double(total - received) / vm.downloadSpeed
        let f = DateComponentsFormatter()
        f.allowedUnits = secs >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return "\(speed) · \(f.string(from: secs) ?? "") left"
    }
}

// MARK: - Composer

struct ComposerView: View {
    @Environment(InspectionViewModel.self) private var vm
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @FocusState private var noteFocused: Bool

    var body: some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 14) {
            if !vm.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(vm.attachments) { a in
                            thumbnail(a)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                }
            }
            HStack(spacing: 12) {
                Menu {
                    Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    Button { showLibrary = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Theme.field))
                }
                .disabled(!vm.canAttach)
                .opacity(vm.canAttach ? 1 : 0.4)

                TextField("Ask or add a note…", text: $vm.note, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($noteFocused)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Theme.field))
                    .disabled(vm.modelState != .ready)

                Button {
                    noteFocused = false
                    Task { await vm.send() }
                } label: {
                    Image(systemName: vm.isAnalyzing ? "hourglass" : "arrow.up")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(vm.canSend ? Theme.accent : Color.white.opacity(0.15)))
                }
                .disabled(!vm.canSend)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.composer.ignoresSafeArea(edges: .bottom))
        .photosPicker(isPresented: $showLibrary, selection: $pickerItems,
                      maxSelectionCount: InspectionViewModel.maxPhotos,
                      matching: .images)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var images: [UIImage] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        images.append(img)
                    }
                }
                vm.attach(images)
                pickerItems = []
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in vm.attach([img]) }
                .ignoresSafeArea()
        }
    }

    private func thumbnail(_ a: Attachment) -> some View {
        Image(uiImage: a.image)
            .resizable()
            .scaledToFill()
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                Button { vm.removeAttachment(a.id) } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.black))
                }
                .offset(x: 8, y: -8)
            }
    }
}
