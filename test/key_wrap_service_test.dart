import 'dart:typed_data';

import 'package:de_kyc/services/key_wrap_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List secret32() =>
      Uint8List.fromList(List.generate(32, (i) => (i * 7 + 3) % 256));

  group('keypair generation', () {
    test('produces a 32-byte private key and a 33-byte compressed public key',
        () {
      final kp = KeyWrapService.generateKeyPair();
      expect(kp.privateKey.length, 32);
      expect(kp.publicKey.length, 33);
      // Compressed points start with 0x02 or 0x03.
      expect(kp.publicKey[0], anyOf(0x02, 0x03));
      expect(KeyWrapService.isValidPublicKey(kp.publicKey), isTrue);
    });

    test('is non-deterministic', () {
      final a = KeyWrapService.generateKeyPair();
      final b = KeyWrapService.generateKeyPair();
      expect(a.privateKey, isNot(equals(b.privateKey)));
      expect(a.publicKey, isNot(equals(b.publicKey)));
    });

    test('publicKeyFor re-derives the same public key', () {
      final kp = KeyWrapService.generateKeyPair();
      expect(KeyWrapService.publicKeyFor(kp.privateKey), equals(kp.publicKey));
    });

    test('rejects out-of-range private keys', () {
      expect(() => KeyWrapService.publicKeyFor(Uint8List(32)),
          throwsArgumentError); // zero
      expect(() => KeyWrapService.publicKeyFor(Uint8List(31)),
          throwsArgumentError); // wrong length
      // n and above are invalid scalars; 0xFF*32 is comfortably above n.
      expect(
        () => KeyWrapService.publicKeyFor(
            Uint8List.fromList(List.filled(32, 0xff))),
        throwsArgumentError,
      );
    });
  });

  group('public key validation', () {
    test('rejects malformed, off-curve and wrong-length points', () {
      expect(KeyWrapService.isValidPublicKey(Uint8List(33)), isFalse);
      expect(KeyWrapService.isValidPublicKey(Uint8List(32)), isFalse);
      // Right length and prefix, but x is genuinely not a curve point:
      // y² = 5³ + 7 = 132 has no square root mod p. (Note x = 1 IS on the
      // curve — roughly half of all x values are, so an arbitrary "looks
      // wrong" value does not test anything.)
      final offCurve = Uint8List(33)
        ..[0] = 0x02
        ..[32] = 0x05;
      expect(KeyWrapService.isValidPublicKey(offCurve), isFalse);

      // x at or above the field prime must also be rejected.
      final overPrime = Uint8List(33)
        ..[0] = 0x02
        ..fillRange(1, 33, 0xff);
      expect(KeyWrapService.isValidPublicKey(overPrime), isFalse);

      // Uncompressed prefix is not accepted.
      final uncompressed = Uint8List(33)..[0] = 0x04;
      expect(KeyWrapService.isValidPublicKey(uncompressed), isFalse);
    });
  });

  group('wrap / unwrap', () {
    test('round-trips a 32-byte AES key', () async {
      final recipient = KeyWrapService.generateKeyPair();
      final secret = secret32();

      final blob = await KeyWrapService.wrap(secret, recipient.publicKey);
      final back = await KeyWrapService.unwrap(blob, recipient.privateKey);
      expect(back, equals(secret));
    });

    test('the wrapped blob does not contain the secret', () async {
      final recipient = KeyWrapService.generateKeyPair();
      final secret = secret32();
      final blob = await KeyWrapService.wrap(secret, recipient.publicKey);

      // The whole point: the transported bytes must not reveal the key.
      final hexBlob = KeyWrapService.toHex(blob);
      expect(hexBlob.contains(KeyWrapService.toHex(secret)), isFalse);
    });

    test('has the documented wire layout', () async {
      final recipient = KeyWrapService.generateKeyPair();
      final blob = await KeyWrapService.wrap(secret32(), recipient.publicKey);
      // version(1) + ephemeral pub(33) + nonce(12) + ct(32) + tag(16)
      expect(blob.length, equals(1 + 33 + 12 + 32 + 16));
      expect(blob[0], equals(0x01));
      final ephemeral = blob.sublist(1, 34);
      expect(KeyWrapService.isValidPublicKey(ephemeral), isTrue);
    });

    test('is non-deterministic — fresh ephemeral key and nonce each time',
        () async {
      final recipient = KeyWrapService.generateKeyPair();
      final secret = secret32();
      final a = await KeyWrapService.wrap(secret, recipient.publicKey);
      final b = await KeyWrapService.wrap(secret, recipient.publicKey);
      expect(a, isNot(equals(b)));
      // ...and both still decrypt.
      expect(await KeyWrapService.unwrap(a, recipient.privateKey),
          equals(secret));
      expect(await KeyWrapService.unwrap(b, recipient.privateKey),
          equals(secret));
    });

    test('the WRONG recipient cannot unwrap it', () async {
      final recipient = KeyWrapService.generateKeyPair();
      final eavesdropper = KeyWrapService.generateKeyPair();
      final blob = await KeyWrapService.wrap(secret32(), recipient.publicKey);

      await expectLater(
        KeyWrapService.unwrap(blob, eavesdropper.privateKey),
        throwsA(anything),
      );
    });

    test('a tampered blob fails the GCM tag', () async {
      final recipient = KeyWrapService.generateKeyPair();
      final blob = await KeyWrapService.wrap(secret32(), recipient.publicKey);

      // Flip a bit in the ciphertext body.
      final tampered = Uint8List.fromList(blob);
      tampered[50] ^= 0x01;
      await expectLater(
        KeyWrapService.unwrap(tampered, recipient.privateKey),
        throwsA(anything),
      );
    });

    test('swapping in a different ephemeral point fails', () async {
      final recipient = KeyWrapService.generateKeyPair();
      final other = KeyWrapService.generateKeyPair();
      final blob = await KeyWrapService.wrap(secret32(), recipient.publicKey);

      // Replace the ephemeral public key with a valid but unrelated point —
      // the derived AES key changes, so the tag must reject it.
      final swapped = Uint8List.fromList(blob);
      swapped.setRange(1, 34, other.publicKey);
      await expectLater(
        KeyWrapService.unwrap(swapped, recipient.privateKey),
        throwsA(anything),
      );
    });

    test('refuses to wrap to an invalid public key', () async {
      await expectLater(
        KeyWrapService.wrap(secret32(), Uint8List(33)),
        throwsArgumentError,
      );
    });

    test('rejects truncated blobs and unknown versions', () async {
      final recipient = KeyWrapService.generateKeyPair();
      final blob = await KeyWrapService.wrap(secret32(), recipient.publicKey);

      await expectLater(
        KeyWrapService.unwrap(blob.sublist(0, 40), recipient.privateKey),
        throwsArgumentError,
      );

      final badVersion = Uint8List.fromList(blob)..[0] = 0x02;
      await expectLater(
        KeyWrapService.unwrap(badVersion, recipient.privateKey),
        throwsArgumentError,
      );
    });
  });

  group('hex helpers', () {
    test('round-trip, tolerating 0x prefix and whitespace', () {
      final kp = KeyWrapService.generateKeyPair();
      final hex = kp.publicKeyHex;
      expect(KeyWrapService.fromHex(hex), equals(kp.publicKey));
      expect(KeyWrapService.fromHex('0x$hex'), equals(kp.publicKey));
      expect(KeyWrapService.fromHex('  $hex \n'), equals(kp.publicKey));
    });

    test('rejects odd-length and non-hex input', () {
      expect(() => KeyWrapService.fromHex('abc'), throwsArgumentError);
      expect(() => KeyWrapService.fromHex('zzzz'), throwsArgumentError);
      expect(() => KeyWrapService.fromHex(''), throwsArgumentError);
    });
  });
}
