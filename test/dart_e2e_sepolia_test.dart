@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:de_kyc/services/ipfs_service.dart';
import 'package:de_kyc/services/key_wrap_service.dart';
import 'package:de_kyc/services/kyc_contract_service.dart';
import 'package:de_kyc/services/kyc_flow_service.dart';
import 'package:de_kyc/services/wallet_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:web3dart/web3dart.dart';

/// LIVE end-to-end run of the flow **through the app's own Dart services**.
///
/// `contracts/scripts/e2e-sepolia.ts` proves the CONTRACT works, but it
/// reimplements the encryption, the envelope and the ABI encoding in Node — so
/// it can pass while the Dart client is broken in exactly the ways that matter
/// (a wrong envelope layout, a mis-encoded uint, a tuple-array it cannot
/// decode). This exercises the real EncryptionService, KeyWrapService,
/// KycContractService and KycFlowService against the deployed registry.
///
/// Skipped by default — it needs network, Sepolia ETH and a funded key:
///
///     flutter test test/dart_e2e_sepolia_test.dart --dart-define=DEKYC_E2E=1
///
/// Every write is made by a wallet generated fresh for the run and funded from
/// the deployer, so it can never touch an account a human uses.
const bool _enabled = bool.fromEnvironment('DEKYC_E2E');

/// Reads .env values without flutter_dotenv (no asset bundle needed here).
Map<String, String> _env(String path) {
  final file = File(path);
  if (!file.existsSync()) return {};
  final out = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    if (!RegExp(r'^[A-Z_]+=').hasMatch(line)) continue;
    final i = line.indexOf('=');
    out[line.substring(0, i)] = line.substring(i + 1).trim();
  }
  return out;
}

/// A [WalletService] stand-in that signs locally with a private key, so the
/// flow can run without MetaMask while still going through the real code.
class _LocalWallet implements WalletService {
  _LocalWallet(this.credentials, this._client, this._chainId);

  final EthPrivateKey credentials;
  final Web3Client _client;
  final int _chainId;

  @override
  String? get address => credentials.address.hexEip55;

  @override
  bool get isConnected => true;

