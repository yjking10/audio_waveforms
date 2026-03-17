#import "NoiseCancelPlayer.h"

@interface AudioRingBuffer : NSObject

@property (nonatomic, readonly) int capacity;     // frame capacity
@property (nonatomic, readonly) int channels;

- (instancetype)initWithCapacity:(int)capacity channels:(int)channels;

- (int)write:(float *)data frames:(int)frames;
- (int)read:(float *)outData frames:(int)frames;
- (int)availableFrames;

@end


@implementation AudioRingBuffer {
    float *_buffer;
    int _writeIndex;
    int _readIndex;
    int _size;
}

- (instancetype)initWithCapacity:(int)capacity channels:(int)channels {
    if (self = [super init]) {
        _capacity = capacity;
        _channels = channels;
        _buffer = (float *)malloc(sizeof(float) * capacity * channels);
        _writeIndex = 0;
        _readIndex = 0;
        _size = 0;
    }
    return self;
}

- (int)write:(float *)data frames:(int)frames {
    int writable = MIN(frames, _capacity - _size);
    for (int i = 0; i < writable; i++) {
        int idx = (_writeIndex + i) % _capacity;
        memcpy(&_buffer[idx * _channels],
               &data[i * _channels],
               sizeof(float) * _channels);
    }
    _writeIndex = (_writeIndex + writable) % _capacity;
    _size += writable;
    return writable;
}

- (int)read:(float *)outData frames:(int)frames {
    int readable = MIN(frames, _size);
    for (int i = 0; i < readable; i++) {
        int idx = (_readIndex + i) % _capacity;
        memcpy(&outData[i * _channels],
               &_buffer[idx * _channels],
               sizeof(float) * _channels);
    }
    _readIndex = (_readIndex + readable) % _capacity;
    _size -= readable;
    return readable;
}

- (int)availableFrames {
    return _size;
}

@end

@interface FrameAligner : NSObject

@property (nonatomic, assign) int frameSize; // 每帧多少 samples（自动算）
@property (nonatomic, assign) int channels;

- (instancetype)initWithSampleRate:(int)sampleRate channels:(int)channels;
- (void)push:(float *)data frames:(int)frames;
- (BOOL)hasFrame;
- (void)popFrame:(float *)outFrame;

@end


@implementation FrameAligner {
    AudioRingBuffer *_buffer;
}

- (instancetype)initWithSampleRate:(int)sampleRate channels:(int)channels {
    if (self = [super init]) {
        _channels = channels;
        _frameSize = sampleRate / 100; // 10ms
        _buffer = [[AudioRingBuffer alloc] initWithCapacity:sampleRate channels:channels];
    }
    return self;
}

- (void)push:(float *)data frames:(int)frames {
    [_buffer write:data frames:frames];
}

- (BOOL)hasFrame {
    return _buffer.availableFrames >= _frameSize;
}

- (void)popFrame:(float *)outFrame {
    [_buffer read:outFrame frames:_frameSize];
}

@end


@interface NoiseCancelPlayer ()
@property(nonatomic, strong) AVAudioEngine *engine;
@property(nonatomic, strong) AVAudioSourceNode *sourceNode;
@property(nonatomic, strong) AVAudioUnitTimePitch *timePitchNode; // 时间音调效果节点

@property(nonatomic, strong) AVAudioFile *audioFile;
@property(nonatomic, strong) AVAudioFormat *targetFormat;

// 进度跟踪相关
@property(nonatomic, strong) CADisplayLink *progressDisplayLink;
@property(nonatomic, assign) NSTimeInterval startTime;
@property(nonatomic, assign) NSTimeInterval pausedTime;
@property(nonatomic, assign) NoiseCancelPlayerState currentState;

@property(nonatomic, assign) AVAudioFramePosition currentFrame;
@property(nonatomic, assign) AVAudioFramePosition currentPosition;

@property(nonatomic, strong) NSMutableData *accumulator;
@property(nonatomic, assign) int accumulatedFrames;
@property(nonatomic, assign) BOOL enableNoiseCancellation;

@end

@implementation NoiseCancelPlayer {

    AudioProcessingWrapper *_apWrapper;
    
    FrameAligner *_aligner;
    AudioRingBuffer *_outputBuffer;
    int _sampleRate;
    int _channels;
    int _frameSize;
}


