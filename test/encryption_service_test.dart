import 'dart:math';
import 'dart:typed_data';

import 'package:de_kyc/services/encryption_service.dart';
import 'package:flutter_test/flutter_test.dart';

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
      expect(cipher.length, greaterThan(plaintext.length));

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

    test('rejects a key of the wrong length', () async {
      final shortKey = Uint8List(16);
      await expectLater(
        service.encryptBytes(Uint8List(4), shortKey),
        throwsArgumentError,
      );
    });

    test('deriveKeyFromSignature is deterministic and 32 bytes', () {
      const sig = '0xdeadbeefcafebabe0011223344556677';
      final k1 = EncryptionService.deriveKeyFromSignature(sig);
      final k2 = EncryptionService.deriveKeyFromSignature(sig);
      expect(k1.length, 32);
      expect(k1, equals(k2));
      // A different signature yields a different key.
      final k3 = EncryptionService.deriveKeyFromSignature('0xabcabcabc0');
      expect(k3, isNot(equals(k1)));
    });
  });
}
