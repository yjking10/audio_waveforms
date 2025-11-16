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
    print("sourceSize   little   $sourceSize");
    return _interpolateWaveformData(data, targetSize);
  }
  print("sourceSize     $sourceSize");
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
      final double interpolated =
          data[lowerIndex] * (1 - fraction) + data[upperIndex] * fraction;
      result.add(interpolated);
    }
  }

  return result;
}

/// Downsamples waveform data using RMS (Root Mean Square) and maximum value combination.
/// This method enhances waveform visibility by preserving both energy and peaks.
List<double> _downsampleWaveformData(List<double> data, int targetSize) {
  if (targetSize <= 0) {
    return [];
  }

  if (targetSize == 1) {
    // Use RMS value for better energy representation
    final double sumSquares =
        data.fold(0.0, (sum, value) => sum + value * value);
    final double meanSquare = sumSquares / data.length;
    final double rms = meanSquare > 0 ? meanSquare : 0.0;
    return [rms];
  }

  final result = <double>[];
  final int sourceSize = data.length;

  if (targetSize == 2) {
    // Use enhanced method for first half and second half
    final int mid = sourceSize ~/ 2;
    final double max1 = data.sublist(0, mid).reduce((a, b) => a > b ? a : b);
    final double sumSquares1 =
        data.sublist(0, mid).fold(0.0, (sum, value) => sum + value * value);
    final double meanSquare1 = sumSquares1 / mid;
    final double rms1 = meanSquare1 > 0 ? meanSquare1 : 0.0;
    final double combined1 = rms1 * 0.5 + max1 * 0.5;

    final double max2 = data.sublist(mid).reduce((a, b) => a > b ? a : b);
    final double sumSquares2 =
        data.sublist(mid).fold(0.0, (sum, value) => sum + value * value);
    final double meanSquare2 = sumSquares2 / (sourceSize - mid);
    final double rms2 = meanSquare2 > 0 ? meanSquare2 : 0.0;
    final double combined2 = rms2 * 0.5 + max2 * 0.5;

    result.add(combined1);
    result.add(combined2);
    return result;
  }

  // Calculate window size for each target sample
  final double windowSize = sourceSize / targetSize;

  // Sample by combining RMS and maximum value in each window
  for (int i = 0; i < targetSize; i++) {
    final int startIndex = (i * windowSize).floor();
    final int endIndex = ((i + 1) * windowSize).floor().clamp(0, sourceSize);

    if (startIndex >= sourceSize) {
      break;
    }

    final int windowLength = endIndex - startIndex;
    if (windowLength == 0) {
      result.add(0.0);
      continue;
    }

    // Calculate RMS (Root Mean Square) for energy representation
    double sumSquares = 0.0;
    double maxValue = data[startIndex];

    for (int j = startIndex; j < endIndex; j++) {
      final double value = data[j];
      sumSquares += value * value;
      if (value > maxValue) {
        maxValue = value;
      }
    }

    final double meanSquare = sumSquares / windowLength;
    final double rms = meanSquare > 0 ? meanSquare : 0.0;

    // Use more aggressive enhancement: prioritize maximum value heavily
    // Combine RMS and maximum: use weighted average (30% RMS + 70% max)
    // This better highlights peaks and makes waveform more visible
    double combined = rms * 0.3 + maxValue * 0.7;

    // Additional aggressive enhancement: apply power curve to boost values
    // This makes the waveform significantly more visible
    if (combined > 0) {
      // Use square root to enhance smaller values, making them more visible
      final double sqrtEnhanced = combined * 0.5 + (combined * combined) * 0.5;
      // Further boost by applying a power curve
      combined = sqrtEnhanced * 0.6 + (sqrtEnhanced * sqrtEnhanced) * 0.4;
    }

    result.add(combined);
  }

  return result;
}
