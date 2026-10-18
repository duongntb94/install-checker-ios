import Foundation

/// Tải model OTA bằng background URLSession: vẫn tải tiếp khi app vào nền / bị iOS tạm dừng,
/// và resume được nếu mất mạng giữa chừng.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    enum Event {
        case progress(received: Int64, total: Int64)
        case finished
        case paused
        case failed(String)
    }

    static let shared = ModelDownloader()
    static let sessionID = "com.dan.poc.NetworkChecker.model-download"

    /// Luôn được gọi trên main thread.
    var onEvent: ((Event) -> Void)?
    /// Do AppDelegate set khi iOS đánh thức app để báo download xong lúc app ở nền.
    var backgroundCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let config: URLSessionConfiguration
        if Self.isLocalNetwork(ModelConfig.downloadURL) {
            // Tải từ Mac trong LAN (python3 -m http.server, xem README): session thường để iOS hỏi quyền Local Network
            // cho app; tải 1–2 phút nên không cần chạy nền.
            config = .default
        } else {
            config = .background(withIdentifier: Self.sessionID)
            config.isDiscretionary = false
            config.sessionSendsLaunchEvents = true
        }
        config.timeoutIntervalForResource = 6 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private static func isLocalNetwork(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host.hasSuffix(".local") || host.hasPrefix("192.168.") || host.hasPrefix("10.")
            || host.hasPrefix("172.") || host == "localhost"
    }

    private var resumeDataURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("model-download.resume")
    }

    /// Bắt đầu tải, hoặc gắn lại vào task đang chạy (app mở lại khi download vẫn chạy nền).
    func start() {
        guard let url = ModelConfig.downloadURL else {
            emit(.failed("Chưa cấu hình ModelDownloadURL trong project.yml."))
            return
        }
        session.getAllTasks { [self] tasks in
            if tasks.contains(where: { $0.state == .running }) { return }
            tasks.forEach { $0.cancel() }
            let task: URLSessionDownloadTask
            if let data = try? Data(contentsOf: resumeDataURL) {
                task = session.downloadTask(withResumeData: data)
            } else {
                task = session.downloadTask(with: url)
            }
            task.countOfBytesClientExpectsToReceive = ModelConfig.approxBytes
            task.resume()
        }
    }

    func pause() {
        session.getAllTasks { tasks in
            for case let task as URLSessionDownloadTask in tasks {
                task.cancel(byProducingResumeData: { [self] data in
                    if let data { try? data.write(to: resumeDataURL) }
                })
            }
        }
    }

    /// AppDelegate gọi để khởi tạo lại session khi app được đánh thức ở nền.
    func reconnect() { _ = session }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { self.onEvent?(event) }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : ModelConfig.approxBytes
        emit(.progress(received: totalBytesWritten, total: total))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        emit(.progress(received: fileOffset, total: expectedTotalBytes))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        try? FileManager.default.removeItem(at: resumeDataURL)
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            emit(.failed("Server trả về HTTP \(http.statusCode)."))
            return
        }
        // Chặn trường hợp server trả trang lỗi HTML thay vì model.
        guard ModelStore.fileSize(location) > 100_000_000 else {
            emit(.failed("File tải về quá nhỏ — kiểm tra lại ModelDownloadURL."))
            return
        }
        do {
            try ModelStore.install(from: location)
            emit(.finished)
        } catch {
            emit(.failed("Không lưu được model: \(error.localizedDescription)"))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as NSError? else { return }
        if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: resumeDataURL)
        }
        if error.code == NSURLErrorCancelled {
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
