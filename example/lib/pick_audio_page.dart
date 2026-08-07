import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';

import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:file_picker/file_picker.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  File? file;

  late PlayerController controller;
  late StreamSubscription<PlayerState> playerStateSubscription;

  final playerWaveStyle = const PlayerWaveStyle(
    fixedWaveColor: Colors.white54,
    liveWaveColor: Colors.white,
    showSeekLine: true,
    waveThickness: 1,
    spacing: 2,
  );

  @override
  void initState() {
    super.initState();
    controller = PlayerController();
    playerStateSubscription = controller.onPlayerStateChanged.listen((state) {
      processingState = state;
    });
  }

  int _loadRequest = 0;
  bool _isExtracting = false;
  bool _isPickingAudio = false;

  static const _audioExtensions = <String>[
    'aac',
    'aiff',
    'flac',
    'm4a',
    'mp3',
    'ogg',
    'opus',
    'wav',
  ];

  Future<void> _pickAudioFile() async {
    if (_isPickingAudio) return;

    setState(() => _isPickingAudio = true);
    try {
      // On iOS, FileType.audio opens the Media Library picker instead of the
      // Files document picker. A custom extension filter keeps the audio-only
      // selection while allowing files outside Apple Music to be chosen.
      final selection = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: _audioExtensions,
        allowMultiple: false,
      );
      final path = selection?.files.singleOrNull?.path;
      if (path == null) return;
      await _loadAudio(path);
    } catch (error, stackTrace) {
      debugPrint('Unable to pick audio file: $error\n$stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法选择音频文件：$error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isPickingAudio = false);
      }
    }
  }

  Future<void> _loadAudio(String path) async {
    final request = ++_loadRequest;
    setState(() {
      file = File(path);
      waveformData = [];
      _isExtracting = true;
    });

    try {
      // Supersede any in-flight extraction so its late result cannot replace
      // the waveform for the newly selected file.
      await controller.waveformExtraction.stopWaveformExtraction();
    } catch (_) {
      // There may be no active extraction for the first selected file.
    }
    try {
      await controller.stopPlayer();
    } catch (_) {
      // The player may not have been prepared yet.
    }

    try {
      await controller.preparePlayer(path: path, shouldExtractWaveform: false);
      await controller.setFinishMode(finishMode: FinishMode.pause);
      final data = await controller.waveformExtraction.extractWaveformData(
        path: path,
        noOfSamplesPerSecond: 10,
      );
      if (!mounted || request != _loadRequest) return;
      setState(() => waveformData = data);
    } catch (error, stackTrace) {
      debugPrint('Unable to load audio waveform: $error\n$stackTrace');
      if (mounted && request == _loadRequest) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法提取该音频的波形：$error')),
        );
      }
    } finally {
      if (mounted && request == _loadRequest) {
        setState(() => _isExtracting = false);
      }
    }
  }

  PlayerState _processingState = PlayerState.stopped;

  PlayerState get processingState => _processingState;

  set processingState(PlayerState value) {
    if (_processingState != value) {
      _processingState = value;

      setState(() {});
    }
  }

  @override
  void dispose() {
    playerStateSubscription.cancel();
    controller.dispose();
    super.dispose();
  }

  int _selectedSegment = 0;

  int _selectedTate = 1;
  List<double> waveformData = [];
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            icon: const Icon(Icons.audio_file),
            onPressed: _isPickingAudio ? null : _pickAudioFile,
            tooltip: '选择音频文件',
          ),
        ],
      ),
      body: file?.path != null
          ? Align(
              alignment: Alignment.topCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    // margin:
                    //     const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: const Color(0xFF343145),
                    ),
                    child: AudioFileWaveforms(
                      size: Size(MediaQuery.of(context).size.width, 70),
                      playerController: controller,
                      waveformData: waveformData,
                      waveformType: WaveformType.long,
                      playerWaveStyle: playerWaveStyle,
                    ),
                  ),
                  if (_isExtracting)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: CircularProgressIndicator(),
                    ),
                  // if (!controller.playerState.isStopped)
                  IconButton(
                    onPressed: () async {
                      if (controller.playerState.isPlaying) {
                        await controller.pausePlayer();
                      } else {
                        await controller.startPlayer();
                      }
                    },
                    icon: Icon(
                      controller.playerState.isPlaying
                          ? Icons.stop
                          : Icons.play_arrow,
                    ),
                    color: Colors.blueAccent,
                    splashColor: Colors.transparent,
                    highlightColor: Colors.transparent,
                  ),
                  CupertinoSlidingSegmentedControl<int>(
                    groupValue: _selectedSegment,
                    children: const {
                      0: Text('none'),
                      1: Text('low'),
                      2: Text('middle'),
                      3: Text('high'),
                    },
                    onValueChanged: (value) {
                      setState(() {
                        _selectedSegment = value!;
                        controller.setNoiseSuppressionLevel(value);
                      });
                    },
                  ),

                  const SizedBox(
                    height: 40,
                  ),
                  CupertinoSlidingSegmentedControl<int>(
                    groupValue: _selectedTate,
                    children: const {
                      0: Text('0.5'),
                      1: Text('1.0'),
                      2: Text('1.25'),
                      3: Text('1.5'),
                      4: Text('2.0'),
                    },
                    onValueChanged: (value) {
                      setState(() {
                        _selectedTate = value!;
                        double rate = 1.0;

                        if (value == 0) {
                          rate = 0.5;
                        } else if (value == 1) {
                          rate = 1.0;
                        } else if (value == 2) {
                          rate = 1.25;
                        } else if (value == 3) {
                          rate = 1.5;
                        } else if (value == 4) {
                          rate = 2.0;
                        }
                        controller.setRate(rate);
                      });
                    },
                  ),
                ],
              ),
            )
          : Center(
              child: ElevatedButton.icon(
                onPressed: _isPickingAudio ? null : _pickAudioFile,
                icon: const Icon(Icons.audio_file),
                label: const Text('选择音频文件'),
              ),
            ),
    );
  }
}
