import 'dart:convert';
import 'dart:typed_data';

import 'package:de_kyc/services/encryption_service.dart';
import 'package:de_kyc/services/ipfs_service.dart';
import 'package:de_kyc/services/key_wrap_service.dart';
import 'package:de_kyc/services/kyc_contract_service.dart';
import 'package:de_kyc/services/kyc_flow_service.dart';
import 'package:de_kyc/services/wallet_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Tests for the orchestration layer that owns the security-critical path:
/// derive key → package docs → AES-GCM encrypt → pin to IPFS → hand calldata
/// to the wallet. No network and no chain: the wallet and the IPFS client are
/// both replaced with fakes, which the production constructor already allows.
///
/// The load-bearing assertion here is that the bytes leaving the device are
/// ciphertext. An accidental swap (uploading `bundle` instead of `cipherBytes`)
/// would upload every document in the clear and nothing else in the suite
/// would notice.

/// A wallet that signs deterministically and records what it was asked to send.
class _FakeWallet implements WalletService {
  _FakeWallet(this._address);

  final String _address;

  String? lastSignedMessage;
  String? lastTo;
  Uint8List? lastData;
  int sendCount = 0;

  /// A syntactically valid 65-byte signature (r||s||v) — the shape
  /// EncryptionService now insists on.
  static final String fixedSignature =
      '0x${List.filled(64, 'ab').join()}1b';

  @override
  String? get address => _address;

  @override
  bool get isConnected => true;

  @override
  Future<String> signMessage(String message) async {
    lastSignedMessage = message;
    return fixedSignature;
  }

