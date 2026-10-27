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

/// Engine kiểm tra ảnh. Cả hai model đều tải từ GitHub release lần đầu mở app.
/// YOLO: Core ML ~5 MB (release `yolo-v*`). Gemma: LiteRT-LM ~3.9 GB (release `model-v*`).
enum InspectionEngine: String, CaseIterable, Identifiable {
    case yolo, gemma
    var id: String { rawValue }
    var title: String { self == .yolo ? "YOLO26n + rules" : "Gemma 4 E2B" }
    var kind: ModelKind { self == .yolo ? .yolo : .gemma }
    /// Cạnh dài ảnh đưa vào model — khớp lúc train (YOLO: yolo/src 1280, Gemma: prepare_dataset 896).
    var maxSide: CGFloat { self == .yolo ? 1280 : 896 }
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

    /// Lưu lựa chọn engine giữa các lần mở app. Mặc định YOLO (model nhỏ, tải vài giây).
    private(set) var engine: InspectionEngine =
        InspectionEngine(rawValue: UserDefaults.standard.string(forKey: "inspectionEngine") ?? "") ?? .yolo

    private let llm = LLMService()
    private var detector: YOLODetector?
    private var downloader: ModelDownloader { ModelDownloader.shared(engine.kind) }
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
        // Cả hai downloader đều báo về đây; handle() chỉ hiển thị sự kiện của engine đang chọn.
        for dl in ModelDownloader.all {
            let kind = dl.kind
            dl.onEvent = { [weak self] event in self?.handle(event, from: kind) }
        }
        if ModelStore.isInstalled(engine.kind) {
            await loadActiveModel()
        } else {
            startDownload()
        }
    }

    func startDownload() {
        speedSample = nil
        downloadSpeed = 0
        modelState = .downloading(received: 0, total: ModelConfig.approxBytes(engine.kind))
        downloader.start()
    }

    func pauseDownload() { downloader.pause() }

    /// Đổi engine (màn Info). Engine chưa có model thì bắt đầu tải.
    func switchEngine(to new: InspectionEngine) async {
        guard new != engine, !isAnalyzing else { return }
        if case .downloading = modelState { downloader.pause() }   // tạm dừng model đang tải dở
        engine = new
        UserDefaults.standard.set(new.rawValue, forKey: "inspectionEngine")
        attachments = []
        await start()
    }

    /// Xoá model của engine đang chọn và tải lại từ GitHub (màn Info).
    func redownloadModel() async {
        switch engine {
        case .gemma: await llm.unload()
        case .yolo: detector = nil
        }
        await downloader.reset()
        ModelStore.remove(engine.kind)
        startDownload()
    }

    private func handle(_ event: ModelDownloader.Event, from kind: ModelKind) {
        guard kind == engine.kind else { return }
        switch event {
        case let .progress(received, total):
            updateSpeed(received)
            modelState = .downloading(received: received, total: total)
        case .finished:
            Task { await loadActiveModel() }
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

    private func loadActiveModel() async {
        modelState = .loading
        let t0 = Date()
        do {
            switch engine {
            case .gemma:
                try await llm.load()
            case .yolo:
                if detector == nil {
                    let url = ModelStore.locate(.yolo)
                    detector = try await Task.detached { try YOLODetector(modelURL: url) }.value
                }
            }
            modelLoadTime = Date().timeIntervalSince(t0)
            modelState = .ready
        } catch {
            modelState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Photos

    func attach(_ images: [UIImage]) {
        // Đã đủ số ảnh thì ảnh mới thay ảnh cũ nhất (maxPhotos = 1: chọn ảnh khác là thay luôn)
        // Chuẩn hoá orientation + resize theo engine (Gemma 896 như prepare_dataset, YOLO 1280 như yolo/src)
        let side = engine.maxSide
        let new = images.suffix(Self.maxPhotos).map { Attachment(image: $0.normalized(maxSide: side)) }
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
        if engine == .yolo {
            do {
                guard let detector else { throw YOLODetector.DetectorError.modelNotFound }
                let dets = try await Task.detached { try detector.detect(image) }.value
                let result = InstallRules.evaluate(dets, imageSize: image.size)
                check.rawOutput = dets.map {
                    String(format: "%@ %.2f [%.0f, %.0f, %.0f, %.0f]", $0.label, $0.confidence,
                           $0.box.minX, $0.box.minY, $0.box.maxX, $0.box.maxY)
                }.joined(separator: "\n")
                check.state = .done(result)
            } catch {
                check.state = .failed(error.localizedDescription)
            }
            check.elapsed = Date().timeIntervalSince(t0)
            turns[ti].checks[ci] = check
            return
        }
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
