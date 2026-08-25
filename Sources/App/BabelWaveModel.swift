import AppKit
import Darwin
import Foundation

enum RecognitionLanguage: String, CaseIterable, Identifiable {
    case automatic = "Auto"
    case chinese = "Chinese"
    case english = "English"
    case japanese = "Japanese"
    case korean = "Korean"

    var id: String { rawValue }
    var requestHeader: String? { self == .automatic ? nil : rawValue }
}

private struct SegmentRevision: Hashable, Comparable, Sendable {
    let utteranceID: UInt64
    let revision: UInt64

    static func < (lhs: SegmentRevision, rhs: SegmentRevision) -> Bool {
        lhs.utteranceID == rhs.utteranceID
            ? lhs.revision < rhs.revision
            : lhs.utteranceID < rhs.utteranceID
    }
}

@MainActor
final class BabelWaveModel: ObservableObject {
    static let shared = BabelWaveModel()

    @Published var isCapturing = false
    @Published var captureAvailable = false
    @Published var serviceStatus = "Starting local models…"
    @Published var modelStatus = "Checking"
    @Published var translationStatus = "Checking"
    @Published var isOverlayVisible = false
    @Published var isOverlayLocked: Bool {
        didSet {
            UserDefaults.standard.set(isOverlayLocked, forKey: Keys.overlayLocked)
            overlay.setInteractionLocked(isOverlayLocked)
        }
    }
    @Published var backgroundTransparency: Double {
        didSet { UserDefaults.standard.set(backgroundTransparency, forKey: Keys.transparency) }
    }
    @Published var fontScale: Double {
        didSet { UserDefaults.standard.set(fontScale, forKey: Keys.fontScale) }
    }
    @Published var debugLoggingEnabled: Bool {
        didSet { UserDefaults.standard.set(debugLoggingEnabled, forKey: Keys.debugLogging) }
    }
    @Published var recognitionLanguage: RecognitionLanguage {
        didSet {
            UserDefaults.standard.set(recognitionLanguage.rawValue, forKey: Keys.recognitionLanguage)
            guard recognitionLanguage != oldValue else { return }
            inferenceTasks.values.forEach { $0.cancel() }
            inferenceTasks.removeAll()
            pendingSegments.removeAll()
            if isCapturing {
                serviceStatus = "Listening · \(recognitionLanguage.rawValue) recognition"
            }
        }
    }
    @Published var sourceText = "BabelWave"
    @Published var translationText = "正在聆听系统音频…"
    @Published var lastTranscript = ""

    lazy var overlay = SubtitlePanelController(model: self)

    private let capture = SystemAudioCapture()
    private let inference = InferenceClient()
    private var daemon: Process?
    private var started = false
    private var pendingSegments: [CapturedSpeechSegment] = []
    private var inferenceTasks: [SegmentRevision: Task<Void, Never>] = [:]
    private var lastPresentedRevision: SegmentRevision?
    private var isInferenceReady = false
    private var isRecoveringInference = false
    private var isShuttingDown = false
    // Both models share one Metal device. Keeping one end-to-end request active
    // minimizes individual latency; the pending slot is coalesced to the newest
    // snapshot if inference ever falls behind capture.
    private let maximumConcurrentInferences = 1
    private let maximumPendingSegments = 3
    private let maximumPendingAge: TimeInterval = 1.5
    private let maximumPresentationAge: TimeInterval = 2.0

    private enum Keys {
        static let transparency = "subtitleBackgroundTransparency"
        static let fontScale = "subtitleFontScaleSwiftUI"
        static let overlayLocked = "subtitleOverlayLockedSwiftUI"
        static let debugLogging = "debugTranscriptLogging"
        static let recognitionLanguage = "recognitionLanguage"
    }

    private init() {
        let defaults = UserDefaults.standard
        let savedTransparency = defaults.object(forKey: Keys.transparency) as? Double
        backgroundTransparency = min(max(savedTransparency ?? 0.23, 0.20), 0.90)
        let savedScale = defaults.object(forKey: Keys.fontScale) as? Double
        fontScale = min(max(savedScale ?? 1.0, 0.70), 1.80)
        isOverlayLocked = defaults.object(forKey: Keys.overlayLocked) as? Bool ?? true
        debugLoggingEnabled = defaults.bool(forKey: Keys.debugLogging)
        recognitionLanguage = RecognitionLanguage(
            rawValue: defaults.string(forKey: Keys.recognitionLanguage) ?? ""
        ) ?? .automatic

        capture.onSegment = { [weak self] segment in
            Task { @MainActor in self?.enqueue(segment) }
        }
        capture.onStopped = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.isCapturing = false
                self.serviceStatus = message
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        startInferenceProcess()
        if ProcessInfo.processInfo.arguments.contains("--preview-long-overlay") {
            sourceText = "When the subtitle window is very small, a much longer sentence must remain complete, stay synchronized with the audio, and never turn into an ellipsis."
            translationText = "当字幕窗口缩得很小时，下一句即使很长，也必须完整显示、跟上正在播放的声音，而且绝不能变成省略号。"
            showOverlay()
        } else if ProcessInfo.processInfo.arguments.contains("--preview-overlay") {
            sourceText = "Good evening, BabelWave."
            translationText = "晚上好，BabelWave。"
            showOverlay()
        }
    }

