import CoreGraphics
import Foundation

/// Một detection từ YOLO. `box` theo pixel của ảnh (gốc toạ độ trên-trái).
struct Detection {
    let label: String
    let confidence: Float
    let box: CGRect
}

/// Rule engine — bản Swift của yolo/rules.py. Sửa luật thì sửa cả hai file.
/// Setup chuẩn: 4 ổ điện từ trái sang phải = [adapter, trống, phích, phích];
/// cổng data trái = dây LAN vàng, cổng data phải = trống.
enum InstallRules {
    static let socketClasses: Set<String> = ["adapter", "power_plug", "empty_socket"]
    static let expectedSockets = ["adapter", "empty_socket", "power_plug", "power_plug"]
    static let ordinal = ["first", "second", "third", "fourth"]
    static let want = ["adapter": "power adapter", "power_plug": "power plug", "empty_socket": "socket left empty"]

    static func evaluate(_ dets: [Detection], imageSize: CGSize) -> InspectionResult {
        var errors: [InspectionResult.InstallError] = []
        let w = imageSize.width, h = imageSize.height

        func circle(_ d: Detection, _ desc: String) -> InspectionResult.InstallError {
            let r = max(d.box.width, d.box.height) / 2 * 1.15
            return .init(x: Double(d.box.midX / w * 1000), y: Double(d.box.midY / h * 1000),
                         r: Double(r / max(w, h) * 1000), desc: desc)
        }

        var sockets = dets.filter { socketClasses.contains($0.label) }.sorted { $0.box.midX < $1.box.midX }
        if sockets.count > 4 {
            sockets = Array(sockets.sorted { $0.confidence > $1.confidence }.prefix(4)).sorted { $0.box.midX < $1.box.midX }
        }
        if sockets.count < 4 {
            errors.append(.init(x: 500, y: 500, r: 400,
                                desc: "Could not see all 4 power sockets. Retake the photo with the whole power strip in view."))
        } else {
            for (i, (det, wanted)) in zip(sockets, expectedSockets).enumerated() where det.label != wanted {
                let desc: String
                switch (wanted, det.label) {
                case ("adapter", "empty_socket"):
                    desc = "Missing power adapter. Plug the adapter into the first socket."
                case ("power_plug", "empty_socket"):
                    desc = "Missing power plug. Plug a power cord into the \(ordinal[i]) socket."
                case ("empty_socket", _):
                    desc = "The second socket must stay empty. Unplug the device from the second socket."
                default:
                    desc = "Wrong device in the \(ordinal[i]) socket. It should have the \(want[wanted] ?? wanted)."
                }
                errors.append(circle(det, desc))
            }
        }

        let lan = dets.filter { $0.label == "lan_cable" }
        let extra = dets.filter { $0.label == "extra_cable" }
        let ports = dets.filter { $0.label == "empty_port" }.sorted { $0.box.minX < $1.box.minX }
        let noLan = "No LAN cable connected. Plug the yellow LAN cable into the left data port."
        if lan.isEmpty {
            if let p = ports.first { errors.append(circle(p, noLan)) }
            else { errors.append(.init(x: 750, y: 600, r: 120, desc: noLan)) }
        }
        for d in extra {
            errors.append(circle(d, "Extra grey cable in the right data port. Only the yellow LAN cable in the left port is allowed. Unplug the grey cable."))
        }
        return InspectionResult(status: errors.isEmpty ? "pass" : "fail", errors: errors)
    }
}
