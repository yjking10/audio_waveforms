#import "NoiseCancelPlayer.h"

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

//因为 WebRTC APM 要求 10ms 块，你可以在 processBuffer 中维护一个环形缓冲区，累积数据直到凑够 160 帧再调用 ProcessStream
@property(nonatomic, strong) NSMutableData *accumulator;
@property(nonatomic, assign) int accumulatedFrames;
@property(nonatomic, assign) BOOL enableNoiseCancellation;

@end

@implementation NoiseCancelPlayer {

    AudioProcessingWrapper *_apWrapper;
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
    NSError *error;
    _audioFile = [[AVAudioFile alloc] initForReading:audioFileURL error:&error];
    if (error) {
        NSLog(@"open file error: %@", error);
        return;
    }

    AVAudioFormat *processingFormat = self.audioFile.processingFormat;
    int sampleRate = (int) processingFormat.sampleRate;
    int channels = (int) processingFormat.channelCount;

    _targetFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate channels:channels];
    NSLog(@"通道数  %d", channels);
    __weak typeof(self) weakSelf = self;

    _sourceNode =
            [[AVAudioSourceNode alloc] initWithFormat:processingFormat
                                          renderBlock:^OSStatus(BOOL *isSilence,
                                                                const AudioTimeStamp *timestamp,
                                                                AVAudioFrameCount frameCount,
                                                                AudioBufferList *outputData) {
                                              __strong typeof(weakSelf) strongSelf = weakSelf;
                                              if (!strongSelf) return noErr;

                                              AVAudioFramePosition framePos = strongSelf.currentFrame;
                                              AVAudioFrameCount framesAvailable =
                                                      (AVAudioFrameCount)(
                                                              strongSelf.audioFile.length -
                                                              framePos);

                                              AVAudioFrameCount framesToRead = MIN(frameCount,
                                                                                   framesAvailable);

                                              if (framesToRead > 0) {
                                                  NSError *readError = nil;
                                                  AVAudioPCMBuffer *tempBuffer =
                                                          [[AVAudioPCMBuffer alloc] initWithPCMFormat:processingFormat
                                                                                        frameCapacity:framesToRead];

                                                  // 设置读取起始位置
                                                  strongSelf.audioFile.framePosition = framePos;

                                                  [strongSelf.audioFile readIntoBuffer:tempBuffer
                                                                            frameCount:framesToRead
                                                                                 error:&readError];
                                                  if (readError) {
                                                      NSLog(@"read error: %@", readError);
                                                      return noErr;
                                                  }

                                                  /// apm降噪处理 - 只在正常播放速率时启用
                                                  if (strongSelf.enableNoiseCancellation) {
                                                      [strongSelf->_apWrapper processBuffer:tempBuffer];
                                                  }

                                                  // 拷贝数据到 outputData
                                                  for (UInt32 ch = 0;
                                                       ch < outputData->mNumberBuffers; ch++) {
                                                      float *outD = (float *) outputData->mBuffers[ch].mData;
                                                      float *inD = tempBuffer.floatChannelData[ch];
                                                      memcpy(outD, inD,
                                                             framesToRead * sizeof(float));
                                                  }
                                              }

                                              // 不够的地方填 0（防止播放垃圾数据）
                                              if (framesToRead < frameCount) {
                                                  for (UInt32 ch = 0;
                                                       ch < outputData->mNumberBuffers; ch++) {
                                                      float *out = (float *) outputData->mBuffers[ch].mData;
                                                      memset(out + framesToRead, 0,
                                                             (frameCount - framesToRead) *
                                                             sizeof(float));
                                                  }
                                              }

                                              strongSelf.currentFrame += framesToRead;
                                              return noErr;
                                          }];

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

    // 记录开始播放的时间
    if (self.currentState == NoiseCancelPlayerStatePaused) {
        _startTime = CACurrentMediaTime() - _pausedTime;
    } else {
        _startTime = CACurrentMediaTime();
    }

    [self startProgressTimer];
    [self updateState:NoiseCancelPlayerStatePlaying];
}

- (void)pause {
    if (self.currentState != NoiseCancelPlayerStatePlaying) return;

    [_engine pause];
    _pausedTime = CACurrentMediaTime() - _startTime;
    [self stopProgressTimer];
    [self updateState:NoiseCancelPlayerStatePaused];
}

- (void)stop {
    [_engine stop];
    [self stopProgressTimer];

    self.currentFrame = 0;
    _startTime = 0;
    _pausedTime = 0;

    [self updateState:NoiseCancelPlayerStateStopped];
}


#pragma mark - 拖拽播放

- (void)seekToTime:(NSTimeInterval)timeInSeconds {
    if (!_audioFile) return;
    NSLog(@"timeInSeconds---- %f    %f", timeInSeconds, self.duration);
    // 限制时间范围
    timeInSeconds = MAX(0, MIN(timeInSeconds, self.duration));

    AVAudioFormat *format = _audioFile.processingFormat;
    double sampleRate = format.sampleRate;
    AVAudioFramePosition newFrame = (AVAudioFramePosition)(sampleRate * timeInSeconds);

    // 设置新的帧位置
    self.currentFrame = newFrame;

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
                        self->_startTime = CACurrentMediaTime() - timeInSeconds;
                        [self startProgressTimer];
                        [self updateState:NoiseCancelPlayerStatePlaying];
                    } else {
                        NSLog(@"Failed to restart engine after seek: %@", error);
                        [self updateState:NoiseCancelPlayerStateStopped];
                    }
                });
    } else {
        _pausedTime = timeInSeconds;
    }
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
    return (NSTimeInterval) _audioFile.length / _audioFile.processingFormat.sampleRate;
}

- (NSTimeInterval)currentTime {
    if (self.currentState == NoiseCancelPlayerStatePlaying) {
        return CACurrentMediaTime() - _startTime;
    } else {
        return _pausedTime;
    }
}

- (NoiseCancelPlayerState)state {
    return _currentState;
}


- (void)setPlaybackRate:(float)rate {
    // 验证速率范围 (0.5 - 2.0 是 AVAudioUnitTimePitch 的有效范围)
    rate = MAX(0.5f, MIN(2.0f, rate));

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
            // 重新开始时间戳跟踪
            _startTime = CACurrentMediaTime() - currentPlaybackTime;
            [self startProgressTimer];
        } else {
            NSLog(@"Failed to restart engine after rate change: %@", error);
        }
    }
}


- (void)setNoiseSuppressionLevel:(NoiseSuppressionLevel)newValue {

    if (newValue != _noiseSuppressionLevel) {
        _noiseSuppressionLevel = newValue;
        [_apWrapper setNoiseSuppressionLevel:newValue];
    }
}


@end