- (instancetype)init {
    if (self = [super init]) {

        AVAudioSession *audioSession = [AVAudioSession sharedInstance];
        NSError *sessionError = nil;

        // 1. 配置 category（支持蓝牙播放+录音，默认外放兜底）
        BOOL success = [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord
                                     withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker |
                                                 AVAudioSessionCategoryOptionAllowBluetoothHFP |
                                                 AVAudioSessionCategoryOptionAllowBluetoothA2DP
                                           error:&sessionError];

        if (!success || sessionError) {
            NSLog(@"配置音频会话失败：%@", sessionError.localizedDescription);

        }

        // 2. 激活音频会话
        success = [audioSession setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&sessionError];
        if (!success || sessionError) {
            NSLog(@"激活音频会话失败：%@", sessionError.localizedDescription);

        }

        // 3. （可选）优先切换到蓝牙设备
        NSArray *availableInputs = audioSession.availableInputs;
        for (AVAudioSessionPortDescription *input in availableInputs) {
            if ([input.portType isEqualToString:AVAudioSessionPortBluetoothHFP] ||
                [input.portType isEqualToString:AVAudioSessionPortBluetoothA2DP]) {
                [audioSession setPreferredInput:input error:nil];
                NSLog(@"已切换到蓝牙设备：%@", input.portName);
                break;
            }
        }

        // ⭐⭐⭐ 关键：设置首选 I/O 缓冲区时长 ⭐⭐⭐
        // 例如，请求 10ms 的缓冲区
        NSTimeInterval preferredBufferDuration = 0.010; // 10 milliseconds
        [audioSession setPreferredIOBufferDuration:preferredBufferDuration error:&sessionError];

        if (sessionError) {
            NSLog(@"Failed to set preferred IO buffer duration: %@", sessionError);
        }

        _rate = 1.0;
        _enableNoiseCancellation = YES;
        _currentState = NoiseCancelPlayerStateStopped;
        _startTime = 0;
        _pausedTime = 0;

        // 激活会话
        [audioSession setActive:YES error:&sessionError];
        _apWrapper = [[AudioProcessingWrapper alloc] init];
        ///默认设置为降噪最高
        [_apWrapper setNoiseSuppressionLevel:NoiseSuppressionLevelVeryHigh];
        _engine = [[AVAudioEngine alloc] init];
        _accumulator = [[NSMutableData alloc] init];

    }
    return self;
}


- (void)setFileURL:(NSURL *)audioFileURL {
    [self resetEngineIfNeeded];

    NSError *error;
    _audioFile = [[AVAudioFile alloc] initForReading:audioFileURL error:&error];
    if (error) {
        NSLog(@"open file error: %@", error);
        return;
    }

    AVAudioFormat *processingFormat = self.audioFile.processingFormat;
    _sampleRate = (int) processingFormat.sampleRate;
//    int channels = (int) processingFormat.channelCount;
    
    
    _channels = (int)processingFormat.channelCount;

    _aligner = [[FrameAligner alloc] initWithSampleRate:_sampleRate
                                               channels:_channels];

    _outputBuffer = [[AudioRingBuffer alloc] initWithCapacity:_sampleRate * 2
                                                     channels:_channels];

    _frameSize = _sampleRate / 100;

    _targetFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:_sampleRate channels:_channels];
    NSLog(@"通道数  %d", _channels);
    __weak typeof(self) weakSelf = self;
    
    _sourceNode = [[AVAudioSourceNode alloc]
     initWithFormat:processingFormat
     renderBlock:^OSStatus(BOOL *isSilence,
                           const AudioTimeStamp *timestamp,
                           AVAudioFrameCount frameCount,
                           AudioBufferList *outputData) {

        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return noErr;

        int channels = self->_channels;

        // ========= 1. 读取音频 =========
        AVAudioPCMBuffer *tempBuffer =
        [[AVAudioPCMBuffer alloc] initWithPCMFormat:processingFormat
                                      frameCapacity:frameCount];

        self.audioFile.framePosition = self.currentFrame;

        NSError *error = nil;
        [self.audioFile readIntoBuffer:tempBuffer
                           frameCount:frameCount
                                error:&error];

        if (error) return noErr;

        self.currentFrame += tempBuffer.frameLength;

        // ========= 2. 转 interleaved =========
        int frames = (int)tempBuffer.frameLength;
        float interleaved[frames * channels];

        for (int ch = 0; ch < channels; ch++) {
            float *src = tempBuffer.floatChannelData[ch];
            for (int i = 0; i < frames; i++) {
                interleaved[i * channels + ch] = src[i];
            }
        }

        // ========= 3. push 到 aligner =========
        [self->_aligner push:interleaved frames:frames];

        // ========= 4. 固定帧处理 =========
        while ([self->_aligner hasFrame]) {

            float frame[self->_frameSize * channels];
            [self->_aligner popFrame:frame];

            if (self.enableNoiseCancellation) {
                [self->_apWrapper processFloatBuffer:frame sampleRate:self->_sampleRate  frameCount:self->_frameSize channels:channels];
            }

            [self->_outputBuffer write:frame frames:self->_frameSize];
        }

        // ========= 5. 输出 =========
        int needed = (int)frameCount;
        float out[needed * channels];

        int got = [self->_outputBuffer read:out frames:needed];

        // 不够补0
        if (got < needed) {
            memset(out + got * channels, 0,
                   (needed - got) * channels * sizeof(float));
        }

        // ========= 6. 写回非 interleaved =========
        for (int ch = 0; ch < channels; ch++) {
            float *dst = (float *)outputData->mBuffers[ch].mData;
            for (int i = 0; i < needed; i++) {
                dst[i] = out[i * channels + ch];
            }
        }

        return noErr;
    }];

