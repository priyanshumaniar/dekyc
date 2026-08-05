import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'crypto/aes_gcm_io.dart'
    if (dart.library.js_interop) 'crypto/aes_gcm_web.dart';

/// ECIES over secp256k1: encrypt a small secret *to* a recipient's public key.
///
/// ## Why this exists
///
/// The KYC bundle is encrypted with one AES key derived from the user's wallet
/// signature. To let a verifier read it, that key has to reach them. Handing
/// over the raw 32-byte key means the secret travels as plaintext: anyone who
/// sees the channel (a screenshot, a chat log, a clipboard manager) gets
/// permanent read access to every bundle that wallet will ever produce, and
/// on-chain `revokeAccess` cannot claw that back.
///
/// Wrapping fixes the transport half of that: the verifier publishes an
/// ephemeral public key, the user encrypts the AES key *to* it, and the blob
/// that travels between them is useless to anyone else.
///
/// ## Scheme
///
/// Standard ECIES with an ephemeral sender key:
///
/// 1. Generate an ephemeral secp256k1 keypair `(e, E)`.
/// 2. Shared secret `S = x-coordinate of (e · R)`, where `R` is the recipient's
///    public key (ECDH).
/// 3. `K = HKDF-SHA256(ikm: S, salt: E‖R compressed, info: "DeKYC-key-wrap-v1")`.
///    Binding both public keys into the salt means a blob cannot be replayed
///    against a different recipient.
/// 4. `AES-256-GCM(K, nonce, secret)`.
///
/// Wire format: `0x01 ‖ E(33, compressed) ‖ nonce(12) ‖ ciphertext ‖ tag(16)`.
///
/// ## Why not MetaMask's `eth_getEncryptionPublicKey`
///
/// That RPC (and `eth_decrypt`) was deprecated and then **removed** from
/// MetaMask, so a wallet-native wrap is no longer implementable. The verifier
/// therefore generates this keypair inside DeKYC and keeps the private half in
/// secure storage. It is a *transport* key — losing it costs nothing but a
/// re-share, and it never touches the user's funds or identity.
class KeyWrapService {
  KeyWrapService._();

  static const int _version = 0x01;
  static const int _pubKeyLength = 33; // compressed secp256k1 point
  static const int _nonceLength = 12;
  static const String _info = 'DeKYC-key-wrap-v1';

  static final ECDomainParameters _curve = ECCurve_secp256k1();

  // --- keypair -------------------------------------------------------------

