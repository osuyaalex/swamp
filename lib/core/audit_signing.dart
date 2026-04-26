import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'package:untitled2/core/secure_storage.dart';

/// Signs audit entries with HMAC-SHA-256 and chains them with a
/// previous-hash field so the resulting log is tamper-evident.
///
/// The signing key lives in the platform keystore and is generated once
/// per device on first use. An auditor verifying the log re-derives each
/// entry's signature and checks that every `prevHash` matches the
/// previous entry's signature — any tampering breaks the chain.
class AuditSigner {
  AuditSigner({required SecureStorage storage}) : _storage = storage;

  static const _keyName = 'audit_signing_key.v1';
  static final _rng = Random.secure();

  final SecureStorage _storage;
  List<int>? _cachedKey;

  Future<List<int>> _key() async {
    final cached = _cachedKey;
    if (cached != null) return cached;
    final stored = await _storage.read(_keyName);
    if (stored != null && stored.isNotEmpty) {
      return _cachedKey = base64Decode(stored);
    }
    final fresh = List<int>.generate(32, (_) => _rng.nextInt(256));
    await _storage.write(_keyName, base64Encode(fresh));
    return _cachedKey = fresh;
  }

  /// Compute an HMAC-SHA-256 over the canonical encoding of [payload]
  /// concatenated with the previous entry's signature, returning the new
  /// signature as base64.
  ///
  /// `prevSignature` may be empty — this is the first entry.
  Future<String> sign({
    required Map<String, Object?> payload,
    required String prevSignature,
  }) async {
    final hmac = Hmac(sha256, await _key());
    final canonical = jsonEncode(payload);
    final input = utf8.encode('$prevSignature$canonical');
    return base64Encode(hmac.convert(input).bytes);
  }

  /// Hash a previous signature into a `prevHash` value the next entry
  /// will store. SHA-256 is overkill for a 32-byte input but it makes
  /// the field self-contained and cheap to verify.
  String prevHashOf(String prevSignature) {
    if (prevSignature.isEmpty) return '';
    final digest = sha256.convert(utf8.encode(prevSignature));
    return base64Encode(digest.bytes);
  }
}
