import Flutter
import UIKit

public class SwiftAudioWaveformsPlugin: NSObject, FlutterPlugin {
    
    let audioRecorder: AudioRecorder
    var audioPlayers = [String: FlutterAudioPlayer]()
    var extractors = [String: WaveformExtractor]()
    var flutterChannel: FlutterMethodChannel
    
    init(registrar: FlutterPluginRegistrar, flutterChannel: FlutterMethodChannel) {
        self.flutterChannel = flutterChannel
        audioRecorder = AudioRecorder(channel: flutterChannel)
        super.init()
    }
    
    deinit {
        audioPlayers.removeAll()
        extractors.removeAll()
    }
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: Constants.methodChannelName, binaryMessenger: registrar.messenger())
        let instance = SwiftAudioWaveformsPlugin(registrar: registrar, flutterChannel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? Dictionary<String, Any>
        switch call.method {
            case Constants.startRecording:
                guard let args = call.arguments as? Dictionary<String, Any> else {
                    result(FlutterError(code: Constants.audioWaveforms, message: "Invalid Arguments", details: nil))
                    return
                }
                audioRecorder.startRecording(result, RecordingSettings.fromJson((args)))
                break
            case Constants.pauseRecording:
                audioRecorder.pauseRecording(result)
                break
            case Constants.resumeRecording:
                audioRecorder.resumeRecording(result)
            case Constants.stopRecording:
                audioRecorder.stopRecording(result)
                break
            case Constants.getDecibel:
                audioRecorder.getDecibel(result)
                break
            case Constants.checkPermission:
                audioRecorder.checkHasPermission(result)
                break
            case Constants.preparePlayer:
                let key = args?[Constants.playerKey] as? String
                if(key != nil){
                    initPlayer(playerKey: key!)
                    audioPlayers[key!]?.preparePlayer(path: args?[Constants.path] as? String,
                                                      volume: args?[Constants.volume] as? Double,
                                                      updateFrequency: args?[Constants.updateFrequency] as? Int,
                                                      result: result,
                                                      overrideAudioSession: (args?[Constants.overrideAudioSession] as? Bool) ?? true)
                } else {
                    result(FlutterError(code: Constants.audioWaveforms, message: "Can not prepare player", details: "Player key is null"))
                }
                break
            case Constants.startPlayer:
                let key = args?[Constants.playerKey] as? String
                if(key != nil){
                    audioPlayers[key!]?.startPlyer(result: result)
                } else {
                    result(FlutterError(code: Constants.audioWaveforms, message: "Can not start player", details: "Player key is null"))
                }
                break
            case Constants.finishMode:
                let key = args?[Constants.playerKey] as? String
                let releaseType = args?[Constants.finishType] as? Int
                if(key != nil){
                    audioPlayers[key!]?.setFinishMode(result: result, releaseType: releaseType)
                }else{
                    result(FlutterError(code: Constants.audioWaveforms, message: "Can not set release mode", details: "Player key is null"))
                }
            case Constants.pausePlayer:
                let key = args?[Constants.playerKey] as? String
                if(key != nil){
                    audioPlayers[key!]?.pausePlayer()
                    result(true)
                } else {
                    result(FlutterError(code: Constants.audioWaveforms, message: "Can not pause player", details: "Player key is null"))
                }
                break
            case Constants.stopPlayer:
                let key = args?[Constants.playerKey] as? String
                if(key != nil){
                    audioPlayers[key!]?.stopPlayer()
                    result(true)
                } else {
                    result(FlutterError(code: Constants.audioWaveforms, message: "Can not stop player", details: "Player key is null"))
                }
                break
            case Constants.releasePlayer:
                let key = args?[Constants.playerKey] as? String
                if let key = key {
                    audioPlayers[key]?.release(result: result)
                    audioPlayers[key] = nil
                } else {
                    result(FlutterError(code: Constants.audioWaveforms, message: "Can not release player", details: "Player key is null"))
                }
                break;
            case Constants.seekTo:
                let key = args?[Constants.playerKey] as? String
                if(key != nil){
                    audioPlayers[key!]?.seekTo(args?[Constants.progress] as? Int,result)
                } else {
                    result(FlutterError(code: Constants.audioWaveforms, message: "Can not seek to postion", details: "Player key is null"))
                }
            case Constants.setVolume:
                let key = args?[Constants.playerKey] as? String
                if(key != nil){
                    audioPlayers[key!]?.setVolume(args?[Constants.volume] as? Double,result)
                } else {
                    result(FlutterError(code: Constants.audioWaveforms, message: "Can not set volume", details: "Player key is null"))
                }
//                   static const String setNoiseSuppressionLevel = "setNoiseSuppressionLevel";
//                   static const String noiseSuppressionLevel = "noiseSuppressionLevel";
            case Constants.setNoiseSuppressionLevel:
                let key = args?[Constants.playerKey] as? String
                if(key != nil){
                    audioPlayers[key!]?.setNoiseSuppressionLevel(args?[Constants.noiseSuppressionLevel] as? Int,result)
                } else {
                    result(FlutterError(code: Constants.audioWaveforms, message: "Can not set noiseSuppressionLevel", details: "Player key is null"))
                }
            case Constants.setRate:
                let key = args?[Constants.playerKey] as? String
                if(key != nil){
                    audioPlayers[key!]?.setRate(args?[Constants.rate] as? Double,result)
                } else {
                    result(FlutterError(code: Constants.audioWaveforms, message: "Can not set rate", details: "Player key is null"))
                }
            case Constants.getDuration:
                let type = args?[Constants.durationType] as? Int
                let key = args?[Constants.playerKey] as? String
                if let key = key, let player = audioPlayers[key] {
                    do{
                        if(type == 0){
                            try player.getDuration(DurationType.Current,result)
                        } else {
                            try player.getDuration(DurationType.Max,result)
                        }
                    } catch{
                        result(FlutterError(code: "", message: "Failed to get duration", details: nil))
                    }
                } else {
                    result(FlutterError(code: Constants.audioWaveforms, message: "Can not get duration", details: "Player has not been prepared"))
                }
            case Constants.stopAllPlayers:
                for (playerKey,_) in audioPlayers {
                    audioPlayers[playerKey]?.stopPlayer()
                    audioPlayers[playerKey] = nil
                }
                result(true)
            case Constants.extractWaveformData:
                guard let key = args?[Constants.playerKey] as? String else {
                    result(
                        FlutterError(
                            code: Constants.audioWaveforms,
                            message: "Can not get waveform data",
                            details: "Waveform key is null"
                        )
                    )
                    break
                }
                let path = args?[Constants.path] as? String
                let noOfSamples = args?[Constants.noOfSamples] as? Int
                let noOfSamplesPerSecond = args?[Constants.noOfSamplesPerSecond] as? Int
                createOrUpdateExtractor(
                    playerKey: key,
                    result: result,
                    path: path,
                    noOfSamples: noOfSamples,
                    noOfSamplesPerSecond: noOfSamplesPerSecond
                )
            case Constants.stopExtraction:
                guard let key = args?[Constants.playerKey] as? String else {
                    result(FlutterError(code: Constants.audioWaveforms, message: "Can not get waveform data", details: "Waveform key is null"))
                    break
                }
                extractors[key]?.cancel()
                result(true)
            case Constants.pauseAllPlayers:
                for(playerKey,_) in audioPlayers {
                    audioPlayers[playerKey]?.pausePlayer()
                }
                result(true)
                break
            default:
                result(FlutterMethodNotImplemented)
                break
        }
    }
    
    
    func initPlayer(playerKey: String) {
        if audioPlayers[playerKey] == nil {
            let newPlayer = FlutterAudioPlayer(plugin: self,playerKey: playerKey,channel: flutterChannel)
            audioPlayers[playerKey] = newPlayer
        }
    }
    
    func createOrUpdateExtractor(
        playerKey: String,
        result: @escaping FlutterResult,
        path: String?,
        noOfSamples: Int?,
        noOfSamplesPerSecond: Int?
    ) {
        if(!(path ?? "").isEmpty) {
            do {
                let audioUrl: URL
                if let url = URL(string: path!), url.scheme != nil {
                    audioUrl = url
                } else {
                    // Callers sometimes provide a URL-encoded POSIX path
                    // (for example `Steve%20Jobs.mp3`) instead of a file://
                    // URL. FileManager treats `%20` literally, so decode it
                    // before constructing the local file URL.
                    let localPath = path!.removingPercentEncoding ?? path!
                    audioUrl = URL(fileURLWithPath: localPath)
                }
                extractors[playerKey]?.cancel()
                let newExtractor = try WaveformExtractor(url: audioUrl)
                extractors[playerKey] = newExtractor
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let data = try newExtractor.extractWaveform(
                            samplesPerPixel: noOfSamples,
                            samplesPerSecond: noOfSamplesPerSecond
                        )
                        DispatchQueue.main.async { [weak self] in
                            if self?.extractors[playerKey] === newExtractor {
                                self?.extractors[playerKey] = nil
                            }
                            result(data)
                        }
                    } catch {
                        DispatchQueue.main.async { [weak self] in
                            if self?.extractors[playerKey] === newExtractor {
                                self?.extractors[playerKey] = nil
                            }
                            result(FlutterError(
                                code: Constants.audioWaveforms,
                                message: "Failed to extract waveform",
                                details: error.localizedDescription
                            ))
                        }
                    }
                }
            } catch {
                result(FlutterError(
                    code: Constants.audioWaveforms,
                    message: "Failed to decode audio file",
                    details: error.localizedDescription
                ))
            }
        } else {
            result(FlutterError(code: Constants.audioWaveforms, message: "Audio file path can't be empty or null", details: nil))
        }
    }
}
