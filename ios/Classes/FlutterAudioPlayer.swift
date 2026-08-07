import AVFoundation
import Darwin
import Foundation
import SFBAudioEngine

class FlutterAudioPlayer: NSObject, AudioPlayer.Delegate, AVAudioPlayerDelegate {

    private var player: AudioPlayer?
    private var systemPlayer: AVAudioPlayer?
    private var timer: Timer?
    private var completionWorkItem: DispatchWorkItem?
    private var playbackRate: Float = 1.0
    private var timePitchNode: AVAudioUnitTimePitch?
    private var overrideAudioSession = true
    private var isPrepared = false
    private var hasSentCompletionEvent = false
    private var shouldNotifyCompletionOnStop = false
    private var lastPreparedPath: String?
    private var activeAudioURL: URL?
    private var decodeRecoveryAttempts = 0
    private var isRecoveringFromDecodeError = false
    private var playbackBackend = PlaybackBackend.sfbaudioEngine

    private var finishMode: FinishMode = FinishMode.stop
    private var updateFrequency = 200
    // 连续恢复失败达到上限后停止，避免同一坏帧无限重试。
    private let maxDecodeRecoveryAttempts = 10
    private let recoverySkipSeconds: TimeInterval = 0.5
    var plugin: SwiftAudioWaveformsPlugin
    var playerKey: String
    var flutterChannel: FlutterMethodChannel

    private enum PlaybackBackend {
        case sfbaudioEngine
        case systemAudioPlayer
    }

    init(
        plugin: SwiftAudioWaveformsPlugin,
        playerKey: String,
        channel: FlutterMethodChannel,
    ) {

        self.plugin = plugin
        self.playerKey = playerKey
        flutterChannel = channel

        self.player = AudioPlayer()
        self.player?.isNoiseSuppressionEnabled = true
    }

    override func responds(to aSelector: Selector!) -> Bool {
        let reconfigureSelector = #selector(audioPlayer(_:reconfigureProcessingGraph:with:))
        if aSelector == reconfigureSelector {
            return !isDefaultPlaybackRate || timePitchNode != nil
        }

        return super.responds(to: aSelector)
    }

    func preparePlayer(
        path: String?,
        volume: Double?,
        updateFrequency: Int?,
        result: @escaping FlutterResult,
        overrideAudioSession: Bool
    ) {

        guard let path = path, !path.isEmpty else {
            result(
                FlutterError(
                    code: Constants.audioWaveforms,
                    message: "Audio file path can't be empty or null",
                    details: ""
                )
            )
            return
        }

        guard let audioUrl = URL(string: path) else {
            result(
                FlutterError(
                    code: Constants.audioWaveforms,
                    message: "Failed to initialise Url from provided audio file",
                    details: "Provide an absolute local path, file:// URL, or http(s) URL"
                )
            )
            return
        }

        if let freq = updateFrequency {
            self.updateFrequency = freq
        }
        self.overrideAudioSession = overrideAudioSession

        do {
            try configureAudioSessionForPlayback()
        } catch {
            result(
                FlutterError(
                    code: Constants.audioWaveforms,
                    message: "Failed to configure audio session: \(error.localizedDescription)",
                    details: ""
                )
            )
            return
        }

        do {
            try prepareAudio(url: audioUrl)
            lastPreparedPath = path
            result(true)
        } catch {
            isPrepared = false
            result(
                FlutterError(
                    code: Constants.audioWaveforms,
                    message: "Failed to prepare audio file: \(error.localizedDescription)",
                    details: ""
                )
            )
        }
    }

