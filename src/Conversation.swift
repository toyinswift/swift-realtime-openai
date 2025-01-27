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
    private let queuedSamples = UnsafeMutableArray<String>()
    private let apiConverter = UnsafeInteriorMutable<AVAudioConverter>()
    private let userConverter = UnsafeInteriorMutable<AVAudioConverter>()
    private let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)!

    public let errors: AsyncStream<ServerError>
    @MainActor public private(set) var id: String?
    @MainActor public private(set) var session: Session?
    @MainActor public private(set) var entries: [Item] = []
    @MainActor public private(set) var connected: Bool = false
    @MainActor public private(set) var isListening: Bool = false
    @MainActor public private(set) var handlingVoice: Bool = false
    @MainActor public private(set) var isUserSpeaking: Bool = false
    @MainActor public private(set) var isPlaying: Bool = false
    @MainActor public var messages: [Item.Message] {
        entries.compactMap { if case let .message(message) = $0 { return message } else { return nil } }
    }

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
                guard let self else { return }
                Task { @MainActor in
                    self.connected = false
                }
            }
            self._keepIsPlayingPropertyUpdated()
        }
    }

    deinit {
        errorStream.finish()
        DispatchQueue.main.asyncAndWait {
            cancelTask?()
            stopHandlingVoice()
        }
    }

    public convenience init(authToken token: String, model: String = "gpt-4o-realtime-preview") {
        self.init(client: RealtimeAPI.webSocket(authToken: token, model: model))
    }

    public convenience init(connectingTo request: URLRequest) {
        self.init(client: RealtimeAPI.webSocket(connectingTo: request))
    }

    @MainActor public func waitForConnection() async {
        while true {
            if connected {
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    @MainActor public func whenConnected<E>(_ callback: @Sendable () async throws(E) -> Void) async throws(E) {
        await waitForConnection()
        try await callback()
    }

    public func updateSession(withChanges callback: (inout Session) -> Void) async throws {
        guard var session = await session else {
            throw ConversationError.sessionNotFound
        }
        callback(&session)
        try await setSession(session)
    }

    public func setSession(_ session: Session) async throws {
        var session = session
        session.id = nil
        try await client.send(event: .updateSession(session))
    }

    public func send(event: ClientEvent) async throws {
        try await client.send(event: event)
    }

    public func send(audioDelta audio: Data, commit: Bool = false) async throws {
        try await send(event: .appendInputAudioBuffer(encoding: audio))
        if commit { try await send(event: .commitInputAudioBuffer()) }
    }

    public func send(from role: Item.ItemRole, text: String, response: Response.Config? = nil) async throws {
        if await handlingVoice { await interruptSpeech() }
        try await send(event: .createConversationItem(Item(message: Item.Message(id: String(randomLength: 32), from: role, content: [.input_text(text)]))))
        try await send(event: .createResponse(response))
    }

    public func send(result output: Item.FunctionCallOutput) async throws {
        try await send(event: .createConversationItem(Item(with: output)))
    }
}

public extension Conversation {
    @MainActor func startListeningOne() throws {
        try startListening(instanceName: "InstanceOne")
    }

    @MainActor func startListeningTwo() throws {
        try startListening(instanceName: "InstanceTwo")
    }

    @MainActor private func startListening(instanceName: String) throws {
        guard !isListening else { return }
        if !handlingVoice { try startHandlingVoice() }
        audioEngine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: audioEngine.inputNode.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.processAudioBufferFromUser(buffer: buffer, instanceName: instanceName)
        }
        isListening = true
        print("\(instanceName) started listening.")
    }

    @MainActor func stopListening() {
        guard isListening else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        isListening = false
    }

    @MainActor func startHandlingVoice() throws {
        guard !handlingVoice else { return }
        guard let converter = AVAudioConverter(from: audioEngine.inputNode.outputFormat(forBus: 0), to: desiredFormat) else {
            throw ConversationError.converterInitializationFailed
        }
        userConverter.set(converter)
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true)
        #endif
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: converter.inputFormat)
        audioEngine.prepare()
        do {
            try audioEngine.start()
            handlingVoice = true
        } catch {
            audioEngine.disconnectNodeInput(playerNode)
            audioEngine.disconnectNodeOutput(playerNode)
            throw error
        }
    }

    @MainActor func interruptSpeech() {
        if isPlaying {
            playerNode.stop()
            queuedSamples.clear()
        }
    }

    @MainActor func stopHandlingVoice() {
        guard handlingVoice else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.disconnectNodeInput(playerNode)
        audioEngine.disconnectNodeOutput(playerNode)
        isListening = false
        handlingVoice = false
    }
}

private extension Conversation {
    @MainActor func handleEvent(_ event: ServerEvent) {
        switch event {
        case let .error(event):
            errorStream.yield(event.error)
        case let .sessionCreated(event):
            connected = true
            session = event.session
        case let .sessionUpdated(event):
            session = event.session
        case let .conversationCreated(event):
            id = event.conversation.id
        case let .conversationItemCreated(event):
            entries.append(event.item)
        case let .conversationItemDeleted(event):
            entries.removeAll { $0.id == event.itemId }
        default:
            return
        }
    }

    private func processAudioBufferFromUser(buffer: AVAudioPCMBuffer, instanceName: String) {
        let ratio = desiredFormat.sampleRate / buffer.format.sampleRate
        guard let convertedBuffer = convertBuffer(buffer: buffer, using: userConverter.get()!, capacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio)) else {
            print("Buffer conversion failed for \(instanceName).")
            return
        }
        guard let sampleBytes = convertedBuffer.audioBufferList.pointee.mBuffers.mData else { return }
        let audioData = Data(bytes: sampleBytes, count: Int(convertedBuffer.audioBufferList.pointee.mBuffers.mDataByteSize))
        Task {
            try await send(audioDelta: audioData)
        }
    }

    private func convertBuffer(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, capacity: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        if buffer.format == converter.outputFormat {
            return buffer
        }
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            print("Failed to create converted audio buffer.")
            return nil
        }
        var error: NSError?
        let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error, let error = error {
            print("Error during conversion: \(error.localizedDescription)")
            return nil
        }
        return convertedBuffer
    }
}

extension Conversation {
    private func _keepIsPlayingPropertyUpdated() {
        withObservationTracking { _ = queuedSamples.isEmpty } onChange: {
            Task { @MainActor in
                self.isPlaying = self.queuedSamples.isEmpty
            }
            self._keepIsPlayingPropertyUpdated()
        }
    }
}
