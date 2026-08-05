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
  /// Version tag for the key-derivation scheme. Bumping it rotates every
  /// user's key, so it only changes when the derivation itself changes.
  static const String keyDerivationVersion = 'v2';

  /// The exact message the wallet signs to derive the encryption key.
  ///
  /// The message is bound to [address] so a signature harvested for one
  /// account cannot derive another account's key, and it is written in plain
  /// language because `personal_sign` shows it verbatim in the wallet — a user
  /// prompted with this text on a site that is not DeKYC has been told, in the
  /// prompt itself, exactly what they would be giving away.
  ///
  /// LIMITATION (documented in the README threat model): `personal_sign` has
  /// no origin/domain separator, so this text alone cannot *prevent* a phishing
  /// site from requesting the same signature — it can only make the
  /// consequence legible. Binding the derivation to the verifying origin needs
  /// EIP-712 typed data with a domain separator.
  static String buildKeyDerivationMessage(String address) {
    return 'DeKYC — derive my document encryption key ($keyDerivationVersion)\n'
        '\n'
        'Account: ${address.toLowerCase()}\n'
        '\n'
        'Signing this does NOT send a transaction and costs nothing. It '
        'produces the single key that encrypts and decrypts your KYC '
        'documents.\n'
        '\n'
        'WARNING: anyone who obtains this signature can decrypt every document '
        'you have uploaded. Only ever sign this in the DeKYC app.';
  }

  static const int _keyLengthBytes = 32; // AES-256
  static const int _nonceLengthBytes = 12; // 96-bit GCM nonce (recommended)
  static const int _signatureLengthBytes = 65; // r(32) || s(32) || v(1)
  // GCM tag is a fixed 16 bytes (128 bits), applied inside the platform backend.

  /// Derive a 32-byte AES key from an EIP-191 `personal_sign` signature.
  ///
  /// [signatureHex] must be a full 65-byte secp256k1 signature (`r || s || v`),
  /// with or without the `0x` prefix. We hash it with SHA-256 to get a uniform
  /// 256-bit key.
  ///
  /// The input is validated rather than coerced. Silently accepting a short or
  /// empty response would be catastrophic: a wallet (or a hostile injected
  /// provider) returning `"0x"` would previously yield `sha256("")` — a
  /// constant every attacker already knows — and the user's documents would be
  /// encrypted under a world-readable key with no visible symptom.
  ///
  /// The `v` byte is canonicalised to 27/28 before hashing. Wallets disagree
  /// here (MetaMask returns 27/28, some return 0/1) and hashing the raw byte
  /// would make the derived key depend on that quirk — so a wallet changing its
  /// encoding, or the user moving to a different wallet for the same account,
  /// would derive a different key and permanently orphan their bundle.
  static Uint8List deriveKeyFromSignature(String signatureHex) {
    final sigBytes = _decodeSignature(signatureHex);
    // Canonicalise v so the key depends only on (r, s, recovery id).
    if (sigBytes[64] < 27) sigBytes[64] += 27;
    final digest = sha256.convert(sigBytes);
    return Uint8List.fromList(digest.bytes); // 32 bytes
  }

  /// Strict hex → 65 bytes. Throws [ArgumentError] on anything else.
  static Uint8List _decodeSignature(String signatureHex) {
    final hex = signatureHex.startsWith('0x') || signatureHex.startsWith('0X')
        ? signatureHex.substring(2)
        : signatureHex;
    if (hex.length != _signatureLengthBytes * 2) {
      throw ArgumentError(
        'Expected a $_signatureLengthBytes-byte (${_signatureLengthBytes * 2} '
        'hex chars) signature, got ${hex.length} hex chars. The wallet did not '
        'return a usable signature — refusing to derive a key from it.',
      );
    }
    final out = Uint8List(_signatureLengthBytes);
    for (var i = 0; i < out.length; i++) {
      final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) {
        throw ArgumentError('Signature contains non-hex characters.');
      }
      out[i] = byte;
    }
    // An all-zero signature is not a real secp256k1 signature; treat the
    // degenerate case explicitly rather than deriving a predictable key.
    if (out.every((b) => b == 0)) {
      throw ArgumentError('Refusing to derive a key from an all-zero signature.');
    }
    return out;
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

}
