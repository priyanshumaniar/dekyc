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
  TransportKeyStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const String _storageKey = 'dekyc.transport.key.v1';

  final FlutterSecureStorage _storage;

  WrapKeyPair? _cached;

  /// The current keypair, generating and persisting one on first use.
  Future<WrapKeyPair> loadOrCreate() async {
    final cached = _cached;
    if (cached != null) return cached;

    String? stored;
    try {
      stored = await _storage.read(key: _storageKey);
    } catch (_) {
      // Secure storage unavailable (some desktop/test environments). Fall
      // through to an in-memory key so the feature still works this session —
      // the user just has to re-share if the app restarts.
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
        return pair;
      } catch (_) {
        // Corrupt entry — discard and mint a fresh pair rather than wedging.
        try {
          await _storage.delete(key: _storageKey);
        } catch (_) {/* best effort */}
      }
    }

    final pair = KeyWrapService.generateKeyPair();
    try {
      await _storage.write(key: _storageKey, value: pair.privateKeyHex);
    } catch (_) {/* in-memory only for this session */}
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
