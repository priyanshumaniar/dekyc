import 'dart:convert';
import 'dart:typed_data';

import 'package:de_kyc/services/auth_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web3dart/crypto.dart';
import 'package:web3dart/web3dart.dart';

void main() {
  // Well-known Hardhat test keys — NEVER hold funds on these.
  final keyA = EthPrivateKey.fromHex(
      '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d');
  final keyB = EthPrivateKey.fromHex(
      '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a');

  String signPersonal(EthPrivateKey key, String message) {
    final sig = key.signPersonalMessageToUint8List(
        Uint8List.fromList(utf8.encode(message)));
    return '0x${bytesToHex(sig)}';
  }

  group('AuthService.recoverPersonalSigner', () {
    test('recovers the address that signed the message', () {
      const message = 'DeKYC auth test message';
      final sigHex = signPersonal(keyA, message);
      final recovered = AuthService.recoverPersonalSigner(message, sigHex);
      expect(recovered.toLowerCase(), keyA.address.hex.toLowerCase());
    });

    test('a different key does NOT recover to the same address', () {
      const message = 'DeKYC auth test message';
      final sigHex = signPersonal(keyB, message);
      final recovered = AuthService.recoverPersonalSigner(message, sigHex);
      expect(recovered.toLowerCase(),
          isNot(equals(keyA.address.hex.toLowerCase())));
    });

    test('a tampered message breaks recovery (different address)', () {
      const message = 'Role: Individual';
      final sigHex = signPersonal(keyA, message);
      final recovered = AuthService.recoverPersonalSigner(
          'Role: Verifier', sigHex); // attacker edits the role
      expect(recovered.toLowerCase(),
          isNot(equals(keyA.address.hex.toLowerCase())));
    });

    test('rejects malformed signatures', () {
      expect(
        () => AuthService.recoverPersonalSigner('msg', '0xdeadbeef'),
        throwsArgumentError,
      );
    });

    test('uses the BYTE length, not the character length, in the EIP-191 prefix',
        () {
      // The prefix is "\x19Ethereum Signed Message:\n<len>". `len` must be the
      // UTF-8 BYTE count. With an ASCII-only test corpus the two are identical,
      // so `message.length` would pass every other test here while breaking
      // recovery for any user whose signed text contains a non-ASCII character
      // — and the sign-in message is user-facing prose.
      const message = 'Rôle: Vérifier — çhars ☃ 🚀';
      expect(message.length, isNot(equals(utf8.encode(message).length)));

      final sigHex = signPersonal(keyA, message);
      expect(
        AuthService.recoverPersonalSigner(message, sigHex).toLowerCase(),
        equals(keyA.address.hex.toLowerCase()),
      );
    });

    test('normalises a v byte of 0/1 to 27/28', () {
      // web3dart always emits v as 27/28, so this branch of
      // recoverPersonalSigner is unreachable from the other tests. Some wallets
      // return the raw recovery id instead; rewrite v to prove we handle it.
      const message = 'DeKYC auth test message';
      final sigHex = signPersonal(keyA, message);
      final bytes = hexToBytes(sigHex.substring(2));
      expect(bytes[64], anyOf(27, 28)); // precondition

      bytes[64] -= 27; // 27/28 -> 0/1, as some wallets report it
      final rawV = '0x${bytesToHex(bytes)}';

      expect(
        AuthService.recoverPersonalSigner(message, rawV).toLowerCase(),
        equals(keyA.address.hex.toLowerCase()),
      );
    });

    test('a signature over a DIFFERENT expiry does not recover to the signer',
        () {
      // The tamper-evidence property the README claims: editing any field of a
      // stored session breaks the signature.
      final issued = DateTime.utc(2026, 6, 11, 12);
      String msg(Duration life) => AuthService.buildSignInMessage(
            address: keyA.address.hex,
            role: UserRole.individual,
            nonce: 'abc123',
            issuedAt: issued,
            expiresAt: issued.add(life),
          );

      final sigHex = signPersonal(keyA, msg(const Duration(hours: 24)));
      // Attacker extends the session to a year.
      final recovered = AuthService.recoverPersonalSigner(
          msg(const Duration(days: 365)), sigHex);
      expect(recovered.toLowerCase(),
          isNot(equals(keyA.address.hex.toLowerCase())));
    });
  });

  group('AuthService.buildSignInMessage', () {
    test('embeds address, role, nonce and expiry in the signed text', () {
      final issued = DateTime.utc(2026, 6, 11, 12);
      final expires = issued.add(const Duration(hours: 24));
      final msg = AuthService.buildSignInMessage(
        address: '0x70997970C51812dc3A010C7d01b50e0d17dc79C8',
        role: UserRole.verifier,
        nonce: 'abc123',
        issuedAt: issued,
        expiresAt: expires,
      );
      expect(msg, contains('0x70997970C51812dc3A010C7d01b50e0d17dc79C8'));
      expect(msg, contains('Role: Verifier'));
      expect(msg, contains('Nonce: abc123'));
      expect(msg, contains('Expires At: ${expires.toIso8601String()}'));
      expect(msg, contains('eip155:11155111'));
    });

    test('session round-trips through JSON', () {
      final s = AuthSession(
        address: '0xAbC',
        role: UserRole.individual,
        nonce: 'n0nce',
        issuedAt: DateTime.utc(2026, 6, 11),
        expiresAt: DateTime.utc(2026, 6, 12),
        signature: '0xsig',
      );
      final back = AuthSession.fromJson(
          jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(back.address, s.address);
      expect(back.role, s.role);
      expect(back.nonce, s.nonce);
      expect(back.issuedAt, s.issuedAt);
      expect(back.expiresAt, s.expiresAt);
      expect(back.signature, s.signature);
    });
  });
}
