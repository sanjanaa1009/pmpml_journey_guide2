import 'dart:async';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Sets up a persistent Android foreground service so the Flutter engine
/// keeps running (and wake-word STT keeps looping) even when the user
/// presses home or turns the screen off.
Future<void> initBackgroundService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: _onServiceStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'busbot_wake_channel',
      initialNotificationTitle: 'BusBot',
      initialNotificationContent: 'Listening for "Hey BusBot"…',
      foregroundServiceNotificationId: 8888,
    ),
    iosConfiguration: IosConfiguration(
      // iOS background audio is handled separately; disable auto-start here.
      autoStart: false,
      onForeground: _onServiceStart,
    ),
  );

  await service.startService();
}

/// Entry point for the background isolate.
/// This isolate's only job is to stay alive and keep the process running.
/// All STT work happens in the main Flutter isolate via [VoiceService].
@pragma('vm:entry-point')
void _onServiceStart(ServiceInstance service) async {
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
  FlutterLocalNotificationsPlugin();

  // ✅ REQUIRED INITIALIZATION
  const AndroidInitializationSettings initializationSettingsAndroid =
  AndroidInitializationSettings('@mipmap/ic_launcher');

  const InitializationSettings initializationSettings =
  InitializationSettings(android: initializationSettingsAndroid);

  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  // ✅ CREATE CHANNEL
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'busbot_wake_channel',
    'BusBot Service',
    description: 'Foreground service for BusBot',
    importance: Importance.low,
  );

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(
      title: 'BusBot',
      content: 'Listening for "Hey BusBot"...',
    );

    service.on('updateNotification').listen((data) {
      service.setForegroundNotificationInfo(
        title: 'BusBot',
        content: data?['content'] ?? 'Listening...',
      );
    });

    service.on('stopService').listen((_) {
      service.stopSelf();
    });
  }

  Timer.periodic(const Duration(seconds: 5), (_) {});
}

/// Call this to update the persistent notification text.
void updateServiceNotification(String content) {
  final service = FlutterBackgroundService();
  service.invoke('updateNotification', {'content': content});
}

/// Call this to stop the service (e.g. on logout / app destroy).
void stopBackgroundService() {
  final service = FlutterBackgroundService();
  service.invoke('stopService');
}
