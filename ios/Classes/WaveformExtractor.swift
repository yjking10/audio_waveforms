import Accelerate
import AVFoundation
import SFBAudioEngine

public class WaveformExtractor {

    public private(set) var audioFile: AVAudioFile?
    private var audioDecoder: AudioDecoder?
    private var isUsingDecoder: Bool = false
    private var decoderFormat: AVAudioFormat?
    private var decoderLength: AVAudioFramePosition = 0
    private var result: FlutterResult
    var flutterChannel: FlutterMethodChannel
    private var waveformData = Array<Float>()
    var progress: Float = 0.0
    var channelCount: Int = 1
    private var currentProgress: Float = 0.0
    private let abortWaveformDataQueue = DispatchQueue(
        label: "WaveformExtractor",
        attributes: .concurrent
    )

    private var _abortGetWaveformData: Bool = false

    public var abortGetWaveformData: Bool {
        get { _abortGetWaveformData }
        set {
            abortWaveformDataQueue.async(flags: .barrier) {
                self._abortGetWaveformData = newValue
            }
        }
    }
    public init(url: URL, flutterResult: @escaping FlutterResult, channel: FlutterMethodChannel) throws {
        result = flutterResult
        self.flutterChannel = channel

        let ext = url.pathExtension.lowercased()

        // AVAudioFile 原生不支持的格式，直接使用 AudioDecoder
        let needsAudioDecoder = ["opus", "flac", "ape", "wv", "tta", "mpc", "dsf", "dff", "shn", "spx"]

        if needsAudioDecoder.contains(ext) {
            // 直接使用 SFBAudioEngine AudioDecoder
            do {
                audioDecoder = try AudioDecoder(url: url)
                try audioDecoder?.open()
                decoderFormat = audioDecoder?.processingFormat
                decoderLength = audioDecoder?.length ?? 0
                isUsingDecoder = true
            } catch {
                audioFile = nil
                audioDecoder = nil
                result(FlutterError(code: Constants.audioWaveforms,
                                  message: error.localizedDescription,
                                  details: "Couldn't initialise AudioDecoder from \(url.absoluteString)"))
            }
        } else {
            // 系统原生格式：优先使用 AVAudioFile，失败后回退到 AudioDecoder
            do {
                audioFile = try AVAudioFile(forReading: url)
                isUsingDecoder = false
            } catch let avError as NSError {
                if avError.code == 1954115647 {
                    NSLog("AVAudioFile failed (type unsupported), using AudioDecoder for: \(url.path)")
                    do {
                        audioDecoder = try AudioDecoder(url: url)
                        try audioDecoder?.open()
                        decoderFormat = audioDecoder?.processingFormat
                        decoderLength = audioDecoder?.length ?? 0
                        isUsingDecoder = true
                    } catch {
                        audioFile = nil
                        audioDecoder = nil
                        result(FlutterError(code: Constants.audioWaveforms,
                                          message: error.localizedDescription,
                                          details: "Couldn't initialise audio decoder from \(url.absoluteString)"))
                    }
                } else {
                    audioFile = nil
                    result(FlutterError(code: Constants.audioWaveforms,
                                      message: avError.localizedDescription,
                                      details: "Couldn't initialise AVAudioFile from \(url.absoluteString)"))
                }
            }
        }
    }

    deinit {
        audioFile = nil
        if let decoder = audioDecoder {
            try? decoder.close()
            audioDecoder = nil
        }
    }

    public func extractWaveform(
        samplesPerPixel: Int?,
        offset: Int? = 0,
        length: UInt? = nil,
        playerKey: String,
        onExtractionComplete: ([Float]?) -> Void
    ) async -> Void {
        // Use decoder if available, otherwise use audioFile
        if isUsingDecoder {
            await extractWaveformWithDecoder(
                samplesPerPixel: samplesPerPixel,
                offset: offset,
                length: length,
                playerKey: playerKey,
                onExtractionComplete: onExtractionComplete
            )
            return
        }

        guard let audioFile = audioFile else { return }

        /// Prevent division by zero, + minimum resolution
        let samplesPerPixel = max(1, samplesPerPixel ?? 100)
        let currentFrame = audioFile.framePosition
        let totalFrames = AVAudioFrameCount(audioFile.length)
        var framesPerBuffer = totalFrames / AVAudioFrameCount(samplesPerPixel)
        
        guard let rmsBuffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: framesPerBuffer
        ) else { return }
        
        let channelCount = Int(audioFile.processingFormat.channelCount)
        let waveformStorage = WaveformStorage(
            channelCount: channelCount,
            size: samplesPerPixel
        )
        
        let startIndex = max(
            0, offset ?? Int(currentFrame / Int64(framesPerBuffer))
        )
        let endIndex = min(
            samplesPerPixel, startIndex + (length.map { Int($0) } ?? samplesPerPixel)
        )
        
        if startIndex > endIndex {
            sendErrorToFlutter(
                message: "Offset is larger than total length.",
                details: "Please select less number of samples"
            )
            return
        }
        
        var startFrame: AVAudioFramePosition = offset == nil
        ? currentFrame
        : Int64(startIndex * Int(framesPerBuffer))
        
