import 'dart:math';

import 'package:package_info_plus/package_info_plus.dart';

import 'package:untitled2/core/secure_storage.dart';

/// Identifies the device and the running app version for audit-trail
/// enrichment.
///
/// The device id is generated once on first launch and stored in the
/// platform keystore (so it survives reinstalls only as long as the
/// keychain entry survives — typically until the user wipes the device).
/// We do not use any platform-level identifier (e.g. `androidId`,
/// `identifierForVendor`) directly — those have privacy implications and
/// rotate in ways we don't control.
class DeviceIdentity {
  DeviceIdentity({required SecureStorage storage}) : _storage = storage;

  static const _deviceIdKey = 'device_id.v1';
  static final _rng = Random.secure();

  final SecureStorage _storage;
  String? _cachedDeviceId;
  String? _cachedAppVersion;

  Future<String> deviceId() async {
    final cached = _cachedDeviceId;
    if (cached != null) return cached;

    final existing = await _storage.read(_deviceIdKey);
    if (existing != null && existing.isNotEmpty) {
      return _cachedDeviceId = existing;
    }
    final fresh = _generate();
    await _storage.write(_deviceIdKey, fresh);
    return _cachedDeviceId = fresh;
  }

  Future<String> appVersion() async {
    final cached = _cachedAppVersion;
    if (cached != null) return cached;
    final info = await PackageInfo.fromPlatform();
    return _cachedAppVersion = '${info.version}+${info.buildNumber}';
  }

  static String _generate() {
    // 16 random bytes, hex-encoded — 128 bits of entropy is plenty for
    // identifying one device across audit entries.
    final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'dev_$hex';
  }
}
