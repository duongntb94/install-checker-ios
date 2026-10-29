import CoreML
import UIKit

/// Chung cho các engine "detect box + luật" (YOLO, RF-DETR): ảnh -> danh sách box theo pixel ảnh.
protocol ObjectDetector: Sendable {
    func detect(_ image: UIImage) throws -> [Detection]
}

extension YOLODetector: ObjectDetector {}

/// RF-DETR Nano (Roboflow, Apache-2.0) chạy bằng Core ML — engine thứ 3.
/// Model tải từ GitHub release `detr-v*` (xem manifest.json của release) và compile thành .mlmodelc trên máy.
///
/// Khác YOLO: Core ML của RF-DETR không có pipeline Vision, nên tự xử lý vào/ra:
/// - Input `tensors` [1, 3, 384, 384]: ảnh resize thẳng 384×384 (không giữ tỉ lệ), RGB / 255, chuẩn hoá ImageNet.
/// - Output: boxes [1, 300, 4] (cx, cy, w, h chuẩn hoá 0–1) và logits [1, 300, 7] (logit i = class i).
/// - Mỗi query: sigmoid, lấy class điểm cao nhất, giữ nếu >= ngưỡng. DETR không cần NMS.
/// Đã kiểm tra cùng cách xử lý này trên macOS (detr/coreml_check.py): 9/9 pass/fail, 14/14 lỗi.
final class DETRDetector: ObjectDetector, @unchecked Sendable {
    enum DetectorError: LocalizedError {
        case modelNotFound, badModel, badImage, badOutput
        var errorDescription: String? {
            switch self {
            case .modelNotFound: "Chưa có model RF-DETR trên máy. Hãy tải lại model."
            case .badModel: "Model RF-DETR không đúng định dạng input [1, 3, H, W]."
            case .badImage: "Không đọc được ảnh."
            case .badOutput: "Model RF-DETR trả về output không đúng định dạng."
            }
        }
    }

    /// Thứ tự class giống lúc train (yolo/boxes.json, detr/build_dataset.py).
    static let classes = ["adapter", "power_plug", "empty_socket", "lan_cable", "extra_cable", "empty_port"]
    private static let mean: [Float] = [0.485, 0.456, 0.406]
    private static let std: [Float] = [0.229, 0.224, 0.225]

    var confidenceThreshold: Float = 0.5

    private let model: MLModel
    private let inputName: String
    private let inputType: MLMultiArrayDataType
    private let side: Int

    /// `url`: thư mục .mlmodelc đã compile (ModelStore.locate(.detr)).
    init(modelURL url: URL?) throws {
        guard let url else { throw DetectorError.modelNotFound }
        let config = MLModelConfiguration()
        config.computeUnits = .all   // Neural Engine / GPU nếu có
        model = try MLModel(contentsOf: url, configuration: config)
        guard let (name, desc) = model.modelDescription.inputDescriptionsByName.first,
              let constraint = desc.multiArrayConstraint, constraint.shape.count == 4 else {
            throw DetectorError.badModel
        }
        inputName = name
        inputType = constraint.dataType
        side = constraint.shape[3].intValue
    }

    /// Trả về detections theo pixel của `image` (đã normalized orientation .up), gốc toạ độ trên-trái.
    func detect(_ image: UIImage) throws -> [Detection] {
        guard let cg = image.cgImage else { throw DetectorError.badImage }
        let input = try makeInput(cg)
        let result = try model.prediction(from: MLDictionaryFeatureProvider(
            dictionary: [inputName: MLFeatureValue(multiArray: input)]))

        // Tên output do coremltools tự đặt (concat_2, linear_102) -> nhận diện theo shape cho chắc.
        var boxes: MLMultiArray?, logits: MLMultiArray?
        for name in result.featureNames {
            guard let a = result.featureValue(for: name)?.multiArrayValue, a.shape.count == 3 else { continue }
            if a.shape[2].intValue == 4 { boxes = a } else { logits = a }
        }
        guard let boxes, let logits, boxes.shape[1] == logits.shape[1] else { throw DetectorError.badOutput }

        let b = MLShapedArray<Float>(converting: boxes).scalars    // tôn trọng strides, đổi fp16 -> Float
        let l = MLShapedArray<Float>(converting: logits).scalars
        let queries = boxes.shape[1].intValue, numLogits = logits.shape[2].intValue
        let w = CGFloat(cg.width), h = CGFloat(cg.height)

        var dets: [Detection] = []
        for q in 0..<queries {
            var best = 0
            var bestLogit = -Float.infinity
            for k in 0..<numLogits where l[q * numLogits + k] > bestLogit {
                bestLogit = l[q * numLogits + k]
                best = k
            }
            let score = 1 / (1 + exp(-bestLogit))
            guard score >= confidenceThreshold, best < Self.classes.count else { continue }
            let cx = CGFloat(b[q * 4]), cy = CGFloat(b[q * 4 + 1])
            let bw = CGFloat(b[q * 4 + 2]), bh = CGFloat(b[q * 4 + 3])
            let rect = CGRect(x: (cx - bw / 2) * w, y: (cy - bh / 2) * h, width: bw * w, height: bh * h)
            dets.append(Detection(label: Self.classes[best], confidence: score, box: rect))
        }
        return dets
    }

    /// Ảnh -> MLMultiArray [1, 3, side, side] đã chuẩn hoá (giống rfdetr predict: resize bilinear, /255, ImageNet).
    private func makeInput(_ cg: CGImage) throws -> MLMultiArray {
        let s = side, plane = s * s
        var pixels = [UInt8](repeating: 0, count: plane * 4)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: s, height: s, bitsPerComponent: 8,
                                      bytesPerRow: s * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: s, height: s))   // resize thẳng, không letterbox
            return true
        }
        guard drawn else { throw DetectorError.badImage }

        var values = [Float](repeating: 0, count: 3 * plane)
        for i in 0..<plane {
            for c in 0..<3 {
                values[c * plane + i] = (Float(pixels[i * 4 + c]) / 255 - Self.mean[c]) / Self.std[c]
            }
        }
        let shape = [1, 3, s, s]
        if inputType == .float16 {
            return MLMultiArray(MLShapedArray<Float16>(scalars: values.map { Float16($0) }, shape: shape))
        }
        return MLMultiArray(MLShapedArray<Float>(scalars: values, shape: shape))
    }
}