  @override
  Future<String> signMessage(String message) async {
    // Matches EIP-191 personal_sign, which is what MetaMask returns.
    final sig = credentials.signPersonalMessageToUint8List(
      Uint8List.fromList(utf8.encode(message)),
    );
    return '0x${sig.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  @override
  Future<String> sendTransaction({
    required String to,
    required Uint8List data,
    BigInt? value,
  }) async {
    return _client.sendTransaction(
      credentials,
      Transaction(
        to: EthereumAddress.fromHex(to),
        data: data,
        value: value == null ? null : EtherAmount.inWei(value),
        maxGas: 400000,
      ),
      chainId: _chainId,
    );
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test installs an HttpOverrides that fails every request with 400.
  // This suite genuinely needs the network.
  HttpOverrides.global = null;

  test('full flow through the real Dart services against live Sepolia',
      () async {
    final root = Directory.current.path;
    final appEnv = _env('$root/.env');
    final contractsEnv = _env('$root/contracts/.env');
    final rpc = contractsEnv['SEPOLIA_RPC_URL'] ?? appEnv['SEPOLIA_RPC_URL']!;
    final deployerKey = contractsEnv['DEPLOYER_PRIVATE_KEY']!;
    final jwt = appEnv['PINATA_JWT']!;
    final gateway = appEnv['PINATA_GATEWAY'] ?? 'gateway.pinata.cloud';

    // The registry the app is compiled against.
    final addrSrc =
        File('$root/lib/config/contract_address.dart').readAsStringSync();
    final registryAddress = RegExp(r'kKycRegistryAddress\s*=\s*"(0x[0-9a-fA-F]{40})"')
        .firstMatch(addrSrc)!
        .group(1)!;

    final client = Web3Client(rpc, http.Client());
    const chainId = 11155111;

    final deployer = EthPrivateKey.fromHex(
      deployerKey.startsWith('0x') ? deployerKey.substring(2) : deployerKey,
    );

    // --- isolate: a throwaway account, funded for this run -------------------
    final userKey = EthPrivateKey.createRandom(Random.secure());
    final userAddr = userKey.address;
    // ignore: avoid_print
    print('User (throwaway): ${userAddr.hexEip55}');

    final fundTx = await client.sendTransaction(
      deployer,
      Transaction(
        to: userAddr,
        value: EtherAmount.inWei(BigInt.from(4000000000000000)), // 0.004 ETH
        maxGas: 21000,
      ),
      chainId: chainId,
    );
    await _await(client, fundTx);

    final wallet = _LocalWallet(userKey, client, chainId);
    final ipfs = _PinataDirect(jwt: jwt, gateway: gateway);

    final flow = KycFlowService(
      wallet: wallet,
      ipfs: ipfs,
      client: client,
      registryAddressOverride: registryAddress,
    );

    // --- 1. UPLOAD -----------------------------------------------------------
    final docs = <String, Uint8List>{
      'aadhaar_front': Uint8List.fromList(utf8.encode('AADHAAR-FRONT-DART')),
      'aadhaar_back': Uint8List.fromList(utf8.encode('AADHAAR-BACK-DART')),
      'pan': Uint8List.fromList(utf8.encode('PAN-DART')),
      'photo': Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]),
    };
    final progress = <double>[];
    final result =
        await flow.submitKyc(docs, onProgress: (p, _) => progress.add(p));
    // ignore: avoid_print
    print('submitKYC -> cid=${result.cid} tx=${result.txHash}');
    expect(progress.last, equals(1.0));

    expect(await flow.hasRecord(userAddr.hexEip55), isTrue);

    // The pointer the chain holds must be the CID we pinned.
    final contract = KycContractService.fromAbiString(
      File('$root/assets/contracts/KYCRegistry.abi.json').readAsStringSync(),
      address: registryAddress,
      client: client,
    );
    final own = await contract.getKyc(userAddr, caller: userAddr);
    expect(own.cid, equals(result.cid));

    // --- 2. SHARE ------------------------------------------------------------
    final verifierKey = EthPrivateKey.createRandom(Random.secure());
    final verifierAddr = verifierKey.address;

    // Before any grant the verifier must be refused.
    expect(await flow.hasAccess(userAddr.hexEip55, verifierAddr.hexEip55),
        isFalse);
    await expectLater(
      contract.getKyc(userAddr, caller: verifierAddr),
      throwsA(anything),
      reason: 'ungranted read must revert',
    );

    final grantTx =
        await flow.grantAccess(verifierAddr.hexEip55, const Duration(days: 7));
    await flow.awaitConfirmation(grantTx);
    expect(await flow.hasAccess(userAddr.hexEip55, verifierAddr.hexEip55),
        isTrue);

    // The guest list must be readable from the chain, decoding the tuple array.
    final grants = await flow.listGrants(userAddr.hexEip55);
    expect(grants.map((g) => g.address), contains(verifierAddr.hexEip55));
    final row = grants.firstWhere((g) => g.address == verifierAddr.hexEip55);
    expect(row.live, isTrue);
    expect(row.expiresAt!.isAfter(DateTime.now()), isTrue);

    // --- 3. WRAP -------------------------------------------------------------
    final transport = KeyWrapService.generateKeyPair();
    final wrapped = await flow.wrapKeyForVerifier(transport.publicKeyHex);
    // The document key must not appear in the blob that travels.
    final documentKey = await flow.deriveUserKey();
    expect(wrapped.contains(KeyWrapService.toHex(documentKey)), isFalse);

    // --- 4. RETRIEVE ---------------------------------------------------------
    final fetched = await flow.readKyc(
      userAddress: userAddr.hexEip55,
      callerAddress: verifierAddr.hexEip55,
      keyMaterial: wrapped,
      transportPrivateKey: transport.privateKey,
    );
    expect(fetched.keys.toSet(), equals(docs.keys.toSet()));
    for (final k in docs.keys) {
      expect(fetched[k], equals(docs[k]), reason: '$k did not round-trip');
    }
    // ignore: avoid_print
    print('decrypted aadhaar_front = ${utf8.decode(fetched['aadhaar_front']!)}');

    // --- 5. CONSENT BINDING --------------------------------------------------
    final reupload = await flow.submitKyc(docs);
    expect(reupload.cid, isNotEmpty);
    expect(await flow.hasAccess(userAddr.hexEip55, verifierAddr.hexEip55),
        isFalse,
        reason: 're-upload must lapse the outstanding grant');
    final stale = (await flow.listGrants(userAddr.hexEip55))
        .firstWhere((g) => g.address == verifierAddr.hexEip55);
    expect(stale.live, isFalse);
    // Still not expired — so the UI can tell "stale" from "expired".
    expect(stale.expiresAt!.isAfter(DateTime.now()), isTrue);

    // --- 6. REVOKE -----------------------------------------------------------
    final regrant =
        await flow.grantAccess(verifierAddr.hexEip55, const Duration(days: 7));
    await flow.awaitConfirmation(regrant);
    expect(await flow.hasAccess(userAddr.hexEip55, verifierAddr.hexEip55),
        isTrue);

    final revokeTx = await flow.revokeAccess(verifierAddr.hexEip55);
    await flow.awaitConfirmation(revokeTx);
    expect(await flow.hasAccess(userAddr.hexEip55, verifierAddr.hexEip55),
        isFalse);
    await expectLater(
      contract.getKyc(userAddr, caller: verifierAddr),
      throwsA(anything),
      reason: 'revoked verifier must be refused again',
    );

    // --- 7. FORGET -----------------------------------------------------------
    final forgetTx = await flow.forgetVerifier(verifierAddr.hexEip55);
    await flow.awaitConfirmation(forgetTx);
    expect(await flow.listGrants(userAddr.hexEip55), isEmpty);

    client.dispose();
    // ignore: avoid_print
    print('\nFULL DART FLOW PASSED against $registryAddress');
  }, timeout: const Timeout(Duration(minutes: 12)), skip: !_enabled);
}