        for i in startIndex..<endIndex {
            if abortGetWaveformData {
                audioFile.framePosition = currentFrame
                abortGetWaveformData = false
                return
            }
            
            do {
                audioFile.framePosition = startFrame
                try audioFile.read(into: rmsBuffer, frameCount: framesPerBuffer)
            } catch {
                sendErrorToFlutter(
                    message: "Couldn't read buffer. \(error.localizedDescription)"
                )
                return
            }
            
            guard let floatData = rmsBuffer.floatChannelData else { return }
            
            for channel in 0..<channelCount {
                /// Calculating RMS(Root mean square)
                var rmsValue: Float = 0.0
                vDSP_rmsqv(
                    floatData[channel], 1, &rmsValue,
                    vDSP_Length(rmsBuffer.frameLength)
                )
                await waveformStorage.update(
                    channel: channel, index: i, value: rmsValue
                )
            }
            
            let progress = Float(i - startIndex + 1) / Float(endIndex - startIndex)
            await sendWaveformDataToFlutter(
                waveformStorage: waveformStorage,
                progress: progress,
                playerKey: playerKey
            )
            
            startFrame += AVAudioFramePosition(framesPerBuffer)
            if startFrame + AVAudioFramePosition(framesPerBuffer) > totalFrames {
                framesPerBuffer = totalFrames - AVAudioFrameCount(startFrame)
                if framesPerBuffer <= 0 { break }
            }
        }
        
        audioFile.framePosition = currentFrame
        let waveformData = await waveformStorage.getData()
        let data = getChannelMean(data: waveformData)
        onExtractionComplete(data);
    }

    func getChannelMean(data: FloatChannelData) -> [Float] {
        var resultWaveform = [Float]()

        if channelCount == 2, !data[0].isEmpty, !data[1].isEmpty {
            resultWaveform = zip(data[0], data[1]).map { ($0 + $1) / 2 }
        } else if !data[0].isEmpty {
            resultWaveform = data[0]
        } else if !data[1].isEmpty {
            resultWaveform = data[1]
        } else {
            sendErrorToFlutter(
                message: "Cannot get waveform mean",
                details: "Both audio channels are null"
            )
        }
        return resultWaveform
    }

    public func cancel() {
        abortGetWaveformData = true
    }

    private func sendWaveformDataToFlutter(
        waveformStorage: WaveformStorage,
        progress: Float,
        playerKey: String
    ) async {
        let waveformData = await waveformStorage.getData()
        let meanData = getChannelMean(data: waveformData)

        DispatchQueue.main.async {
            self.flutterChannel.invokeMethod(
                Constants.onCurrentExtractedWaveformData,
                arguments: [
                    Constants.waveformData: meanData,
                    Constants.progress: progress,
                    Constants.playerKey: playerKey
                ]
            )
        }
    }

    private func sendErrorToFlutter(message: String, details: String? = nil) {
        DispatchQueue.main.async {
            self.result(
                FlutterError(
                    code: Constants.audioWaveforms,
                    message: message,
                    details: details
                )
            )
        }
    }

    // Extract waveform using SFBAudioEngine decoder for OPUS files
    private func extractWaveformWithDecoder(
        samplesPerPixel: Int?,
        offset: Int? = 0,
        length: UInt? = nil,
        playerKey: String,
        onExtractionComplete: ([Float]?) -> Void
    ) async -> Void {
        guard let decoder = audioDecoder,
              let format = decoderFormat else { return }

        let samplesPerPixel = max(1, samplesPerPixel ?? 100)
        let totalFrames = AVAudioFrameCount(decoderLength)
        var framesPerBuffer = totalFrames / AVAudioFrameCount(samplesPerPixel)

        guard let rmsBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: framesPerBuffer
        ) else { return }

        let channelCount = Int(format.channelCount)
        let waveformStorage = WaveformStorage(
            channelCount: channelCount,
            size: samplesPerPixel
        )

        let startIndex = max(0, offset ?? 0)
        let endIndex = min(
            samplesPerPixel, startIndex + (length.map { Int($0) } ?? samplesPerPixel)
        )

        if startIndex > endIndex {
            sendErrorToFlutter(
                message: "Offset is larger than total length.",
                details: "Please select less number of samples"
            )
            return
        }

        var startFrame: AVAudioFramePosition = Int64(startIndex * Int(framesPerBuffer))

        // Seek to start position
        do {
            try decoder.seek(to: startFrame)
        } catch {
            sendErrorToFlutter(
                message: "Couldn't seek to position. \(error.localizedDescription)"
            )
            return
        }

        for i in startIndex..<endIndex {
            if abortGetWaveformData {
                abortGetWaveformData = false
                return
            }

            do {
                try decoder.decode(into: rmsBuffer, length: framesPerBuffer)
            } catch {
                sendErrorToFlutter(
                    message: "Couldn't decode buffer. \(error.localizedDescription)"
                )
                return
            }

            if rmsBuffer.frameLength == 0 {
                break
            }

            guard let floatData = rmsBuffer.floatChannelData else { return }

            for channel in 0..<channelCount {
                var rmsValue: Float = 0.0
                vDSP_rmsqv(
                    floatData[channel], 1, &rmsValue,
                    vDSP_Length(rmsBuffer.frameLength)
                )
                await waveformStorage.update(
                    channel: channel, index: i, value: rmsValue
                )
            }

            let progress = Float(i - startIndex + 1) / Float(endIndex - startIndex)
            await sendWaveformDataToFlutter(
                waveformStorage: waveformStorage,
                progress: progress,
                playerKey: playerKey
            )

            startFrame += AVAudioFramePosition(framesPerBuffer)
            if startFrame + AVAudioFramePosition(framesPerBuffer) > Int64(totalFrames) {
                framesPerBuffer = totalFrames - AVAudioFrameCount(startFrame)
                if framesPerBuffer <= 0 { break }
            }
        }

        let waveformData = await waveformStorage.getData()
        let data = getChannelMean(data: waveformData)
        onExtractionComplete(data)
    }
}

actor WaveformStorage {
    private var data: [[Float]]

    init(channelCount: Int, size: Int) {
        data = Array(repeating: [Float](repeating: 0, count: size), count: channelCount)
    }

    func update(channel: Int, index: Int, value: Float) {
        data[channel][index] = value
    }

    func getData() -> [[Float]] {
        return data
    }
}
