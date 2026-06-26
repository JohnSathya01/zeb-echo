# zeb Echo — Client (Flutter desktop)

The desktop client for **zeb Echo**, a local AI meeting assistant. This package
is intentionally **thin**: it owns the UI and (eventually) native audio capture
only. The entire AI pipeline (Vosk STT, question detection, the provider-agnostic
LLM layer) lives in the separate Node/TypeScript backend, which the client talks
to over a localhost WebSocket (default `ws://127.0.0.1:8787`). See the root
`CLAUDE.md` for the full spec and architecture.

## Status: scaffolding

> **Flutter is not installed in the environment where this was scaffolded**, so
> `flutter create`, `flutter pub get`, `flutter analyze`, and `flutter run`
> could **not** be executed here. Every file was hand-authored to be ready to
> run once a developer installs Flutter. The `macos/` and `windows/` runner
> directories that `flutter create` normally generates are **not** present —
> see "First-time setup" below.

## Requirements

- Flutter SDK **>= 3.22** (Dart **>= 3.4**) with desktop support enabled.
- macOS or Windows (Phase 1 targets; no mobile/web).

Enable desktop once:

```bash
flutter config --enable-macos-desktop
flutter config --enable-windows-desktop
```

## First-time setup

This scaffold contains `lib/`, `pubspec.yaml`, `analysis_options.yaml`, and
`.gitignore`, but not the native runner projects. Generate them in-place
(this does not overwrite existing Dart/config files):

```bash
cd client
flutter create --platforms=macos,windows .
flutter pub get
```

## Common commands

```bash
flutter pub get          # fetch dependencies
flutter run -d macos     # run on macOS
flutter run -d windows   # run on Windows
flutter analyze          # static analysis (keep clean)
dart format .            # format before committing
flutter test             # run tests
flutter build macos      # release build (macOS)
flutter build windows    # release build (Windows)
```

## Running without the backend (fake mode)

The UI runs **standalone** with no Node backend and no audio hardware. By
default the app wires up `FakeBackendClient` (canned transcript / questions /
streamed response tokens on a timer) and `FakeAudioCaptureService` (synthetic
levels + silent PCM frames), so `flutter run -d macos` shows a fully demoable
dashboard immediately. Press **Start** to play the scripted session.

### Fake vs. real backend toggle

The switch lives in `lib/state/providers.dart`:

```dart
final useFakeServicesProvider = Provider<bool>((ref) => true); // fake by default
```

To use the real backend, either flip that to `false` or override it at the
`ProviderScope` in `lib/main.dart`:

```dart
runApp(
  ProviderScope(
    overrides: [useFakeServicesProvider.overrideWithValue(false)],
    child: const ZebEchoApp(),
  ),
);
```

With `false`, `WebSocketBackendClient` connects to `ws://127.0.0.1:8787` and
auto-reconnects with backoff. **Audio capture is still fake** — native capture
is a documented TODO (see below), so the real backend will receive silent
frames until platform channels are implemented.

## State management: Riverpod

This client uses **`flutter_riverpod`**, per the `CLAUDE.md` §6 recommendation
("pick ONE; `riverpod` recommended"). The choice is used everywhere:

- `ProviderScope` is installed at the app root in `lib/main.dart`.
- Services are exposed as providers (`backendClientProvider`,
  `audioCaptureServiceProvider`) so fakes/reals are swapped in one place.
- `sessionControllerProvider` (a `StateNotifier`) owns the session lifecycle
  (idle / running / paused) and start/pause/resume/stop.
- Inbound backend streams feed dedicated providers: `transcriptProvider`,
  `detectedQuestionsProvider`, `aiResponseProvider`, `audioStatusProvider`,
  `connectionStateProvider`, `backendStatusProvider`, `backendErrorProvider`.
- Widgets are `ConsumerWidget` / `ConsumerStatefulWidget` and `ref.watch` the
  providers; the UI never touches the socket directly.

Do **not** mix in another state-management library.

## Directory layout (feature-first)

```
lib/
  main.dart                       # ProviderScope + app entry, dark theme
  theme/
    app_colors.dart               # color tokens (CLAUDE.md §5) — only place with hex
    app_theme.dart                # ThemeData (dark) + spacing/radius tokens
  protocol/
    messages.dart                 # Dart mirror of the backend wire protocol (§3.2)
  services/
    backend_client.dart           # BackendClient + WebSocket + Fake impls
    audio_capture_service.dart    # AudioCaptureService + Native (TODO) + Fake impls
  state/
    providers.dart                # Riverpod providers wiring services -> UI
    session_controller.dart       # session lifecycle StateNotifier
  features/
    dashboard/
      dashboard_screen.dart       # Meeting Dashboard layout
      widgets/
        panel_card.dart           # shared panel frame
        live_transcript_panel.dart
        detected_question_panel.dart
        ai_response_panel.dart
        audio_status_indicator.dart
        session_controls.dart
```

## Protocol must stay in sync with the backend

`lib/protocol/messages.dart` is a **hand-mirrored** Dart port of the backend
protocol. The single source of truth is `backend/src/protocol/messages.ts`.
Any change to message `type` strings, fields, or `protocolVersion` on either
side **must be mirrored on the other**. Message type names here intentionally
match `CLAUDE.md` §3.2 (`session.start/pause/stop`, `audio.chunk`,
`transcript.partial/final`, `question.detected`, `response.token/done`,
`status`, `error`).

## Native audio capture (TODO)

`NativeAudioCaptureService` in `lib/services/audio_capture_service.dart` is a
documented stub — it throws `UnimplementedError`. System-audio loopback is the
hardest platform piece (`CLAUDE.md` §10) and needs native code behind platform
channels:

- **macOS:** ScreenCaptureKit audio (or a virtual loopback device) for system
  output + `AVAudioEngine` for the mic. Mic and screen-recording permission
  prompts must be surfaced in the Audio Status Indicator.
- **Windows:** WASAPI loopback for system output + WASAPI capture for the mic.

Keep capture off the UI isolate. Until this lands, use the fake service.
