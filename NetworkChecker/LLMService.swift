import Foundation
import LiteRTLM

/// Bọc LiteRT-LM Engine trong actor để mọi lời gọi chạy tuần tự, ngoài main thread.
actor LLMService {
    enum LLMError: LocalizedError {
        case modelNotFound
        case notLoaded
        var errorDescription: String? {
            switch self {
            case .modelNotFound:
                return "Không tìm thấy model.litertlm. Tải OTA lại hoặc copy file vào app qua Finder (Files › Install Checker)."
            case .notLoaded:
                return "Model chưa được load."
            }
        }
    }

    private var engine: Engine?

    func unload() { engine = nil }

    func load() async throws {
        guard engine == nil else { return }
        guard let url = ModelStore.locate() else { throw LLMError.modelNotFound }

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("litertlm", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let config = try EngineConfig(
            modelPath: url.path,
            backend: .gpu,          // text prefill/decode trên Metal
            visionBackend: .cpu(),  // vision encoder phải chạy CPU trên iOS (Metal chưa hỗ trợ op của encoder)
            cacheDir: cacheDir.path
        )
        let engine = Engine(engineConfig: config)
        try await engine.initialize()
        self.engine = engine
    }

    /// Mỗi lần kiểm tra tạo conversation mới để không bị lẫn context từ ảnh trước.
    func inspect(imageURL: URL, prompt: String) async throws -> String {
        guard let engine else { throw LLMError.notLoaded }

        // Greedy-ish: output JSON cần ổn định, không cần sáng tạo.
        let sampler = try SamplerConfig(topK: 1, topP: 1.0, temperature: 0.1)
        // Không dùng system message — lúc train cũng không có.
        // Nếu SDK version của bạn bắt buộc systemMessage, truyền: systemMessage: nil
        let convConfig = ConversationConfig(samplerConfig: sampler)
        let conversation = try await engine.createConversation(with: convConfig)

        // Thứ tự ảnh -> text phải giống lúc train (xem scripts/common.py:user_message)
        let message = Message(contents: [
            Content.imageFile(imageURL.path),
            Content.text(prompt)
        ])
        let response = try await conversation.sendMessage(message)
        return response.toString
    }
}
