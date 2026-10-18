import SwiftUI
import UIKit

/// Một ảnh đã gửi đi và kết quả kiểm tra của nó.
struct PhotoCheck: Identifiable {
    enum State {
        case queued
        case analyzing
        case done(InspectionResult)
        case failed(String)
    }

    let id = UUID()
    let image: UIImage
    var state: State = .queued
    var rawOutput = ""
    var elapsed: TimeInterval = 0
}

/// Một lượt gửi: tối đa 4 ảnh + ghi chú.
struct ChatTurn: Identifiable {
    let id = UUID()
    let note: String
    var checks: [PhotoCheck]
}

struct Attachment: Identifiable {
    let id = UUID()
    let image: UIImage
}

@MainActor
@Observable
final class InspectionViewModel {
    enum ModelState: Equatable {
        case downloading(received: Int64, total: Int64)
        case paused
        case loading
        case ready
        case failed(String)
    }

    /// Demo: mỗi lần chỉ phân tích 1 ảnh. Tăng lên để cho phép gửi nhiều ảnh một lượt.
    static let maxPhotos = 1

    var modelState: ModelState = .loading
    var downloadSpeed: Double = 0          // bytes/s
    var modelLoadTime: TimeInterval = 0
    var attachments: [Attachment] = []
    var note = ""
    var turns: [ChatTurn] = []
    private(set) var isAnalyzing = false

    var canSend: Bool { modelState == .ready && !attachments.isEmpty && !isAnalyzing }
    var canAttach: Bool { modelState == .ready && !isAnalyzing }

    private let llm = LLMService()
    private let downloader = ModelDownloader.shared
    private var speedSample: (date: Date, bytes: Int64)?

    /// Prompt dùng chung với script train (prompt.txt) — phải khớp từng chữ.
    private let prompt: String = {
        guard let url = Bundle.main.url(forResource: "prompt", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("Thiếu prompt.txt trong bundle")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    // MARK: - Model

    func start() async {
        downloader.onEvent = { [weak self] event in self?.handle(event) }
        if ModelStore.isInstalled {
            await loadModel()
        } else {
            startDownload()
        }
    }

    func startDownload() {
        let needed = ModelConfig.approxBytes + 500_000_000
        guard ModelStore.availableDiskBytes > needed else {
            modelState = .failed("Không đủ dung lượng. Cần trống khoảng \(Self.format(bytes: needed)).")
            return
        }
        speedSample = nil
        downloadSpeed = 0
        modelState = .downloading(received: 0, total: ModelConfig.approxBytes)
        downloader.start()
    }

    func pauseDownload() { downloader.pause() }

    /// Xoá model OTA và tải lại (dùng trong màn Info).
    func redownloadModel() async {
        await llm.unload()
        ModelStore.remove()
        startDownload()
    }

    private func handle(_ event: ModelDownloader.Event) {
        switch event {
        case let .progress(received, total):
            updateSpeed(received)
            modelState = .downloading(received: received, total: total)
        case .finished:
            Task { await loadModel() }
        case .paused:
            modelState = .paused
        case .failed(let msg):
            modelState = .failed(msg)
        }
    }

    private func updateSpeed(_ received: Int64) {
        let now = Date()
        guard let s = speedSample else { speedSample = (now, received); return }
        let dt = now.timeIntervalSince(s.date)
        guard dt >= 1 else { return }
        let instant = Double(received - s.bytes) / dt
        downloadSpeed = downloadSpeed == 0 ? instant : downloadSpeed * 0.7 + instant * 0.3
        speedSample = (now, received)
    }

    private func loadModel() async {
        modelState = .loading
        let t0 = Date()
        do {
            try await llm.load()
            modelLoadTime = Date().timeIntervalSince(t0)
            modelState = .ready
        } catch {
            modelState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Photos

    func attach(_ images: [UIImage]) {
        // Đã đủ số ảnh thì ảnh mới thay ảnh cũ nhất (maxPhotos = 1: chọn ảnh khác là thay luôn)
        // Chuẩn hoá orientation + resize giống bước prepare_dataset (cạnh dài 896)
        let new = images.suffix(Self.maxPhotos).map { Attachment(image: $0.normalized(maxSide: 896)) }
        attachments = Array((attachments + new).suffix(Self.maxPhotos))
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    func send() async {
        guard canSend else { return }
        // Ghi chú chỉ hiển thị trong lịch sử — model được train với prompt cố định nên không đưa vào prompt.
        let turn = ChatTurn(note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                            checks: attachments.map { PhotoCheck(image: $0.image) })
        turns.append(turn)
        attachments = []
        note = ""
        isAnalyzing = true
        defer { isAnalyzing = false }

        for check in turn.checks {
            await analyze(check.id, in: turn.id)
        }
    }

    private func analyze(_ checkID: UUID, in turnID: UUID) async {
        guard let ti = turns.firstIndex(where: { $0.id == turnID }),
              let ci = turns[ti].checks.firstIndex(where: { $0.id == checkID }) else { return }
        turns[ti].checks[ci].state = .analyzing
        let image = turns[ti].checks[ci].image
        let t0 = Date()
        var check = turns[ti].checks[ci]
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(checkID).jpg")
            try image.jpegData(compressionQuality: 0.9)?.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let text = try await llm.inspect(imageURL: url, prompt: prompt)
            check.rawOutput = text
            if let parsed = InspectionResult.parse(text) {
                check.state = .done(parsed)
            } else {
                check.state = .failed("Model trả về không phải JSON hợp lệ.")
            }
        } catch {
            check.state = .failed(error.localizedDescription)
        }
        check.elapsed = Date().timeIntervalSince(t0)
        turns[ti].checks[ci] = check
    }

    static func format(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension UIImage {
    /// Vẽ lại ảnh với orientation .up và cạnh dài tối đa `maxSide` px.
    func normalized(maxSide: CGFloat) -> UIImage {
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
