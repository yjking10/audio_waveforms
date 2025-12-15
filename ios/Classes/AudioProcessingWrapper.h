#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, NoiseSuppressionLevel) {
    NoiseSuppressionLevelLow,
            NoiseSuppressionLevelModerate,
            NoiseSuppressionLevelHigh,
            NoiseSuppressionLevelVeryHigh
};

typedef NS_ENUM(NSUInteger, GainControllerMode) {
GainControllerModeAdaptiveAnalog,
GainControllerModeAdaptiveDigital,
GainControllerModeFixedDigital
};

@interface AudioProcessingWrapper : NSObject

- (instancetype)init;

// Reset to default configuration
- (void)resetToDefaultConfiguration;

// Noise suppression configuration
- (void)setNoiseSuppressionLevel:(NoiseSuppressionLevel)level;
- (void)setNoiseSuppressionEnabled:(BOOL)enabled;

// Gain controller configuration
- (void)setGainControllerMode:(GainControllerMode)mode;
- (void)setTargetLevelDbfs:(int)level;
- (void)setCompressionGainDb:(int)gain;

// Filter configuration
- (void)setHighPassFilterEnabled:(BOOL)enabled;

// Echo cancellation
- (void)setEchoCancellationEnabled:(BOOL)enabled;

// Transient suppression
- (void)setTransientSuppressionEnabled:(BOOL)enabled;

#pragma mark - 处理 16-bit Int 音频（交错）
- (NSData *)processAudioFrame:(NSData *)pcmData sampleRate:(int)sampleRate channels:(int)channels;

- (void)processBuffer10ms:(AVAudioPCMBuffer *)buffer;

- (void)processBuffer:(AVAudioPCMBuffer *)buffer ;

#pragma mark - 处理 Float 音频（非交错，多通道）
- (NSData *)processAudioFrameFloat:(NSData *)pcmData sampleRate:(int)sampleRate channels:(int)channels ;


- (void)processFloatAudio:(float **)channelBuffers sampleRate:(int)sampleRate channels:(int)channels ;

@end

NS_ASSUME_NONNULL_END