//    _sourceNode =
//            [[AVAudioSourceNode alloc] initWithFormat:processingFormat
//                                          renderBlock:^OSStatus(BOOL *isSilence,
//                                                                const AudioTimeStamp *timestamp,
//                                                                AVAudioFrameCount frameCount,
//                                                                AudioBufferList *outputData) {
//                                              __strong typeof(weakSelf) strongSelf = weakSelf;
//                                              if (!strongSelf) return noErr;
//                
//                NSLog(@"renderBlock frameCount=%d", frameCount);
//                                              AVAudioFramePosition framePos = strongSelf.currentFrame;
//                                              AVAudioFrameCount framesAvailable =
//                                                      (AVAudioFrameCount)(
//                                                              strongSelf.audioFile.length -
//                                                              framePos);
//
//                                              AVAudioFrameCount framesToRead = MIN(frameCount,
//                                                                                   framesAvailable);
//
//                                              if (framesToRead > 0) {
//                                                  NSError *readError = nil;
//                                                  AVAudioPCMBuffer *tempBuffer =
//                                                          [[AVAudioPCMBuffer alloc] initWithPCMFormat:processingFormat
//                                                                                        frameCapacity:framesToRead];
//
//                                                  // 设置读取起始位置
//                                                  strongSelf.audioFile.framePosition = framePos;
//
//                                                  [strongSelf.audioFile readIntoBuffer:tempBuffer
//                                                                            frameCount:framesToRead
//                                                                                 error:&readError];
//                                                  if (readError) {
//                                                      NSLog(@"read error: %@", readError);
//                                                      return noErr;
//                                                  }
//
//                                                  /// apm降噪处理 - 只在正常播放速率时启用
//                                                  if (strongSelf.enableNoiseCancellation) {
//                                                      [strongSelf->_apWrapper processBuffer:tempBuffer];
//                                                  }
//
//                                                  // 拷贝数据到 outputData
//                                                  for (UInt32 ch = 0;
//                                                       ch < outputData->mNumberBuffers; ch++) {
//                                                      float *outD = (float *) outputData->mBuffers[ch].mData;
//                                                      float *inD = tempBuffer.floatChannelData[ch];
//                                                      memcpy(outD, inD,
//                                                             framesToRead * sizeof(float));
//                                                  }
//                                              }
//
//                                              // 不够的地方填 0（防止播放垃圾数据）
//                                              if (framesToRead < frameCount) {
//                                                  for (UInt32 ch = 0;
//                                                       ch < outputData->mNumberBuffers; ch++) {
//                                                      float *out = (float *) outputData->mBuffers[ch].mData;
//                                                      memset(out + framesToRead, 0,
//                                                             (frameCount - framesToRead) *
//                                                             sizeof(float));
//                                                  }
//                                              }
//
//                                              strongSelf.currentFrame += framesToRead;
//                                              return noErr;
//                                          }];

    [_engine attachNode:_sourceNode];

    // 如果有时间音调节点，先连接到它，否则直接连接到主混音器
    if (_timePitchNode) {
        [_engine connect:_sourceNode to:_timePitchNode format:_targetFormat];
        [_engine connect:_timePitchNode to:_engine.mainMixerNode format:_targetFormat];
    } else {
        [_engine connect:_sourceNode to:_engine.mainMixerNode format:_targetFormat];
    }

    [self updateState:NoiseCancelPlayerStateReady];
}

- (void)play {
    if (self.currentState == NoiseCancelPlayerStatePlaying) return;

    NSError *error = nil;
    [_engine prepare];
    [_engine startAndReturnError:&error];
    if (error) {
        NSLog(@"Engine start error: %@", error);
        return;
    }

    // currentTime 现在基于 currentFrame 计算，不需要维护 _startTime
    // 但保留 _startTime 用于其他可能的用途
    _startTime = CACurrentMediaTime();
    

    [self updateState:NoiseCancelPlayerStatePlaying];
    [self startProgressTimer];
}

