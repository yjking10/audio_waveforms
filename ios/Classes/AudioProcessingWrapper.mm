#import "AudioProcessingWrapper.h"

// WebRTC C++ headers
//#include "webrtc-audio-processing-2/modules/audio_processing/include/audio_processing.h"

#import <webrtc_audio_processing/webrtc-audio-processing-1/modules/audio_processing/include/audio_processing.h>


using namespace webrtc;

@implementation AudioProcessingWrapper {
    rtc::scoped_refptr<AudioProcessing> _apm;
    NSMutableData *_processedBuffer;
    AudioProcessing::Config _currentConfig;
    StreamConfig _streamConfig;

}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self resetToDefaultConfiguration];
        _processedBuffer = [NSMutableData data];
    }
    return self;
}

- (void)resetToDefaultConfiguration {
    AudioProcessing::Config config;

    // Default noise suppression (can be adjusted later)
    config.noise_suppression.enabled = true;
    config.noise_suppression.level = AudioProcessing::Config::NoiseSuppression::kVeryHigh;

    // Default gain control
    config.gain_controller1.enabled = true;
    config.gain_controller1.mode = AudioProcessing::Config::GainController1::kAdaptiveDigital;
    config.gain_controller1.target_level_dbfs = 0;
    config.gain_controller1.compression_gain_db = 12;
    config.gain_controller1.enable_limiter = true;

    // Default high-pass filter
    config.high_pass_filter.enabled = true;

    // Default echo cancellation (off by default for pure recording)
    config.echo_canceller.enabled = false;

    // Default transient suppression
    config.transient_suppression.enabled = true;

    _currentConfig = config;
    [self applyCurrentConfiguration];
}

- (void)applyCurrentConfiguration {
    if (!_apm) {
        _apm = AudioProcessingBuilder().Create();
    }
    _apm->ApplyConfig(_currentConfig);
    _apm->Initialize();
}

#pragma mark - Dynamic Configuration Methods

- (void)setNoiseSuppressionLevel:(NoiseSuppressionLevel)level {
    switch (level) {
        case NoiseSuppressionLevelLow:
            _currentConfig.noise_suppression.level = AudioProcessing::Config::NoiseSuppression::kLow;
            break;
        case NoiseSuppressionLevelModerate:
            _currentConfig.noise_suppression.level = AudioProcessing::Config::NoiseSuppression::kModerate;
            break;
        case NoiseSuppressionLevelHigh:
            _currentConfig.noise_suppression.level = AudioProcessing::Config::NoiseSuppression::kHigh;
            break;
        case NoiseSuppressionLevelVeryHigh:
            _currentConfig.noise_suppression.level = AudioProcessing::Config::NoiseSuppression::kVeryHigh;
            break;
    }
    [self applyCurrentConfiguration];
}

- (void)setNoiseSuppressionEnabled:(BOOL)enabled {
    _currentConfig.noise_suppression.enabled = enabled;
    [self applyCurrentConfiguration];
}

- (void)setGainControllerMode:(GainControllerMode)mode {
    switch (mode) {
        case GainControllerModeAdaptiveAnalog:
            _currentConfig.gain_controller1.mode = AudioProcessing::Config::GainController1::kAdaptiveAnalog;
            break;
        case GainControllerModeAdaptiveDigital:
            _currentConfig.gain_controller1.mode = AudioProcessing::Config::GainController1::kAdaptiveDigital;
            break;
        case GainControllerModeFixedDigital:
            _currentConfig.gain_controller1.mode = AudioProcessing::Config::GainController1::kFixedDigital;
            break;
    }
    [self applyCurrentConfiguration];
}

- (void)setTargetLevelDbfs:(int)level {
    _currentConfig.gain_controller1.target_level_dbfs = level;
    [self applyCurrentConfiguration];
}

- (void)setCompressionGainDb:(int)gain {
    _currentConfig.gain_controller1.compression_gain_db = gain;
    [self applyCurrentConfiguration];
}

- (void)setHighPassFilterEnabled:(BOOL)enabled {
    _currentConfig.high_pass_filter.enabled = enabled;
    [self applyCurrentConfiguration];
}

- (void)setEchoCancellationEnabled:(BOOL)enabled {
    _currentConfig.echo_canceller.enabled = enabled;
    [self applyCurrentConfiguration];
}

- (void)setTransientSuppressionEnabled:(BOOL)enabled {
    _currentConfig.transient_suppression.enabled = enabled;
    [self applyCurrentConfiguration];
}

