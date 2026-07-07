import SwiftUI

struct ChatView: View {
    let store: ChatStore
    @State private var draft = ""
    @State private var speech = SpeechRecognizer()
    @State private var draftBeforeDictation = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch store.modelState {
                case .ready:
                    messageList
                    composer
                case .idle, .downloading:
                    loadingScreen
                case .failed(let message):
                    failureScreen(message)
                }
            }
            .navigationTitle("Clawd Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Chat", systemImage: "square.and.pencil") {
                        store.clear()
                    }
                    .disabled(store.messages.isEmpty)
                }
            }
        }
        .task { await store.loadModel() }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if store.messages.isEmpty {
                        emptyState
                    }
                    ForEach(store.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: store.messages.last?.text) {
                if let last = store.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onTapGesture { inputFocused = false }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.gen3")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Running \(store.modelName)\nentirely on this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 80)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(speech.isRecording ? "Listening…" : "Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 18))
                .focused($inputFocused)
                .onChange(of: speech.transcript) {
                    guard speech.isRecording else { return }
                    draft = draftBeforeDictation.isEmpty
                        ? speech.transcript
                        : draftBeforeDictation + " " + speech.transcript
                }

            Button {
                if !speech.isRecording { draftBeforeDictation = draft }
                speech.toggle()
            } label: {
                Image(systemName: speech.isRecording ? "mic.circle.fill" : "mic.circle")
                    .font(.title)
                    .foregroundStyle(speech.isRecording ? .red : .accentColor)
            }

            if store.isGenerating {
                Button {
                    store.stopGenerating()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title)
                }
            } else {
                Button {
                    if speech.isRecording { speech.stop() }
                    store.send(draft)
                    draft = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var loadingScreen: some View {
        VStack(spacing: 16) {
            Spacer()
            if case .downloading(let fraction) = store.modelState, fraction > 0 {
                ProgressView(value: fraction) {
                    Text(fraction < 1 ? "Downloading model…" : "Preparing model…")
                } currentValueLabel: {
                    Text("\(Int(fraction * 100))% of \(store.modelName)")
                }
                .padding(.horizontal, 40)
                Text(
                    "One-time download — after this, everything runs offline.\n"
                        + "Most of the model is a single large file, so the percentage "
                        + "can sit still for a long stretch while it downloads. Hang tight."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            } else {
                ProgressView("Preparing model…")
            }
            Spacer()
        }
    }

    private func failureScreen(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Couldn't load the model")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") {
                Task { await store.loadModel() }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }
}
