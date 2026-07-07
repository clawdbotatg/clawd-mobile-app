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
    /// `ModelConfiguration(id: "mlx-community/…")`). 4-bit 4B models fit
    /// comfortably on a 12 GB iPhone Pro and handle tool calling well;
    /// `qwen3_8b_4bit` (~4.4 GB) also fits if you want more smarts.
    private static let model = LLMRegistry.qwen3_4b_4bit

    private static let instructions = """
        You are a helpful assistant running fully on-device on the user's iPhone. \
        You can call tools to search their contacts, read their upcoming calendar \
        events, check device status, search the web, and fetch web pages. Use \
        tools whenever the question is about the user's own data or needs current \
        information, and answer from the tool results. Be concise.
        """

    private var container: ModelContainer?
    private var session: ChatSession?

    var modelName: String { Self.model.name }

    func load(onProgress: @escaping @MainActor (Double) -> Void) async throws {
        guard container == nil else { return }

        // Cap MLX's GPU buffer cache so inference stays inside the iOS
        // per-app memory budget.
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

        print("[ClawdChat] load() starting, model: \(Self.model.name)")
        let container = try await #huggingFaceLoadModelContainer(
            configuration: Self.model,
            progressHandler: { progress in
                let fraction = progress.fractionCompleted
                print("[ClawdChat] download progress: \(fraction) (\(progress.completedUnitCount)/\(progress.totalUnitCount))")
                Task { @MainActor in
                    onProgress(fraction)
                }
            }
        )
        print("[ClawdChat] model container loaded")
        self.container = container
        reset()
    }

    func reset() {
        guard let container else { return }
        session = ChatSession(
            container,
            instructions: Self.instructions,
            tools: PhoneTools.specs + WebTools.specs,
            toolDispatch: { call in
                if let result = await WebTools.dispatch(call) { return result }
                return await PhoneTools.dispatch(call)
            }
        )
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