    //    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer,successfully flag: Bool) {
    //        var finishType = 2
    //
    //        switch self.finishMode{
    //
    //        case .loop:
    //            self.player?.seek(toTime: 0)
    //            self.player?.play()
    //            finishType = 0
    //
    //        case .pause:
    //            self.player?.pause()
    //            stopListening()
    //            finishType = 1
    //
    //        case .stop:
    //            self.player?.stop()
    //            stopListening()
    //            self.player = nil
    //            finishType = 2
    //
    //
    //        }
    //
    //        plugin.flutterChannel.invokeMethod(Constants.onDidFinishPlayingAudio, arguments: [
    //                 Constants.finishType: finishType,
    //                 Constants.playerKey: playerKey])
    //    }

    func startPlyer(result: @escaping FlutterResult) {
        do {
            try configureAudioSessionForPlayback()
            print("startPlyer isPrepared=\(isPrepared)")
            
            if !isPrepared {
                guard let path = lastPreparedPath,
                      let audioUrl = URL(string: path) else {
                    result(false)
                    return
                }
                try prepareAudio(url: audioUrl)
            }

            guard isPrepared else {
                result(false)
                return
            }

            beginPlaybackTracking()
            switch playbackBackend {
            case .sfbaudioEngine:
                guard let player = player else {
                    result(false)
                    return
                }
                try player.play()
            case .systemAudioPlayer:
                guard systemPlayer?.play() == true else {
                    result(false)
                    return
                }
            }
            startListening()
            result(true)
        } catch {
            result(
                FlutterError(
                    code: Constants.audioWaveforms,
                    message: "Failed to start playback: \(error.localizedDescription)",
                    details: ""
                )
            )
        }
    }

    func pausePlayer() {
        cancelCompletionTracking()
        stopListening()
        switch playbackBackend {
        case .sfbaudioEngine:
            _ = player?.pause()
        case .systemAudioPlayer:
            systemPlayer?.pause()
        }
    }

    func stopPlayer() {
        cancelCompletionTracking()
        stopListening()
        isRecoveringFromDecodeError = false
        switch playbackBackend {
        case .sfbaudioEngine:
            player?.stop()
        case .systemAudioPlayer:
            systemPlayer?.stop()
            systemPlayer?.currentTime = 0
        }
        isPrepared = false
        timer = nil
    }

    func release(result: @escaping FlutterResult) {
        cancelCompletionTracking()
        stopListening()
        player?.stop()
        systemPlayer?.stop()
        systemPlayer = nil
        timePitchNode = nil
        playbackRate = 1.0
        isPrepared = false
        lastPreparedPath = nil
        activeAudioURL = nil
        isRecoveringFromDecodeError = false
        player = nil
        result(true)
    }

    func getDuration(_ type: DurationType, _ result: @escaping FlutterResult)
        throws
    {
        if type == .Current {
            let currentTime: TimeInterval
            switch playbackBackend {
            case .sfbaudioEngine:
                currentTime = player?.currentTime ?? 0
            case .systemAudioPlayer:
                currentTime = systemPlayer?.currentTime ?? 0
            }
            let ms = currentTime * 1000
            result(Int(ms))
        } else {
            let totalTime: TimeInterval
            switch playbackBackend {
            case .sfbaudioEngine:
                totalTime = player?.totalTime ?? 0
            case .systemAudioPlayer:
                totalTime = systemPlayer?.duration ?? 0
            }
            let ms = totalTime * 1000
            print("player?.totalTime----------------\(ms)")
            result(Int(ms))
        }
    }

    func setVolume(_ volume: Double?, _ result: @escaping FlutterResult) {
        #if !os(iOS)
        do {
//            try player?.setVolume(Float(volume ?? 1.0))
            result(true)
        } catch {
            result(
                FlutterError(
                    code: Constants.audioWaveforms,
                    message: "Failed to set volume: \(error.localizedDescription)",
                    details: ""
                )
            )
        }
        #else
        // On iOS, volume is controlled through AVAudioSession
        result(true)
        #endif
    }

    func setNoiseSuppressionLevel(
        _ level: Int?,
        _ result: @escaping FlutterResult
    ) {
        player?.isNoiseSuppressionEnabled = (level ?? 0) > 0
        result(true)
    }

