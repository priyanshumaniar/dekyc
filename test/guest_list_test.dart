import 'package:de_kyc/services/guest_list.dart';
import 'package:de_kyc/services/kyc_contract_service.dart' show VerifierGrant;
import 'package:flutter_test/flutter_test.dart';
import 'package:web3dart/web3dart.dart' show EthereumAddress;

VerifierGrant grant(String address, {bool live = true}) => VerifierGrant(
      verifier: EthereumAddress.fromHex(address),
      expiresAt: DateTime.now().add(const Duration(days: 7)),
      grantedVersion: 1,
      live: live,
    );

void main() {
  const a = '0x1111111111111111111111111111111111111111';
  const b = '0x2222222222222222222222222222222222222222';
  // Mixed casing on purpose — a real paste from Etherscan is checksummed.
  const cLower = '0xabcdefabcdefabcdefabcdefabcdefabcdefabcd';

  group('GuestList.merge', () {
    test('a pending address SURVIVES a chain sync that does not know it', () {
      // The regression: adding an address and syncing wiped the row about a
      // second later, because a not-yet-granted address has no on-chain entry.
      final merged = GuestList.merge(chain: const [], pending: [a]);
      expect(merged.rows, equals([GuestList.canon(a)]));
      expect(merged.pending, equals({GuestList.canon(a)}));
    });

    test('chain rows and pending additions both appear, chain first', () {
      final merged = GuestList.merge(chain: [grant(a)], pending: [b]);
      expect(merged.rows, equals([GuestList.canon(a), GuestList.canon(b)]));
      expect(merged.pending, equals({GuestList.canon(b)}));
    });

    test('a pending address is PROMOTED once it appears on-chain', () {
      // After granting, the address must stop being pending rather than being
      // listed twice.
      final merged = GuestList.merge(chain: [grant(a)], pending: [a]);
      expect(merged.rows, equals([GuestList.canon(a)]));
      expect(merged.pending, isEmpty);
    });

    test('casing never produces a duplicate row', () {
      // grantsOf returns checksummed; the user may paste lowercase. Comparing
      // raw strings would show the same verifier twice, one of them forever
      // "status unknown".
      final checksummed = GuestList.canon(cLower);
      expect(checksummed, isNot(equals(cLower))); // precondition

      final merged =
          GuestList.merge(chain: [grant(checksummed)], pending: [cLower]);
      expect(merged.rows.length, equals(1));
      expect(merged.rows.single, equals(checksummed));
      expect(merged.pending, isEmpty);
    });

    test('duplicate pending entries collapse', () {
      final merged =
          GuestList.merge(chain: const [], pending: [a, a, a.toLowerCase()]);
      expect(merged.rows.length, equals(1));
    });

    test('duplicate chain rows collapse', () {
      final merged =
          GuestList.merge(chain: [grant(a), grant(a)], pending: const []);
      expect(merged.rows.length, equals(1));
    });

    test('a revoked (not live) row still shows — it is history, not absence',
        () {
      final merged =
          GuestList.merge(chain: [grant(a, live: false)], pending: const []);
      expect(merged.rows, equals([GuestList.canon(a)]));
    });

    test('empty in, empty out', () {
      final merged = GuestList.merge(chain: const [], pending: const []);
      expect(merged.rows, isEmpty);
      expect(merged.pending, isEmpty);
    });

    test('order is stable across repeated merges', () {
      final first = GuestList.merge(chain: [grant(a)], pending: [b, cLower]);
      final second =
          GuestList.merge(chain: [grant(a)], pending: first.pending);
      expect(second.rows, equals(first.rows));
    });
  });

  group('GuestList.canon', () {
    test('normalises casing and tolerates surrounding whitespace', () {
      final want = GuestList.canon(a);
      expect(GuestList.canon(a.toLowerCase()), equals(want));
      expect(GuestList.canon(a.toUpperCase().replaceFirst('0X', '0x')),
          equals(want));
      expect(GuestList.canon('  $a  '), equals(want));
    });

    test('rejects a malformed address', () {
      expect(() => GuestList.canon('0xnope'), throwsA(anything));
    });
  });
}