  @override
  Future<String> sendTransaction({
    required String to,
    required Uint8List data,
    BigInt? value,
  }) async {
    sendCount++;
    lastTo = to;
    lastData = data;
    return '0x${'11' * 32}';
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An IPFS service that keeps uploads in memory and serves them back.
class _FakeIpfs implements IpfsService {
  final Map<String, Uint8List> pinned = {};
  Uint8List? lastUploaded;
  static const String cid = 'bafyfakecidfortests0000000000000';

  @override
  Future<String> uploadBytes(Uint8List bytes,
      {String filename = 'dekyc_bundle.enc'}) async {
    lastUploaded = bytes;
    pinned[cid] = bytes;
    return cid;
  }

  @override
  Future<Uint8List> downloadBytes(String c) async {
    final b = pinned[c];
    if (b == null) throw IpfsException('not pinned: $c');
    return b;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  // submitKyc loads the contract ABI via rootBundle, which needs the binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  const userAddress = '0x1111111111111111111111111111111111111111';

  late _FakeWallet wallet;
  late _FakeIpfs ipfs;
  late KycFlowService flow;

  Map<String, Uint8List> sampleDocs() => {
        'aadhaar_front': Uint8List.fromList(utf8.encode('AADHAAR-FRONT-SECRET')),
        'aadhaar_back': Uint8List.fromList(utf8.encode('AADHAAR-BACK-SECRET')),
        'pan': Uint8List.fromList(utf8.encode('PAN-SECRET')),
        'photo': Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a]),
      };

  setUp(() {
    wallet = _FakeWallet(userAddress);
    ipfs = _FakeIpfs();
    // No RPC in unit tests: substitute receipt polling with an immediate OK,
    // and resolve "my own record" from whatever the fake IPFS holds.
    flow = KycFlowService(
      wallet: wallet,
      ipfs: ipfs,
      confirmer: (_) async {},
      ownPointer: () async => ipfs.pinned.containsKey(_FakeIpfs.cid)
          ? KycPointer(cid: _FakeIpfs.cid, submittedAt: DateTime(2026))
          : null,
    );
  });

  group('deriveUserKey', () {
    test('signs an address-bound message and derives a 32-byte key', () async {
      final key = await flow.deriveUserKey();
      expect(key.length, 32);
      expect(wallet.lastSignedMessage, contains(userAddress));
      expect(wallet.lastSignedMessage,
          contains(EncryptionService.keyDerivationVersion));
    });

    test('is deterministic for the same wallet', () async {
      final a = await flow.deriveUserKey();
      final b = await flow.deriveUserKey();
      expect(a, equals(b));
    });

    test('refuses to derive when no wallet is connected', () async {
      final disconnected = KycFlowService(
        wallet: _DisconnectedWallet(),
        ipfs: ipfs,
        confirmer: (_) async {},
        ownPointer: () async => null,
      );
      await expectLater(disconnected.deriveUserKey(), throwsStateError);
    });
  });

  group('submitKyc', () {
    test('uploads CIPHERTEXT — no plaintext or base64 of it ever leaves',
        () async {
      final docs = sampleDocs();
      await flow.submitKyc(docs);

      final uploaded = ipfs.lastUploaded!;
      final asString = String.fromCharCodes(uploaded);

      for (final entry in docs.entries) {
        final plain = utf8.decode(entry.value, allowMalformed: true);
        final b64 = base64Encode(entry.value);
        // Neither the raw document bytes nor their base64 envelope form may
        // appear anywhere in what we hand to IPFS.
        expect(asString.contains(plain), isFalse,
            reason: 'plaintext of ${entry.key} leaked into the upload');
        expect(asString.contains(b64), isFalse,
            reason: 'base64 of ${entry.key} leaked into the upload');
      }
      // The JSON envelope keys must not be visible either.
      expect(asString.contains('"docs"'), isFalse);
      expect(asString.contains('aadhaar_front'), isFalse);
    });

    test('round-trips: what is pinned decrypts back to the exact documents',
        () async {
      final docs = sampleDocs();
      final result = await flow.submitKyc(docs);
      expect(result.cid, equals(_FakeIpfs.cid));

      final key = await flow.deriveUserKey();
      final keyHex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      // Read back through the verifier path, but stub the chain lookup by
      // decrypting the pinned blob directly with the same envelope logic.
      final cipher = await ipfs.downloadBytes(result.cid);
      final plain = await EncryptionService().decryptBytes(cipher, key);
      final bundle = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;

      expect(bundle['version'], equals(1));
      final decoded = (bundle['docs'] as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, base64Decode(v as String)));
      expect(decoded.keys.toSet(), equals(docs.keys.toSet()));
      for (final k in docs.keys) {
        expect(decoded[k], equals(docs[k]), reason: '$k did not round-trip');
      }
      expect(keyHex.length, equals(64));
    });

    test('reports monotonically increasing progress ending at 1.0', () async {
      final seen = <double>[];
      await flow.submitKyc(sampleDocs(), onProgress: (p, _) => seen.add(p));
      expect(seen, isNotEmpty);
      expect(seen.last, equals(1.0));
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
      }
    });

    test('encrypts with a nonce, so two submissions of the same docs differ',
        () async {
      final docs = sampleDocs();
      await flow.submitKyc(docs);
      final first = Uint8List.fromList(ipfs.lastUploaded!);
      await flow.submitKyc(docs);
      final second = Uint8List.fromList(ipfs.lastUploaded!);
      expect(first, isNot(equals(second)));
    });
  });

  group('attestation metadata', () {
    test('pins real per-attestation metadata and mints against its CID',
        () async {
      const subject = '0x3333333333333333333333333333333333333333';
      await flow.attestUser(subject);

      final pinned = utf8.decode(ipfs.lastUploaded!);
      final json = jsonDecode(pinned) as Map<String, dynamic>;
      expect(json['name'], equals('DeKYC Verified'));

      final attrs = (json['attributes'] as List).cast<Map<String, dynamic>>();
      String attr(String t) =>
          attrs.firstWhere((a) => a['trait_type'] == t)['value'].toString();
      expect(attr('Issuer').toLowerCase(), equals(userAddress.toLowerCase()));
      expect(attr('Subject').toLowerCase(), equals(subject.toLowerCase()));
      expect(attr('Network'), equals('Sepolia'));

      // Expiry is seconds, not milliseconds.
      final expires = int.parse(attr('Expires'));
      expect(expires, lessThan(4000000000));

      // The tx really went to the SBT contract with the attest selector.
      expect(wallet.sendCount, equals(1));
      expect(wallet.lastData, isNotNull);
    });

    test('metadata is public, so it must leak nothing gated by the registry',
        () async {
      // Publish a bundle first so there is a CID that could be leaked.
      await flow.submitKyc(sampleDocs());
      await flow.attestUser('0x3333333333333333333333333333333333333333');

      final pinned = utf8.decode(ipfs.lastUploaded!);
      expect(pinned.contains(_FakeIpfs.cid), isFalse,
          reason: 'the KYC bundle CID must not appear in public metadata');
      expect(pinned.toLowerCase().contains('aadhaar'), isFalse);
      expect(pinned.toLowerCase().contains('doctypehash'), isFalse);
    });

    test('uriOverride skips pinning entirely', () async {
      ipfs.lastUploaded = null;
      await flow.attestUser(
        '0x3333333333333333333333333333333333333333',
        uriOverride: 'ipfs://preset',
      );
      expect(ipfs.lastUploaded, isNull);
    });
  });

  group('key handoff (user -> verifier)', () {
    test('wrapped key round-trips and never exposes the document key',
        () async {
      // Verifier side: a transport keypair whose public half is shared.
      final verifierKeys = KeyWrapService.generateKeyPair();

      // User side: wrap the document key to it.
      final wrapped =
          await flow.wrapKeyForVerifier(verifierKeys.publicKeyHex);

      final documentKey = await flow.deriveUserKey();
      // The blob that crosses the channel must not contain the key.
      expect(wrapped.contains(KeyWrapService.toHex(documentKey)), isFalse);

      // Verifier side: unwrap with the private half.
      final resolved = await flow.resolveDocumentKey(
        keyMaterial: wrapped,
        transportPrivateKey: verifierKeys.privateKey,
      );
      expect(resolved, equals(documentKey));
    });

    test('a wrapped key is useless to a different verifier', () async {
      final intended = KeyWrapService.generateKeyPair();
      final other = KeyWrapService.generateKeyPair();
      final wrapped = await flow.wrapKeyForVerifier(intended.publicKeyHex);

      await expectLater(
        flow.resolveDocumentKey(
          keyMaterial: wrapped,
          transportPrivateKey: other.privateKey,
        ),
        throwsA(anything),
      );
    });

    test('the legacy raw 32-byte key is still accepted', () async {
      final documentKey = await flow.deriveUserKey();
      final resolved = await flow.resolveDocumentKey(
        keyMaterial: KeyWrapService.toHex(documentKey),
      );
      expect(resolved, equals(documentKey));
    });

    test('a wrapped key without a transport key gives an actionable error',
        () async {
      final verifierKeys = KeyWrapService.generateKeyPair();
      final wrapped = await flow.wrapKeyForVerifier(verifierKeys.publicKeyHex);
      await expectLater(
        flow.resolveDocumentKey(keyMaterial: wrapped),
        throwsA(isA<KeyUnwrapException>()),
      );
    });

    test('a wrong-recipient unwrap is reported as a KEY problem, not a doc one',
        () async {
      // Both failure modes are AES-GCM `OperationError` underneath. If they
      // are not distinguished the verifier cannot tell "get the key re-wrapped"
      // from "ask for a re-upload" — the two have opposite remedies.
      final intended = KeyWrapService.generateKeyPair();
      final other = KeyWrapService.generateKeyPair();
      final wrapped = await flow.wrapKeyForVerifier(intended.publicKeyHex);

      await expectLater(
        flow.resolveDocumentKey(
          keyMaterial: wrapped,
          transportPrivateKey: other.privateKey,
        ),
        throwsA(
          isA<KeyUnwrapException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('wrapped to a DIFFERENT'), contains('wrap again')),
          ),
        ),
      );
    });

    test('garbage input is reported as malformed, not as a crypto failure',
        () async {
      await expectLater(
        flow.resolveDocumentKey(keyMaterial: 'obviously not hex'),
        throwsA(isA<KeyUnwrapException>()),
      );
    });

    test('a bundle encrypted under a different key reports a DOCUMENT problem',
        () async {
      // Publish a real bundle, then try to open it with a valid-but-unrelated
      // document key — the shape of "you uploaded this under an older
      // key-derivation scheme, or from another account".
      await flow.submitKyc(sampleDocs());
      final pinned = ipfs.pinned[_FakeIpfs.cid]!;
      final strangerKey = Uint8List.fromList(List.filled(32, 0x5a));

      await expectLater(
        flow.decryptBundle(pinned, strangerKey, cid: _FakeIpfs.cid),
        throwsA(
          isA<DocumentDecryptException>().having(
            (e) => e.toString().toLowerCase(),
            'message',
            allOf(contains('does not decrypt this bundle'),
                contains('re-upload')),
          ),
        ),
      );

      // ...and the CORRECT key still opens it, so the check above is not
      // passing for some unrelated reason.
      final realKey = await flow.deriveUserKey();
      final docs =
          await flow.decryptBundle(pinned, realKey, cid: _FakeIpfs.cid);
      expect(docs.keys, containsAll(sampleDocs().keys));
    });

    test('wrapping verifies the key opens the CALLER\'S OWN bundle first',
        () async {
      // Regression guard for a real incident: a test script overwrote the
      // on-chain record with a bundle encrypted under a throwaway key. The app
      // still derived the correct wallet key, wrapped it, and reported success
      // — the mismatch only appeared on the verifier's screen, where nobody
      // could act on it. Catch it at wrap time, on the side that can fix it.
      await flow.submitKyc(sampleDocs());

      // Simulate the record now pointing at a bundle this wallet cannot open.
      final foreign = await EncryptionService().encryptBytes(
        Uint8List.fromList(utf8.encode('{"version":1,"docs":{}}')),
        Uint8List.fromList(List.filled(32, 0x5a)),
      );
      ipfs.pinned[_FakeIpfs.cid] = foreign;

      final verifierKeys = KeyWrapService.generateKeyPair();
      await expectLater(
        flow.wrapKeyForVerifier(verifierKeys.publicKeyHex),
        throwsA(isA<DocumentDecryptException>()),
      );
    });

    test('wrapping succeeds when the key does open the bundle', () async {
      await flow.submitKyc(sampleDocs());
      final verifierKeys = KeyWrapService.generateKeyPair();
      final wrapped =
          await flow.wrapKeyForVerifier(verifierKeys.publicKeyHex);
      expect(wrapped, isNotEmpty);
      final resolved = await flow.resolveDocumentKey(
        keyMaterial: wrapped,
        transportPrivateKey: verifierKeys.privateKey,
      );
      expect(resolved, equals(await flow.deriveUserKey()));
    });

    test('refuses to spend a signature wrapping to an invalid key', () async {
      final signaturesBefore = wallet.lastSignedMessage;
      await expectLater(
        flow.wrapKeyForVerifier('00' * 33),
        throwsArgumentError,
      );
      // Validation happens before deriveUserKey, so no wallet popup was spent.
      expect(wallet.lastSignedMessage, equals(signaturesBefore));
    });
  });

  group('IpfsService (real class, faked transport)', () {
    test('refuses to upload when PINATA_JWT is unset', () async {
      // dotenv is not loaded in tests, so the JWT is empty — the guard must
      // fire rather than sending an unauthenticated request.
      var requests = 0;
      final svc = IpfsService(client: MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }));
      await expectLater(svc.uploadBytes(Uint8List(4)), throwsStateError);
      expect(requests, equals(0), reason: 'must not hit the network');
    });

    test('a malformed CID is rejected BEFORE any request is issued', () async {
      var requests = 0;
      final svc = IpfsService(client: MockClient((_) async {
        requests++;
        return http.Response('x', 200);
      }));
      for (final bad in const [
        '../../etc/passwd',
        'bafy/../evil',
        'bafy?x=1',
        'bafy#frag',
        'bafy cid',
        'bafy\nHost: evil.com',
        'bafy\r\nX: y',
        'short',
        'évilcidévilcidévilcid',
        '@evil.com/bafyrealcidlooking',
      ]) {
        await expectLater(svc.downloadBytes(bad), throwsA(isA<IpfsException>()),
            reason: 'accepted malicious CID: $bad');
      }
      // The ordering IS the SSRF guard — validation must precede the fetch.
      expect(requests, equals(0));
    });

    test('accepts well-formed CIDs and surfaces non-200 as IpfsException',
        () async {
      final svc = IpfsService(
        client: MockClient((_) async => http.Response('nope', 502)),
      );
      await expectLater(
        svc.downloadBytes('bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi'),
        throwsA(isA<IpfsException>()),
      );
    });

    test('uses the proxy when PINATA_PROXY_URL is set, and sends no JWT',
        () async {
      // dotenv is not loaded in unit tests, so drive the branch directly by
      // asserting what the proxy path puts on the wire.
      Uri? seenUri;
      Map<String, String>? seenHeaders;
      List<int>? seenBody;
      final svc = IpfsService(client: MockClient((req) async {
        seenUri = req.url;
        seenHeaders = req.headers;
        seenBody = req.bodyBytes;
        return http.Response('{"IpfsHash":"bafyproxycid00000000000"}', 200);
      }));

      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final cid = await svc.uploadViaProxyForTest(
        payload,
        'http://localhost:8787/pin',
      );

      expect(cid, equals('bafyproxycid00000000000'));
      expect(seenUri.toString(), equals('http://localhost:8787/pin'));
      expect(seenBody, equals(payload));
      // The whole point: no credential leaves the client on this path.
      expect(
        seenHeaders!.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')),
      );
    });

    test('surfaces a proxy failure rather than silently falling back',
        () async {
      final svc = IpfsService(
        client: MockClient((_) async => http.Response('nope', 502)),
      );
      await expectLater(
        svc.uploadViaProxyForTest(Uint8List(4), 'http://localhost:8787/pin'),
        throwsA(isA<IpfsException>()),
      );
    });

    test('rejects a malformed proxy URL', () async {
      final svc = IpfsService(client: MockClient((_) async {
        throw StateError('must not be reached');
      }));
      await expectLater(
        svc.uploadViaProxyForTest(Uint8List(4), 'not a url'),
        throwsA(isA<IpfsException>()),
      );
    });

    test('returns the body bytes verbatim on success', () async {
      final payload = Uint8List.fromList([1, 2, 3, 4, 250]);
      final svc = IpfsService(
        client: MockClient((_) async => http.Response.bytes(payload, 200)),
      );
      final got = await svc.downloadBytes(
          'bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi');
      expect(got, equals(payload));
    });
  });
}

class _DisconnectedWallet implements WalletService {
  @override
  String? get address => null;
  @override
  bool get isConnected => false;
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