  /// Generate a fresh secp256k1 transport keypair.
  static WrapKeyPair generateKeyPair() {
    final rng = FortunaRandom()
      ..seed(KeyParameter(_secureSeed(32)));
    final gen = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(_curve), rng));
    final pair = gen.generateKeyPair();
    final priv = pair.privateKey as ECPrivateKey;
    final pub = pair.publicKey as ECPublicKey;
    return WrapKeyPair(
      privateKey: _bigIntTo32Bytes(priv.d!),
      publicKey: Uint8List.fromList(pub.Q!.getEncoded(true)), // compressed
    );
  }

  /// The compressed public key for a stored private key.
  static Uint8List publicKeyFor(Uint8List privateKey) {
    _requirePrivateKey(privateKey);
    final d = _bytesToBigInt(privateKey);
    final q = _curve.G * d;
    return Uint8List.fromList(q!.getEncoded(true));
  }

  /// Whether [publicKey] is a well-formed compressed point ON the curve.
  ///
  /// The recipient key is pasted in by a human from an untrusted channel, so it
  /// is validated before use — an off-curve or identity point would otherwise
  /// produce a degenerate shared secret.
  static bool isValidPublicKey(Uint8List publicKey) {
    if (publicKey.length != _pubKeyLength) return false;
    if (publicKey[0] != 0x02 && publicKey[0] != 0x03) return false;
    try {
      final point = _curve.curve.decodePoint(publicKey);
      if (point == null || point.isInfinity) return false;
      // Reject small-subgroup / off-curve points.
      return (point * _curve.n)?.isInfinity ?? false;
    } catch (_) {
      return false;
    }
  }

  // --- wrap / unwrap -------------------------------------------------------

  /// Encrypt [secret] to [recipientPublicKey]. Non-deterministic: a fresh
  /// ephemeral key and nonce per call.
  static Future<Uint8List> wrap(
    Uint8List secret,
    Uint8List recipientPublicKey,
  ) async {
    if (!isValidPublicKey(recipientPublicKey)) {
      throw ArgumentError(
        'Not a valid secp256k1 compressed public key — refusing to wrap a '
        'secret to it.',
      );
    }
    final ephemeral = generateKeyPair();
    final shared = _ecdh(ephemeral.privateKey, recipientPublicKey);
    final aesKey = _hkdf(shared, ephemeral.publicKey, recipientPublicKey);

    final nonce = _secureSeed(_nonceLength);
    final ciphertextAndTag = await aesGcmEncrypt(aesKey, nonce, secret);

    final out = BytesBuilder()
      ..addByte(_version)
      ..add(ephemeral.publicKey)
      ..add(nonce)
      ..add(ciphertextAndTag);
    return out.toBytes();
  }

  /// Decrypt a blob produced by [wrap] using the recipient's private key.
  /// Throws if the blob is malformed, was wrapped to a different key, or was
  /// tampered with (the GCM tag fails).
  static Future<Uint8List> unwrap(
    Uint8List blob,
    Uint8List recipientPrivateKey,
  ) async {
    _requirePrivateKey(recipientPrivateKey);
    const headerLength = 1 + _pubKeyLength + _nonceLength;
    // 16 = GCM tag; anything at or below this carries no ciphertext at all.
    if (blob.length <= headerLength + 16) {
      throw ArgumentError('Wrapped key is too short to be valid.');
    }
    if (blob[0] != _version) {
      throw ArgumentError(
        'Unsupported wrapped-key version 0x${blob[0].toRadixString(16)}.',
      );
    }
    final ephemeralPub = blob.sublist(1, 1 + _pubKeyLength);
    if (!isValidPublicKey(ephemeralPub)) {
      throw ArgumentError('Wrapped key carries an invalid ephemeral point.');
    }
    final nonce = blob.sublist(1 + _pubKeyLength, headerLength);
    final ciphertextAndTag = blob.sublist(headerLength);

    final shared = _ecdh(recipientPrivateKey, ephemeralPub);
    final aesKey = _hkdf(
      shared,
      ephemeralPub,
      publicKeyFor(recipientPrivateKey),
    );
    return aesGcmDecrypt(aesKey, nonce, ciphertextAndTag);
  }

  // --- hex helpers (what the UI passes around) ------------------------------

  static String toHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Parse hex, tolerating a `0x` prefix and surrounding whitespace — these
  /// strings are copy-pasted by hand between two people.
  static Uint8List fromHex(String hex) {
    var clean = hex.trim().replaceAll(RegExp(r'\s'), '');
    if (clean.startsWith('0x') || clean.startsWith('0X')) {
      clean = clean.substring(2);
    }
    if (clean.isEmpty || clean.length.isOdd) {
      throw ArgumentError('Expected an even-length hex string.');
    }
    final out = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final b = int.tryParse(clean.substring(i * 2, i * 2 + 2), radix: 16);
      if (b == null) throw ArgumentError('Not valid hex.');
      out[i] = b;
    }
    return out;
  }

  // --- internals -----------------------------------------------------------

  /// ECDH: the x-coordinate of privateKey · publicKey.
  static Uint8List _ecdh(Uint8List privateKey, Uint8List publicKey) {
    final d = _bytesToBigInt(privateKey);
    final point = _curve.curve.decodePoint(publicKey);
    final shared = (point! * d)!;
    if (shared.isInfinity) {
      throw ArgumentError('Degenerate ECDH result.');
    }
    return _bigIntTo32Bytes(shared.x!.toBigInteger()!);
  }

  /// HKDF-SHA256 (extract + expand) down to a 32-byte AES key. Both public
  /// keys go into the salt so a blob is bound to this exact key pairing.
  static Uint8List _hkdf(
    Uint8List sharedSecret,
    Uint8List ephemeralPub,
    Uint8List recipientPub,
  ) {
    final salt = Uint8List.fromList([...ephemeralPub, ...recipientPub]);
    final hkdf = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(
        sharedSecret,
        32,
        salt,
        Uint8List.fromList(_info.codeUnits),
      ));
    final out = Uint8List(32);
    hkdf.deriveKey(sharedSecret, 0, out, 0);
    return out;
  }

  static void _requirePrivateKey(Uint8List key) {
    if (key.length != 32) {
      throw ArgumentError('Private key must be 32 bytes, got ${key.length}.');
    }
    final d = _bytesToBigInt(key);
    if (d == BigInt.zero || d >= _curve.n) {
      throw ArgumentError('Private key is outside the valid scalar range.');
    }
  }

  static Uint8List _secureSeed(int n) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    var v = BigInt.zero;
    for (final b in bytes) {
      v = (v << 8) | BigInt.from(b);
    }
    return v;
  }

  static Uint8List _bigIntTo32Bytes(BigInt v) {
    final out = Uint8List(32);
    var x = v;
    for (var i = 31; i >= 0; i--) {
      out[i] = (x & BigInt.from(0xff)).toInt();
      x = x >> 8;
    }
    return out;
  }
}

/// A secp256k1 transport keypair. The private half never leaves the device.
class WrapKeyPair {
  const WrapKeyPair({required this.privateKey, required this.publicKey});

  /// 32 bytes.
  final Uint8List privateKey;

  /// 33 bytes, compressed — this is what the verifier shares with the user.
  final Uint8List publicKey;

  String get privateKeyHex => KeyWrapService.toHex(privateKey);
  String get publicKeyHex => KeyWrapService.toHex(publicKey);
}
