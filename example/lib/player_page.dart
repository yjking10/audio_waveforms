import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:flutter/services.dart';

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
    _getDir();

    controller = PlayerController();
    _preparePlayer();
    playerStateSubscription = controller.onPlayerStateChanged.listen((state) {
      processingState = state;
      print('state= $state');
    });
  }

  // late Directory _appDirectory;

  void _getDir() async {}

  Future<void> _preparePlayer() async {
    await controller.pauseAllPlayers();

    final appDirectory = await getApplicationDocumentsDirectory();

    // String fileName = 'audio3.mp3';
    // String fileName = 'test.opus';
    String fileName = 'audio2.mp3';

    // fileName = '.opus';

    // Opening file from assets folder
    file = File('${appDirectory.path}/$fileName');
    final byteData = await rootBundle.load('assets/audios/$fileName');
    final audioBytes = byteData.buffer.asUint8List();
    await file?.writeAsBytes(audioBytes);
    if (file?.path == null) {
      return;
    }
    // Prepare player with extracting waveform if index is even.
    await controller.preparePlayer(
        path: file!.path, shouldExtractWaveform: true, noOfSamples: 100);

    print('controller-playerKey ${controller.playerKey}');
    // Extracting waveform separately if index is odd.
    // controller.waveformExtraction
    //     .extractWaveformData(
    //   path: file!.path,
    //   noOfSamples:
    //       playerWaveStyle.getSamplesForWidth(MediaQuery.of(context).size.width),
    // )
    //     .then((waveformData) {
    //   setState(() {
    //     this.waveformData = waveformData;
    //   });
    //   print("${this.waveformData}");
    // });
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
      appBar: AppBar(),
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
                      waveformType: WaveformType.fitWidth,
                      playerWaveStyle: playerWaveStyle,
                    ),
                  ),
                  // if (!controller.playerState.isStopped)
                  IconButton(
                    onPressed: () async {
                      if (controller.playerState.isPlaying) {
                        await controller.pausePlayer();
                      } else {
                        await controller.startPlayer();
                      }
                      controller.setFinishMode(finishMode: FinishMode.pause);
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
          : const SizedBox.shrink(),
    );
  }
}