    func setRate(_ rate: Double?, _ result: @escaping FlutterResult) {
        guard let rate = rate, rate.isFinite, rate > 0 else {
            result(false)
            return
        }

        let newRate = max(0.5, min(Float(rate), 2.0))
        if newRate == playbackRate && (!isDefaultPlaybackRate || timePitchNode == nil) {
            result(true)
            return
        }

        playbackRate = newRate
        if playbackBackend == .systemAudioPlayer {
            systemPlayer?.enableRate = true
            systemPlayer?.rate = playbackRate
            result(true)
            return
        }

        if isDefaultPlaybackRate && timePitchNode == nil {
            result(true)
            return
        }

        player?.modifyProcessingGraph { [weak self] engine in
            guard let self = self, let player = self.player else { return }
            let format = player.sourceNode.outputFormat(forBus: 0)
            _ = self.configurePlaybackRateGraph(
                engine,
                sourceFormat: format,
                connectSource: true
            )
        }

        result(true)
    }

    func getRate(_ result: @escaping FlutterResult) {
        result(Double(playbackRate))
    }

    func seekTo(_ time: Int?, _ result: @escaping FlutterResult) {
        if let time = time {
            completionWorkItem?.cancel()
            completionWorkItem = nil
            let seconds = Double(time) / 1000.0
            switch playbackBackend {
            case .sfbaudioEngine:
                _ = player?.seek(time: seconds)
            case .systemAudioPlayer:
                systemPlayer?.currentTime = seconds
            }
            sendCurrentDuration()
            result(true)
        } else {
            result(false)
        }
    }

    func setFinishMode(result: @escaping FlutterResult, releaseType: Int?) {
        if releaseType != nil && releaseType == 0 {
            self.finishMode = FinishMode.loop
        } else if releaseType != nil && releaseType == 1 {
            self.finishMode = FinishMode.pause
        } else {
            self.finishMode = FinishMode.stop
        }
        result(nil)
    }