Future<void> _await(Web3Client c, String hash) async {
  for (var i = 0; i < 60; i++) {
    final r = await c.getTransactionReceipt(hash);
    if (r != null) return;
    await Future<void>.delayed(const Duration(seconds: 3));
  }
  throw StateError('funding tx $hash never confirmed');
}

/// The real [IpfsService] reads its credentials from flutter_dotenv, which is
/// not loaded here — this supplies them directly while keeping the same HTTP
/// behaviour and CID validation.
class _PinataDirect implements IpfsService {
  _PinataDirect({required this.jwt, required this.gateway});

  final String jwt;
  final String gateway;
  final http.Client _client = http.Client();

  @override
  Future<String> uploadBytes(Uint8List bytes,
      {String filename = 'dekyc_bundle.enc'}) async {
    final req = http.MultipartRequest(
      'POST',
      Uri.parse('https://api.pinata.cloud/pinning/pinFileToIPFS'),
    )
      ..headers['Authorization'] = 'Bearer $jwt'
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename))
      ..fields['pinataOptions'] = jsonEncode({'cidVersion': 1});
    final res = await http.Response.fromStream(await _client.send(req));
    if (res.statusCode != 200) {
      throw IpfsException('Pinata ${res.statusCode}: ${res.body}');
    }
    return (jsonDecode(res.body) as Map<String, dynamic>)['IpfsHash'] as String;
  }

  @override
  Future<Uint8List> downloadBytes(String cid) async {
    if (!IpfsService.isValidCid(cid)) {
      throw IpfsException('Refusing to fetch a malformed CID: "$cid"');
    }
    for (var i = 0; i < 12; i++) {
      final res = await _client.get(Uri.parse('https://$gateway/ipfs/$cid'));
      if (res.statusCode == 200) return res.bodyBytes;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    throw IpfsException('gateway never served $cid');
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