    func shutdown() {
        isShuttingDown = true
        isInferenceReady = false
        inferenceTasks.values.forEach { $0.cancel() }
        inferenceTasks.removeAll()
        pendingSegments.removeAll()
        Task { try? await capture.stop() }
        if daemon?.isRunning == true {
            daemon?.terminate()
            daemon?.waitUntilExit()
        }
    }

    func toggleCapture() {
        if isCapturing {
            Task {
                do {
                    try await capture.stop()
                    isCapturing = false
                    serviceStatus = "Capture stopped"
                } catch {
                    serviceStatus = "Stop failed: \(error.localizedDescription)"
                }
            }
            return
        }

        captureAvailable = false
        serviceStatus = "Requesting Screen Recording permission…"
        Task {
            do {
                try await capture.start()
                isCapturing = true
                captureAvailable = true
                serviceStatus = "Listening to system audio"
                sourceText = "BabelWave"
                translationText = "正在聆听系统音频…"
                showOverlay()
            } catch {
                captureAvailable = true
                serviceStatus = "Capture failed: \(error.localizedDescription)"
            }
        }
    }

    func toggleOverlay() {
        isOverlayVisible ? overlay.hide() : showOverlay()
    }

    func showOverlay() {
        overlay.show()
        isOverlayVisible = true
    }

    func hideOverlay() {
        overlay.hide()
        isOverlayVisible = false
    }

    func toggleOverlayLock() {
        isOverlayLocked.toggle()
    }

    func increaseFontSize() {
        fontScale = min(fontScale + 0.10, 1.80)
        showOverlay()
    }

    func decreaseFontSize() {
        fontScale = max(fontScale - 0.10, 0.70)
        showOverlay()
    }

    func resetOverlayPosition() {
        overlay.resetPosition()
        showOverlay()
    }

