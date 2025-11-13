import 'player_identifier.dart';

//ignore_for_file: constant_identifier_names
extension DurationExtension on Duration {
  /// Converts duration to HH:MM:SS format
  String toHHMMSS() => toString().split('.').first.padLeft(8, "0");
}

extension IntExtension on int {
  /// Converts total seconds to MM:SS format
  String toMMSS() =>
      '${(this ~/ 60).toString().padLeft(2, '0')}:${(this % 60).toString().padLeft(2, '0')}';
}

/// State of recorder
enum RecorderState {
  initialized,
  recording,
  paused,
  stopped;

  bool get isRecording => this == RecorderState.recording;

  bool get isInitialized => this == RecorderState.initialized;

  bool get isPaused => this == RecorderState.paused;

  bool get isStopped => this == RecorderState.stopped;
}

/// Android encoders.
///
/// Android and IOS are have been separated to better support
/// platform wise encoder and output formats.
///
/// Check [MediaRecorder.AudioEncoder](https://developer.android.com/reference/android/media/MediaRecorder.AudioEncoder)
/// for more info.
enum AndroidEncoder {
  wav('WAV'),
  aacLc('AAC_LC'),
  aacHe('AAC_HE'),
  aacEld('AAC_ELD'),
  amrNb('AMR_NB'),
  amrWb('AMR_WB'),
  opus('OPUS');

  const AndroidEncoder(this.nativeFormat);

  final String nativeFormat;
}

/// IOS encoders.
///
/// Android and IOS are have been separated to better support
/// platform wise encoder and output formats.
///
/// Check [Audio Format Identifiers](https://developer.apple.com/documentation/coreaudiotypes/1572096-audio_format_identifiers)
/// for more info.
enum IosEncoder {
  /// Default
  kAudioFormatMPEG4AAC,
  kAudioFormatMPEGLayer1,
  kAudioFormatMPEGLayer2,
  kAudioFormatMPEGLayer3,
  kAudioFormatMPEG4AAC_ELD,
  kAudioFormatMPEG4AAC_HE,
  kAudioFormatOpus,
  kAudioFormatAMR,
  kAudioFormatAMR_WB,
  kAudioFormatLinearPCM,
  kAudioFormatAppleLossless,
  kAudioFormatMPEG4AAC_HE_V2
}

/// States of audio player
enum PlayerState {
  /// When player is [initialised]
  initialized,

  /// When player is playing the audio file
  playing,

  /// When player is paused.
  paused,

  /// when player is stopped. Default state of any player ([uninitialised]).
  stopped;

  bool get isPlaying => this == PlayerState.playing;

  bool get isStopped => this == PlayerState.stopped;

  bool get isInitialised => this == PlayerState.initialized;

  bool get isPaused => this == PlayerState.paused;
}

/// There are two type duration which we can get while playing an audio.
///
/// 1. max -: Max duration is [full] duration of audio file
///
/// 2. current -: Current duration is how much audio has been played
enum DurationType {
  current,

  /// Default
  max
}

/// This extension filter playerKey from the stream and provides
/// only necessary generic type.
extension FilterForPlayer<T> on Stream<PlayerIdentifier<T>> {
  Stream<T> filter(String playerKey) {
    return where((identifier) => identifier.playerKey == playerKey)
        .map((identifier) => identifier.type);
  }
}

/// An enum to be used to change behaviour of player when audio
/// is finished playing.
enum FinishMode {
  ///Keeps the buffered data and plays again after completion, creating a loop.
  loop,

  ///Stop audio playback but keep all resources intact.
  ///Use this if you intend to play again later.
  pause,

  ///Stops player and disposes it(a PlayerController won't be disposed).
  stop,
}

/// An enum to decide which type of waveform to show.
enum WaveformType {
  /// Fits Waveform in provided width. Audio can be seeked with
  /// tap and drag gesture.
  ///
  /// **Important**-: Make sure to provide number of sample according to
  /// the width using `getSamplesForWidth` function from PlayerWaveStyle
  /// otherwise full waveform may get cut off.
  fitWidth,

  /// This waveform starts from middle. When audio progresses waveform is
  /// pushed back and a middle line shows current progress.
  ///
  /// This waveform only allows seek with drag.
  long;

  /// Check WaveformType is equals to fitWidth or not.
  bool get isFitWidth => this == WaveformType.fitWidth;

  /// Check WaveformType is equals to long or not.
  bool get isLong => this == WaveformType.long;
}

/// Rate of updating the reported current duration.
enum UpdateFrequency {
  /// Reports duration at every 50 milliseconds.
  high(50),

  /// Reports duration at every 100 milliseconds.
  medium(100),

  /// Reports duration at every 200 milliseconds.
  low(200);

  const UpdateFrequency(this.value);

  final int value;
}

/// Resizes waveform data to a fixed target size.
/// 
/// If the input data is smaller than target size, interpolates using average values.
/// If the input data is larger than target size, downsamples by removing middle values.
/// 
/// [data] - Original waveform data
/// [targetSize] - Target number of samples
/// 
/// Returns resized waveform data with exactly [targetSize] elements.
List<double> resizeWaveformData(List<double> data, int targetSize) {
  if (data.isEmpty) {
    return List.filled(targetSize, 0.0);
  }
  
  if (targetSize <= 0) {
    return [];
  }
  
  final int sourceSize = data.length;
  
  // If sizes match, return original data
  if (sourceSize == targetSize) {
    return List.from(data);
  }
  
  // If source is smaller, interpolate
  if (sourceSize < targetSize) {
    return _interpolateWaveformData(data, targetSize);
  }
  
  // If source is larger, downsample
  return _downsampleWaveformData(data, targetSize);
}

/// Interpolates waveform data by inserting average values between existing points.
List<double> _interpolateWaveformData(List<double> data, int targetSize) {
  final result = <double>[];
  final int sourceSize = data.length;
  final double ratio = (sourceSize - 1) / (targetSize - 1);
  
  for (int i = 0; i < targetSize; i++) {
    final double sourceIndex = i * ratio;
    final int lowerIndex = sourceIndex.floor();
    final int upperIndex = (lowerIndex + 1).clamp(0, sourceSize - 1);
    final double fraction = sourceIndex - lowerIndex;
    
    if (lowerIndex == upperIndex || fraction == 0) {
      result.add(data[lowerIndex]);
    } else {
      // Linear interpolation
      final double interpolated = data[lowerIndex] * (1 - fraction) + 
                                  data[upperIndex] * fraction;
      result.add(interpolated);
    }
  }
  
  return result;
}

/// Downsamples waveform data by uniformly removing middle values.
/// Preserves first and last values, then evenly distributes remaining samples.
List<double> _downsampleWaveformData(List<double> data, int targetSize) {
  if (targetSize <= 0) {
    return [];
  }
  
  if (targetSize == 1) {
    // Return average of all values
    final double average = data.reduce((a, b) => a + b) / data.length;
    return [average];
  }
  
  final result = <double>[];
  final int sourceSize = data.length;
  
  // Always include first value
  result.add(data[0]);
  
  if (targetSize == 2) {
    // Only first and last
    result.add(data[sourceSize - 1]);
    return result;
  }
  
  // Calculate step size for uniform sampling
  final double step = (sourceSize - 1) / (targetSize - 1);
  
  // Sample uniformly, excluding first and last (already added)
  for (int i = 1; i < targetSize - 1; i++) {
    final int index = (i * step).round().clamp(0, sourceSize - 1);
    result.add(data[index]);
  }
  
  // Always include last value
  result.add(data[sourceSize - 1]);
  
  return result;
}
