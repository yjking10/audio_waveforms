# AudioPlayPage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an example page that plays the bundled `output22.mp3` audio with a waveform, progress, and play/pause control.

**Architecture:** `AudioPlayPage` owns a `PlayerController`, copies the bundled asset to the temporary directory before native playback, and listens to controller streams to render time and state. `Home` only presents a new app-bar action and pushes the page.

**Tech Stack:** Flutter, `audio_waveforms`, `path_provider`, `flutter_test`.

## Global Constraints

- Play the exact bundled asset path `assets/audios/output22.mp3`.
- Keep recording and file-picker flows unchanged.
- Dispose every `PlayerController` and `StreamSubscription` owned by `AudioPlayPage`.
- Show a visible error message if asset staging or player preparation fails.

---

### Task 1: Create the player page behavior

**Files:**
- Modify: `example/lib/audio_play_page.dart`
- Create: `example/test/audio_play_page_test.dart`

**Interfaces:**
- Consumes: `PlayerController.preparePlayer(path: String, shouldExtractWaveform: bool)`, `PlayerController.startPlayer()`, `PlayerController.pausePlayer()`, and `PlayerController.onCurrentDurationChanged`.
- Produces: `AudioPlayPage`, plus `String formatDuration(Duration duration)` for display and test coverage.

- [ ] **Step 1: Write the failing duration-formatting test**

```dart
import 'package:audio_waveforms_example/audio_play_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats playback durations as minutes and seconds', () {
    expect(formatDuration(const Duration(minutes: 2, seconds: 5)), '02:05');
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/audio_play_page_test.dart`

Expected: FAIL because `formatDuration` does not yet exist.

- [ ] **Step 3: Implement asset staging, preparation, and UI state**

Replace the placeholder with a stateful page that:

```dart
final PlayerController _playerController = PlayerController();
int _currentMilliseconds = 0;
int _totalMilliseconds = 0;
bool _isPreparing = true;
String? _errorMessage;
```

In `initState`, load `assets/audios/output22.mp3` with `rootBundle.load`, write it to `getTemporaryDirectory()/output22.mp3`, call `preparePlayer(path: stagedPath, shouldExtractWaveform: true)`, then listen to `onCurrentDurationChanged`, `onPlayerStateChanged`, and `onCompletion`. Render `AudioFileWaveforms` with `enableSeekGesture: true`, elapsed/total `formatDuration` labels, and an `IconButton` that pauses when playing and starts otherwise. Catch failures into `_errorMessage` and show it with `Text`.

Add:

```dart
String formatDuration(Duration duration) {
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
```

- [ ] **Step 4: Dispose native resources**

```dart
@override
void dispose() {
  _currentDurationSubscription?.cancel();
  _playerStateSubscription?.cancel();
  _completionSubscription?.cancel();
  _playerController.dispose();
  super.dispose();
}
```

- [ ] **Step 5: Run the focused test to verify it passes**

Run: `flutter test test/audio_play_page_test.dart`

Expected: PASS with one test.

- [ ] **Step 6: Commit the player page and test**

```bash
git add example/lib/audio_play_page.dart example/test/audio_play_page_test.dart
git commit -m "feat: add bundled audio player example"
```

### Task 2: Add the Home app-bar entry point

**Files:**
- Modify: `example/lib/main.dart`

**Interfaces:**
- Consumes: `const AudioPlayPage()` from `audio_play_page.dart`.
- Produces: A tappable app-bar action that pushes the player page.

- [ ] **Step 1: Add the page import and navigation button**

```dart
import 'audio_play_page.dart';
```

Add this `IconButton` to `Home`'s `AppBar.actions`:

```dart
IconButton(
  icon: const Icon(Icons.play_circle_outline),
  tooltip: '播放示例音频',
  onPressed: () {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AudioPlayPage()),
    );
  },
),
```

- [ ] **Step 2: Verify static analysis**

Run: `flutter analyze --no-fatal-infos --no-fatal-warnings lib example/lib example/test`

Expected: exit code 0 and no new errors.

- [ ] **Step 3: Verify iOS asset packaging and native compilation**

Run: `flutter build ios --debug --no-codesign`

Expected: `Built build/ios/iphoneos/Runner.app`.

- [ ] **Step 4: Commit the entry point**

```bash
git add example/lib/main.dart
git commit -m "feat: link home page to audio player"
```
