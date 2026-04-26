import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// Wrapper over `local_auth`. Centralised so tests can inject a fake and
/// the rest of the app stays unaware of the plugin.
abstract class Biometrics {
  /// Whether the device exposes any biometric (Face ID, Touch ID, fingerprint).
  Future<bool> isAvailable();

  /// Prompt the user. Returns true on success, false on cancel/fail/lock-out.
  Future<bool> authenticate({required String reason});
}

class PlatformBiometrics implements Biometrics {
  PlatformBiometrics() : _auth = LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> isAvailable() async {
    try {
      final canCheck = await _auth.canCheckBiometrics;
      final supported = await _auth.isDeviceSupported();
      return canCheck && supported;
    } catch (e) {
      if (kDebugMode) debugPrint('[biometrics] isAvailable failed: $e');
      return false;
    }
  }

  @override
  Future<bool> authenticate({required String reason}) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false, // allow device passcode fallback
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[biometrics] authenticate failed: $e');
      return false;
    }
  }
}
