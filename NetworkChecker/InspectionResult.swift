import Foundation

/// Output của model. Toạ độ x, y: 0–1000 theo chiều rộng / cao ảnh. r: 0–1000 theo cạnh dài.
struct InspectionResult: Codable, Equatable {
    var status: String
    var errors: [InstallError]

    var passed: Bool { status.lowercased() == "pass" && errors.isEmpty }

    struct InstallError: Codable, Equatable, Identifiable {
        var x: Double
        var y: Double
        var r: Double?
        var desc: String
        var id: String { "\(x)-\(y)-\(desc.prefix(16))" }
        var radius: Double { r ?? 60 }
    }

    /// Lấy JSON object đầu tiên trong text (model đôi khi thêm ```json ... ```).
    static func parse(_ text: String) -> InspectionResult? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end else { return nil }
        let json = String(text[start...end])
        guard let data = json.data(using: .utf8) else { return nil }
        if var result = try? JSONDecoder().decode(InspectionResult.self, from: data) {
            result.errors = result.errors.map { e in
                var e = e
                e.x = min(max(e.x, 0), 1000)
                e.y = min(max(e.y, 0), 1000)
                return e
            }
            return result
        }
        return nil
    }
}
