import AVFoundation
import Darwin
import Foundation
import SFBAudioEngine

class FlutterAudioPlayer: NSObject, AudioPlayer.Delegate {

    private var player: AudioPlayer?
    private var timer: Timer?
    private var completionWorkItem: DispatchWorkItem?
    private var playbackRate: Float = 1.0
    private var timePitchNode: AVAudioUnitTimePitch?
    private var overrideAudioSession = true
    private var isPrepared = false
    private var hasSentCompletionEvent = false
    private var shouldNotifyCompletionOnStop = false
    private var lastPreparedPath: String?

    private var finishMode: FinishMode = FinishMode.stop
    private var updateFrequency = 200
    var plugin: SwiftAudioWaveformsPlugin
    var playerKey: String
    var flutterChannel: FlutterMethodChannel

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

        guard let audioUrl = AudioURLResolver.makeAudioURL(from: path) else {
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
                      let audioUrl = AudioURLResolver.makeAudioURL(from: path) else {
                    result(false)
                    return
                }
                try prepareAudio(url: audioUrl)
            }

            guard let player = player, isPrepared else {
                result(false)
                return
            }

            beginPlaybackTracking()
            try player.play()
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
        _ = player?.pause()
    }

    func stopPlayer() {
        cancelCompletionTracking()
        stopListening()
        player?.stop()
        isPrepared = false
        timer = nil
    }

    func release(result: @escaping FlutterResult) {
        cancelCompletionTracking()
        stopListening()
        player?.stop()
        timePitchNode = nil
        playbackRate = 1.0
        isPrepared = false
        lastPreparedPath = nil
        player = nil
        result(true)
    }

    func getDuration(_ type: DurationType, _ result: @escaping FlutterResult)
        throws
    {
        if type == .Current {
            let ms = (player?.currentTime ?? 0) * 1000
            result(Int(ms))
        } else {
            let ms = (player?.totalTime ?? 0) * 1000
            print("player?.totalTime----------------\(ms)")
            result(Int(ms))
        }
    }

    func setVolume(_ volume: Double?, _ result: @escaping FlutterResult) {
        #if !TARGET_OS_IPHONE
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
            _ = player?.seek(time: Double(time) / 1000.0)
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
        let ms = (player?.currentTime ?? 0) * 1000
        flutterChannel.invokeMethod(
            Constants.onCurrentDuration,
            arguments: [
                Constants.current: Int(ms), Constants.playerKey: playerKey,
            ]
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
        if player == nil {
            player = AudioPlayer()
        }
        player?.isNoiseSuppressionEnabled = false
        isPrepared = false

        playbackRate = 1.0
        timePitchNode = nil
        resetCompletionTracking()

        let decoder = try AudioDecoder(url: audioUrl)
        try player?.enqueue(decoder, immediate: true)
        player?.delegate = self
        isPrepared = true

        if #available(iOS 17.0, *) {
        } else {
            player?.modifyProcessingGraph { [weak self] engine in
                guard let self = self, let player = self.player else { return }
                let format = player.sourceNode.outputFormat(forBus: 0)
                _ = self.configurePlaybackRateGraph(
                    engine,
                    sourceFormat: format,
                    connectSource: true
                )
            }
        }
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
        handlePlaybackCompletion()
    }

    func audioPlayer(
        _ audioPlayer: AudioPlayer,
        renderingWillComplete decoder: PCMDecoding,
        at hostTime: UInt64
    ) {
        schedulePlaybackCompletion(at: hostTime)
    }

    func audioPlayerEndOfAudio(_ audioPlayer: AudioPlayer) {
        handlePlaybackCompletion()
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, nowPlayingChanged nowPlaying: PCMDecoding?) {
        if nowPlaying == nil {
            handlePlaybackCompletion()
        }
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, playbackStateChanged playbackState: AudioPlayer.PlaybackState) {
        print("playbackStateChanged ====\(playbackState) shouldNotifyCompletionOnStop=\(shouldNotifyCompletionOnStop)")
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
                    _ = self.player?.seek(time: 0)
                    try self.player?.play()
                    self.startListening()
                } catch {
                    print("Failed to loop: \(error)")
                }
            }

        case .pause:
            finishType = 1
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                _ = self.player?.seek(time: 0)
                _ = self.player?.pause()
                self.stopListening()
                self.isPrepared = false
            }

        case .stop:
            finishType = 2
            DispatchQueue.main.async { [weak self] in
                _ = self?.player?.seek(time: 0)
                self?.stopListening()
                self?.isPrepared = false
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
}
