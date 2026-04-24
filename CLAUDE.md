# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`audio_waveforms` is a Flutter plugin (v2.0.2) for audio recording and playback with real-time waveform visualization. Supports Android, iOS, and macOS (macOS support unreleased in v2.1.0).

## Commands

```bash
# Lint / analyze
flutter analyze

# Run example app
cd example && flutter run

# Run tests
flutter test example/test/widget_test.dart
```

Analyzer is configured with strict mode (`strict-inference`, `strict-raw-types`; `argument_type_not_assignable` as error) in `analysis_options.yaml`.

## Architecture

### Dart Layer (`lib/src/`)

Three controllers manage state and native communication:

- **`RecorderController`** — recording lifecycle, amplitude streaming, duration tracking. Exposes streams: `onAmplitude`, `onCurrentDuration`, `onRecordingEnded`, `onRecorderStateChanged`.
- **`PlayerController`** — playback lifecycle, seeking, volume, rate. Supports multiple simultaneous instances via unique player keys. Streams: `onPlayerStateChanged`, `onDurationChanged`, `onCompletion`.
- **`WaveformExtractionController`** — async waveform data extraction from audio files. Streams: `onCurrentExtractedWaveformData`, `onExtractionProgress`.

Two Flutter widgets render waveforms:

- **`AudioWaveforms`** — real-time recording visualization, driven by `RecorderController`.
- **`AudioFileWaveforms`** — playback visualization with seek gestures, driven by `PlayerController`.

**`PlatformStreams`** is a singleton that owns all `MethodChannel` and `EventChannel` instances. All native calls and event subscriptions go through it. Method channel name: `simform_audio_waveforms_plugin/methods`.

Style configuration lives in `WaveStyle` (recording) and `PlayerWaveStyle` (playback). All method channel string constants are in `base/constants.dart`.

### Native Layer

**Android** (`android/src/main/kotlin/com/simform/audio_waveforms/`):
- Uses ExoPlayer 2.17.1 for playback, `AudioRecord`/`MediaRecorder` for recording.
- `AudioWaveformsPlugin.kt` is the entry point; delegates to `AudioRecorder.kt`, `AudioPlayer.kt`, `WaveformExtractor.kt`.
- `WavEncoder.kt` handles WAV encoding; `CommonEncoder.kt` is the base.
- minSdk 21, compileSdk 34.

**iOS** (`ios/Classes/`):
- `SwiftAudioWaveformsPlugin.swift` is the entry point; delegates to `AudioRecorder.swift`, `AudioPlayer.swift`, `WaveformExtractor.swift`.
- `AudioProcessingWrapper.mm` is an Obj-C++ bridge for audio processing.
- `NoiseCancelPlayer.m` handles noise cancellation.
- Bundles vendored frameworks: SFBAudioEngine, FLAC, lame, ogg, opus, vorbis, webrtc_audio_processing, and others (under `ios/Frameworks/`).
- iOS 8.0+, Swift 5.0.

### Example App (`example/`)

- `lib/main.dart` — recording UI home page.
- `lib/player_page.dart` — playback demo.
- `lib/waveform_task_manager.dart` — manages concurrent waveform extraction tasks.
- `lib/opus_to_ogg.dart` — format conversion utility.
