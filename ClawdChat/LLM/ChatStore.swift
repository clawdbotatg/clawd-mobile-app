import Foundation

/// Owns the model lifecycle (download → load → chat) and the message list
/// the UI renders. The actual generation backend is an `LLMEngine`:
/// MLX on device, a mock in the simulator.
@Observable
@MainActor
final class ChatStore {
    enum ModelState: Equatable {
        case idle
        case downloading(Double)  // 0...1 fraction of the weights download
        case ready
        case failed(String)
    }

    private(set) var modelState: ModelState = .idle
    private(set) var messages: [ChatMessage] = []
    private(set) var isGenerating = false

    private let engine: LLMEngine
    private var generationTask: Task<Void, Never>?

    init() {
        #if targetEnvironment(simulator)
        engine = MockEngine()
        #else
        engine = MLXEngine()
        #endif
    }

    var modelName: String { engine.modelName }

    func loadModel() async {
        guard modelState != .ready else { return }
        modelState = .downloading(0)
        do {
            try await engine.load { fraction in
                self.modelState = .downloading(fraction)
            }
            modelState = .ready
        } catch {
            modelState = .failed(error.localizedDescription)
        }
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard modelState == .ready, !isGenerating, !trimmed.isEmpty else { return }

        messages.append(ChatMessage(role: .user, text: trimmed))
        messages.append(ChatMessage(role: .assistant, text: ""))
        let index = messages.count - 1
        isGenerating = true

        generationTask = Task {
            do {
                for try await chunk in engine.respond(to: trimmed) {
                    messages[index].text += chunk
                }
            } catch is CancellationError {
                // User tapped stop; keep whatever was generated.
            } catch {
                messages[index].text += "\n\n⚠️ \(error.localizedDescription)"
            }
            isGenerating = false
        }
    }

    func stopGenerating() {
        generationTask?.cancel()
    }

    /// New conversation: drop UI messages and the engine's history state.
    func clear() {
        stopGenerating()
        messages.removeAll()
        engine.reset()
    }
}
