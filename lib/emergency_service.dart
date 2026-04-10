import 'dart:async';
import 'package:flutter/services.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  RouteStop  (minimal — just needs a name for now)
// ─────────────────────────────────────────────────────────────────────────────
class RouteStop {
  final String name;
  final double? latitude;
  final double? longitude;

  const RouteStop({required this.name, this.latitude, this.longitude});
}

// ─────────────────────────────────────────────────────────────────────────────
//  EmergencyService
//  • Sends SMS alerts to emergency contacts at key journey moments
//  • Monitors stop progress and fires alerts automatically
// ─────────────────────────────────────────────────────────────────────────────
class EmergencyService {
  static const _smsChannel = MethodChannel('com.pmpml.busbot/sms');

  final List<String> emergencyContacts; // e.g. ['919876543210']
  final List<RouteStop> routeStops;
  final String userName;
  final String busNumber;
  final String destination;

  bool _monitoring = false;
  int _currentStopIndex = 0;
  bool isNightMode;  // set via constructor or enableNightMode()

  EmergencyService({
    required this.emergencyContacts,
    required this.routeStops,
    required this.userName,
    required this.busNumber,
    required this.destination,
    bool nightMode = false,       // pass true if night mode is already on
  }) : isNightMode = nightMode;

  // ── Start monitoring ──────────────────────────────────────────────────────
  Future<void> startMonitoring() async {
    if (_monitoring) return;
    _monitoring = true;
    _currentStopIndex = 0;

    // Only send SMS if night mode is ON
    if (!isNightMode) return;

    final startMsg =
        '🚌 BusBot Alert: $userName has started journey on Bus $busNumber '
        'to $destination. '
        'Stops: ${routeStops.map((s) => s.name).join(" → ")}';

    await _sendToAll(startMsg);
  }

  // ── Call this each time a stop is reached ─────────────────────────────────
  Future<void> onStopReached(int stopIndex, String stopName) async {
    if (!_monitoring) return;
    if (!isNightMode) return;  // SMS only in night mode
    _currentStopIndex = stopIndex;

    final total = routeStops.length;
    final remaining = total - 1 - stopIndex;

    // 2 stops before destination
    if (remaining == 2) {
      final msg =
          '⚠️ BusBot: $userName is 2 stops away from $destination '
          '(Bus $busNumber). Currently at $stopName.';
      await _sendToAll(msg);
    }

    // 1 stop before destination
    if (remaining == 1) {
      final msg =
          '🔔 BusBot: $userName is 1 stop away from $destination '
          '(Bus $busNumber). Next stop is destination!';
      await _sendToAll(msg);
    }
  }

  // ── Call when journey is complete ─────────────────────────────────────────
  Future<void> onArrived() async {
    if (!_monitoring) return;
    if (!isNightMode) return;  // SMS only in night mode
    final msg =
        '✅ BusBot: $userName has safely arrived at $destination '
        '(Bus $busNumber). Journey complete.';
    await _sendToAll(msg);
    _monitoring = false;
  }

  // ── Manual SOS alert (e.g. voice command "night mode") ───────────────────
  Future<void> sendManualAlert() async {
    final stop = _currentStopIndex < routeStops.length
        ? routeStops[_currentStopIndex].name
        : 'unknown location';

    final msg =
        '🆘 BusBot SOS: $userName needs help! '
        'Currently near $stop on Bus $busNumber heading to $destination. '
        'Please contact them immediately.';
    await _sendToAll(msg);
  }

  // ── Stop monitoring ───────────────────────────────────────────────────────
  void stopMonitoring() {
    _monitoring = false;
  }

  // ── Internal: send to all contacts ───────────────────────────────────────
  Future<void> _sendToAll(String message) async {
    for (final number in emergencyContacts) {
      await _sendSms(number, message);
    }
  }

  // ── Internal: single SMS via MethodChannel ────────────────────────────────
  Future<void> _sendSms(String number, String message) async {
    // FIX: Clean the number — strip spaces, dashes, brackets
    final cleanNumber = number.replaceAll(RegExp(r'[\s\-\(\)]'), '');

    try {
      final result = await _smsChannel.invokeMethod<String>('sendSMS', {
        'number': cleanNumber,
        'message': message,
      });
      print('📱 SMS to $cleanNumber: $result');
    } on PlatformException catch (e) {
      print('❌ SMS failed to $cleanNumber: ${e.code} — ${e.message}');
    } catch (e) {
      print('❌ SMS error: $e');
    }
  }

  // ── Debug: test SMS immediately ───────────────────────────────────────────
  Future<void> debugTestSms() async {
    print('🧪 Testing SMS to: $emergencyContacts');
    await _sendToAll('🧪 BusBot SMS test — this is a test message from BusBot.');
  }

  // Toggle night mode — SMS alerts only fire when this is true
  void enableNightMode() {
    isNightMode = true;
    print('🌙 Night mode ON — SMS alerts active');
  }

  void disableNightMode() {
    isNightMode = false;
    print('☀️ Night mode OFF — SMS alerts paused');
  }

  bool get isMonitoring => _monitoring;
}