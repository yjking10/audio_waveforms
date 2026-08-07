import 'dart:async';
import 'dart:io';

import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class AudioPlayPage extends StatefulWidget {
  const AudioPlayPage({super.key});

  @override
  State<AudioPlayPage> createState() => _AudioPlayPageState();
}

class _AudioPlayPageState extends State<AudioPlayPage> {
  final PlayerController _playerController = PlayerController();
  final PlayerPreparationLifecycle _preparationLifecycle =
      PlayerPreparationLifecycle();
  int _currentMilliseconds = 0;
  int _totalMilliseconds = 0;
  List<double> _waveformData = [];
  bool _isPreparing = true;
  String? _errorMessage;

  StreamSubscription<int>? _currentDurationSubscription;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<void>? _completionSubscription;
  late final Future<void> _preparationFuture;

  bool get _canUpdateUi => mounted && _preparationLifecycle.canUpdateUi;

  @override
  void initState() {
    super.initState();
    _currentDurationSubscription =
        _playerController.onCurrentDurationChanged.listen((duration) {
      if (_canUpdateUi) {
        setState(() => _currentMilliseconds = duration);
      }
    });
    _playerStateSubscription =
        _playerController.onPlayerStateChanged.listen((_) {
      if (_canUpdateUi) {
        setState(() {});
      }
    });
    _completionSubscription = _playerController.onCompletion.listen((_) {
      if (_canUpdateUi) {
        setState(() => _currentMilliseconds = _totalMilliseconds);
      }
    });
    _preparationFuture = _prepareBundledAudio();
  }

  Future<void> _prepareBundledAudio() async {
    try {
      final audioData = await rootBundle.load('assets/audios/output22.mp3');
      final temporaryDirectory = await getTemporaryDirectory();
      final stagedAudio = File('${temporaryDirectory.path}/output22.mp3');
      await stagedAudio.writeAsBytes(
        audioData.buffer.asUint8List(
          audioData.offsetInBytes,
          audioData.lengthInBytes,
        ),
      );

      if (!_canUpdateUi) return;
      await _playerController.preparePlayer(
        path: stagedAudio.path,
        shouldExtractWaveform: false,
      );
      if (!_canUpdateUi) return;
      await _playerController.setFinishMode(finishMode: FinishMode.pause);
      if (!_canUpdateUi) return;
      final waveformData =
          await _playerController.waveformExtraction.extractWaveformData(
        path: stagedAudio.path,
      );
      if (_canUpdateUi) {
        setState(() {
          _totalMilliseconds = _playerController.maxDuration;
          _waveformData = waveformData;
          _isPreparing = false;
        });
      }
    } catch (error) {
      if (_canUpdateUi) {
        setState(() {
          _errorMessage = 'Unable to prepare bundled audio: $error';
          _isPreparing = false;
        });
      }
    }
  }

  Future<void> _togglePlayback() async {
    try {
      if (_playerController.playerState.isPlaying) {
        await _playerController.pausePlayer();
      } else {
        await _playerController.startPlayer();
      }
    } catch (error) {
      if (_canUpdateUi) {
        setState(() => _errorMessage = 'Unable to update playback: $error');
      }
    }
  }

  @override
  void dispose() {
    _preparationLifecycle.beginDisposing();
    unawaited(_disposePlayerAfterPreparation());
    super.dispose();
  }

  Future<void> _disposePlayerAfterPreparation() async {
    await Future.wait([
      _currentDurationSubscription?.cancel() ?? Future<void>.value(),
      _playerStateSubscription?.cancel() ?? Future<void>.value(),
      _completionSubscription?.cancel() ?? Future<void>.value(),
    ]);
    await _preparationLifecycle.cleanUpAfterPreparation(
      _preparationFuture,
      _playerController.dispose,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMessage != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Bundled audio player')),
        body: Center(child: Text(_errorMessage!)),
      );
    }

    if (_isPreparing) {
      return Scaffold(
        appBar: AppBar(title: const Text('Bundled audio player')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final totalDuration = Duration(milliseconds: _totalMilliseconds);
    final elapsedDuration = Duration(milliseconds: _currentMilliseconds);
    final isPlaying = _playerController.playerState.isPlaying;

    return Scaffold(
      appBar: AppBar(title: const Text('Bundled audio player')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AudioFileWaveforms(
              size: Size(MediaQuery.sizeOf(context).width - 48, 80),
              playerController: _playerController,
              enableSeekGesture: true,
              waveformData: _waveformData,
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(formatDuration(elapsedDuration)),
                Text(formatDuration(totalDuration)),
              ],
            ),
            IconButton(
              onPressed: _togglePlayback,
              iconSize: 48,
              tooltip: isPlaying ? 'Pause' : 'Play',
              icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
            ),
          ],
        ),
      ),
    );
  }
}

String formatDuration(Duration duration) {
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// Coordinates async player preparation with synchronous widget disposal.
class PlayerPreparationLifecycle {
  var _isDisposing = false;

  bool get canUpdateUi => !_isDisposing;

  void beginDisposing() {
    _isDisposing = true;
  }

  Future<void> cleanUpAfterPreparation(
    Future<void> preparation,
    void Function() cleanUp,
  ) async {
    try {
      await preparation;
    } finally {
      cleanUp();
    }
  }
}