    func startListening() {
        timer?.invalidate()
        timer = nil

        if #available(iOS 10.0, *) {
            timer = Timer.scheduledTimer(
                withTimeInterval: (Double(updateFrequency) / 1000),
                repeats: true,
                block: { [weak self] _ in
                    self?.sendCurrentDuration()
                }
            )
        } else {
            // Fallback on earlier versions
        }
    }

    func stopListening() {
        timer?.invalidate()
        timer = nil
        sendCurrentDuration()
    }

    func sendCurrentDuration() {
        let currentTime: TimeInterval
        switch playbackBackend {
        case .sfbaudioEngine:
            currentTime = player?.currentTime ?? 0
        case .systemAudioPlayer:
            currentTime = systemPlayer?.currentTime ?? 0
        }
        let ms = currentTime * 1000
        flutterChannel.invokeMethod(
            Constants.onCurrentDuration,
            arguments: [
                Constants.current: Int(ms), Constants.playerKey: playerKey,
            ]
        )
          print(
            "currentTimeMs=\(Int(currentTime * 1000)) "
        )
    }

    private func configureAudioSessionForPlayback() throws {
        guard overrideAudioSession else { return }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private var isDefaultPlaybackRate: Bool {
        abs(playbackRate - 1.0) < 0.0001
    }

    private func prepareAudio(url audioUrl: URL) throws {
        if shouldUseSystemAudioPlayer(for: audioUrl) {
            try prepareSystemAudioPlayer(url: audioUrl)
            return
        }

        systemPlayer?.stop()
        systemPlayer = nil
        playbackBackend = .sfbaudioEngine
        activeAudioURL = audioUrl
        decodeRecoveryAttempts = 0
        isRecoveringFromDecodeError = false

        if player == nil {
            player = AudioPlayer()
        }
        player?.isNoiseSuppressionEnabled = true
        isPrepared = false

        playbackRate = 1.0
        timePitchNode = nil
        resetCompletionTracking()

        let decoder = try AudioDecoder(url: audioUrl)
        try player?.enqueue(decoder, immediate: true)
        player?.delegate = self
        isPrepared = true
    }

    private func prepareSystemAudioPlayer(url audioUrl: URL) throws {
        player?.stop()
        systemPlayer?.stop()

        playbackBackend = .systemAudioPlayer
        isPrepared = false

        playbackRate = 1.0
        timePitchNode = nil
        resetCompletionTracking()

        let audioPlayer = try AVAudioPlayer(contentsOf: audioUrl)
        audioPlayer.delegate = self
        audioPlayer.enableRate = true
        audioPlayer.rate = playbackRate
        audioPlayer.prepareToPlay()

        systemPlayer = audioPlayer
        isPrepared = true
    }

    /// 仅在旧版 iOS 的兼容场景下为特定 MP3 使用 AVAudioPlayer；iOS 17 及以上保留
    /// SFBAudioEngine，以支持波形、倍速和损坏帧恢复。
    private func shouldUseSystemAudioPlayer(for audioUrl: URL) -> Bool {
        // 仅对本地 MP3 判断是否需要使用系统播放器，其他格式继续交给 SFBAudioEngine。
        guard audioUrl.isFileURL,
              audioUrl.pathExtension.lowercased() == "mp3" else {
            return false
        }

        // iOS 17 及以上优先使用 SFBAudioEngine，以支持插件的音频处理与容错恢复逻辑。
        if #available(iOS 17.0, *) {
            return false
        }

        // 旧版 iOS 对低采样率或单声道 MP3 的 SFBAudioEngine 兼容性较差，改用系统播放器。
        guard let audioFile = try? AVAudioFile(forReading: audioUrl) else {
            return true
        }

        let format = audioFile.fileFormat
        return format.sampleRate <= 24_000 || format.channelCount == 1
    }

    private func resetCompletionTracking() {
        completionWorkItem?.cancel()
        completionWorkItem = nil
        hasSentCompletionEvent = false
        shouldNotifyCompletionOnStop = false
    }

    private func beginPlaybackTracking() {
        completionWorkItem?.cancel()
        completionWorkItem = nil
        hasSentCompletionEvent = false
        shouldNotifyCompletionOnStop = true
    }

    private func cancelCompletionTracking() {
        completionWorkItem?.cancel()
        completionWorkItem = nil
        shouldNotifyCompletionOnStop = false
    }

    @discardableResult
    private func configurePlaybackRateGraph(
        _ engine: AVAudioEngine,
        sourceFormat: AVAudioFormat,
        connectSource: Bool
    ) -> AVAudioNode {
        if let timePitchNode = timePitchNode {
            engine.disconnectNodeOutput(timePitchNode)
            engine.detach(timePitchNode)
            self.timePitchNode = nil
        }

        if connectSource, let player = player {
            engine.disconnectNodeOutput(player.sourceNode)
        }

        guard !isDefaultPlaybackRate else {
            if connectSource, let player = player {
                engine.connect(player.sourceNode, to: engine.mainMixerNode, format: sourceFormat)
            }
            return engine.mainMixerNode
        }

        let timePitchNode = AVAudioUnitTimePitch()
        timePitchNode.rate = playbackRate
        engine.attach(timePitchNode)
        engine.connect(timePitchNode, to: engine.mainMixerNode, format: sourceFormat)

        if connectSource, let player = player {
            engine.connect(player.sourceNode, to: timePitchNode, format: sourceFormat)
        }

        self.timePitchNode = timePitchNode
        return timePitchNode
    }

    // MARK: - AudioPlayerDelegate Methods

    func audioPlayer(
        _ audioPlayer: AudioPlayer,
        reconfigureProcessingGraph engine: AVAudioEngine,
        with format: AVAudioFormat
    ) -> AVAudioNode {
        return configurePlaybackRateGraph(
            engine,
            sourceFormat: format,
            connectSource: false
        )
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, renderingComplete decoder: PCMDecoding) {
        logPlaybackSignal("renderingComplete")
        guard !isRecoveringFromDecodeError else { return }
        handlePlaybackCompletion()
    }

    func audioPlayer(
        _ audioPlayer: AudioPlayer,
        renderingWillComplete decoder: PCMDecoding,
        at hostTime: UInt64
    ) {
        logPlaybackSignal("renderingWillComplete")
        guard !isRecoveringFromDecodeError else { return }
        schedulePlaybackCompletion(at: hostTime)
    }

    func audioPlayerEndOfAudio(_ audioPlayer: AudioPlayer) {
        logPlaybackSignal("endOfAudio")
        guard !isRecoveringFromDecodeError else { return }
        handlePlaybackCompletion()
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, nowPlayingChanged nowPlaying: PCMDecoding?) {
        logPlaybackSignal("nowPlayingChanged isNil=\(nowPlaying == nil)")
        guard !isRecoveringFromDecodeError else { return }
        if nowPlaying == nil {
            handlePlaybackCompletion()
        }
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, playbackStateChanged playbackState: AudioPlayer.PlaybackState) {
        let currentTime: TimeInterval
        switch playbackBackend {
        case .sfbaudioEngine:
            currentTime = player?.currentTime ?? 0
        case .systemAudioPlayer:
            currentTime = systemPlayer?.currentTime ?? 0
        }
        print(
            "playbackStateChanged ====\(playbackState) " +
            "currentTimeMs=\(Int(currentTime * 1000)) " +
            "shouldNotifyCompletionOnStop=\(shouldNotifyCompletionOnStop)"
        )
        if isRecoveringFromDecodeError {
            if playbackState == .playing {
                // A replacement decoder is now rendering. Older stopped events
                // from the aborted decoder must not finish this playback.
                isRecoveringFromDecodeError = false
                decodeRecoveryAttempts = 0
            }
            return
        }
        if playbackState == .stopped && shouldNotifyCompletionOnStop {
            handlePlaybackCompletion(forceStopped: true)
        }
    }

    private func schedulePlaybackCompletion(at hostTime: UInt64) {
        guard shouldNotifyCompletionOnStop, !hasSentCompletionEvent else { return }

        completionWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.handlePlaybackCompletion()
        }
        completionWorkItem = workItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + secondsUntilHostTime(hostTime),
            execute: workItem
        )
    }

    private func secondsUntilHostTime(_ hostTime: UInt64) -> TimeInterval {
        let now = mach_absolute_time()
        guard hostTime > now else { return 0 }

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let nanos = (hostTime - now) * UInt64(timebase.numer) / UInt64(timebase.denom)
        return Double(nanos) / 1_000_000_000
    }

    private func handlePlaybackCompletion() {
        handlePlaybackCompletion(forceStopped: false)
    }

    private func handlePlaybackCompletion(forceStopped: Bool) {
        logPlaybackSignal("handlePlaybackCompletion forceStopped=\(forceStopped)")
        guard shouldNotifyCompletionOnStop, !hasSentCompletionEvent else { return }
        completionWorkItem?.cancel()
        completionWorkItem = nil
        hasSentCompletionEvent = true
        shouldNotifyCompletionOnStop = false

        var finishType = 2

        switch forceStopped ? FinishMode.stop : self.finishMode {
        case .loop:
            finishType = 0
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                do {
                    switch self.playbackBackend {
                    case .sfbaudioEngine:
                        _ = self.player?.seek(time: 0)
                        try self.player?.play()
                    case .systemAudioPlayer:
                        self.systemPlayer?.currentTime = 0
                        self.systemPlayer?.play()
                    }
                    self.startListening()
                } catch {
                    print("Failed to loop: \(error)")
                }
            }

        case .pause:
            finishType = 1
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                switch self.playbackBackend {
                case .sfbaudioEngine:
                    _ = self.player?.seek(time: 0)
                    _ = self.player?.pause()
                case .systemAudioPlayer:
                    self.systemPlayer?.currentTime = 0
                    self.systemPlayer?.pause()
                }
                self.stopListening()
                self.isPrepared = false
            }

        case .stop:
            finishType = 2
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                switch self.playbackBackend {
                case .sfbaudioEngine:
                    _ = self.player?.seek(time: 0)
                case .systemAudioPlayer:
                    self.systemPlayer?.currentTime = 0
                    self.systemPlayer?.stop()
                }
                self.stopListening()
                self.isPrepared = false
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.plugin.flutterChannel.invokeMethod(
                Constants.onDidFinishPlayingAudio,
                arguments: [
                    Constants.finishType: finishType,
                    Constants.playerKey: self.playerKey,
                ]
            )
            if finishType == 0 {
                self.beginPlaybackTracking()
            }
        }
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, encounteredError error: Error) {
        print("Audio player error: \(error.localizedDescription)")
    }

    func audioPlayer(
        _ audioPlayer: AudioPlayer,
        decodingAborted decoder: PCMDecoding,
        error: Error,
        framesRendered: AVAudioFramePosition
    ) {
        logPlaybackSignal(
            "decodingAborted error=\(error.localizedDescription) framesRendered=\(framesRendered)"
        )
        guard case .sfbaudioEngine = playbackBackend,
              let url = activeAudioURL,
              url.isFileURL,
              url.pathExtension.lowercased() == "mp3",
              decoder.processingFormat.sampleRate > 0 else {
            handlePlaybackCompletion(forceStopped: true)
            return
        }

        guard decodeRecoveryAttempts < maxDecodeRecoveryAttempts else {
            isRecoveringFromDecodeError = false
            handlePlaybackCompletion(forceStopped: true)
            return
        }

        decodeRecoveryAttempts += 1
        isRecoveringFromDecodeError = true
        completionWorkItem?.cancel()
        completionWorkItem = nil

        // `framesRendered` is expressed in the failed decoder's PCM sample
        // rate. Convert it to time before creating a replacement decoder:
        // malformed MP3 headers can cause its PCM sample rate to differ.
        let resumeTime = Double(framesRendered) / decoder.processingFormat.sampleRate + recoverySkipSeconds

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            do {
                let replacement = try AudioDecoder(url: url)
                try replacement.open()
                let replacementResumeFrame = AVAudioFramePosition(
                    resumeTime * replacement.processingFormat.sampleRate
                )
                guard replacementResumeFrame < replacement.length else {
                    throw NSError(
                        domain: Constants.audioWaveforms,
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "No audio remains after decode failure"]
                    )
                }

                try replacement.seek(to: replacementResumeFrame)
                try self.player?.enqueue(replacement, immediate: true)
                try self.player?.play()
                self.startListening()
            } catch {
                self.isRecoveringFromDecodeError = false
                self.handlePlaybackCompletion(forceStopped: true)
            }
        }
    }

    private func logPlaybackSignal(_ signal: String) {
        let currentTime: TimeInterval
        switch playbackBackend {
        case .sfbaudioEngine:
            currentTime = player?.currentTime ?? 0
        case .systemAudioPlayer:
            currentTime = systemPlayer?.currentTime ?? 0
        }
        print(
            "audioPlayerSignal=\(signal) " +
            "currentTimeMs=\(Int(currentTime * 1000)) " +
            "recoveryAttempts=\(decodeRecoveryAttempts) " +
            "isRecovering=\(isRecoveringFromDecodeError) " +
            "shouldNotifyCompletionOnStop=\(shouldNotifyCompletionOnStop)"
        )
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        handlePlaybackCompletion()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if let error = error {
            print("System audio player error: \(error.localizedDescription)")
        }
    }
}
