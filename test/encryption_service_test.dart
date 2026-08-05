import 'dart:math';
import 'dart:typed_data';

import 'package:de_kyc/services/crypto/aes_gcm_io.dart';
import 'package:de_kyc/services/encryption_service.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// A syntactically valid 65-byte secp256k1 signature (r || s || v).
/// [v] defaults to 27, the encoding MetaMask returns.
String _signature({int fill = 0xab, int v = 27}) {
  final bytes = Uint8List(65)..fillRange(0, 64, fill);
  bytes[64] = v;
  return '0x${_toHex(bytes)}';
}

void main() {
  final service = EncryptionService();

  Uint8List randomKey() {
    final rng = Random(42);
    return Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
  }

  group('EncryptionService AES-256-GCM', () {
    test('round-trips bytes', () async {
      final key = randomKey();
      final plaintext = Uint8List.fromList(
        List.generate(1024, (i) => i % 256),
      );

      final cipher = await service.encryptBytes(plaintext, key);
      // Ciphertext must differ from plaintext and carry nonce+tag overhead.
      expect(cipher, isNot(equals(plaintext)));
      expect(cipher.length, equals(plaintext.length + 12 + 16));

      final decrypted = await service.decryptBytes(cipher, key);
      expect(decrypted, equals(plaintext));
    });

    test('round-trips a UTF-8 string', () async {
      final key = randomKey();
      const message = 'DeKYC 🚀 — encrypted bundle with çhars';
      final cipher = await service.encryptString(message, key);
      expect(await service.decryptString(cipher, key), equals(message));
    });

    test('encryption is non-deterministic (random nonce)', () async {
      final key = randomKey();
      final pt = Uint8List.fromList([1, 2, 3, 4, 5]);
      final a = await service.encryptBytes(pt, key);
      final b = await service.encryptBytes(pt, key);
      expect(a, isNot(equals(b)));
      // Only the 12-byte nonce prefix should differ in length terms.
      expect(a.sublist(0, 12), isNot(equals(b.sublist(0, 12))));
    });

    test('decrypting with the wrong key throws', () async {
      final key = randomKey();
      final wrong = Uint8List.fromList(List.generate(32, (i) => 255 - i));
      final cipher = await service.encryptBytes(
        Uint8List.fromList([9, 8, 7, 6]),
        key,
      );
      await expectLater(
        service.decryptBytes(cipher, wrong),
        throwsA(anything),
      );
    });

    test('a single flipped ciphertext byte fails the GCM tag', () async {
      final key = randomKey();
      final cipher =
          await service.encryptBytes(Uint8List.fromList([1, 2, 3, 4]), key);
      // Tamper inside the ciphertext body, past the nonce.
      cipher[13] = cipher[13] ^ 0x01;
      await expectLater(service.decryptBytes(cipher, key), throwsA(anything));
    });

    test('rejects a key of the wrong length', () async {
      final shortKey = Uint8List(16);
      await expectLater(
        service.encryptBytes(Uint8List(4), shortKey),
        throwsArgumentError,
      );
    });

    test('rejects ciphertext too short to hold a nonce', () async {
      await expectLater(
        service.decryptBytes(Uint8List(8), randomKey()),
        throwsArgumentError,
      );
    });
  });

  group('AES-GCM known-answer vector', () {
    // McGrew & Viega AES-GCM Test Case 15 (AES-256, 60-byte plaintext, no AAD).
    // This pins the exact byte layout the backend produces: `ciphertext || tag`
    // with a 16-byte tag appended. The web backend (WebCrypto) documents the
    // same layout, so this vector is what makes the cross-platform claim —
    // "a bundle encrypted in the browser decrypts on desktop" — checkable
    // rather than merely asserted in a comment.
    const keyHex =
        'feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308';
    const ivHex = 'cafebabefacedbaddecaf888';
    const ptHex = 'd9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a'
        '318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255';
    const ctHex = '522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd25'
        '55d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662898015ad';
    const tagHex = 'b094dac5d93471bdec1a502270e3cc6c';

    test('encrypt produces the published ciphertext and tag', () async {
      final out = await aesGcmEncrypt(_hex(keyHex), _hex(ivHex), _hex(ptHex));
      expect(_toHex(out), equals(ctHex + tagHex));
    });

    test('decrypt recovers the published plaintext', () async {
      final pt = await aesGcmDecrypt(
        _hex(keyHex),
        _hex(ivHex),
        _hex(ctHex + tagHex),
      );
      expect(_toHex(pt), equals(ptHex));
    });
  });

  group('deriveKeyFromSignature', () {
    test('is deterministic and 32 bytes', () {
      final sig = _signature();
      final k1 = EncryptionService.deriveKeyFromSignature(sig);
      final k2 = EncryptionService.deriveKeyFromSignature(sig);
      expect(k1.length, 32);
      expect(k1, equals(k2));
      // A different signature yields a different key.
      final k3 = EncryptionService.deriveKeyFromSignature(_signature(fill: 0x01));
      expect(k3, isNot(equals(k1)));
    });

    test('accepts the signature with or without the 0x prefix', () {
      final withPrefix = _signature();
      final without = withPrefix.substring(2);
      expect(
        EncryptionService.deriveKeyFromSignature(without),
        equals(EncryptionService.deriveKeyFromSignature(withPrefix)),
      );
    });

    test('canonicalises v: 0/1 derive the same key as 27/28', () {
      // Wallets disagree on the v encoding. If the raw byte were hashed, the
      // same account on a different wallet would derive a different key and
      // permanently orphan the user's bundle.
      expect(
        EncryptionService.deriveKeyFromSignature(_signature(v: 0)),
        equals(EncryptionService.deriveKeyFromSignature(_signature(v: 27))),
      );
      expect(
        EncryptionService.deriveKeyFromSignature(_signature(v: 1)),
        equals(EncryptionService.deriveKeyFromSignature(_signature(v: 28))),
      );
      // ...but 27 and 28 are genuinely different recovery ids.
      expect(
        EncryptionService.deriveKeyFromSignature(_signature(v: 27)),
        isNot(equals(EncryptionService.deriveKeyFromSignature(_signature(v: 28)))),
      );
    });

    test('REJECTS an empty or "0x" response instead of deriving sha256("")',
        () {
      // The critical case: a wallet (or hostile injected provider) returning
      // "0x" must not silently produce a world-known constant key.
      expect(() => EncryptionService.deriveKeyFromSignature('0x'),
          throwsArgumentError);
      expect(() => EncryptionService.deriveKeyFromSignature(''),
          throwsArgumentError);
    });

    test('rejects short, long, odd-length and non-hex signatures', () {
      expect(() => EncryptionService.deriveKeyFromSignature('0xdeadbeef'),
          throwsArgumentError);
      // 64 bytes — one short of a full signature.
      expect(
        () => EncryptionService.deriveKeyFromSignature('0x${'ab' * 64}'),
        throwsArgumentError,
      );
      // 66 bytes — one too many.
      expect(
        () => EncryptionService.deriveKeyFromSignature('0x${'ab' * 66}'),
        throwsArgumentError,
      );
      // Odd length must be rejected, not left-padded.
      expect(
        () => EncryptionService.deriveKeyFromSignature('0x${'ab' * 64}a'),
        throwsArgumentError,
      );
      // Right length, but not hex.
      expect(
        () => EncryptionService.deriveKeyFromSignature('0x${'zz' * 65}'),
        throwsArgumentError,
      );
    });

    test('rejects an all-zero signature', () {
      expect(
        () => EncryptionService.deriveKeyFromSignature('0x${'00' * 65}'),
        throwsArgumentError,
      );
    });
  });

  group('buildKeyDerivationMessage', () {
    test('binds the derivation to the signing account', () {
      const a = '0x1111111111111111111111111111111111111111';
      const b = '0x2222222222222222222222222222222222222222';
      final msgA = EncryptionService.buildKeyDerivationMessage(a);
      expect(msgA, contains(a));
      expect(msgA, isNot(equals(EncryptionService.buildKeyDerivationMessage(b))));
    });

    test('is case-insensitive in the address so checksum casing cannot fork the key',
        () {
      const lower = '0xabcdefabcdefabcdefabcdefabcdefabcdefabcd';
      final upper = lower.toUpperCase().replaceFirst('0X', '0x');
      expect(
        EncryptionService.buildKeyDerivationMessage(lower),
        equals(EncryptionService.buildKeyDerivationMessage(upper)),
      );
    });

    test('carries the version tag and an explicit warning', () {
      final msg = EncryptionService.buildKeyDerivationMessage(
        '0x1111111111111111111111111111111111111111',
      );
      expect(msg, contains(EncryptionService.keyDerivationVersion));
      expect(msg.toLowerCase(), contains('warning'));
    });
  });
}
