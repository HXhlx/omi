import 'package:flutter/services.dart';

import 'package:omi/utils/logger.dart';

/// Screen keep-on for capture that must stay foregrounded.
///
/// A window flag on Android (`FLAG_KEEP_SCREEN_ON`) and the idle timer on iOS
/// (`UIApplication.isIdleTimerDisabled`); neither needs a permission. Handlers
/// live in `MainActivity.kt` and `AppDelegate.swift` on channel
/// `com.omi/keep_screen_on`.
class KeepScreenOn {
  static const MethodChannel _channel = MethodChannel('com.omi/keep_screen_on');

  KeepScreenOn._();

  /// Sets screen keep-on. A missing handler or a dead engine is logged and
  /// swallowed: capture must not fail because a screen could fall asleep —
  /// worst case the OS sleeps the screen and the camera session pauses until
  /// the user unlocks, which is the pre-existing behaviour.
  static Future<void> set(bool on) async {
    try {
      await _channel.invokeMethod<void>('set', on);
    } catch (e) {
      Logger.debug('KeepScreenOn: set($on) failed: ${e.runtimeType}');
    }
  }
}
