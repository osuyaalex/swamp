import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Thin wrapper over `flutter_secure_storage` so the rest of the app
/// depends on an interface, not the plugin directly.
///
/// Keys live in the platform keystore — Keychain on iOS (with
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so they never sync to
/// iCloud) and AndroidKeyStore-backed EncryptedSharedPreferences on
/// Android. Fundamentals: never write any of this to plain
/// `SharedPreferences`, never log it, never serialise it to JSON.
abstract class SecureStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PlatformSecureStorage implements SecureStorage {
  PlatformSecureStorage()
      : _store = const FlutterSecureStorage(
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.unlocked_this_device,
          ),
          aOptions: AndroidOptions(
            encryptedSharedPreferences: true,
          ),
        );

  final FlutterSecureStorage _store;

  @override
  Future<String?> read(String key) => _store.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _store.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _store.delete(key: key);
}
