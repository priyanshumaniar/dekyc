import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

// Picks the platform AES-GCM primitive: PointyCastle off the web, the browser's
// native (and non-blocking) SubtleCrypto on the web.
import 'crypto/aes_gcm_io.dart'
    if (dart.library.js_interop) 'crypto/aes_gcm_web.dart';

/// Client-side AES-256-GCM encryption for KYC bundles.
///
/// The symmetric key is derived deterministically from a wallet signature
/// over [keyDerivationMessage]. Because the signature is reproducible by the
/// wallet at any time, the user can always re-derive the key without ever
/// storing it. The key never leaves the device and is never put on-chain.
class EncryptionService {
  /// The exact message the wallet signs to derive the encryption key.
  /// Changing this string rotates everyone's key, so it is versioned.
  static const String keyDerivationMessage = 'DeKYC encryption key v1';

  static const int _keyLengthBytes = 32; // AES-256
  static const int _nonceLengthBytes = 12; // 96-bit GCM nonce (recommended)
  // GCM tag is a fixed 16 bytes (128 bits), applied inside the platform backend.

  /// Derive a 32-byte AES key from a hex signature string.
  ///
  /// [signatureHex] is the wallet's signature over [keyDerivationMessage]
  /// (e.g. from `personal_sign`). We hash it with SHA-256 to get a uniform
  /// 256-bit key regardless of the signature's length/format.
  static Uint8List deriveKeyFromSignature(String signatureHex) {
    final normalized = signatureHex.startsWith('0x')
        ? signatureHex.substring(2)
        : signatureHex;
    final sigBytes = _hexToBytes(normalized);
    final digest = sha256.convert(sigBytes);
    return Uint8List.fromList(digest.bytes); // 32 bytes
  }

  /// Encrypt [plaintext] with [key]. Output layout: `nonce || ciphertext || tag`.
  ///
  /// Async because the web backend (SubtleCrypto) is async and runs off the UI
  /// thread; the non-web backend completes synchronously inside the Future.
  Future<Uint8List> encryptBytes(Uint8List plaintext, Uint8List key) async {
    _assertKey(key);
    final nonce = _randomBytes(_nonceLengthBytes);
    final ciphertextAndTag = await aesGcmEncrypt(key, nonce, plaintext);
    final out = Uint8List(nonce.length + ciphertextAndTag.length);
    out.setRange(0, nonce.length, nonce);
    out.setRange(nonce.length, out.length, ciphertextAndTag);
    return out;
  }

  /// Decrypt data produced by [encryptBytes]. Throws if the tag is invalid
  /// (tampering / wrong key).
  Future<Uint8List> decryptBytes(Uint8List data, Uint8List key) async {
    _assertKey(key);
    if (data.length <= _nonceLengthBytes) {
      throw ArgumentError('Ciphertext too short.');
    }
    final nonce = data.sublist(0, _nonceLengthBytes);
    final ciphertextAndTag = data.sublist(_nonceLengthBytes);
    return aesGcmDecrypt(key, nonce, ciphertextAndTag);
  }

  /// Convenience: encrypt a UTF-8 string.
  Future<Uint8List> encryptString(String plaintext, Uint8List key) =>
      encryptBytes(Uint8List.fromList(utf8.encode(plaintext)), key);

  /// Convenience: decrypt to a UTF-8 string.
  Future<String> decryptString(Uint8List data, Uint8List key) async =>
      utf8.decode(await decryptBytes(data, key));

  void _assertKey(Uint8List key) {
    if (key.length != _keyLengthBytes) {
      throw ArgumentError(
        'Key must be $_keyLengthBytes bytes, got ${key.length}.',
      );
    }
  }

  static Uint8List _randomBytes(int n) {
    final rng = Random.secure();
    final b = Uint8List(n);
    for (var i = 0; i < n; i++) {
      b[i] = rng.nextInt(256);
    }
    return b;
  }

  static Uint8List _hexToBytes(String hex) {
    final clean = hex.length.isOdd ? '0$hex' : hex;
    final result = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}
