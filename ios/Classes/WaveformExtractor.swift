import Accelerate
import AVFoundation
import SFBAudioEngine

/// Decodes an entire local audio source into fixed peak-amplitude values.
///
/// This type deliberately has no MethodChannel dependency. The plugin owns the
/// one-shot Flutter reply, which prevents an extraction error from leaving the
/// Dart Future pending.
public final class WaveformExtractor {

    private enum ExtractionError: LocalizedError {
        case invalidSource(String)
        case invalidFormat
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidSource(let message): return message
            case .invalidFormat: return "Audio source has no readable PCM channels."
            case .cancelled: return "Waveform extraction was cancelled."
            }
        }
    }

    private var audioFile: AVAudioFile?
    private var audioDecoder: AudioDecoder?
    private let sourceURL: URL
    private let usesDecoder: Bool
    private let decoderFormat: AVAudioFormat?
    private let decoderLength: AVAudioFramePosition

    private let cancellationLock = NSLock()
    private var isCancelled = false

    public init(url: URL) throws {
        guard url.isFileURL else {
            throw ExtractionError.invalidSource(
                "Only local file URLs are supported for waveform extraction: \(url.absoluteString)"
            )
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ExtractionError.invalidSource("Audio file does not exist: \(url.path)")
        }
        sourceURL = url

        let extensionName = url.pathExtension.lowercased()
        let decoderOnlyExtensions: Set<String> = [
            "opus", "flac", "ape", "wv", "tta", "mpc", "dsf", "dff", "shn", "spx"
        ]

        if decoderOnlyExtensions.contains(extensionName) {
            let decoder = try AudioDecoder(url: url)
            try decoder.open()
            audioDecoder = decoder
            decoderFormat = decoder.processingFormat
            decoderLength = decoder.length
            usesDecoder = true
            return
        }

        do {
            audioFile = try AVAudioFile(forReading: url)
            decoderFormat = nil
            decoderLength = 0
            usesDecoder = false
        } catch {
            // Some containers supported by SFBAudioEngine are not accepted by
            // AVAudioFile, so use it as a general fallback rather than relying
            // on a private AVFoundation error code.
            let avAudioFileError = error
            do {
                let decoder = try AudioDecoder(url: url)
                try decoder.open()
                audioDecoder = decoder
                decoderFormat = decoder.processingFormat
                decoderLength = decoder.length
                usesDecoder = true
            } catch {
                throw ExtractionError.invalidSource(
                    "AVAudioFile could not open the source: \(avAudioFileError.localizedDescription). " +
                    "SFBAudioEngine fallback also failed: \(error.localizedDescription)"
                )
            }
        }
    }

    deinit {
        try? audioDecoder?.close()
    }

    public func cancel() {
        cancellationLock.lock()
        isCancelled = true
        cancellationLock.unlock()
    }

    public func extractWaveform(
        samplesPerPixel: Int?,
        samplesPerSecond: Int? = nil
    ) throws -> [Float] {
        if usesDecoder {
            guard let decoder = audioDecoder, let format = decoderFormat else {
                throw ExtractionError.invalidSource("Couldn't initialise the audio decoder.")
            }
            let sampleCount = resolvedSampleCount(
                requestedSamples: samplesPerPixel,
                samplesPerSecond: samplesPerSecond,
                frameCount: decoderLength,
                sampleRate: format.sampleRate
            )
            return try extractWithDecoder(
                decoder,
                format: format,
                frameLength: decoderLength,
                sampleCount: sampleCount
            )
        }

        guard let audioFile = audioFile else {
            throw ExtractionError.invalidSource("Couldn't initialise AVAudioFile.")
        }
        let sampleCount = resolvedSampleCount(
            requestedSamples: samplesPerPixel,
            samplesPerSecond: samplesPerSecond,
            frameCount: audioFile.length,
            sampleRate: audioFile.processingFormat.sampleRate
        )
        do {
            return try extractWithAudioFile(audioFile, sampleCount: sampleCount)
        } catch ExtractionError.cancelled {
            throw ExtractionError.cancelled
        } catch {
            // AVAudioFile can open an MP3 successfully but fail when it later
            // reaches a malformed frame. Retry from the start through
            // SFBAudioEngine, whose decoder has different error tolerance.
            return try extractWithFallbackDecoder(
                requestedSamples: samplesPerPixel,
                samplesPerSecond: samplesPerSecond,
                avAudioFileError: error
            )
        }
    }

    private func resolvedSampleCount(
        requestedSamples: Int?,
        samplesPerSecond: Int?,
        frameCount: AVAudioFramePosition,
        sampleRate: Double
    ) -> Int {
        if let samplesPerSecond, samplesPerSecond > 0, sampleRate > 0 {
            let duration = Double(max(0, frameCount)) / sampleRate
            let calculated = (duration * Double(samplesPerSecond)).rounded()
            return max(1, min(Int.max, Int(calculated)))
        }
        return max(1, requestedSamples ?? 100)
    }

    private func extractWithAudioFile(_ audioFile: AVAudioFile, sampleCount: Int) throws -> [Float] {
        let originalFrame = audioFile.framePosition
        defer { audioFile.framePosition = originalFrame }

        let totalFrames = Int64(audioFile.length)
        guard totalFrames > 0 else { return Array(repeating: 0, count: sampleCount) }
        return try extract(
            format: audioFile.processingFormat,
            totalFrames: totalFrames,
            sampleCount: sampleCount,
            read: { buffer, frameCount in
                try audioFile.read(into: buffer, frameCount: frameCount)
            }
        )
    }

    private func extractWithDecoder(
        _ decoder: AudioDecoder,
        format: AVAudioFormat,
        frameLength: AVAudioFramePosition,
        sampleCount: Int
    ) throws -> [Float] {
        let totalFrames = Int64(frameLength)
        guard totalFrames > 0 else { return Array(repeating: 0, count: sampleCount) }
        try decoder.seek(to: 0)
        return try extract(
            format: format,
            totalFrames: totalFrames,
            sampleCount: sampleCount,
            read: { buffer, frameCount in
                try decoder.decode(into: buffer, length: frameCount)
            }
        )
    }

    private func extractWithFallbackDecoder(
        requestedSamples: Int?,
        samplesPerSecond: Int?,
        avAudioFileError: Error
    ) throws -> [Float] {
        do {
            let decoder = try AudioDecoder(url: sourceURL)
            try decoder.open()
            defer { try? decoder.close() }

            let format = decoder.processingFormat
            let frameLength = decoder.length
            let sampleCount = resolvedSampleCount(
                requestedSamples: requestedSamples,
                samplesPerSecond: samplesPerSecond,
                frameCount: frameLength,
                sampleRate: format.sampleRate
            )
            return try extractWithDecoder(
                decoder,
                format: format,
                frameLength: frameLength,
                sampleCount: sampleCount
            )
        } catch ExtractionError.cancelled {
            throw ExtractionError.cancelled
        } catch {
            throw ExtractionError.invalidSource(
                "AVAudioFile failed while reading: \(avAudioFileError.localizedDescription). " +
                "SFBAudioEngine fallback also failed: \(error.localizedDescription)"
            )
        }
    }

    /// Reads at most 65k PCM frames at a time. This keeps memory flat for long
    /// audio while preserving the peak amplitude for every time bucket.
    private func extract(
        format: AVAudioFormat,
        totalFrames: Int64,
        sampleCount: Int,
        read: (AVAudioPCMBuffer, AVAudioFrameCount) throws -> Void
    ) throws -> [Float] {
        let channels = Int(format.channelCount)
        guard channels > 0 else { throw ExtractionError.invalidFormat }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            throw ExtractionError.invalidSource("Couldn't allocate the PCM buffer.")
        }

        let framesPerBucket: Int64 = max(
            1,
            (totalFrames + Int64(sampleCount) - 1) / Int64(sampleCount)
        )
        var values = [Float](repeating: 0, count: sampleCount)
        var decodedFrames: Int64 = 0

        for index in 0..<sampleCount {
            try throwIfCancelled()
            if decodedFrames >= totalFrames { break }

            let bucketFrames = min(framesPerBucket, totalFrames - decodedFrames)
            var remainingFrames = bucketFrames
            var peak: Float = 0

            while remainingFrames > 0 {
                try throwIfCancelled()
                let requested = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remainingFrames))
                buffer.frameLength = 0
                try read(buffer, requested)
                let frameLength = Int64(buffer.frameLength)
                if frameLength <= 0 { break }
                guard let channelData = buffer.floatChannelData else {
                    throw ExtractionError.invalidFormat
                }

                for channel in 0..<channels {
                    var channelPeak: Float = 0
                    vDSP_maxmgv(channelData[channel], 1, &channelPeak, vDSP_Length(frameLength))
                    peak = max(peak, channelPeak)
                }
                decodedFrames += frameLength
                remainingFrames -= frameLength
            }

            values[index] = peak
            // A decoder reaching EOF early should end extraction, but still
            // return the requested fixed-size overview with zero tail buckets.
            if remainingFrames > 0 { break }
        }
        guard let maximum = values.max(), maximum > 0 else { return values }
        return values.map { $0 / maximum }
    }

    private func throwIfCancelled() throws {
        cancellationLock.lock()
        let cancelled = isCancelled
        cancellationLock.unlock()
        if cancelled { throw ExtractionError.cancelled }
    }
}
