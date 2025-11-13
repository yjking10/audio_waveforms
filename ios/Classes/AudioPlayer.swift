import Foundation
import AVFoundation
import WebRTCAudioProcessing

class AudioPlayer: NSObject, NoiseCancelPlayerDelegate {
 
    private var player: NoiseCancelPlayer?
    private var seekToStart = true
    private var stopWhenCompleted = false
    private var timer: Timer?

    private var finishMode:FinishMode = FinishMode.stop
    private var updateFrequency = 200
    var plugin: SwiftAudioWaveformsPlugin
    var playerKey: String
    var flutterChannel: FlutterMethodChannel
    

    init(plugin: SwiftAudioWaveformsPlugin, playerKey: String, channel: FlutterMethodChannel, result: @escaping FlutterResult) {
      
        
        self.plugin = plugin
        self.playerKey = playerKey
        flutterChannel = channel


        self.player = NoiseCancelPlayer.init()
    }
    
    
    func preparePlayer(
        path: String?,
        volume: Double?,
        updateFrequency: Int?,
        result: @escaping FlutterResult,
        overrideAudioSession: Bool
    ) {
        
        // 1. 基础校验：路径非空
        guard let path = path, !path.isEmpty else {
          
            
            result(FlutterError(code: Constants.audioWaveforms, message: "Audio file path can't be empty or null", details: ""))
            return
        }
        
        let audioUrl = URL.init(string: path)
        if(audioUrl == nil){
                      result(FlutterError(code: Constants.audioWaveforms, message: "Failed to initialise Url from provided audio file", details: "If path contains `file://` try removing it"))
                      return
        }

       
            player?.setFileURL(audioUrl!);
            result(true)
     
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
        player?.play();
        player?.delegate = self
        stopListening()
        result(true)
  

    }
    func pausePlayer() {
         stopListening()
         player?.pause()
     }
     
     func stopPlayer() {
         stopListening()
         player?.stop()
         timer = nil
     }
    
    
    func release(result: @escaping FlutterResult) {
        
         player = nil
         result(true)
     }
    
    func getDuration(_ type: DurationType, _ result: @escaping FlutterResult) throws {
        if type == .Current {
              let ms = (player?.currentTime ?? 0) * 1000
              result(Int(ms))
          } else {
              let ms = (player?.duration ?? 0) * 1000
              print("player?.duration----------------\(ms)")
              result(Int(ms))
          }
    }
    
    func setVolume(_ volume: Double?, _ result: @escaping FlutterResult) {
//        player?.volume = Float(volume ?? 1.0)
        if (Float(volume ?? 1.0) > 100){
            player?.noiseSuppressionLevel = .high
        }
        
        result(true)
    }


   func setNoiseSuppressionLevel(_ level: Int?, _ result: @escaping FlutterResult) {

         if(level == 1){
         player?.noiseSuppressionLevel = .moderate
         } else if(level == 2){
         player?.noiseSuppressionLevel = .high
         }else if(level == 3){
       player?.noiseSuppressionLevel = .veryHigh
       } else {
       player?.noiseSuppressionLevel = .low
       }

        result(true)
    }

    func setRate(_ rate: Double?, _ result: @escaping FlutterResult) {
        player?.setPlaybackRate(Float(rate ?? 1.0));
        result(true)
        

    }

    func seekTo(_ time: Int?, _ result: @escaping FlutterResult) {
        if(time != nil) {
            
            player?.seek(toTime: Double(time! / 1000))
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
            timer = Timer.scheduledTimer(withTimeInterval: (Double(updateFrequency) / 1000), repeats: true, block: { [weak self] _ in
                self?.sendCurrentDuration()
            })
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
        
        print("sendCurrentDuration  \(ms)")
        flutterChannel.invokeMethod(Constants.onCurrentDuration, arguments: [Constants.current: Int(ms), Constants.playerKey: playerKey])
    }
    
    
    func audioPlayerDidFinishPlaying(_ player: Any) {
        print("audioPlayerDidFinishPlaying")
        var finishType = 2
        
        switch self.finishMode{
            
        case .loop:
            self.player?.seek(toTime: 0)
            self.player?.play()
            finishType = 0
            
        case .pause:
            self.player?.pause()
            stopListening()
            finishType = 1
            
        case .stop:
            self.player?.stop()
            stopListening()
            self.player = nil
            finishType = 2
            
            
        }
        
        plugin.flutterChannel.invokeMethod(Constants.onDidFinishPlayingAudio, arguments: [
                 Constants.finishType: finishType,
                 Constants.playerKey: playerKey])
    }
    
    func audioPlayer(_ player: Any, didUpdateProgress currentTime: TimeInterval, duration: TimeInterval) {
        print("didUpdateProgress \(currentTime)  \(duration)")
        sendCurrentDuration()
    }
    func audioPlayer(_ player: Any, didChange state: NoiseCancelPlayerState) {
        print("didChange \(NoiseCancelPlayerState.RawValue())")
        
    }
}
