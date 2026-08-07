# AudioPlayPage design

## Scope

Add a self-contained example page that plays the bundled
`assets/audios/output22.mp3`. Add an app-bar action on the home page that
opens it.

## Behavior

- On opening, copy the bundled audio asset to the temporary directory and
  prepare a `PlayerController` with waveform extraction enabled.
- Show the filename, an `AudioFileWaveforms` view with tap-to-seek, elapsed and
  total durations, and one play/pause button.
- Disable the play control while preparation is in progress. If preparation
  fails, show an error message and keep the page usable.
- Dispose the controller and duration subscriptions when leaving the page.

## Boundaries

`AudioPlayPage` owns its controller, asset copy, and UI state. `main.dart`
only imports the page and adds one navigation action. Existing recording and
file-picking behavior remains unchanged.

## Verification

Static analysis must report no new errors, and the iOS Debug build must package
the new asset and compile the example app.
