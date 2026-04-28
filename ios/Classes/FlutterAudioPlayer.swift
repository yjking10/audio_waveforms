import AVFoundation
import Foundation
import SFBAudioEngine

class FlutterAudioPlayer: NSObject, AudioPlayer.Delegate {

    private var player: AudioPlayer?
    private var seekToStart = true
    private var stopWhenCompleted = false
    private var timer: Timer?
    private var playbackRate: Float = 1.0
    private var timePitchNode: AVAudioUnitTimePitch?
    private var overrideAudioSession = true

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

        guard let audioUrl = makeAudioURL(from: path) else {
            result(
                FlutterError(
                    code: Constants.audioWaveforms,
                    message: "Failed to initialise Url from provided audio file",
                    details: "If path contains `file://` try removing it"
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
            player?.isNoiseSuppressionEnabled = false

            // Reset rate state before enqueue to avoid stale graph on older iOS.
            playbackRate = 1.0
            timePitchNode = nil

            let decoder = try AudioDecoder(url: audioUrl)
            try player?.enqueue(decoder, immediate: true)
            player?.delegate = self

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

            result(true)
        } catch {
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
            try player?.play()
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
        stopListening()
        _ = player?.pause()
    }

    func stopPlayer() {
        stopListening()
        player?.stop()
        timer = nil
    }

    func release(result: @escaping FlutterResult) {
        stopListening()
        player?.stop()
        timePitchNode = nil
        playbackRate = 1.0
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

    private func makeAudioURL(from path: String) -> URL? {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }

        if path.hasPrefix("file://") {
            return URL(string: path)
        }

        return URL(fileURLWithPath: path)
    }

    private var isDefaultPlaybackRate: Bool {
        abs(playbackRate - 1.0) < 0.0001
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
        print("audioPlayer renderingComplete")
        var finishType = 2

        switch self.finishMode {
        case .loop:
            do {
                try self.player?.enqueue(decoder, immediate: true)
                try self.player?.play()
                finishType = 0
            } catch {
                print("Failed to loop: \(error)")
            }

        case .pause:
            _ = self.player?.pause()
            stopListening()
            finishType = 1

        case .stop:
            finishType = 2
            // Dispatch to main thread to avoid destroying AudioPlayer from its own event thread
            DispatchQueue.main.async { [weak self] in
                self?.stopListening()
                self?.player?.stop()
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
        }
    }

//    func audioPlayer(_ audioPlayer: AudioPlayer, playbackStateChanged playbackState: AudioPlayerPlaybackState) {
//        // Handle playback state changes if needed
//    }

    func audioPlayer(_ audioPlayer: AudioPlayer, encounteredError error: Error) {
        print("Audio player error: \(error.localizedDescription)")
    }
}
