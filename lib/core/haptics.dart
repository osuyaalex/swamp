import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class Haptics {
  Haptics._();

  static bool get _supported {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  static Future<void> dragStart() async {
    if (!_supported) return;
    await HapticFeedback.mediumImpact();
  }

  static Future<void> dragHover() async {
    if (!_supported) return;
    await HapticFeedback.selectionClick();
  }

  static Future<void> dragDrop() async {
    if (!_supported) return;
    await HapticFeedback.lightImpact();
  }

  static Future<void> dragCancel() async {
    if (!_supported) return;
    await HapticFeedback.heavyImpact();
  }
}