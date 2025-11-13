#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <WebRTCAudioProcessing/AudioProcessingWrapper.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NoiseCancelPlayerState) {
    NoiseCancelPlayerStateReady,
    NoiseCancelPlayerStatePlaying,
    NoiseCancelPlayerStatePaused,
    NoiseCancelPlayerStateStopped
};

@protocol NoiseCancelPlayerDelegate <NSObject>
@optional
- (void)audioPlayer:(id)player didUpdateProgress:(NSTimeInterval)currentTime duration:(NSTimeInterval)duration;
- (void)audioPlayer:(id)player didChangeState:(NoiseCancelPlayerState)state;
- (void)audioPlayerDidFinishPlaying:(id)player;
@end

@interface NoiseCancelPlayer : NSObject
@property (nonatomic, weak) id<NoiseCancelPlayerDelegate> delegate;
@property (nonatomic, assign, readonly) float rate; // 播放倍速，默认 1.0
@property (nonatomic, assign, readonly) NSTimeInterval duration; // 音频总时长
@property (nonatomic, assign, readonly) NSTimeInterval currentTime; // 当前播放时间
@property (nonatomic, assign, readonly) NoiseCancelPlayerState state; // 播放状态
@property (nonatomic, assign) NoiseSuppressionLevel noiseSuppressionLevel;

- (void)setFileURL:(NSURL *)audioFileURL;
- (void)play;
- (void)pause;
- (void)stop;
- (void)setPlaybackRate:(float)rate;
- (void)seekToTime:(NSTimeInterval)timeInSeconds;

@end

NS_ASSUME_NONNULL_END
