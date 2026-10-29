import Foundation

/// Các model của app. Mỗi model nằm trong 1 GitHub release riêng.
enum ModelKind: String, CaseIterable, Sendable {
    case gemma, yolo, detr

    /// Model Core ML (.mlpackage trong release, compile thành .mlmodelc trên máy). Gemma là .litertlm.
    var coreMLName: String? {
        switch self {
        case .gemma: nil
        case .yolo: "NetworkChecker"
        case .detr: "RFDETR"
        }
    }
}

/// `manifest.json` đính kèm mỗi GitHub release — mô tả các asset cần tải và cách ghép lại.
/// Ví dụ Gemma: 3 phần `model.litertlm.part-a*` cùng `target` = `model.litertlm` -> nối theo thứ tự.
/// Ví dụ YOLO: 3 file cùng thư mục `NetworkChecker.mlpackage/...` -> dựng lại .mlpackage rồi compile.
struct ModelManifest: Codable, Sendable {
    struct Part: Codable, Sendable {
        /// Tên asset trong release
        let asset: String
        /// Đường dẫn tương đối của file sau khi ghép (nhiều part cùng target thì nối theo thứ tự)
        let target: String
        let size: Int64
    }
    let name: String
    let version: String
    let parts: [Part]
    /// target -> SHA-256 (hex) của file sau khi ghép
    let sha256: [String: String]

    var totalBytes: Int64 { parts.reduce(0) { $0 + $1.size } }
}

/// Cấu hình tải model — đọc từ Info.plist (khai báo trong project.yml).
enum ModelConfig {
    /// `https://github.com/<owner>/<repo>/releases/download` — repo phải public (tải không cần auth).
    static let releaseBaseURL: URL = URL(string: info("ModelReleaseBaseURL")
        ?? "https://github.com/duongntb94/install-checker-ios/releases/download")!

    /// Tag của release chứa model. Đổi tag (vd. `yolo-v2`) -> app tự xoá bản cũ và tải bản mới.
    static func tag(_ kind: ModelKind) -> String {
        switch kind {
        case .gemma: info("GemmaModelTag") ?? "model-v2"
        case .yolo: info("YOLOModelTag") ?? "yolo-v1"
        case .detr: info("DETRModelTag") ?? "detr-v1"
        }
    }

    static func assetURL(_ kind: ModelKind, _ asset: String) -> URL {
        releaseBaseURL.appendingPathComponent(tag(kind)).appendingPathComponent(asset)
    }

    static func manifestURL(_ kind: ModelKind) -> URL { assetURL(kind, "manifest.json") }

    /// Chỉ để hiển thị / kiểm tra dung lượng trước khi có manifest.
    static func approxBytes(_ kind: ModelKind) -> Int64 {
        switch kind {
        case .gemma: 3_900_000_000
        case .yolo: 5_100_000
        case .detr: 54_000_000
        }
    }

    private static func info(_ key: String) -> String? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: key) as? String, !s.isEmpty else { return nil }
        return s
    }
}

/// Nơi lưu model trên máy: Application Support/Models/<kind>/ — không bị iOS dọn, không backup iCloud.
enum ModelStore {
    private static let fm = FileManager.default

    static var root: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
    }

    static func directory(_ kind: ModelKind) -> URL {
        root.appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    /// Gemma: file .litertlm đã ghép đủ 3 phần.
    static var gemmaURL: URL { directory(.gemma).appendingPathComponent("model.litertlm") }

    /// YOLO / RF-DETR: model Core ML đã compile trên máy (.mlmodelc là thư mục).
    static func compiledURL(_ kind: ModelKind) -> URL {
        directory(kind).appendingPathComponent("\(kind.coreMLName ?? kind.rawValue).mlmodelc")
    }

    /// Nơi model của `kind` được cài (file .litertlm hoặc thư mục .mlmodelc).
    static func installURL(_ kind: ModelKind) -> URL { kind == .gemma ? gemmaURL : compiledURL(kind) }

    /// Bản Gemma copy tay qua Finder (Files › Install Checker) — tiện khi dev, ưu tiên hơn bản tải về.
    static var sideloadedURL: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("model.litertlm")
    }

    private static func versionKey(_ kind: ModelKind) -> String { "installedModelVersion.\(kind.rawValue)" }

    static func installedVersion(_ kind: ModelKind) -> String? {
        UserDefaults.standard.string(forKey: versionKey(kind))
    }

    static func isInstalled(_ kind: ModelKind) -> Bool { locate(kind) != nil }

    /// URL model đang dùng được, hoặc nil nếu cần tải (chưa có / khác tag trong Info.plist).
    static func locate(_ kind: ModelKind) -> URL? {
        if kind == .gemma, fm.fileExists(atPath: sideloadedURL.path) { return sideloadedURL }
        let url = installURL(kind)
        guard fm.fileExists(atPath: url.path), installedVersion(kind) == ModelConfig.tag(kind) else { return nil }
        return url
    }

    /// Chuyển file/thư mục đã ghép + kiểm tra vào chỗ cố định và ghi version.
    static func install(_ kind: ModelKind, from source: URL, version: String) throws {
        let dest = installURL(kind)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: source, to: dest)
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        UserDefaults.standard.set(version, forKey: versionKey(kind))
    }

    static func remove(_ kind: ModelKind) {
        try? fm.removeItem(at: directory(kind))
        UserDefaults.standard.removeObject(forKey: versionKey(kind))
    }

    /// Dung lượng file, hoặc tổng dung lượng nếu là thư mục (.mlmodelc).
    static func fileSize(_ url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
        let files = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let f = files?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static var availableDiskBytes: Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? .max
    }
}
