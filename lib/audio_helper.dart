import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Mutes/unmutes STREAM_MUSIC briefly to suppress the Android
/// SpeechRecognizer start/stop beep sound.
class AudioHelper {
  static const _channel = MethodChannel('com.pmpml.busbot/audio');

  static Future<void> muteBeep() async {
    try {
      await _channel.invokeMethod('muteBeep');
    } catch (_) {}
  }

  static Future<void> unmuteBeep() async {
    try {
      await _channel.invokeMethod('unmuteBeep');
    } catch (_) {}
  }
}
