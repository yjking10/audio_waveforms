import 'dart:async';

import 'package:audio_waveforms_example/audio_play_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats playback durations as minutes and seconds', () {
    expect(formatDuration(const Duration(minutes: 2, seconds: 5)), '02:05');
  });

  test('defers player cleanup until preparation settles during disposal',
      () async {
    final lifecycle = PlayerPreparationLifecycle();
    final preparation = Completer<void>();
    var didCleanUp = false;

    lifecycle.beginDisposing();
    final cleanup = lifecycle.cleanUpAfterPreparation(
      preparation.future,
      () => didCleanUp = true,
    );

    expect(lifecycle.canUpdateUi, isFalse);
    expect(didCleanUp, isFalse);

    preparation.complete();
    await cleanup;

    expect(didCleanUp, isTrue);
  });
}
