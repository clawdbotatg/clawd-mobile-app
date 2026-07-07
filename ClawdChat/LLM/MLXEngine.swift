#if !targetEnvironment(simulator)

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Real on-device backend: downloads the model from Hugging Face once,
/// then runs inference on the GPU via MLX.
@MainActor
final class MLXEngine: LLMEngine {
    /// Swap the model by pointing at any entry in `LLMRegistry` (or a custom
    /// `ModelConfiguration(id: "mlx-community/…")`). 4-bit ~2B models are the
    /// sweet spot for current iPhones.
    private static let model = LLMRegistry.qwen3_5_2b_4bit

    private static let instructions =
        "You are a helpful assistant running fully on-device on an iPhone. Be concise."

    private var container: ModelContainer?
    private var session: ChatSession?

    var modelName: String { Self.model.name }

    func load(onProgress: @escaping @MainActor (Double) -> Void) async throws {
        guard container == nil else { return }

        // Cap MLX's GPU buffer cache so inference stays inside the iOS
        // per-app memory budget.
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

        let container = try await #huggingFaceLoadModelContainer(
            configuration: Self.model,
            progressHandler: { progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    onProgress(fraction)
                }
            }
        )
        self.container = container
        reset()
    }

    func reset() {
        guard let container else { return }
        session = ChatSession(container, instructions: Self.instructions)
    }

    func respond(to prompt: String) -> AsyncThrowingStream<String, Error> {
        guard let session else {
            return AsyncThrowingStream { $0.finish(throwing: EngineError.notLoaded) }
        }
        return session.streamResponse(to: prompt)
    }

    enum EngineError: LocalizedError {
        case notLoaded
        var errorDescription: String? { "The model is not loaded yet." }
    }
}

#endif
