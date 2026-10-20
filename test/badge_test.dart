import 'dart:convert';
import 'dart:io';

import 'package:de_kyc/services/badge.dart';
import 'package:de_kyc/services/sbt_contract_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:web3dart/crypto.dart' show bytesToHex, keccakUtf8;
import 'package:web3dart/web3dart.dart';

/// Raw `eth_call` return data captured from the REAL contract on a local
/// Hardhat chain: issuer A attested the user at T0 for a year; issuer B
/// attested at T0+100 for 30 days, then revoked at T0+200. Decoding these
/// bytes with the ABI the app ships proves the Dart side reads the new
/// `BadgeView` structs exactly as Solidity encodes them.
const _t0 = 1900000000;
const _issuerA = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266';
const _issuerB = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8';
const _user = '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC';
const _contract = '0x5FbDB2315678afecb367f032d93F642f64180aa3';

const _subjectIssuerCount = '0x0000000000000000000000000000000000000000000000000000000000000002';
const _badgesOf = '0x000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000001000000000000000000000000f39fd6e51aad88f6f4ce6ab8827279cfffb922660000000000000000000000003c44cdddb6a900fa2b585dd299e03d12fa4293bc00000000000000000000000000000000000000000000000000000000713fb300000000000000000000000000000000000000000000000000000000007320e68000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200000000000000000000000070997970c51812dc3a010c7d01b50e0d17dc79c80000000000000000000000003c44cdddb6a900fa2b585dd299e03d12fa4293bc00000000000000000000000000000000000000000000000000000000713fb364000000000000000000000000000000000000000000000000000000007167406400000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000';
const _badgeForA = '0x0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000f39fd6e51aad88f6f4ce6ab8827279cfffb922660000000000000000000000003c44cdddb6a900fa2b585dd299e03d12fa4293bc00000000000000000000000000000000000000000000000000000000713fb300000000000000000000000000000000000000000000000000000000007320e68000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001';
const _badgeForNone = '0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000';
const _issuerSubjectCountA = '0x0000000000000000000000000000000000000000000000000000000000000001';
const _badgesIssuedByA = '0x000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000f39fd6e51aad88f6f4ce6ab8827279cfffb922660000000000000000000000003c44cdddb6a900fa2b585dd299e03d12fa4293bc00000000000000000000000000000000000000000000000000000000713fb300000000000000000000000000000000000000000000000000000000007320e68000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001';

String _sel(String signature) =>
    bytesToHex(keccakUtf8(signature).sublist(0, 4));

