import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// ──────────────────────────────────────────────────────────────────────────
///  VoiceService v2
///
///  Uses a native Android SpeechRecognizer (via MethodChannel) instead of
///  the flutter speech_to_text package.  Benefits:
///    • No beep on each recognition cycle restart.
///    • Works with screen off (paired with PARTIAL_WAKE_LOCK in MainActivity).
///    • Truly continuous — the native layer auto-restarts on silence.
///
///  Dart side just receives text events and classifies them as wake-word
///  hits or active commands.
/// ──────────────────────────────────────────────────────────────────────────

enum VoiceMode { sleeping, wakeWord, active }

class VoiceService {
  // ── Channels ─────────────────────────────────────────────────────────────
  static const _sttChannel   = MethodChannel('com.pmpml.busbot/stt');
  static const _sttEvents    = EventChannel('com.pmpml.busbot/stt_events');

  // ── TTS ───────────────────────────────────────────────────────────────────
  final FlutterTts _tts = FlutterTts();
  bool _isSpeaking = false;

  // ── State ─────────────────────────────────────────────────────────────────
  VoiceMode _mode = VoiceMode.sleeping;
  VoiceMode get mode => _mode;

  Function()?      _onWakeWordDetected;
  Function(String)? _onActiveCommand;

  StreamSubscription<dynamic>? _eventSub;

  // ── One-shot listen (mic button) ──────────────────────────────────────────
  Completer<String?>? _oneShotCompleter;

  // ─────────────────────────────────────────────────────────────────────────
  // INIT
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> initialize() async {
    await _tts.setLanguage('en-IN');
    await _tts.setSpeechRate(0.48);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _tts.setStartHandler(() => _isSpeaking = true);
    _tts.setCompletionHandler(() => _isSpeaking = false);
    _tts.setErrorHandler((_) => _isSpeaking = false);

    // Keep CPU alive
    await WakelockPlus.enable();

    // Subscribe to native STT events once
    _eventSub = _sttEvents.receiveBroadcastStream().listen(_onNativeEvent);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // NATIVE EVENT HANDLER
  // ─────────────────────────────────────────────────────────────────────────
  void _onNativeEvent(dynamic raw) {
    final String event = raw as String;
    final isPartial = event.startsWith('PARTIAL:');
    final text = isPartial
        ? event.substring('PARTIAL:'.length).toLowerCase().trim()
        : event.substring('FINAL:'.length).toLowerCase().trim();

    if (text.isEmpty) return;

    // ── One-shot listener (mic button) ─────────────────────────────────────
    if (_oneShotCompleter != null && !_oneShotCompleter!.isCompleted) {
      if (!isPartial) {
        _oneShotCompleter!.complete(text);
        _oneShotCompleter = null;
      }
      return;
    }

    // ── Don't process while speaking ──────────────────────────────────────
    if (_isSpeaking) return;

    if (_mode == VoiceMode.wakeWord) {
      // Check partials too for faster response
      if (_isWakeWord(text)) {
        _onWakeWordDetected?.call();
      }
    } else if (_mode == VoiceMode.active) {
      if (!isPartial) {
        _onActiveCommand?.call(text);
      }
    }
  }

  bool _isWakeWord(String text) {
    return text.contains('hey busbot') ||
        text.contains('hey bus bot') ||
        text.contains('hey busbud') ||
        text.contains('hey bustbot') ||
        text.contains('a busbot') ||
        text.contains('hey bus assistant') ||
        text.contains('bus assistant');
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PUBLIC API
  // ─────────────────────────────────────────────────────────────────────────

  /// Start continuous native STT in wake-word mode.
  Future<void> startWakeWordListening({
    required Function() onWakeWordDetected,
    required Function(String) onActiveCommand,
  }) async {
    // 🔴 ADD THIS
    var status = await Permission.microphone.request();
    if (!status.isGranted) {
      print("❌ Microphone permission denied");
      return;
    }

    _onWakeWordDetected = onWakeWordDetected;
    _onActiveCommand    = onActiveCommand;
    _mode = VoiceMode.wakeWord;

    print("✅ Starting native STT...");
    await _sttChannel.invokeMethod('startListening');
  }

  /// Switch from wake-word mode to full command mode.
  void activateFullListening() {
    _mode = VoiceMode.active;
    // Native STT is already running — no restart needed.
  }

  /// Switch back to wake-word mode.
  void deactivateToWakeWord() {
    _mode = VoiceMode.wakeWord;
  }

  /// Speak text via TTS.  Suspends STT processing while speaking so the
  /// bot doesn't hear itself.
  Future<void> speak(String text) async {
    _isSpeaking = true;
    await _tts.stop();
    await _tts.speak(text);
    // Wait for TTS to finish
    final done = Completer<void>();
    _tts.setCompletionHandler(() {
      _isSpeaking = false;
      if (!done.isCompleted) done.complete();
    });
    _tts.setErrorHandler((_) {
      _isSpeaking = false;
      if (!done.isCompleted) done.complete();
    });
    await done.future.timeout(const Duration(seconds: 30), onTimeout: () {
      _isSpeaking = false;
    });
  }
  // Future<void> speak(String text) async {
  //   _isSpeaking = true;
  //
  //   await _tts.stop();
  //   await _tts.speak(text);
  //
  //   // Wait for completion properly
  //   final completer = Completer<void>();
  //
  //   _tts.setCompletionHandler(() {
  //     if (!completer.isCompleted) completer.complete();
  //   });
  //
  //   _tts.setErrorHandler((_) {
  //     if (!completer.isCompleted) completer.complete();
  //   });
  //
  //   await completer.future;
  //
  //   _isSpeaking = false;
  //
  //   // ✅ IMPORTANT: NO restart needed
  //   // Native STT is already running continuously
  // }

  /// One-shot listen triggered by the mic button in the UI.
  Future<String?> listen({int timeoutSeconds = 6}) async {
    _oneShotCompleter = Completer<String?>();
    return _oneShotCompleter!.future.timeout(
      Duration(seconds: timeoutSeconds),
      onTimeout: () {
        _oneShotCompleter = null;
        return null;
      },
    );
  }

  Future<void> stop() async {
    _mode = VoiceMode.sleeping;
    await _sttChannel.invokeMethod('stopListening');
    await _tts.stop();
  }

  bool get isSpeaking  => _isSpeaking;
  bool get isActive    => _mode == VoiceMode.active;

  void dispose() {
    _eventSub?.cancel();
    WakelockPlus.disable();
    _tts.stop();
    _sttChannel.invokeMethod('stopListening');
  }
}