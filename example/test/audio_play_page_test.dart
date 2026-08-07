import 'package:audio_waveforms_example/audio_play_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats playback durations as minutes and seconds', () {
    expect(formatDuration(const Duration(minutes: 2, seconds: 5)), '02:05');
  });
}
