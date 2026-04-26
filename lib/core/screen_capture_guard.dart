import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:screen_protector/screen_protector.dart';

/// Activates on-device protection against screenshots and screen
/// recording when sensitive content is on screen. Behaviour per platform:
///
///   - Android: sets `WindowManager.LayoutParams.FLAG_SECURE` so the
///     OS refuses to capture the window into a screenshot or recording.
///     System-wide and reliable.
///   - iOS: cannot block screenshots (Apple does not expose an API),
///     but listens for screen-recording state and can blur the
///     screen / present a warning. We use it for a soft barrier — the
///     user knows we noticed.
///
/// The guard is reference-counted so multiple sensitive screens can
/// activate it simultaneously and the OS-level protection only turns
/// off when the last screen disables it.
class ScreenCaptureGuard {
  ScreenCaptureGuard._();

  static final ScreenCaptureGuard instance = ScreenCaptureGuard._();

  int _activeCount = 0;

  Future<void> protect() async {
    _activeCount++;
    if (_activeCount > 1) return;
    try {
      if (Platform.isAndroid) {
        await ScreenProtector.protectDataLeakageOn();
      } else if (Platform.isIOS) {
        await ScreenProtector.protectDataLeakageWithBlur();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[screen_capture_guard] protect failed: $e');
    }
  }

  Future<void> release() async {
    if (_activeCount == 0) return;
    _activeCount--;
    if (_activeCount > 0) return;
    try {
      if (Platform.isAndroid) {
        await ScreenProtector.protectDataLeakageOff();
      } else if (Platform.isIOS) {
        await ScreenProtector.protectDataLeakageWithBlurOff();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[screen_capture_guard] release failed: $e');
    }
  }
}
