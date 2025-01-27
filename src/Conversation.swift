import Foundation
@preconcurrency import AVFoundation

public enum ConversationError: Error {
    case sessionNotFound
    case converterInitializationFailed
}

@Observable
public final class Conversation: Sendable {
    private let client: RealtimeAPI
    @MainActor private var cancelTask: (() -> Void)?
    private let errorStream: AsyncStream<ServerError>.Continuation

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let sharedFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)!
    private let inputProcessingQueue = DispatchQueue(label: "Conversation.AudioProcessing")

    private let userAudioConverter = UnsafeInteriorMutable<AVAudioConverter>()
    private let apiAudioConverter = UnsafeInteriorMutable<AVAudioConverter>()

    /// A stream of errors that occur during the conversation.
    public let errors: AsyncStream<ServerError>

    /// The unique ID of the conversation.
    @MainActor public private(set) var id: String?

    /// The current session for this conversation.
    @MainActor public private(set) var session: Session?

    /// A list of items in the conversation.
    @MainActor public private(set) var entries: [Item] = []

    /// Whether the conversation is currently connected to the server.
    @MainActor public private(set) var connected: Bool = false

    /// Whether the conversation is currently listening to the user's microphone.
    @MainActor public private(set) var isListening: Bool = false

    /// Whether this conversation is currently handling voice input and output.
    @MainActor public private(set) var handlingVoice: Bool = false

    /// Whether the user is currently speaking.
    @MainActor public private(set) var isUserSpeaking: Bool = false

    /// Whether the model is currently speaking.
    @MainActor public private(set) var isPlaying: Bool = false

    private init(client: RealtimeAPI) {
        self.client = client
        (errors, errorStream) = AsyncStream.makeStream(of: ServerError.self)

        let task = Task.detached { [weak self] in
            guard let self else { return }
            for try await event in client.events {
                await self.handleEvent(event)
            }
            await MainActor.run {
                self.connected = false
            }
        }

        Task { @MainActor in
            self.cancelTask = task.cancel
            client.onDisconnect = { [weak self] in
                Task { @MainActor in self?.connected = false }
            }
        }
    }

    deinit {
        errorStream.finish()
        DispatchQueue.main.asyncAndWait {
            cancelTask?()
            stopHandlingVoice()
        }
    }

    /// Create a new conversation providing an API token and optionally a model.
    public convenience init(authToken token: String, model: String = "gpt-4o-realtime-preview") {
        self.init(client: RealtimeAPI.webSocket(authToken: token, model: model))
    }

    /// Start listening to the microphone and distribute audio to multiple processors.
    @MainActor public func startListening() throws {
        guard !isListening else { return }
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        // Install a single tap on the microphone input node
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.processMicrophoneInput(buffer)
        }

        try audioEngine.start()
        isListening = true
        print("Microphone listening started.")
    }

    /// Stop listening to the microphone.
    @MainActor public func stopListening() {
        guard isListening else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isListening = false
        print("Microphone listening stopped.")
    }

    /// Process microphone input and distribute it to multiple handlers.
    private func processMicrophoneInput(_ buffer: AVAudioPCMBuffer) {
        inputProcessingQueue.async { [weak self] in
            guard let self else { return }
            // Process for user handling
            self.processUserAudio(buffer)

            // Process for server handling
            self.processServerAudio(buffer)
        }
    }

    /// Handle audio intended for user-specific processing.
    private func processUserAudio(_ buffer: AVAudioPCMBuffer) {
        print("Processing audio for user...")
        // Add your user-specific processing logic here
    }

    /// Handle audio intended for server-specific processing.
    private func processServerAudio(_ buffer: AVAudioPCMBuffer) {
        print("Processing audio for server...")
        // Add your server-specific processing logic here
    }

    /// Stop playing audio and reset the audio engine.
    @MainActor public func stopHandlingVoice() {
        guard handlingVoice else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isListening = false
        handlingVoice = false
        print("Voice handling stopped.")
    }
}

/// Extension for event handling
private extension Conversation {
    @MainActor func handleEvent(_ event: ServerEvent) {
        switch event {
        case let .error(event):
            errorStream.yield(event.error)
        case let .sessionCreated(event):
            connected = true
            session = event.session
        case let .conversationCreated(event):
            id = event.conversation.id
        default:
            break
        }
    }
}