#pragma mark - Audio Processing
#pragma mark - 处理 16-bit Int 音频（交错）
- (NSData *)processAudioFrame:(NSData *)pcmData sampleRate:(int)sampleRate channels:(int)channels {
    if (!pcmData || pcmData.length == 0) return nil;
    if (sampleRate <= 0 || channels <= 0) return nil;

    const int16_t *audioFrame = (const int16_t *)pcmData.bytes;

    // Reuse buffer
    _processedBuffer.length = pcmData.length;
    int16_t *processedFrame = (int16_t *)_processedBuffer.mutableBytes;

    webrtc::StreamConfig config(sampleRate,
                                channels);
    int result = _apm->ProcessStream(audioFrame,
                                     config,
                                     config,
                                     processedFrame);
    
    if (result != webrtc::AudioProcessing::kNoError) {
        NSLog(@"Audio processing failed: %d",
              result);
        return nil;
    }
    
    return [_processedBuffer copy];
}


- (void)processBuffer10ms:(AVAudioPCMBuffer *)buffer {
    int channels = (int)buffer.format.channelCount;
    int sampleRate = (int)buffer.format.sampleRate;
    int frameCount = (int)buffer.frameLength;
    NSLog(@"processBuffer10ms: %@",
          [buffer.format description]);
    
    // 每个声道的指针
    std::vector<float*> channelPtrs(channels);
    for (int c = 0; c < channels; c++) {
        channelPtrs[c] = buffer.floatChannelData[c];
    }
    
    StreamConfig inputConfig(sampleRate,
                             channels);
    StreamConfig outputConfig(sampleRate,
                              channels);
    
    int ret = _apm->ProcessStream((const float* const*)channelPtrs.data(),
                                  inputConfig,
                                  outputConfig,
                                  channelPtrs
                                  .data());
    if (ret != 0) {
        NSLog(@"ProcessStream failed: %d",
              ret);
    }
}


- (void)processBuffer:(AVAudioPCMBuffer *)buffer {
    int channels = (int)buffer.format.channelCount;
    int sampleRate = (int)buffer.format.sampleRate;
    int frameCount = (int)buffer.frameLength;
    
    NSLog(@"ProcessStream channels: %d sampleRate: %d frameCount: %d",
          channels,
          sampleRate,
          frameCount);
    
    std::vector<float*> channelPtrs(channels);
    for (int c = 0; c < channels; c++) {
        channelPtrs[c] = buffer.floatChannelData[c];
    }
    
    webrtc::StreamConfig inputConfig(sampleRate,
                                     channels);
    webrtc::StreamConfig outputConfig(sampleRate,
                                      channels);
    
    int samplesPer10ms = sampleRate / 100;
    int totalFrames = frameCount;
    int offset = 0;
    
    // 1. 处理完整的 10ms 块
    while (offset + samplesPer10ms <= totalFrames) {
        NSLog(@"Processing full block: offset=%d, length=%d",
              offset,
              samplesPer10ms);
        std::vector<float*> blockPtrs(channels);
        for (int c = 0; c < channels; c++) {
            blockPtrs[c] = channelPtrs[c] + offset;
        }
        
        int ret = _apm->ProcessStream((const float* const*)blockPtrs.data(),
                                      inputConfig,
                                      outputConfig,
                                      blockPtrs
                                      .data());
        if (ret != 0) {
            NSLog(@"ProcessStream failed: %d",
                  ret);
        }
        
        offset += samplesPer10ms;
    }
    
    
    //     2. ⭐⭐⭐ 处理剩余的不足 10ms 的帧 ⭐⭐⭐
    //    if (offset < totalFrames) {
    //        int remainingFrames = totalFrames - offset;
    //        NSLog(@"Processing remaining block: offset=%d, length=%d", offset, remainingFrames);
    //        
    //        std::vector<float*> blockPtrs(channels);
    //        for (int c = 0; c < channels; c++) {
    //            blockPtrs[c] = channelPtrs[c] + offset;
    //        }
    //        
    //        int ret = _apm->ProcessStream((const float* const*)blockPtrs.data(),
    //                                     inputConfig,
    //                                     outputConfig,
    //                                     blockPtrs.data());
    //        if (ret != 0) {
    //            NSLog(@"ProcessStream (remaining) failed: %d", ret);
    //        }
    //        
    //        offset += remainingFrames; // 可选：标记处理完成
    //    }
}