/// A fake RPC node answering eth_call from the fixtures above.
http.Client _fakeNode() => MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final call = (body['params'] as List).first as Map<String, dynamic>;
      final data = (call['data'] ?? call['input']) as String;
      final hex = data.toLowerCase().replaceFirst('0x', '');
      final sel = hex.substring(0, 8);
      final firstArg = hex.substring(8 + 24, 8 + 64);
      String result;
      if (sel == _sel('subjectIssuerCount(address)')) {
        result = _subjectIssuerCount;
      } else if (sel == _sel('badgesOf(address,uint256,uint256)')) {
        result = _badgesOf;
      } else if (sel == _sel('badgeFor(address,address)')) {
        result = firstArg == _issuerA.substring(2).toLowerCase()
            ? _badgeForA
            : _badgeForNone;
      } else if (sel == _sel('issuerSubjectCount(address)')) {
        result = _issuerSubjectCountA;
      } else if (sel == _sel('badgesIssuedBy(address,uint256,uint256)')) {
        result = _badgesIssuedByA;
      } else {
        return http.Response('unexpected selector $sel', 500);
      }
      return http.Response(
        jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

DateTime _at(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000);

void main() {
  late SbtContractService sbt;

  setUp(() {
    // The real ABI the app ships, so a stale asset fails here.
    final abi =
        File('assets/contracts/KYCSoulboundToken.abi.json').readAsStringSync();
    sbt = SbtContractService.fromAbiString(
      abi,
      address: _contract,
      client: Web3Client('http://fake-node', _fakeNode()),
    );
  });

  group('SbtContractService badge lists (real contract bytes)', () {
    test('badgesOf decodes every issuer row with dates and flags', () async {
      final rows = await sbt.badgesOf(EthereumAddress.fromHex(_user));
      expect(rows.length, 2);

      final a = rows[0];
      expect(a.tokenId, 1);
      expect(a.issuer.hexEip55, EthereumAddress.fromHex(_issuerA).hexEip55);
      expect(a.subject.hexEip55, EthereumAddress.fromHex(_user).hexEip55);
      expect(a.issuedAt, _at(_t0));
      expect(a.expiresAt, _at(_t0 + 365 * 86400));
      expect(a.revoked, isFalse);
      expect(a.validOnChain, isTrue);

      final b = rows[1];
      expect(b.tokenId, 2);
      expect(b.issuer.hexEip55, EthereumAddress.fromHex(_issuerB).hexEip55);
      expect(b.issuedAt, _at(_t0 + 100));
      expect(b.revoked, isTrue);
      expect(b.validOnChain, isFalse);
      expect(b.statusAt(_at(_t0 + 300)), BadgeStatus.revoked);
    });

    test("badgeFor returns the issuer's badge, or null for none", () async {
      final mine = await sbt.badgeFor(
          EthereumAddress.fromHex(_issuerA), EthereumAddress.fromHex(_user));
      expect(mine, isNotNull);
      expect(mine!.tokenId, 1);
      expect(mine.statusAt(_at(_t0 + 300)), BadgeStatus.valid);

      final none = await sbt.badgeFor(
          EthereumAddress.fromHex(_user), EthereumAddress.fromHex(_issuerA));
      expect(none, isNull);
    });

    test('badgesIssuedBy lists what an issuer gave out', () async {
      final given =
          await sbt.badgesIssuedBy(EthereumAddress.fromHex(_issuerA));
      expect(given.length, 1);
      expect(given.single.subject.hexEip55, EthereumAddress.fromHex(_user).hexEip55);
      expect(given.single.issuer.hexEip55, EthereumAddress.fromHex(_issuerA).hexEip55);
    });
  });

  group('KycBadge status', () {
    KycBadge badge({
      required DateTime expires,
      bool revoked = false,
      bool validOnChain = true,
    }) =>
        KycBadge(
          tokenId: 7,
          issuer: EthereumAddress.fromHex(_issuerA),
          subject: EthereumAddress.fromHex(_user),
          issuedAt: DateTime(2026, 8, 6),
          expiresAt: expires,
          revoked: revoked,
          validOnChain: validOnChain,
        );
    final now = DateTime(2026, 10, 20);

    test('valid well before expiry', () {
      expect(badge(expires: DateTime(2027, 8, 6)).statusAt(now),
          BadgeStatus.valid);
    });

    test('expiring soon inside 30 days', () {
      expect(badge(expires: DateTime(2026, 11, 10)).statusAt(now),
          BadgeStatus.expiringSoon);
    });

    test('expired once the date has passed', () {
      expect(badge(expires: DateTime(2026, 10, 1)).statusAt(now),
          BadgeStatus.expired);
    });

    test('the chain saying "not valid" wins over the local clock', () {
      expect(
          badge(expires: DateTime(2027, 8, 6), validOnChain: false)
              .statusAt(now),
          BadgeStatus.expired);
    });

    test('revoked wins over everything', () {
      expect(badge(expires: DateTime(2027, 8, 6), revoked: true).statusAt(now),
          BadgeStatus.revoked);
    });

    test('issuedBy ignores address casing', () {
      expect(badge(expires: DateTime(2027)).issuedBy(_issuerA.toLowerCase()),
          isTrue);
      expect(badge(expires: DateTime(2027)).issuedBy(_issuerB), isFalse);
    });
  });

  test('formatBadgeDate reads like a person writes it', () {
    expect(formatBadgeDate(DateTime(2027, 8, 6)), '6 Aug 2027');
    expect(formatBadgeDate(DateTime(2026, 12, 25)), '25 Dec 2026');
  });

  test('sortNewestFirst puts the latest verification on top', () {
    KycBadge at(DateTime d, int id) => KycBadge(
          tokenId: id,
          issuer: EthereumAddress.fromHex(_issuerA),
          subject: EthereumAddress.fromHex(_user),
          issuedAt: d,
          expiresAt: d.add(const Duration(days: 365)),
          revoked: false,
          validOnChain: true,
        );
    final sorted = sortNewestFirst(
        [at(DateTime(2026, 1, 1), 1), at(DateTime(2026, 9, 1), 2)]);
    expect(sorted.map((b) => b.tokenId), [2, 1]);
  });

  test('badgeStatusLabel covers every status', () {
    expect(BadgeStatus.values.map(badgeStatusLabel),
        ['Valid', 'Expiring soon', 'Expired', 'Revoked']);
  });
}
