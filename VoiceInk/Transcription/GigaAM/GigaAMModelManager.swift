import Foundation
import AppKit
import CryptoKit
import os

struct GigaAMDownloadStatus {
    let fractionCompleted: Double
    let message: String
}

private struct GigaAMModelFile {
    let filename: String
    let sha256: String

    var huggingFaceURL: URL {
        // The istupakov/gigaam-v3-onnx weights on Hugging Face lack the
        // `vocab_size` ONNX metadata field that sherpa-onnx's nemo_transducer
        // loader requires — loading them aborts the process. The amidexe
        // govorun-lite GitHub Release republishes the same weights with that
        // metadata baked in (proven in the Android reference app), so we
        // pull from there instead.
        URL(string: "https://github.com/amidexe/govorun-lite/releases/download/model-gigaam-v3/\(filename)")!
    }
}

@MainActor
final class GigaAMModelManager: ObservableObject {
    @Published private var downloadStatuses: [String: GigaAMDownloadStatus] = [:]
    @Published var downloadProgress: [String: Double] = [:]

    private var activeDownloadIDs: [String: UUID] = [:]
    private var activeDownloadTasks: [String: [URLSessionDownloadTask]] = [:]
    private var activeProgressObservations: [String: [NSKeyValueObservation]] = [:]

