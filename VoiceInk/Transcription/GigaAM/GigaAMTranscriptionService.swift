import Foundation
import SherpaOnnx
import os.log

enum GigaAMTranscriptionError: LocalizedError {
    case modelFilesMissing(URL)
    case recognizerInitializationFailed
    case streamCreationFailed
    case resultUnavailable
    case invalidAudioData

    var errorDescription: String? {
        switch self {
        case .modelFilesMissing(let dir):
            return "GigaAM model files not found at \(dir.path)"
        case .recognizerInitializationFailed:
            return "Failed to initialize sherpa-onnx recognizer for GigaAM"
        case .streamCreationFailed:
            return "Failed to create sherpa-onnx offline stream"
        case .resultUnavailable:
            return "sherpa-onnx returned no recognition result"
        case .invalidAudioData:
            return "Audio data is too short or malformed for GigaAM transcription"
        }
    }
}

@MainActor
final class GigaAMTranscriptionService: TranscriptionService {
    private var recognizer: OpaquePointer?
    private var loadedModelName: String?
    private var pendingDecodes: Set<Task<String, Error>> = []

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink.gigaam", category: "GigaAMTranscriptionService")

    init() {}

    deinit {
        if let recognizer {
            SherpaOnnxDestroyOfflineRecognizer(recognizer)
        }
    }

    // MARK: - TranscriptionService

    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        try await ensureLoaded(modelName: model.name)
        guard let recognizer else { throw GigaAMTranscriptionError.recognizerInitializationFailed }

        let samples = try Self.readAudioSamples(from: audioURL)
        // GigaAM v3 produces Russian text with native punctuation/capitalization.
        // TextNormalizer.shared is an English ITN — skip it.
        let task = Task.detached(priority: .userInitiated) {
            try Self.decode(recognizer: recognizer, samples: samples)
        }
        pendingDecodes.insert(task)
        defer { pendingDecodes.remove(task) }
        return try await task.value
    }

    // Awaits all in-flight decodes before destroying the recognizer to avoid a
    // use-after-free between detached decode tasks and cleanup/teardown.
    func cleanup() async {
        await drainPendingDecodes()
        if let recognizer {
            SherpaOnnxDestroyOfflineRecognizer(recognizer)
            self.recognizer = nil
            self.loadedModelName = nil
            logger.info("GigaAM recognizer released")
        }
    }

    // MARK: - Loading

    private func ensureLoaded(modelName: String) async throws {
        if recognizer != nil, loadedModelName == modelName { return }

        // A model switch destroys the recognizer; drain detached decodes first
        // so they don't dereference a freed pointer.
        if recognizer != nil {
            await drainPendingDecodes()
            if let recognizer {
                SherpaOnnxDestroyOfflineRecognizer(recognizer)
                self.recognizer = nil
                self.loadedModelName = nil
            }
        }

        let modelDir = GigaAMModelManager.modelDirectory(for: modelName)
        let paths = GigaAMModelPaths(directory: modelDir)
        try paths.validate()

        for provider in ["coreml", "cpu"] {
            if let r = createRecognizer(paths: paths, provider: provider) {
                self.recognizer = r
                self.loadedModelName = modelName
                logger.info("GigaAM recognizer ready (provider=\(provider, privacy: .public))")
                return
            }
            logger.notice("GigaAM init failed for provider=\(provider, privacy: .public); trying fallback")
        }

        throw GigaAMTranscriptionError.recognizerInitializationFailed
    }

    private func drainPendingDecodes() async {
        while let task = pendingDecodes.first {
            _ = try? await task.value
            pendingDecodes.remove(task)
        }
    }

    private func createRecognizer(paths: GigaAMModelPaths, provider: String) -> OpaquePointer? {
        let modelType = "nemo_transducer"
        let decodingMethod = "greedy_search"

        return paths.encoder.path.withCString { encCStr in
            paths.decoder.path.withCString { decCStr in
                paths.joiner.path.withCString { joinCStr in
                    paths.tokens.path.withCString { tokenCStr in
                        modelType.withCString { typeCStr in
                            provider.withCString { provCStr in
                                decodingMethod.withCString { dmCStr in
                                    var config = SherpaOnnxOfflineRecognizerConfig()
                                    config.feat_config.sample_rate = 16000
                                    config.feat_config.feature_dim = 80
                                    config.model_config.transducer.encoder = encCStr
                                    config.model_config.transducer.decoder = decCStr
                                    config.model_config.transducer.joiner = joinCStr
                                    config.model_config.tokens = tokenCStr
                                    config.model_config.num_threads = 2
                                    config.model_config.provider = provCStr
                                    config.model_config.model_type = typeCStr
                                    config.decoding_method = dmCStr
                                    return SherpaOnnxCreateOfflineRecognizer(&config)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Decoding

    nonisolated private static func decode(recognizer: OpaquePointer, samples: [Float]) throws -> String {
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
            throw GigaAMTranscriptionError.streamCreationFailed
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        samples.withUnsafeBufferPointer { ptr in
            SherpaOnnxAcceptWaveformOffline(stream, 16000, ptr.baseAddress, Int32(samples.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
            throw GigaAMTranscriptionError.resultUnavailable
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }

        return result.pointee.text.map { String(cString: $0) } ?? ""
    }

    // MARK: - Audio I/O

    private static func readAudioSamples(from url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        // 44-byte canonical PCM WAV header + at least one Int16 sample.
        guard data.count >= 46 else {
            throw GigaAMTranscriptionError.invalidAudioData
        }

        // Bound the upper limit so the last 2-byte slice never reads past the end
        // for odd-length payloads.
        let end = data.count - ((data.count - 44) % 2)
        return stride(from: 44, to: end, by: 2).map { offset in
            data[offset..<offset + 2].withUnsafeBytes {
                let short = Int16(littleEndian: $0.load(as: Int16.self))
                return max(-1.0, min(Float(short) / 32768.0, 1.0))
            }
        }
    }

}

private struct GigaAMModelPaths {
    let encoder: URL
    let decoder: URL
    let joiner: URL
    let tokens: URL

    init(directory: URL) {
        self.encoder = directory.appendingPathComponent("v3_e2e_rnnt_encoder.int8.onnx")
        self.decoder = directory.appendingPathComponent("v3_e2e_rnnt_decoder.onnx")
        self.joiner = directory.appendingPathComponent("v3_e2e_rnnt_joint.onnx")
        self.tokens = directory.appendingPathComponent("v3_e2e_rnnt_vocab.txt")
    }

    func validate() throws {
        let fm = FileManager.default
        for url in [encoder, decoder, joiner, tokens] {
            if !fm.fileExists(atPath: url.path) {
                throw GigaAMTranscriptionError.modelFilesMissing(url.deletingLastPathComponent())
            }
        }
    }
}
