import 'package:de_kyc/services/ipfs_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IpfsService.isValidCid', () {
    test('accepts real CIDv0 and CIDv1 strings', () {
      // CIDv0 (base58btc, "Qm…")
      expect(
        IpfsService.isValidCid('QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG'),
        isTrue,
      );
      // CIDv1 (base32, "b…") — the app uploads with cidVersion 1.
      expect(
        IpfsService.isValidCid(
            'bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi'),
        isTrue,
      );
    });

    test('rejects path-traversal and URL-injection attempts', () {
      const attacks = [
        '../../etc/passwd',
        'Qm/../secret',
        'cid with spaces',
        'cid?query=1',
        'cid#frag',
        'cid/extra/path',
        'http://evil.com/x',
        '..',
        '',
      ];
      for (final a in attacks) {
        expect(IpfsService.isValidCid(a), isFalse, reason: 'should reject "$a"');
      }
    });

    test('rejects absurdly short or long strings', () {
      expect(IpfsService.isValidCid('Qm'), isFalse);
      expect(IpfsService.isValidCid('a' * 200), isFalse);
    });

    test('gatewayUrl throws on a malformed CID', () {
      final svc = IpfsService();
      expect(() => svc.gatewayUrl('../evil'), throwsA(isA<IpfsException>()));
      svc.dispose();
    });
  });
}
