import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

/// Health of a single audio source (mic or system loopback), surfaced in the
/// Audio Status Indicator (CLAUDE.md §4.2 / §4.3).
enum AudioSourceStatus { idle, capturing, error, permissionDenied }

/// The two concurrent capture sources required in Phase 1 (CLAUDE.md §4.1).
enum AudioSource { microphone, systemOutput }

/// Snapshot of both audio sources plus a coarse input level for metering.
class AudioStatus {
  const AudioStatus({
    required this.microphone,
    required this.systemOutput,
    this.micLevel = 0,
    this.systemLevel = 0,
  });

  final AudioSourceStatus microphone;
  final AudioSourceStatus systemOutput;

  /// Normalized 0..1 levels for simple meters (low-distraction UI, §5).
  final double micLevel;
  final double systemLevel;

  static const AudioStatus idle = AudioStatus(
    microphone: AudioSourceStatus.idle,
    systemOutput: AudioSourceStatus.idle,
  );

  AudioStatus copyWith({
    AudioSourceStatus? microphone,
    AudioSourceStatus? systemOutput,
    double? micLevel,
    double? systemLevel,
  }) {
    return AudioStatus(
      microphone: microphone ?? this.microphone,
      systemOutput: systemOutput ?? this.systemOutput,
      micLevel: micLevel ?? this.micLevel,
      systemLevel: systemLevel ?? this.systemLevel,
    );
  }
}

/// A captured PCM frame ready to upload (signed 16-bit LE, see [AudioFormat]).
class PcmChunk {
  const PcmChunk({required this.bytes, required this.sequence});

  final Uint8List bytes;
  final int sequence;
}

/// Abstraction over native audio capture (CLAUDE.md §3 client-side contracts).
///
/// Captures mic + system-audio concurrently, emits mixed PCM chunks, and
/// exposes per-source status. Implemented by a future native-backed class
/// (platform channels) and by [FakeAudioCaptureService] for hardware-free dev.
abstract interface class AudioCaptureService {
  /// Per-source status + levels (CLAUDE.md §4.2 Audio Status Indicator).
  Stream<AudioStatus> get status;

  /// Captured PCM frames to stream upstream to the backend.
  Stream<PcmChunk> get chunks;

  /// Most recent status snapshot (for synchronous reads).
  AudioStatus get currentStatus;

  /// Begin capturing from both sources.
  Future<void> start();

  /// Pause capture without releasing devices.
  Future<void> pause();

  /// Stop capture and release devices.
  Future<void> stop();

  /// Release all resources.
  Future<void> dispose();
}

/// TODO(native-audio): Real capture implementation.
///
/// This is intentionally NOT implemented in scaffolding — system-audio loopback
/// is the hardest platform piece (CLAUDE.md §10) and requires native code:
///   - macOS: ScreenCaptureKit audio capture or a virtual loopback device,
///     plus microphone via AVAudioEngine. Mic + screen-recording permission
///     prompts must be surfaced in the Audio Status Indicator (§10).
///   - Windows: WASAPI loopback for system output + WASAPI capture for the mic.
///
/// Wire these up behind platform channels (MethodChannel for control +
/// EventChannel for the PCM stream) so the Dart side stays the abstraction
/// (CLAUDE.md §6 "Platform code"). Run capture off the UI isolate (§4.3).
/// Until then, the app defaults to [FakeAudioCaptureService].
class NativeAudioCaptureService implements AudioCaptureService {
  NativeAudioCaptureService() {
    throw UnimplementedError(
      'Native audio capture is a documented TODO (CLAUDE.md §10). '
      'Use FakeAudioCaptureService for UI development.',
    );
  }

  @override
  Stream<AudioStatus> get status => throw UnimplementedError();

  @override
  Stream<PcmChunk> get chunks => throw UnimplementedError();

  @override
  AudioStatus get currentStatus => throw UnimplementedError();

  @override
  Future<void> start() => throw UnimplementedError();

  @override
  Future<void> pause() => throw UnimplementedError();

  @override
  Future<void> stop() => throw UnimplementedError();

  @override
  Future<void> dispose() => throw UnimplementedError();
}

/// Fake capture so the UI runs with NO microphone or system audio hardware
/// (CLAUDE.md §8). Emits silent PCM frames on a timer and animates fake levels
/// so the Audio Status Indicator looks live.
class FakeAudioCaptureService implements AudioCaptureService {
  FakeAudioCaptureService();

  final _statusCtrl = StreamController<AudioStatus>.broadcast();
  final _chunksCtrl = StreamController<PcmChunk>.broadcast();
  final Random _rng = Random();

  AudioStatus _status = AudioStatus.idle;
  Timer? _timer;
  int _seq = 0;

  @override
  Stream<AudioStatus> get status => _statusCtrl.stream;

  @override
  Stream<PcmChunk> get chunks => _chunksCtrl.stream;

  @override
  AudioStatus get currentStatus => _status;

  void _emit(AudioStatus next) {
    _status = next;
    if (!_statusCtrl.isClosed) _statusCtrl.add(next);
  }

  @override
  Future<void> start() async {
    _emit(
      const AudioStatus(
        microphone: AudioSourceStatus.capturing,
        systemOutput: AudioSourceStatus.capturing,
      ),
    );
    _timer?.cancel();
    // ~100ms frames at 16kHz mono s16le => 1600 samples => 3200 bytes.
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final bytes = Uint8List(3200); // silence
      _chunksCtrl.add(PcmChunk(bytes: bytes, sequence: _seq++));
      _emit(
        _status.copyWith(
          micLevel: _rng.nextDouble() * 0.6 + 0.1,
          systemLevel: _rng.nextDouble() * 0.6 + 0.1,
        ),
      );
    });
  }

  @override
  Future<void> pause() async {
    _timer?.cancel();
    _timer = null;
    _emit(
      const AudioStatus(
        microphone: AudioSourceStatus.idle,
        systemOutput: AudioSourceStatus.idle,
      ),
    );
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _seq = 0;
    _emit(AudioStatus.idle);
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    await _statusCtrl.close();
    await _chunksCtrl.close();
  }
}
