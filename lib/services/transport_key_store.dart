import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'key_wrap_service.dart';

/// Persists the verifier's ECIES transport keypair.
///
/// This is NOT a wallet key and holds no funds or identity. Its only job is to
/// let a user encrypt a document key *to* this verifier, so the secret never
/// travels as plaintext. Losing it costs one re-share: generate a new pair,
/// hand the user the new public key, and ask them to wrap again.
///
/// The private half lives in `flutter_secure_storage` and is never displayed,
/// copied to the clipboard, or sent anywhere.
class TransportKeyStore {
  TransportKeyStore._({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// Process-wide singleton.
  ///
  /// This MUST NOT be per-screen state. The verifier shows their public key,
  /// the user goes away and wraps to it, and the verifier comes back — often
  /// re-mounting the screen in between. A per-State store starts with an empty
  /// cache each time, so any hiccup reading storage silently mints a NEW
  /// keypair and the key the user just wrapped to is already stale. The
  /// symptom is an unwrap failure that looks like a crypto bug.
  static final TransportKeyStore instance = TransportKeyStore._();

  /// Test seam — an isolated store over a supplied backend.
  @visibleForTesting
  factory TransportKeyStore.forTesting(FlutterSecureStorage storage) =>
      TransportKeyStore._(storage: storage);

  static const String _storageKey = 'dekyc.transport.key.v1';

  final FlutterSecureStorage _storage;

  WrapKeyPair? _cached;

  /// Whether the current keypair actually made it to persistent storage.
  ///
  /// False means it lives only in memory: it will not survive a reload, so any
  /// key the user wraps to it must be used in this session. The UI surfaces
  /// this rather than letting the user discover it as a decryption failure.
  bool get isPersisted => _isPersisted;
  bool _isPersisted = false;

  /// The current keypair, generating and persisting one on first use.
  Future<WrapKeyPair> loadOrCreate() async {
    final cached = _cached;
    if (cached != null) return cached;

    String? stored;
    try {
      stored = await _storage.read(key: _storageKey);
    } catch (_) {
      // Secure storage unavailable (some desktop/web/test environments). Fall
      // through to an in-memory key so the feature still works this session —
      // but record that it is NOT durable so the UI can warn.
      stored = null;
    }

    if (stored != null) {
      try {
        final priv = KeyWrapService.fromHex(stored);
        final pair = WrapKeyPair(
          privateKey: priv,
          publicKey: KeyWrapService.publicKeyFor(priv),
        );
        _cached = pair;
        _isPersisted = true;
        return pair;
      } catch (_) {
        // Corrupt entry — discard and mint a fresh pair rather than wedging.
        try {
          await _storage.delete(key: _storageKey);
        } catch (_) {/* best effort */}
      }
    }

    final pair = KeyWrapService.generateKeyPair();
    _isPersisted = false;
    try {
      await _storage.write(key: _storageKey, value: pair.privateKeyHex);
      // Read back rather than trusting the write: some web/desktop backends
      // accept a write and then fail to return it, which would leave us
      // claiming durability we do not have.
      _isPersisted = await _storage.read(key: _storageKey) == pair.privateKeyHex;
    } catch (_) {
      _isPersisted = false; // in-memory only for this session
    }
    _cached = pair;
    return pair;
  }

  /// Discard the current keypair and mint a new one. Any wrapped key the user
  /// already produced for the old public key becomes undecryptable.
  Future<WrapKeyPair> rotate() async {
    _cached = null;
    try {
      await _storage.delete(key: _storageKey);
    } catch (_) {/* best effort */}
    return loadOrCreate();
  }
}