- (void)pause {
    if (self.currentState != NoiseCancelPlayerStatePlaying) return;

    [_engine pause];
    // currentFrame 已经保存了当前位置，currentTime 会基于它计算
 
    [self updateState:NoiseCancelPlayerStatePaused];
    [self stopProgressTimer];
}

- (void)stop {
    [_engine stop];
    self.currentFrame = 0;
    _startTime = 0;
    _pausedTime = 0;

    [self updateState:NoiseCancelPlayerStateStopped];
    [self stopProgressTimer];

  
}
- (void)resetEngineIfNeeded {
    if (_engine.isRunning) {
        [_engine stop];
    }

    if (_sourceNode) {
        [_engine disconnectNodeOutput:_sourceNode];
        [_engine detachNode:_sourceNode];
        _sourceNode = nil;
    }

    if (_timePitchNode) {
        [_engine disconnectNodeOutput:_timePitchNode];
        [_engine detachNode:_timePitchNode];
        _timePitchNode = nil;
    }

    _currentFrame = 0;
}



#pragma mark - 拖拽播放

- (void)seekToTime:(NSTimeInterval)timeInSeconds {
    if (!_audioFile) return;
    NSLog(@"timeInSeconds---- %f    %f", timeInSeconds, self.duration);
    // 限制时间范围（timeInSeconds 是秒，duration 也是秒）
    timeInSeconds = MAX(0, MIN(timeInSeconds, self.duration));

    AVAudioFormat *format = _audioFile.processingFormat;
    double sampleRate = format.sampleRate;
    AVAudioFramePosition newFrame = (AVAudioFramePosition)(sampleRate * timeInSeconds);
    
    // 确保不超出文件范围
    newFrame = MAX(0, MIN(newFrame, _audioFile.length));

    // 设置新的帧位置 - 无论什么状态都要设置
    self.currentFrame = newFrame;
    
    // 更新音频文件的 framePosition，确保下次读取时从正确位置开始
    _audioFile.framePosition = newFrame;

    // 如果正在播放，需要重启音频引擎以确保跳转生效
    if (self.currentState == NoiseCancelPlayerStatePlaying) {

        [_engine stop];
        [self stopProgressTimer];

        // 短暂延迟后重新开始播放
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                    NSError *error = nil;
                    [self->_engine prepare];
                    if ([self->_engine startAndReturnError:&error]) {
                        // currentTime 现在基于 currentFrame 计算，不需要设置 _startTime
                        self->_startTime = CACurrentMediaTime();
                        [self startProgressTimer];
                        [self updateState:NoiseCancelPlayerStatePlaying];
                    } else {
                        NSLog(@"Failed to restart engine after seek: %@", error);
                        [self updateState:NoiseCancelPlayerStateStopped];
                    }
                });
    }
    // 在非播放状态下，currentFrame 已经保存了位置，currentTime 会基于它计算
    // 下次播放时会从 currentFrame 指定的位置开始
}

#pragma mark - Progress Tracking

- (void)startProgressTimer {
    [self stopProgressTimer];
    self.progressDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(updateProgress)];
    self.progressDisplayLink.preferredFramesPerSecond = 30;
    [self.progressDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopProgressTimer {
    if (self.progressDisplayLink) {
        [self.progressDisplayLink invalidate];
        self.progressDisplayLink = nil;
    }
}

- (void)updateProgress {
    if (self.currentState != NoiseCancelPlayerStatePlaying) return;

    NSTimeInterval currentTime = self.currentTime;
    NSTimeInterval duration = self.duration;

    if (self.delegate &&
        [self.delegate respondsToSelector:@selector(audioPlayer:didUpdateProgress:duration:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate audioPlayer:self didUpdateProgress:currentTime duration:duration];
        });
    }

    // 检查是否播放完成
    if (currentTime >= duration - 0.1) { // 0.1秒容差
        [self stop];
        if (self.delegate &&
            [self.delegate respondsToSelector:@selector(audioPlayerDidFinishPlaying:)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate audioPlayerDidFinishPlaying:self];
            });
        }
    }
}

#pragma mark - State Management

- (void)updateState:(NoiseCancelPlayerState)newState {
    if (self.currentState == newState) return;

    self.currentState = newState;

    if (self.delegate &&
        [self.delegate respondsToSelector:@selector(audioPlayer:didChangeState:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate audioPlayer:self didChangeState:newState];
        });
    }
}

