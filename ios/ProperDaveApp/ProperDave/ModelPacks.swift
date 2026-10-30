import Foundation
import ProperDaveCore

#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(MLXFoundationModels)
import MLXFoundationModels
import MLXLMCommon
import MLXVLM
import Tokenizers
#endif

/// Owns the downloadable offline pack: explicit download, progress,
/// cancel, exact installed size, and deletion (TRD-003 CLD-08/11).
/// Inference never touches this manager's network code.
final class ModelPackManager: NSObject, ObservableObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case downloaded
        case failed(String)
    }

    @Published private(set) var state: State = .notDownloaded
    let spec = ModelPackSpec.qwen3VL2B

    private lazy var session: URLSession = URLSession(
        configuration: .default, delegate: self, delegateQueue: nil)
    private var task: URLSessionDownloadTask?
    private let lock = NSLock()
    private var fileIndex = 0
    private var completedBytes: Int64 = 0

    override init() {
        super.init()
        refresh()
    }

    var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ProperDave/Models/Qwen3-VL-2B-Instruct-4bit", isDirectory: true)
    }

    var isDownloaded: Bool {
        spec.files.allSatisfy { file in
            let url = directory.appendingPathComponent(file.name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            return size == file.bytes
        }
    }

    var installedBytes: Int64 {
        spec.files.map { file in
            ((try? FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(file.name).path)[.size] as? NSNumber)?.int64Value) ?? 0
        }.reduce(0, +)
    }

    var statusText: String {
        switch state {
        case .notDownloaded:
            return "Not downloaded. Download is about \(Self.format(spec.totalBytes)); it stays on this device and can be deleted here."
        case .downloading(let progress):
            return "Downloading… \(Int(progress * 100))% of about \(Self.format(spec.totalBytes))."
        case .downloaded:
            return "Downloaded: \(Self.format(installedBytes)) on this device. Inference uses no network."
        case .failed(let message):
            return "Download failed: \(message)"
        }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func refresh() {
        if task == nil { setState(isDownloaded ? .downloaded : .notDownloaded) }
    }

    func startDownload() {
        guard task == nil else { return }
        let free = (try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory())[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free > spec.totalBytes + 500_000_000 else {
            setState(.failed("Not enough free space. This pack needs about \(Self.format(spec.totalBytes)), plus room to work."))
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            setState(.failed(error.localizedDescription)); return
        }
        lock.lock(); fileIndex = 0; completedBytes = 0; lock.unlock()
        startNextFile()
    }

    func cancelDownload() {
        task?.cancel(); task = nil
        try? FileManager.default.removeItem(at: directory)
        setState(.notDownloaded)
    }

    func deletePack() {
        task?.cancel(); task = nil
        try? FileManager.default.removeItem(at: directory)
        setState(.notDownloaded)
    }

    private func startNextFile() {
        lock.lock(); let index = fileIndex; lock.unlock()
        guard index < spec.files.count else {
            if isDownloaded { setState(.downloaded) }
            else { setState(.failed("The downloaded files did not verify against the pinned sizes.")) }
            return
        }
        let file = spec.files[index]
        setState(.downloading(Double(completedBytes) / Double(spec.totalBytes)))
        task = session.downloadTask(with: spec.downloadURL(file.name))
        task?.resume()
    }

    private func setState(_ newState: State) {
        DispatchQueue.main.async { self.state = newState }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock(); let done = completedBytes; lock.unlock()
        setState(.downloading(Double(done + totalBytesWritten) / Double(spec.totalBytes)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        lock.lock(); let index = fileIndex; lock.unlock()
        guard index < spec.files.count else { return }
        let file = spec.files[index]
        let destination = directory.appendingPathComponent(file.name)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock(); completedBytes += file.bytes; fileIndex += 1; lock.unlock()
            task = nil
            startNextFile()
        } catch {
            setState(.failed(error.localizedDescription))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        self.task = nil
        setState(.failed(error.localizedDescription))
    }
}

#if canImport(FoundationModels) && canImport(MLXFoundationModels)

/// Local equivalent of MLXHuggingFace's tokenizer-loader macro. The
/// macro product would not enable in this hand-maintained Xcode
/// project, so the (small, documented) bridge is written out instead.
private struct TransformersTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream)
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]],
                           tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

@available(iOS 27.0, *)
struct MLXDownloadableLocalClient: CloudModelClient {
    let packManager: ModelPackManager
    var modelName: String { "offline:qwen3-vl-2b-mlx" }

    private func foundationClient() throws -> FoundationLocalClient {
        guard packManager.isDownloaded else {
            throw OfflineModelError.unavailable(
                "The downloadable offline model is not downloaded yet. Download it in Settings first.")
        }
        let directory = packManager.directory
        let model = MLXLanguageModel(
            configuration: ModelConfiguration(directory: directory),
            capabilities: [.guidedGeneration, .vision],
            weightsLocation: { _ in directory },
            load: { _, _ in
                try await loadModelContainer(from: directory, using: TransformersTokenizerLoader())
            })
        return FoundationLocalClient(modelName: modelName) {
            LanguageModelSession(model: model,
                                 instructions: "You parse and judge watch goals for a blind user. Prefer silence over low-value speech.")
        }
    }

    func parseGoal(_ rawText: String) async throws -> GoalContext {
        try await foundationClient().parseGoal(rawText)
    }

    func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
        try await foundationClient().evaluate(request)
    }
}

struct DownloadableLocalClient: CloudModelClient {
    let packManager: ModelPackManager
    var modelName: String { "offline:qwen3-vl-2b-mlx" }
    func parseGoal(_ rawText: String) async throws -> GoalContext {
        if #available(iOS 27.0, *) {
            return try await MLXDownloadableLocalClient(packManager: packManager).parseGoal(rawText)
        }
        throw OfflineModelError.unavailable("The downloadable offline model requires iOS 27 or later.")
    }
    func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
        if #available(iOS 27.0, *) {
            return try await MLXDownloadableLocalClient(packManager: packManager).evaluate(request)
        }
        throw OfflineModelError.unavailable("The downloadable offline model requires iOS 27 or later.")
    }
}

#else

struct DownloadableLocalClient: CloudModelClient {
    let packManager: ModelPackManager
    var modelName: String { "offline:qwen3-vl-2b-mlx" }
    func parseGoal(_ rawText: String) async throws -> GoalContext {
        throw OfflineModelError.unavailable("The downloadable offline model requires iOS 27 or later.")
    }
    func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
        throw OfflineModelError.unavailable("The downloadable offline model requires iOS 27 or later.")
    }
}

#endif