- (void)processFloatBuffer:(float *)data
                sampleRate:(int)sampleRate
                frameCount:(int)frameCount
                  channels:(int)channels {
    
    if (!_apm) return;
    
    
    // ⚠️ 强校验（APM必须10ms）
    int expectedFrames = sampleRate / 100;
    if (frameCount != expectedFrames) {
        // 这里不应该发生（因为你前面已经对齐了）
        return;
    }
    
    
    if (_streamConfig.sample_rate_hz() != sampleRate ||
        _streamConfig
        .num_channels() != channels) {
            
            _streamConfig = webrtc::StreamConfig(sampleRate,
                                                 channels);
        }
    
    //    webrtc::StreamConfig config(sampleRate, channels); // float = true
    
    // ========= 1️⃣ 创建 deinterleaved buffer =========
    float *channelBuffers[channels];
    
    for (int ch = 0; ch < channels; ch++) {
        channelBuffers[ch] = (float *)malloc(sizeof(float) * frameCount);
    }
    
    // interleaved → deinterleaved
    for (int i = 0; i < frameCount; i++) {
        for (int ch = 0; ch < channels; ch++) {
            channelBuffers[ch][i] = data[i * channels + ch];
        }
    }
    
    // ========= 2️⃣ 调用 APM =========
    _apm->ProcessStream(
                        (const float *const *)channelBuffers,
                        _streamConfig,
                        _streamConfig,
                        channelBuffers
                        );
    
    // ========= 3️⃣ 写回 interleaved =========
    for (int i = 0; i < frameCount; i++) {
        for (int ch = 0; ch < channels; ch++) {
            data[i * channels + ch] = channelBuffers[ch][i];
        }
    }
    
    // ========= 4️⃣ 释放 =========
    for (int ch = 0; ch < channels; ch++) {
        free(channelBuffers[ch]);
    }
}


- (NSData *)processAudioFrameFloat:(NSData *)pcmData sampleRate:(int)sampleRate channels:(int)channels {
    if (!pcmData || pcmData.length == 0) return nil;
    if (sampleRate <= 0 || channels <= 0) return nil;
    
    const float *interleaved = (const float *)pcmData.bytes;
    int frameCount = (int)(pcmData.length / sizeof(float) / channels);
    
    // Step 1: 分配 deinterleaved buffers（src 和 dest）
    float **srcChannels = (float **)calloc(channels,
                                           sizeof(float*));
    float **destChannels = (float **)calloc(channels,
                                            sizeof(float*));
    
    // 为每个 channel 分配 buffer
    for (int c = 0; c < channels; c++) {
        srcChannels[c] = (float *)malloc(frameCount * sizeof(float));
        destChannels[c] = (float *)malloc(frameCount * sizeof(float));
    }
    
    // Step 2: Interleaved → Deinterleaved
    for (int c = 0; c < channels; c++) {
        for (int i = 0; i < frameCount; i++) {
            srcChannels[c][i] = interleaved[i * channels + c];
        }
    }
    
    // Step 3: WebRTC 处理（降噪、AGC、AEC 等）
    webrtc::StreamConfig config(sampleRate,
                                channels); // float = true
    
    int result = _apm->ProcessStream(
                                     const_cast<const float* const*>(srcChannels),
                                     // src
                                     config,
                                     // input config
                                     config,
                                     // output config
                                     destChannels                                   // dest
                                     );
    
    if (result != webrtc::AudioProcessing::kNoError) {
        NSLog(@"Audio processing failed: %d",
              result);

        // 清理
        for (int c = 0; c < channels; c++) {
            free(srcChannels[c]);
            free(destChannels[c]);
        }
        free(srcChannels);
        free(destChannels);

        return nil;
    }

    // Step 4: Deinterleaved → Interleaved（写回）
    NSMutableData *outputData = [[NSMutableData alloc] initWithLength:frameCount * channels * sizeof(float)];
    float *outInterleaved = (float *)outputData.mutableBytes;

    for (int i = 0; i < frameCount; i++) {
        for (int c = 0; c < channels; c++) {
            outInterleaved[i * channels + c] = destChannels[c][i];
        }
    }

    // Step 5: 清理
    for (int c = 0; c < channels; c++) {
        free(srcChannels[c]);
        free(destChannels[c]);
    }
    free(srcChannels);
    free(destChannels);

    return [outputData copy];
}




@end