#pragma mark - Properties

- (NSTimeInterval)duration {
    if (!_audioFile) return 0.0;
    return (NSTimeInterval) _audioFile.length / _audioFile.processingFormat.sampleRate ;
}

- (NSTimeInterval)currentTime {
    if (!_audioFile) return 0.0;
    
    // 基于帧位置计算当前时间，这样更准确，特别是在变速播放时
    AVAudioFormat *format = _audioFile.processingFormat;
    double sampleRate = format.sampleRate;
    if (sampleRate > 0) {
        return (NSTimeInterval)self.currentFrame / sampleRate;
    }
    return 0.0;
}

- (NoiseCancelPlayerState)state {
    return _currentState;
}


- (void)setPlaybackRate:(float)rate {
    // 验证速率范围 (0.5 - 2.0 是 AVAudioUnitTimePitch 的有效范围)
    rate = MAX(0.5f, MIN(2.0f, rate));
    NSLog(@"设置播放速率为: %f", rate);

    // 如果速率改变且不是1.0，暂时禁用降噪（因为APM可能不兼容变速）
    if (_rate != rate && rate != 1.0) {
        _enableNoiseCancellation = NO;
    } else if (rate == 1.0) {
        _enableNoiseCancellation = YES; // 恢复降噪
    }

    // 如果速率没有变化，不需要重新配置
    if (_rate == rate) return;

    // 保存当前播放位置（以秒为单位）
    NSTimeInterval currentPlaybackTime = self.currentTime;

    _rate = rate;

    // 获取当前是否正在播放
    BOOL wasPlaying = (self.currentState == NoiseCancelPlayerStatePlaying);

    if (wasPlaying) {
        // 如果正在播放，先暂停
        [_engine pause];
        [self stopProgressTimer];
    }

    // 断开现有连接
    if (_timePitchNode) {
        [_engine disconnectNodeOutput:_sourceNode];
        [_engine disconnectNodeOutput:_timePitchNode];
        [_engine detachNode:_timePitchNode];
        _timePitchNode = nil;
    } else {
        // 如果之前没有 timePitchNode，也需要断开 sourceNode 的连接
        [_engine disconnectNodeOutput:_sourceNode];
    }

    // 更新 currentFrame 以反映正确的播放位置
    if (_audioFile) {
        AVAudioFormat *format = _audioFile.processingFormat;
        double sampleRate = format.sampleRate;
        self.currentFrame = (AVAudioFramePosition)(currentPlaybackTime * sampleRate);
        // 确保不超出文件范围
        self.currentFrame = MAX(0, MIN(self.currentFrame, _audioFile.length));
    }

    // 如果速率不是1.0，需要创建时间音调节点
    if (rate != 1.0f) {
        _timePitchNode = [[AVAudioUnitTimePitch alloc] init];
        _timePitchNode.rate = rate;

        // 连接节点链路：sourceNode -> timePitchNode -> mainMixerNode
        [_engine attachNode:_timePitchNode];
        [_engine connect:_sourceNode to:_timePitchNode format:_targetFormat];
        [_engine connect:_timePitchNode to:_engine.mainMixerNode format:_targetFormat];
    } else {
        // 速率是1.0，直接连接 sourceNode -> mainMixerNode
        [_engine connect:_sourceNode to:_engine.mainMixerNode format:_targetFormat];
    }

    // 如果之前在播放，恢复播放
    if (wasPlaying) {
        NSError *error = nil;
        [_engine prepare];
        if ([_engine startAndReturnError:&error]) {
            // currentTime 现在基于 currentFrame 计算，不需要基于时间戳
            _startTime = CACurrentMediaTime();
            [self startProgressTimer];
        } else {
            NSLog(@"Failed to restart engine after rate change: %@", error);
        }
    }
}


- (void)setNoiseSuppressionLevel:(SuppressionLevel)newValue {

    if (newValue != _noiseSuppressionLevel) {
        _noiseSuppressionLevel = newValue;
        if(newValue == SuppressionLevelVeryHigh) {
            [_apWrapper setNoiseSuppressionLevel:NoiseSuppressionLevelVeryHigh];
        } else if(newValue == SuppressionLevelHigh) {
            [_apWrapper setNoiseSuppressionLevel:NoiseSuppressionLevelHigh];
        }else if(newValue == SuppressionLevelModerate) {
            [_apWrapper setNoiseSuppressionLevel:NoiseSuppressionLevelModerate];
        } else {
            [_apWrapper setNoiseSuppressionLevel:NoiseSuppressionLevelLow];

        }

    }
}


@end
