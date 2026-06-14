import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Non-web AES-256-GCM via PointyCastle (pure Dart). Used on mobile/desktop
/// and in unit tests running on the Dart VM. Returns `ciphertext || tag`.
Future<Uint8List> aesGcmEncrypt(
  Uint8List key,
  Uint8List nonce,
  Uint8List plaintext,
) async {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)),
    );
  return cipher.process(plaintext);
}

/// Decrypts `ciphertext || tag`. Throws if the GCM tag is invalid.
Future<Uint8List> aesGcmDecrypt(
  Uint8List key,
  Uint8List nonce,
  Uint8List ciphertextAndTag,
) async {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      false,
      AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)),
    );
  return cipher.process(ciphertextAndTag);
}
