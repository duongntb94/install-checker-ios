import CoreML
import UIKit
import Vision

/// Chạy model YOLO (Core ML, export với nms=True) bằng Vision.
/// Model tải từ GitHub release (`yolo-v*`) và được compile thành .mlmodelc trên máy — xem ModelDownloader.
final class YOLODetector {
    enum DetectorError: LocalizedError {
        case modelNotFound
        var errorDescription: String? { "Chưa có model YOLO trên máy. Hãy tải lại model." }
    }

    private let request: VNCoreMLRequest
    var confidenceThreshold: Float = 0.35

    /// `url`: thư mục .mlmodelc đã compile (ModelStore.locate(.yolo)).
    init(modelURL url: URL?) throws {
        guard let url else { throw DetectorError.modelNotFound }
        let config = MLModelConfiguration()
        config.computeUnits = .all   // Neural Engine nếu có
        let model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config))
        request = VNCoreMLRequest(model: model)
        // Giữ đúng tỉ lệ ảnh giống lúc train (letterbox), không crop mất hai mép.
        request.imageCropAndScaleOption = .scaleFit
    }

    /// Trả về detections theo pixel của `image` (đã normalized orientation .up).
    func detect(_ image: UIImage) throws -> [Detection] {
        guard let cg = image.cgImage else { return [] }
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
        try handler.perform([request])
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let results = (request.results as? [VNRecognizedObjectObservation]) ?? []
        return results.compactMap { obs in
            guard let top = obs.labels.first, top.confidence >= confidenceThreshold else { return nil }
            // Vision: bbox normalized, gốc dưới-trái -> đổi sang pixel gốc trên-trái
            let b = obs.boundingBox
            let rect = CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
            return Detection(label: top.identifier, confidence: top.confidence, box: rect)
        }
    }
}

// VNCoreMLRequest không Sendable; detector chỉ được gọi tuần tự (mỗi lần 1 ảnh) nên an toàn.
extension YOLODetector: @unchecked Sendable {}
