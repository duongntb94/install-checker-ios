import CoreML
import CryptoKit
import Foundation

/// Tải 1 model từ GitHub release bằng background URLSession:
/// 1. tải `manifest.json` của release,
/// 2. tải lần lượt từng asset (vẫn chạy khi app vào nền, resume được khi mất mạng),
/// 3. ghép các phần theo `target`, kiểm tra SHA-256,
/// 4. cài vào ModelStore (YOLO / RF-DETR: compile .mlpackage -> .mlmodelc trên máy).
final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Event {
        case progress(received: Int64, total: Int64)
        case finished
        case paused
        case failed(String)
    }

    static let gemma = ModelDownloader(kind: .gemma)
    static let yolo = ModelDownloader(kind: .yolo)
    static let detr = ModelDownloader(kind: .detr)
    static func shared(_ kind: ModelKind) -> ModelDownloader {
        switch kind {
        case .gemma: gemma
        case .yolo: yolo
        case .detr: detr
        }
    }
    static var all: [ModelDownloader] { [gemma, yolo, detr] }

    let kind: ModelKind
    var sessionID: String { "com.dan.poc.NetworkChecker.download.\(kind.rawValue)" }

    /// Luôn được gọi trên main thread.
    var onEvent: ((Event) -> Void)?
    /// Do AppDelegate set khi iOS đánh thức app để báo download xong lúc app ở nền.
    var backgroundCompletionHandler: (() -> Void)?

    /// Mọi trạng thái (manifest, part đang tải) chỉ đụng tới trên queue này — cũng là delegate queue của session.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private var manifest: ModelManifest?
    private var ignoreCancelUntil = Date.distantPast
    private let fm = FileManager.default

    private init(kind: ModelKind) {
        self.kind = kind
        super.init()
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForResource = 6 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    /// Caches/ModelDownload/<kind>/<tag>/ — part đã tải, resume data, manifest.
    private var staging: URL {
        fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ModelDownload/\(kind.rawValue)/\(ModelConfig.tag(kind))", isDirectory: true)
    }
    private var manifestFile: URL { staging.appendingPathComponent("manifest.json") }
    private func partFile(_ i: Int) -> URL { staging.appendingPathComponent("part-\(i).bin") }
    private func resumeFile(_ i: Int) -> URL { staging.appendingPathComponent("part-\(i).resume") }

    // MARK: - API

    /// Bắt đầu tải, hoặc gắn lại vào task đang chạy (app mở lại khi download vẫn chạy nền).
    func start() {
        Task {
            do {
                let m = try await loadManifest()
                queue.addOperation { [self] in
                    manifest = m
                    session.getAllTasks { [self] tasks in
                        queue.addOperation { [self] in
                            if tasks.contains(where: { $0.state == .running }) { return }
                            tasks.forEach { $0.cancel() }
                            startNextPart()
                        }
                    }
                }
            } catch {
                emit(.failed("Không tải được manifest của \(ModelConfig.tag(kind)): \(error.localizedDescription)"))
            }
        }
    }

    func pause() {
        session.getAllTasks { tasks in
            for case let task as URLSessionDownloadTask in tasks {
                task.cancel(byProducingResumeData: { [self] data in
                    guard let data, let i = Int(task.taskDescription ?? "") else { return }
                    try? data.write(to: resumeFile(i))
                })
            }
        }
    }

    /// Huỷ task đang chạy và xoá các part tải dở (dùng khi tải lại từ đầu).
    func reset() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            session.getAllTasks { [self] tasks in
                tasks.forEach { $0.cancel() }
                queue.addOperation { [self] in
                    manifest = nil
                    ignoreCancelUntil = Date().addingTimeInterval(3)   // không báo "paused" cho các task vừa huỷ
                    try? fm.removeItem(at: staging.deletingLastPathComponent())
                    done.resume()
                }
            }
        }
    }

    /// AppDelegate gọi để khởi tạo lại session khi app được đánh thức ở nền.
    func reconnect() { _ = session }

    // MARK: - Manifest

    private func loadManifest() async throws -> ModelManifest {
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: manifestFile),
           let m = try? JSONDecoder().decode(ModelManifest.self, from: data) {
            return m
        }
        let (data, response) = try await URLSession.shared.data(from: ModelConfig.manifestURL(kind))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "ModelDownloader", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        let m = try JSONDecoder().decode(ModelManifest.self, from: data)
        let needed = m.totalBytes + 300_000_000
        guard ModelStore.availableDiskBytes > needed else {
            throw NSError(domain: "ModelDownloader", code: 0, userInfo: [NSLocalizedDescriptionKey:
                "Không đủ dung lượng. Cần trống khoảng \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file))."])
        }
        try data.write(to: manifestFile)
        return m
    }

    // MARK: - Tải từng part (chạy trên `queue`)

    private func isDone(_ i: Int) -> Bool {
        guard let m = manifest else { return false }
        return ModelStore.fileSize(partFile(i)) == m.parts[i].size
    }

    private func completedBytes() -> Int64 {
        guard let m = manifest else { return 0 }
        return m.parts.indices.filter(isDone).reduce(0) { $0 + m.parts[$1].size }
    }

    private func startNextPart() {
        guard let m = manifest else { return }
        guard let i = m.parts.indices.first(where: { !isDone($0) }) else {
            assembleAndInstall(m)
            return
        }
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeFile(i)) {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: ModelConfig.assetURL(kind, m.parts[i].asset))
        }
        task.taskDescription = String(i)
        task.countOfBytesClientExpectsToReceive = m.parts[i].size
        task.resume()
        emit(.progress(received: completedBytes(), total: m.totalBytes))
    }

    // MARK: - Ghép + kiểm tra + cài (chạy trên `queue`)

    private func assembleAndInstall(_ m: ModelManifest) {
        let out = staging.appendingPathComponent("assembled", isDirectory: true)
        do {
            try? fm.removeItem(at: out)
            // Gom part theo target, giữ thứ tự trong manifest
            var order: [String] = []
            var byTarget: [String: [Int]] = [:]
            for (i, p) in m.parts.enumerated() {
                if byTarget[p.target] == nil { order.append(p.target) }
                byTarget[p.target, default: []].append(i)
            }
            for target in order {
                let dest = out.appendingPathComponent(target)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: dest.path, contents: nil)
                let writer = try FileHandle(forWritingTo: dest)
                var hasher = SHA256()
                for i in byTarget[target] ?? [] {
                    let reader = try FileHandle(forReadingFrom: partFile(i))
                    while let chunk = try reader.read(upToCount: 16 * 1024 * 1024), !chunk.isEmpty {
                        hasher.update(data: chunk)
                        try writer.write(contentsOf: chunk)
                    }
                    try reader.close()
                    try? fm.removeItem(at: partFile(i))   // giải phóng chỗ ngay (Gemma ~3.9 GB)
                }
                try writer.close()
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                if let expected = m.sha256[target], expected.lowercased() != digest {
                    try? fm.removeItem(at: staging)
                    throw NSError(domain: "ModelDownloader", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "Sai checksum \(target) — file tải về bị hỏng, thử tải lại."])
                }
            }

            let source: URL
            if let name = kind.coreMLName {
                // YOLO / RF-DETR: .mlpackage -> .mlmodelc (compile trên máy, vài trăm ms tới vài giây)
                let package = out.appendingPathComponent("\(name).mlpackage")
                source = try MLModel.compileModel(at: package)
            } else {
                source = out.appendingPathComponent("model.litertlm")
            }
            try ModelStore.install(kind, from: source, version: m.version)
            try? fm.removeItem(at: staging)
            manifest = nil
            emit(.finished)
        } catch {
            emit(.failed(error.localizedDescription))
        }
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { self.onEvent?(event) }
    }

    // MARK: - URLSessionDownloadDelegate (chạy trên `queue`)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let m = manifest else { return }
        emit(.progress(received: completedBytes() + totalBytesWritten, total: m.totalBytes))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let i = Int(downloadTask.taskDescription ?? "") else { return }
        try? fm.removeItem(at: resumeFile(i))
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            emit(.failed("GitHub trả về HTTP \(http.statusCode) cho part \(i + 1)."))
            return
        }
        // Tải lại sau khi app bị kill: manifest có thể chưa được nạp lại -> đọc từ staging.
        if manifest == nil, let data = try? Data(contentsOf: manifestFile) {
            manifest = try? JSONDecoder().decode(ModelManifest.self, from: data)
        }
        guard let m = manifest else { return }
        // File tạm bị xoá ngay khi hàm này return -> phải move đồng bộ ở đây.
        guard ModelStore.fileSize(location) == m.parts[i].size else {
            emit(.failed("Part \(i + 1) tải về sai dung lượng — thử tải lại."))
            return
        }
        try? fm.removeItem(at: partFile(i))
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try fm.moveItem(at: location, to: partFile(i))
        } catch {
            emit(.failed("Không lưu được part \(i + 1): \(error.localizedDescription)"))
            return
        }
        startNextPart()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as NSError? else { return }
        if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
           let i = Int(task.taskDescription ?? "") {
            try? data.write(to: resumeFile(i))
        }
        if error.code == NSURLErrorCancelled {
            if Date() < ignoreCancelUntil { return }
            emit(.paused)
        } else {
            emit(.failed(error.localizedDescription))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