    func copyLastTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lastTranscript, forType: .string)
    }

    func revealDebugLog() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: InferenceClient.debugLogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: InferenceClient.debugLogURL.path) {
            fileManager.createFile(atPath: InferenceClient.debugLogURL.path, contents: nil)
        }
        NSWorkspace.shared.selectFile(
            InferenceClient.debugLogURL.path,
            inFileViewerRootedAtPath: InferenceClient.debugLogURL.deletingLastPathComponent().path
        )
    }

    private func enqueue(_ segment: CapturedSpeechSegment) {
        // Only the newest unprocessed snapshot of one utterance matters. Final
        // snapshots replace partial ones, but completed utterances stay in
        // order so a newer HTTP response can never overwrite a newer caption.
        if let index = pendingSegments.lastIndex(where: {
            $0.utteranceID == segment.utteranceID
        }) {
            pendingSegments[index] = segment
        } else {
            pendingSegments.append(segment)
        }
        trimPendingSegments(referenceTime: segment.capturedThrough)
        serviceStatus = segment.isFinal ? "Finalizing subtitle…" : "Live transcription…"
        pumpInferencePipeline()
    }

    private func pumpInferencePipeline() {
        guard isInferenceReady else { return }
        trimPendingSegments(referenceTime: ProcessInfo.processInfo.systemUptime)
        while inferenceTasks.count < maximumConcurrentInferences,
              !pendingSegments.isEmpty {
            let segment = pendingSegments.removeFirst()
            let key = SegmentRevision(
                utteranceID: segment.utteranceID,
                revision: segment.revision
            )
            if let lastPresentedRevision, key <= lastPresentedRevision {
                continue
            }

            inferenceTasks[key] = Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.inference.transcribe(
                        segment.samples,
                        utteranceID: segment.utteranceID,
                        revision: segment.revision,
                        language: self.recognitionLanguage.requestHeader,
                        debugLogging: self.debugLoggingEnabled
                    )
                    if Task.isCancelled { return }
                    self.receive(result, for: segment, key: key)
                } catch {
                    if Task.isCancelled { return }
                    self.receive(error, for: key)
                }
            }
        }
    }

    private func receive(
        _ result: TranscriptionResponse,
        for segment: CapturedSpeechSegment,
        key: SegmentRevision
    ) {
        inferenceTasks[key] = nil
        defer { pumpInferencePipeline() }

        if let lastPresentedRevision, key <= lastPresentedRevision { return }
        // Empty ASR output means silence/no usable speech. Ignore both partial
        // and final empty revisions so they cannot replace the last caption.
        if result.text.isEmpty { return }

        let displayLatencyMS = max(0, Int(
            (ProcessInfo.processInfo.systemUptime - segment.capturedThrough) * 1_000
        ))
        if displayLatencyMS > Int(maximumPresentationAge * 1_000) {
            lastPresentedRevision = key
            serviceStatus = "Skipped stale subtitle · resynced to live audio"
            return
        }
        sourceText = result.text
        translationText = result.translation.isEmpty ? "翻译暂不可用" : result.translation
        lastTranscript = result.translation.isEmpty
            ? result.text
            : "\(result.text)\n\(result.translation)"
        lastPresentedRevision = key
        serviceStatus = "Processing \(displayLatencyMS) ms · ASR \(result.inferenceMS) · Translate \(result.translationMS)"
        if !result.translationError.isEmpty {
            translationStatus = "Unavailable"
        }
        showOverlay()
    }

    private func receive(_ error: Error, for key: SegmentRevision) {
        inferenceTasks[key] = nil
        if let lastPresentedRevision, key <= lastPresentedRevision { return }
        if isTimeout(error) {
            retainOnlyNewestPendingSegment()
            serviceStatus = "Inference timed out · restarting local models…"
            restartInferenceProcess()
            return
        }
        defer { pumpInferencePipeline() }
        let newerWorkExists = pendingSegments.contains {
            SegmentRevision(utteranceID: $0.utteranceID, revision: $0.revision) > key
        } || inferenceTasks.keys.contains { $0 > key }
        if !newerWorkExists {
            serviceStatus = "Inference failed: \(error.localizedDescription)"
        }
    }

    private func trimPendingSegments(referenceTime: TimeInterval) {
        let cutoff = referenceTime - maximumPendingAge
        pendingSegments.removeAll { $0.capturedThrough < cutoff }
        if pendingSegments.count > maximumPendingSegments {
            pendingSegments.removeFirst(pendingSegments.count - maximumPendingSegments)
        }
    }

    private func retainOnlyNewestPendingSegment() {
        guard let newest = pendingSegments.max(by: {
            $0.capturedThrough < $1.capturedThrough
        }) else {
            pendingSegments.removeAll()
            return
        }
        pendingSegments = [newest]
    }

    private func isTimeout(_ error: Error) -> Bool {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }

    private func restartInferenceProcess() {
        guard !isRecoveringInference, !isShuttingDown else { return }
        isRecoveringInference = true
        isInferenceReady = false
        inferenceTasks.values.forEach { $0.cancel() }
        inferenceTasks.removeAll()

        guard let oldProcess = daemon, oldProcess.isRunning else {
            daemon = nil
            startInferenceProcess()
            return
        }
        daemon = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            oldProcess.terminate()
            let forceKillAt = Date().addingTimeInterval(3)
            while oldProcess.isRunning && Date() < forceKillAt {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if oldProcess.isRunning {
                Darwin.kill(oldProcess.processIdentifier, SIGKILL)
            }
            oldProcess.waitUntilExit()
            DispatchQueue.main.async {
                guard let self, !self.isShuttingDown else { return }
                self.startInferenceProcess()
            }
        }
    }

    private func startInferenceProcess() {
        guard !isShuttingDown else { return }
        isInferenceReady = false
        guard let executable = Bundle.main.resourceURL?
            .appendingPathComponent("bin/babelwaved") else {
            serviceStatus = "Inference executable missing"
            return
        }

        let models = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("BabelWave/models", isDirectory: true)
        let asrModel = models.appendingPathComponent("qwen3-asr-0.6b-q8_0.gguf")
        let translationQ4 = models.appendingPathComponent("qwen3-1.7b-q4_k_m.gguf")
        let translationQ8 = models.appendingPathComponent("qwen3-1.7b-q8_0.gguf")
        let useQ4 = FileManager.default.fileExists(atPath: translationQ4.path)
        let translationModel = useQ4 ? translationQ4 : translationQ8
        let hasASR = FileManager.default.fileExists(atPath: asrModel.path)
        let hasTranslation = FileManager.default.fileExists(atPath: translationModel.path)
        let runtimeLogURL = InferenceClient.runtimeLogURL

        modelStatus = hasASR ? "Qwen3-ASR 0.6B" : "Mock mode"
        translationStatus = hasTranslation
            ? (useQ4 ? "Qwen3 1.7B · Q4 fast" : "Qwen3 1.7B · Q8")
            : "Source only"

        let process = Process()
        process.executableURL = executable
        process.arguments = hasASR
            ? ["--model", asrModel.path,
               "--translation-model", translationModel.path,
               "--log", runtimeLogURL.path,
               "--port", String(InferenceClient.port),
               "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
            : ["--mock",
               "--translation-model", translationModel.path,
               "--log", runtimeLogURL.path,
               "--port", String(InferenceClient.port),
               "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]

        do {
            try FileManager.default.createDirectory(
                at: runtimeLogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try process.run()
            daemon = process
            pollHealth(for: process)
        } catch {
            isRecoveringInference = false
            serviceStatus = "Inference launch failed: \(error.localizedDescription)"
        }
    }

    private func pollHealth(for process: Process) {
        Task {
            for _ in 0..<60 {
                guard daemon === process, !isShuttingDown else { return }
                do {
                    let health = try await inference.health()
                    guard daemon === process, !isShuttingDown else { return }
                    isInferenceReady = true
                    isRecoveringInference = false
                    serviceStatus = "Local models ready"
                    captureAvailable = true
                    if !health.translationReady {
                        translationStatus = "Source only"
                    }
                    pumpInferencePipeline()
                    return
                } catch {
                    serviceStatus = daemon?.isRunning == true
                        ? "Loading local models…"
                        : "Inference service unavailable"
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            guard daemon === process, !isShuttingDown else { return }
            isRecoveringInference = false
            serviceStatus = "Model loading timed out"
        }
    }
}

private struct HealthResponse: Decodable {
    let translationReady: Bool

    enum CodingKeys: String, CodingKey {
        case translationReady = "translation_ready"
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String
    let translation: String
    let translationError: String
    let inferenceMS: Int
    let translationMS: Int
    let sourceLanguage: String
    let targetLanguage: String
    let durationSeconds: Double
    let requestMS: Int
    let translationTokens: Int
    let translationDraftedTokens: Int
    let translationCacheHit: Bool

    enum CodingKeys: String, CodingKey {
        case text, translation
        case translationError = "translation_error"
        case inferenceMS = "inference_ms"
        case translationMS = "translation_ms"
        case sourceLanguage = "source_language"
        case targetLanguage = "target_language"
        case durationSeconds = "duration_seconds"
        case requestMS = "request_ms"
        case translationTokens = "translation_tokens"
        case translationDraftedTokens = "translation_drafted_tokens"
        case translationCacheHit = "translation_cache_hit"
    }
}

private actor InferenceClient {
    static let port = 39_173
    static let runtimeLogURL = FileManager.default.urls(
        for: .libraryDirectory,
        in: .userDomainMask
    )[0]
    .appendingPathComponent("Logs", isDirectory: true)
    .appendingPathComponent("BabelWave.log")
    static let debugLogURL = FileManager.default.urls(
        for: .libraryDirectory,
        in: .userDomainMask
    )[0]
    .appendingPathComponent("Logs", isDirectory: true)
    .appendingPathComponent("BabelWave-Debug.jsonl")

    private let decoder = JSONDecoder()

    func health() async throws -> HealthResponse {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/health")!)
        request.timeoutInterval = 2
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try decoder.decode(HealthResponse.self, from: data)
    }

    func transcribe(
        _ samples: [Float],
        utteranceID: UInt64,
        revision: UInt64,
        language: String?,
        debugLogging: Bool
    ) async throws -> TranscriptionResponse {
        var pcm = [Int16]()
        pcm.reserveCapacity(samples.count)
        for sample in samples {
            pcm.append(Int16((min(max(sample, -1), 1) * Float(Int16.max)).rounded()))
        }
        let body = pcm.withUnsafeBytes { Data($0) }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/v1/transcribe")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 10
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("16000", forHTTPHeaderField: "X-BabelWave-Sample-Rate")
        request.setValue(String(utteranceID), forHTTPHeaderField: "X-BabelWave-Utterance-ID")
        request.setValue(String(revision), forHTTPHeaderField: "X-BabelWave-Revision")
        if let language {
            request.setValue(language, forHTTPHeaderField: "X-BabelWave-Language")
        }
        if debugLogging {
            request.setValue("1", forHTTPHeaderField: "X-BabelWave-Debug-Log")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try decoder.decode(TranscriptionResponse.self, from: data)
    }
}
