import Foundation

/// Cấu hình model OTA — đọc từ Info.plist (khai báo trong project.yml).
enum ModelConfig {
    /// URL tải trực tiếp file .litertlm (HTTPS, không cần auth). Ví dụ: HF repo public
    /// `https://huggingface.co/<user>/<repo>/resolve/main/model.litertlm`, S3/GCS presigned…
    static let downloadURL: URL? = {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "ModelDownloadURL") as? String,
              !s.contains("REPLACE_ME"), let url = URL(string: s) else { return nil }
        return url
    }()

    /// Đổi giá trị này khi upload model mới -> app tự xoá bản cũ và tải lại.
    static let version: String = Bundle.main.object(forInfoDictionaryKey: "ModelVersion") as? String ?? "1"

    /// Chỉ để hiển thị trước khi server trả Content-Length.
    static let approxBytes: Int64 = 3_900_000_000
}

/// Nơi lưu model trên máy.
enum ModelStore {
    private static let fm = FileManager.default
    private static let versionKey = "installedModelVersion"

    /// Application Support/Model/model.litertlm — không bị iOS dọn như Caches, không backup iCloud.
    static var installedURL: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Model", isDirectory: true)
            .appendingPathComponent("model.litertlm")
    }

    /// Bản copy tay qua Finder (Files › Install Checker) — tiện khi dev, ưu tiên hơn bản OTA.
    static var sideloadedURL: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("model.litertlm")
    }

    static var isInstalled: Bool { locate() != nil }

    /// Thứ tự: Documents (sideload) -> bản OTA đúng version -> app bundle.
    static func locate() -> URL? {
        if fm.fileExists(atPath: sideloadedURL.path) { return sideloadedURL }
        if fm.fileExists(atPath: installedURL.path),
           UserDefaults.standard.string(forKey: versionKey) == ModelConfig.version {
            return installedURL
        }
        return Bundle.main.url(forResource: "model", withExtension: "litertlm")
    }

    /// Gọi trong delegate của URLSession (file tạm bị xoá ngay sau khi hàm delegate return).
    static func install(from tempURL: URL) throws {
        let dir = installedURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: installedURL.path) { try fm.removeItem(at: installedURL) }
        try fm.moveItem(at: tempURL, to: installedURL)
        var url = installedURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        UserDefaults.standard.set(ModelConfig.version, forKey: versionKey)
    }

    static func remove() {
        try? fm.removeItem(at: installedURL)
        UserDefaults.standard.removeObject(forKey: versionKey)
    }

    static func fileSize(_ url: URL) -> Int64 {
        (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    static var availableDiskBytes: Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? .max
    }
}
