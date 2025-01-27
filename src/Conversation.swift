import Foundation
@preconcurrency import AVFoundation

public enum ConversationError: Error {
    case sessionNotFound
    case converterInitializationFailed
}

@Observable
public final class Conversation: Sendable {
    private let clientOne: RealtimeAPI
    private let clientTwo: RealtimeAPI
    @MainActor private var cancelTaskOne: (() -> Void)?
    @MainActor private var cancelTaskTwo: (() -> Void)?
    private let errorStreamOne: AsyncStream<ServerError>.Continuation
    private let errorStreamTwo: AsyncStream<ServerError>.Continuation

    private let audioEngineOne = AVAudioEngine()
    private let audioEngineTwo = AVAudioEngine()
    private let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)!

    /// Errors streams for both instances
    public let errorsOne: AsyncStream<ServerError>
    public let errorsTwo: AsyncStream<ServerError>

    /// Instance state
    @MainActor public private(set) var isListeningOne: Bool = false
    @MainActor public private(set) var isListeningTwo: Bool = false
    @MainActor public private(set) var handlingVoiceOne: Bool = false
    @MainActor public private(set) var handlingVoiceTwo: Bool = false

    /// Initializes the `Conversation` class with two API tokens.
    public init(authTokenOne: String, authTokenTwo: String) {
        let modelName = "gpt-4o-mini-realtime-preview-2024-12-17"
        self.clientOne = RealtimeAPI.webSocket(authToken: authTokenOne, model: modelName)
        self.clientTwo = RealtimeAPI.webSocket(authToken: authTokenTwo, model: modelName)
        (errorsOne, errorStreamOne) = AsyncStream.makeStream(of: ServerError.self)
        (errorsTwo, errorStreamTwo) = AsyncStream.makeStream(of: ServerError.self)

        setupClient(client: clientOne, errorStream: errorStreamOne, taskCancel: &cancelTaskOne)
        setupClient(client: clientTwo, errorStream: errorStreamTwo, taskCancel: &cancelTaskTwo)
    }

    deinit {
        errorStreamOne.finish()
        errorStreamTwo.finish()
        DispatchQueue.main.asyncAndWait {
            cancelTaskOne?()
            cancelTaskTwo?()
            stopHandlingVoiceOne()
            stopHandlingVoiceTwo()
        }
    }

    /// Setup a realtime client for event handling
    private func setupClient(client: RealtimeAPI, errorStream: AsyncStream<ServerError>.Continuation, taskCancel: inout (() -> Void)?) {
        let task = Task.detached { [weak self] in
            guard let self else { return }
            for try await event in client.events {
                // Handle events for the specific client here (if needed)
            }
        }
        taskCancel = task.cancel
    }

    // MARK: - Listening and Handling Voice Input

    /// Start listening for the first instance
    @MainActor public func startListeningOne() throws {
        guard !isListeningOne else { return }
        if !handlingVoiceOne { try startHandlingVoiceOne() }

        audioEngineOne.inputNode.installTap(onBus: 0, bufferSize: 4096, format: audioEngineOne.inputNode.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.processAudioBufferOne(buffer: buffer)
        }
        isListeningOne = true
    }

    /// Start listening for the second instance
    @MainActor public func startListeningOther() throws {
        guard !isListeningTwo else { return }
        if !handlingVoiceTwo { try startHandlingVoiceTwo() }

        audioEngineTwo.inputNode.installTap(onBus: 0, bufferSize: 4096, format: audioEngineTwo.inputNode.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.processAudioBufferTwo(buffer: buffer)
        }
        isListeningTwo = true
    }

    /// Stop listening for the first instance
    @MainActor public func stopListeningOne() {
        guard isListeningOne else { return }
        audioEngineOne.inputNode.removeTap(onBus: 0)
        isListeningOne = false
    }

    /// Stop listening for the second instance
    @MainActor public func stopListeningOther() {
        guard isListeningTwo else { return }
        audioEngineTwo.inputNode.removeTap(onBus: 0)
        isListeningTwo = false
    }

    /// Handle voice input for the first instance
    @MainActor private func startHandlingVoiceOne() throws {
        guard !handlingVoiceOne else { return }
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        audioEngineOne.prepare()
        try audioEngineOne.start()
        handlingVoiceOne = true
    }

    /// Handle voice input for the second instance
    @MainActor private func startHandlingVoiceTwo() throws {
        guard !handlingVoiceTwo else { return }
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        audioEngineTwo.prepare()
        try audioEngineTwo.start()
        handlingVoiceTwo = true
    }

    /// Stop handling voice input for the first instance
    @MainActor public func stopHandlingVoiceOne() {
        guard handlingVoiceOne else { return }
        audioEngineOne.stop()
        handlingVoiceOne = false
    }

    /// Stop handling voice input for the second instance
    @MainActor public func stopHandlingVoiceTwo() {
        guard handlingVoiceTwo else { return }
        audioEngineTwo.stop()
        handlingVoiceTwo = false
    }

    // MARK: - Audio Processing

    /// Process audio buffer for the first instance
    private func processAudioBufferOne(buffer: AVAudioPCMBuffer) {
        let audioData = buffer.toData(format: desiredFormat)
        Task { try await clientOne.send(audioDelta: audioData) }
    }

    /// Process audio buffer for the second instance
    private func processAudioBufferTwo(buffer: AVAudioPCMBuffer) {
        let audioData = buffer.toData(format: desiredFormat)
        Task { try await clientTwo.send(audioDelta: audioData) }
    }
}

// MARK: - Utility Extensions

private extension AVAudioPCMBuffer {
    func toData(format: AVAudioFormat) -> Data {
        let ratio = format.sampleRate / self.format.sampleRate
        let capacity = AVAudioFrameCount(Double(frameLength) * ratio)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return Data() }
        let audioData = convertedBuffer.audioBufferList.pointee.mBuffers.mData
        let dataSize = Int(convertedBuffer.audioBufferList.pointee.mBuffers.mDataByteSize)
        return Data(bytes: audioData, count: dataSize)
    }
}