    var onModelDeleted: ((String) -> Void)?
    var onModelsChanged: (() -> Void)?

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "GigaAMModelManager")

    // SHA-256 hashes verified against the amidexe/govorun-lite "model-gigaam-v3"
    // GitHub Release (the metadata-patched republish — see huggingFaceURL).
    private static let modelFiles: [String: [GigaAMModelFile]] = [
        "gigaam-v3-rnnt-int8": [
            GigaAMModelFile(
                filename: "gigaam_v3_e2e_rnnt_encoder_int8.onnx",
                sha256: "2cac62d0c270bd128f898f2be1a2d34780d524a6e9483888ebac7b00f97410f1"
            ),
            GigaAMModelFile(
                filename: "gigaam_v3_e2e_rnnt_decoder.onnx",
                sha256: "781971998e6a355d6a714f6932a30eab295e7ba0d14fd7e0f78c83b87e811860"
            ),
            GigaAMModelFile(
                filename: "gigaam_v3_e2e_rnnt_joint.onnx",
                sha256: "602ff7017a93311aad34df1437c8d7f49911353c13d6eae7a6ee7b041339465c"
            ),
            GigaAMModelFile(
                filename: "gigaam_v3_e2e_rnnt_tokens.txt",
                sha256: "7ddf22514c42c531358182c81446a8159771e9921019f09ae743ea622d40221d"
            ),
        ],
    ]

    init() {}

    // MARK: - Paths

    static func modelDirectory(for modelName: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
        return appSupport.appendingPathComponent("Models/GigaAM/\(modelName)")
    }

    func gigaAMModelDirectory(for modelName: String = "gigaam-v3-rnnt-int8") -> URL {
        Self.modelDirectory(for: modelName)
    }

    // MARK: - Query helpers

    func isGigaAMModelDownloaded(named modelName: String) -> Bool {
        guard let files = GigaAMModelManager.modelFiles[modelName] else { return false }
        let dir = gigaAMModelDirectory(for: modelName)
        for file in files {
            let path = dir.appendingPathComponent(file.filename).path
            if !FileManager.default.fileExists(atPath: path) { return false }
        }
        return true
    }

    func isGigaAMModelDownloaded(_ model: GigaAMModel) -> Bool {
        isGigaAMModelDownloaded(named: model.name)
    }

    func isGigaAMModelDownloading(_ model: GigaAMModel) -> Bool {
        downloadStatuses[model.name] != nil
    }

    func downloadStatus(for model: GigaAMModel) -> GigaAMDownloadStatus? {
        downloadStatuses[model.name]
    }

    // MARK: - Download

    func downloadGigaAMModel(_ model: GigaAMModel) async throws {
        let modelName = model.name

        if isGigaAMModelDownloaded(named: modelName) || isGigaAMModelDownloading(model) {
            return
        }

        guard let files = GigaAMModelManager.modelFiles[modelName] else {
            throw GigaAMModelError.unknownModel(modelName)
        }

        let downloadID = UUID()
        activeDownloadIDs[modelName] = downloadID
        activeDownloadTasks[modelName] = []
        updateStatus(modelName: modelName, downloadID: downloadID,
                     fraction: 0.0, message: "Preparing GigaAM download...")

        let dir = gigaAMModelDirectory(for: modelName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            clearDownloadState(for: modelName, downloadID: downloadID)
            throw error
        }

        defer {
            clearDownloadState(for: modelName, downloadID: downloadID)
            onModelsChanged?()
        }

        var perFileProgress = [Double](repeating: 0.0, count: files.count)

        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            guard activeDownloadIDs[modelName] == downloadID else {
                throw CancellationError()
            }

            let dest = dir.appendingPathComponent(file.filename)

            // Skip if already on disk and hash matches
            if FileManager.default.fileExists(atPath: dest.path),
               (try? await Self.verifySHA256(at: dest, expected: file.sha256)) == true {
                perFileProgress[index] = 1.0
                updateAggregateProgress(modelName: modelName, downloadID: downloadID,
                                        perFile: perFileProgress, currentIndex: index, currentFile: file.filename)
                continue
            }

            try? FileManager.default.removeItem(at: dest)

            try await downloadFile(
                from: file.huggingFaceURL,
                to: dest,
                modelName: modelName,
                downloadID: downloadID
            ) { fraction in
                perFileProgress[index] = fraction
                self.updateAggregateProgress(modelName: modelName, downloadID: downloadID,
                                             perFile: perFileProgress, currentIndex: index, currentFile: file.filename)
            }

            do {
                try await Self.verifySHA256(at: dest, expected: file.sha256, throwOnMismatch: true)
            } catch {
                // Remove the corrupt download so isGigaAMModelDownloaded() doesn't
                // mistakenly report a mismatched file as ready.
                try? FileManager.default.removeItem(at: dest)
                throw error
            }
            perFileProgress[index] = 1.0
            updateAggregateProgress(modelName: modelName, downloadID: downloadID,
                                    perFile: perFileProgress, currentIndex: index, currentFile: file.filename)
        }
    }

    func cancelDownload(for model: GigaAMModel) {
        let modelName = model.name
        for task in activeDownloadTasks[modelName] ?? [] {
            task.cancel()
        }
        for observation in activeProgressObservations[modelName] ?? [] {
            observation.invalidate()
        }
        activeDownloadTasks[modelName] = nil
        activeProgressObservations[modelName] = nil
        activeDownloadIDs[modelName] = nil
        downloadStatuses[modelName] = nil
        downloadProgress[modelName] = nil
    }

    // MARK: - Delete

    func deleteGigaAMModel(_ model: GigaAMModel) {
        let dir = gigaAMModelDirectory(for: model.name)
        do {
            if FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.removeItem(at: dir)
            }
        } catch {
            logger.error("❌ Failed to delete GigaAM model \(model.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        onModelDeleted?(model.name)
        onModelsChanged?()
    }

    // MARK: - Finder

    func showGigaAMModelInFinder(_ model: GigaAMModel) {
        let dir = gigaAMModelDirectory(for: model.name)
        if FileManager.default.fileExists(atPath: dir.path) {
            NSWorkspace.shared.selectFile(dir.path, inFileViewerRootedAtPath: "")
        }
    }

    // MARK: - Private download helpers

    private func downloadFile(
        from url: URL,
        to destination: URL,
        modelName: String,
        downloadID: UUID,
        progress: @escaping (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let session = URLSession.shared
            let task = session.downloadTask(with: url) { tempURL, response, error in
                if let error {
                    if (error as? URLError)?.code == .cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      let tempURL else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }

                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            let observation = task.progress.observe(\.fractionCompleted) { taskProgress, _ in
                Task { @MainActor in
                    progress(taskProgress.fractionCompleted)
                }
            }

            // Retain task and KVO observation for the duration of the download —
            // observations would otherwise be released when this closure returns,
            // breaking progress callbacks.
            self.activeDownloadTasks[modelName, default: []].append(task)
            self.activeProgressObservations[modelName, default: []].append(observation)

            task.resume()
        }
    }

    private func updateAggregateProgress(
        modelName: String,
        downloadID: UUID,
        perFile: [Double],
        currentIndex: Int,
        currentFile: String
    ) {
        guard activeDownloadIDs[modelName] == downloadID else { return }
        guard !perFile.isEmpty else { return }
        let total = perFile.reduce(0.0, +) / Double(perFile.count)
        let message = "Downloading \(currentIndex + 1)/\(perFile.count): \(currentFile)"
        updateStatus(modelName: modelName, downloadID: downloadID,
                     fraction: min(max(total, 0.0), 1.0), message: message)
    }

    private func updateStatus(modelName: String, downloadID: UUID, fraction: Double, message: String) {
        guard activeDownloadIDs[modelName] == downloadID else { return }
        downloadStatuses[modelName] = GigaAMDownloadStatus(
            fractionCompleted: fraction,
            message: message
        )
        downloadProgress[modelName] = fraction
    }

    private func clearDownloadState(for modelName: String, downloadID: UUID) {
        guard activeDownloadIDs[modelName] == downloadID else { return }
        for observation in activeProgressObservations[modelName] ?? [] {
            observation.invalidate()
        }
        activeProgressObservations[modelName] = nil
        activeDownloadIDs[modelName] = nil
        activeDownloadTasks[modelName] = nil
        downloadStatuses[modelName] = nil
        downloadProgress[modelName] = nil
    }

    // MARK: - SHA-256

    @discardableResult
    private static func verifySHA256(at url: URL, expected: String, throwOnMismatch: Bool = false) async throws -> Bool {
        // Hashing 250+ MB of model weights would block the main actor; run on a
        // background task with a bounded buffer to keep peak memory low.
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var hasher = SHA256()
            let chunkSize = 1 << 20
            while true {
                try Task.checkCancellation()
                let chunk = try autoreleasepool { () throws -> Data in
                    try handle.read(upToCount: chunkSize) ?? Data()
                }
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }

            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let matches = actual.caseInsensitiveCompare(expected) == .orderedSame
            if !matches && throwOnMismatch {
                throw GigaAMModelError.sha256Mismatch(file: url.lastPathComponent, expected: expected, actual: actual)
            }
            return matches
        }.value
    }
}

enum GigaAMModelError: LocalizedError {
    case unknownModel(String)
    case sha256Mismatch(file: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .unknownModel(let name):
            return "Unknown GigaAM model: \(name)"
        case .sha256Mismatch(let file, let expected, let actual):
            return "SHA-256 mismatch for \(file): expected \(expected), got \(actual)"
        }
    }
}
