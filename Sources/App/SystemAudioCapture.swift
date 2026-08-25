import AudioToolbox
import CoreMedia
import Foundation
import ScreenCaptureKit

struct CapturedSpeechSegment: Sendable {
    let utteranceID: UInt64
    let revision: UInt64
    let samples: [Float]
    let capturedThrough: TimeInterval
    let isFinal: Bool
}

final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onSegment: ((CapturedSpeechSegment) -> Void)?
    var onStopped: ((String) -> Void)?

    private let queue = DispatchQueue(label: "dev.babelwave.system-audio")
    private let segmenter = SpeechSegmenter()
    private var stream: SCStream?

    override init() {
        super.init()
        segmenter.onSegment = { [weak self] samples in self?.onSegment?(samples) }
    }

    func start() async throws {
        segmenter.reset()
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }
        let ownBundle = Bundle.main.bundleIdentifier
        let excluded = content.applications.filter { $0.bundleIdentifier == ownBundle }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excluded,
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.showsCursor = false
        configuration.queueDepth = 3

        let nextStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try nextStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await nextStream.startCapture()
        stream = nextStream
    }

    func stop() async throws {
        guard let stream else { return }
        try await stream.stopCapture()
        queue.sync { segmenter.flush() }
        self.stream = nil
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, sampleBuffer.isValid,
              let formatDescription = sampleBuffer.formatDescription,
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else { return }

        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        )
        var retainedBlock: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlock
        )
        guard status == noErr, let data = list.mBuffers.mData else { return }

        let frameCount = sampleBuffer.numSamples
        let channelCount = max(Int(format.mChannelsPerFrame), 1)
        var mono = [Float](repeating: 0, count: frameCount)
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0

        if isFloat, format.mBitsPerChannel == 32 {
            let source = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += source[frame * channelCount + channel]
                }
                mono[frame] = sum / Float(channelCount)
            }
        } else if format.mBitsPerChannel == 16 {
            let source = data.assumingMemoryBound(to: Int16.self)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += Float(source[frame * channelCount + channel]) / 32_768
                }
                mono[frame] = sum / Float(channelCount)
            }
        } else {
            return
        }

        segmenter.append(resample(mono, from: format.mSampleRate, to: 16_000))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        self.stream = nil
        onStopped?("Capture stopped: \(error.localizedDescription)")
    }

    private func resample(_ input: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !input.isEmpty, sourceRate > 0, abs(sourceRate - targetRate) > 0.5 else { return input }
        let outputCount = max(1, Int(Double(input.count) * targetRate / sourceRate))
        let scale = sourceRate / targetRate
        return (0..<outputCount).map { index in
            let position = Double(index) * scale
            let lower = min(input.count - 1, Int(position))
            let upper = min(input.count - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            return input[lower] + (input[upper] - input[lower]) * fraction
        }
    }

    private enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "No display is available for system-audio capture." }
    }
}

private final class SpeechSegmenter {
    var onSegment: ((CapturedSpeechSegment) -> Void)?

    private var lookBehind: [Float] = []
    private var current: [Float] = []
    private var quietSamples = 0
    private var isSpeaking = false
    private var utteranceID: UInt64 = 0
    private var revision: UInt64 = 0
    private var samplesAtLastEmission = 0

    // Progressive snapshots keep captions moving during continuous speech.
    // A short utterance is finalized quickly, while the hard limit prevents a
    // single subtitle from growing without bound.
    private let preRollSamples = 4_800         // 300 ms
    private let silenceSamples = 6_400         // 400 ms
    private let firstPartialSamples = 10_240   // 640 ms, including pre-roll
    private let partialInterval = 9_600        // 600 ms after the first snapshot
    private let minimumSpeechSamples = 6_400   // 400 ms
    private let maximumSegmentSamples = 128_000 // 8 seconds

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let energy = samples.reduce(Float.zero) { $0 + $1 * $1 }
        let containsVoice = sqrt(energy / Float(samples.count)) >= 0.006

        if !isSpeaking {
            lookBehind.append(contentsOf: samples)
            if lookBehind.count > preRollSamples {
                lookBehind.removeFirst(lookBehind.count - preRollSamples)
            }
            if containsVoice {
                isSpeaking = true
                utteranceID &+= 1
                revision = 0
                current = lookBehind
                lookBehind.removeAll(keepingCapacity: true)
                quietSamples = 0
                samplesAtLastEmission = 0
            }
            return
        }

        current.append(contentsOf: samples)
        quietSamples = containsVoice ? 0 : quietSamples + samples.count
        if current.count >= maximumSegmentSamples || quietSamples >= silenceSamples {
            finish()
        } else if current.count >= minimumSpeechSamples,
                  current.count - samplesAtLastEmission >=
                    (revision == 0 ? firstPartialSamples : partialInterval) {
            emit(isFinal: false)
        }
    }

    func flush() {
        if isSpeaking { finish() }
    }

    func reset() {
        lookBehind.removeAll(keepingCapacity: true)
        current.removeAll(keepingCapacity: true)
        quietSamples = 0
        isSpeaking = false
        revision = 0
        samplesAtLastEmission = 0
    }

    private func finish() {
        if current.count >= 6_400 {
            emit(isFinal: true)
        }
        reset()
    }

    private func emit(isFinal: Bool) {
        revision &+= 1
        samplesAtLastEmission = current.count
        onSegment?(CapturedSpeechSegment(
            utteranceID: utteranceID,
            revision: revision,
            samples: current,
            capturedThrough: ProcessInfo.processInfo.systemUptime,
            isFinal: isFinal
        ))
    }
}
