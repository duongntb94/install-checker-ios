import SwiftUI

struct ChatListView: View {
    @Environment(InspectionViewModel.self) private var vm

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(vm.turns) { turn in
                        UserBubble(turn: turn)
                        ForEach(Array(turn.checks.enumerated()), id: \.element.id) { i, check in
                            ResultCard(check: check, index: i + 1, count: turn.checks.count)
                                .id(check.id)
                        }
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: vm.turns.last?.id) { _, _ in
                guard let id = vm.turns.last?.checks.first?.id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }
}

/// Ảnh + ghi chú người dùng gửi, căn phải như tin nhắn.
struct UserBubble: View {
    let turn: ChatTurn

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(turn.checks) { c in
                    Image(uiImage: c.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            if !turn.note.isEmpty {
                Text(turn.note)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Theme.accent))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Kết quả kiểm tra một ảnh: ảnh có khoanh lỗi, PASS/FAIL, danh sách lỗi.
struct ResultCard: View {
    let check: PhotoCheck
    let index: Int
    let count: Int
    @State private var selected: Int?
    @State private var showRaw = false
    @State private var showFullScreen = false

    private var result: InspectionResult? {
        if case .done(let r) = check.state { return r }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(count > 1 ? "Photo \(index) of \(count)" : "Photo")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                statusBadge
            }

            AnnotatedImageView(image: check.image, errors: result?.errors ?? [], selected: selected)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture { if result != nil { showFullScreen = true } }

            detail
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.card))
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenResult(image: check.image, errors: result?.errors ?? [], selected: $selected)
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch check.state {
        case .queued:
            badge("Queued", icon: "clock", color: .gray)
        case .analyzing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Checking…").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            }
        case .done(let r):
            r.passed
                ? badge("PASS", icon: "checkmark.seal.fill", color: Theme.pass)
                : badge("FAIL · \(r.errors.count) issue\(r.errors.count == 1 ? "" : "s")",
                        icon: "exclamationmark.triangle.fill", color: Theme.fail)
        case .failed:
            badge("Error", icon: "xmark.octagon.fill", color: .orange)
        }
    }

    private func badge(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    @ViewBuilder private var detail: some View {
        switch check.state {
        case .queued, .analyzing:
            EmptyView()
        case .done(let r):
            if r.passed {
                Text("Setup matches the checklist. No issues found.")
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(r.errors.enumerated()), id: \.offset) { i, e in
                        issueRow(i, e)
                    }
                }
            }
            footer
        case .failed(let msg):
            Text(msg).font(.footnote).foregroundStyle(.orange)
            footer
        }
    }

    private func issueRow(_ i: Int, _ e: InspectionResult.InstallError) -> some View {
        Button {
            withAnimation(.snappy) { selected = (selected == i) ? nil : i }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text("\(i + 1)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.fail))
                Text(e.desc)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected == i ? Theme.fail.opacity(0.22) : Color.white.opacity(0.05)))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        DisclosureGroup(isExpanded: $showRaw) {
            Text(check.rawOutput.isEmpty ? "(empty)" : check.rawOutput)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Text(String(format: "On-device · %.1fs", check.elapsed))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
        }
        .tint(.white.opacity(0.45))
    }
}

/// Xem ảnh lớn, pinch để zoom.
struct FullScreenResult: View {
    let image: UIImage
    let errors: [InspectionResult.InstallError]
    @Binding var selected: Int?
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            AnnotatedImageView(image: image, errors: errors, selected: selected)
                .scaleEffect(scale)
                .gesture(MagnifyGesture()
                    .onChanged { scale = max(1, $0.magnification) }
                    .onEnded { _ in withAnimation { scale = 1 } })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }
            .padding()
        }
    }
}
