import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web3dart/web3dart.dart';

import '../config/chain_config.dart';
import 'encryption_service.dart';
import 'ipfs_service.dart';
import 'kyc_contract_service.dart';
import 'sbt_contract_service.dart';
import 'wallet_service.dart';

/// End-to-end orchestration: encrypt → pin to IPFS → write CID on-chain, and
/// the reverse path for a verifier. Keeps the UI screens thin.
class KycFlowService {
  KycFlowService({
    WalletService? wallet,
    IpfsService? ipfs,
    EncryptionService? encryption,
  })  : _wallet = wallet ?? WalletService.instance,
        _ipfs = ipfs ?? IpfsService(),
        _encryption = encryption ?? EncryptionService();

  final WalletService _wallet;
  final IpfsService _ipfs;
  final EncryptionService _encryption;

  Web3Client? _client;
  KycContractService? _contract;
  SbtContractService? _sbt;

  Future<KycContractService> _contractService() async {
    _client ??= Web3Client(ChainConfig.rpcUrl, http.Client());
    _contract ??= await KycContractService.load(client: _client);
    return _contract!;
  }

  Future<SbtContractService> _sbtService() async {
    _client ??= Web3Client(ChainConfig.rpcUrl, http.Client());
    _sbt ??= await SbtContractService.load(client: _client);
    return _sbt!;
  }

  /// Derive the user's symmetric key by asking the wallet to sign the
  /// canonical key-derivation message. Deterministic: same wallet → same key.
  Future<Uint8List> deriveUserKey() async {
    final signature =
        await _wallet.signMessage(EncryptionService.keyDerivationMessage);
    return EncryptionService.deriveKeyFromSignature(signature);
  }

  /// Submit a full KYC bundle. [files] maps doc-type → file bytes (works on
  /// web, desktop and mobile). Reports coarse progress via [onProgress] (0..1).
  Future<KycSubmitResult> submitKyc(
    Map<String, Uint8List> files, {
    void Function(double progress, String label)? onProgress,
  }) async {
    // Yield to the event loop so the progress overlay actually repaints before
    // each CPU-heavy, synchronous step (encoding the bundle). Without this the
    // UI stays frozen on the previous label.
    Future<void> report(double p, String l) async {
      onProgress?.call(p, l);
      await Future<void>.delayed(Duration.zero);
    }

    await report(0.10, 'Deriving your encryption key…');
    final key = await deriveUserKey();

    await report(0.30, 'Packaging documents…');
    final docs = <String, String>{};
    for (final entry in files.entries) {
      docs[entry.key] = base64Encode(entry.value);
    }
    final bundle = jsonEncode({
      'version': 1,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'docs': docs,
    });

    await report(0.45, 'Encrypting (AES-256-GCM)…');
    final cipherBytes = await _encryption.encryptBytes(
        Uint8List.fromList(utf8.encode(bundle)), key);

    await report(0.60, 'Pinning to IPFS…');
    final cid = await _ipfs.uploadBytes(cipherBytes);

    await report(0.80, 'Writing CID on-chain (sign in your wallet)…');
    final contract = await _contractService();
    final txHash = await _wallet.sendTransaction(
      to: contract.contractAddress.hexEip55,
      data: contract.encodeSubmitKyc(cid),
    );

    await report(1.0, 'Submitted.');
    return KycSubmitResult(cid: cid, txHash: txHash);
  }

  /// Grant a verifier access for [duration]. Returns the tx hash.
  Future<String> grantAccess(String verifierAddress, Duration duration) async {
    final contract = await _contractService();
    final verifier = EthereumAddress.fromHex(verifierAddress);
    final expiresAt = DateTime.now().add(duration);
    return _wallet.sendTransaction(
      to: contract.contractAddress.hexEip55,
      data: contract.encodeGrantAccess(verifier, expiresAt),
    );
  }

  /// Revoke a verifier's access. Returns the tx hash.
  Future<String> revokeAccess(String verifierAddress) async {
    final contract = await _contractService();
    final verifier = EthereumAddress.fromHex(verifierAddress);
    return _wallet.sendTransaction(
      to: contract.contractAddress.hexEip55,
      data: contract.encodeRevokeAccess(verifier),
    );
  }

  /// Whether [verifierAddress] currently has access to [userAddress]'s KYC.
  Future<bool> hasAccess(String userAddress, String verifierAddress) async {
    final contract = await _contractService();
    return contract.hasAccess(
      EthereumAddress.fromHex(userAddress),
      EthereumAddress.fromHex(verifierAddress),
    );
  }

  /// Whether [userAddress] has ever submitted a KYC record.
  Future<bool> hasRecord(String userAddress) async {
    final contract = await _contractService();
    return contract.hasRecord(EthereumAddress.fromHex(userAddress));
  }

  /// Verifier path: fetch + decrypt a user's KYC bundle.
  /// [keyHex] is the symmetric key shared by the user out-of-band on grant.
  Future<Map<String, Uint8List>> readKyc({
    required String userAddress,
    required String callerAddress,
    required String keyHex,
  }) async {
    final contract = await _contractService();
    final user = EthereumAddress.fromHex(userAddress);
    final caller = EthereumAddress.fromHex(callerAddress);

    final pointer = await contract.getKyc(user, caller: caller);
    final cipherBytes = await _ipfs.downloadBytes(pointer.cid);
    final plain =
        await _encryption.decryptBytes(cipherBytes, _hexToBytes(keyHex));
    final bundle = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    final docs = (bundle['docs'] as Map<String, dynamic>);
    return docs.map(
      (k, v) => MapEntry(k, base64Decode(v as String)),
    );
  }

  // ---------------------------------------------------------------------------
  // Soulbound KYC attestations (verify once, reuse everywhere)
  // ---------------------------------------------------------------------------

  /// Verifier action: mint a soulbound "Verified" badge to [subjectAddress],
  /// valid for [duration]. Returns the tx hash.
  Future<String> attestUser(
    String subjectAddress, {
    Duration duration = const Duration(days: 365),
    String uri = 'ipfs://dekyc-attestation',
  }) async {
    final sbt = await _sbtService();
    final subject = EthereumAddress.fromHex(subjectAddress);
    final expiresAt = DateTime.now().add(duration);
    return _wallet.sendTransaction(
      to: sbt.contractAddress.hexEip55,
      data: sbt.encodeAttest(subject, expiresAt, uri),
    );
  }

  /// Verifier action: revoke a previously-minted badge for [subjectAddress].
  Future<String> revokeAttestation(String subjectAddress) async {
    final sbt = await _sbtService();
    final subject = EthereumAddress.fromHex(subjectAddress);
    return _wallet.sendTransaction(
      to: sbt.contractAddress.hexEip55,
      data: sbt.encodeRevokeAttestation(subject),
    );
  }

  /// Whether [issuerAddress] has a valid badge for [subjectAddress].
  Future<bool> isVerifiedBy(String issuerAddress, String subjectAddress) async {
    final sbt = await _sbtService();
    return sbt.isVerifiedBy(
      EthereumAddress.fromHex(issuerAddress),
      EthereumAddress.fromHex(subjectAddress),
    );
  }

  /// How many organizations have verified [userAddress] (valid badge count).
  Future<int> verifiedCount(String userAddress) async {
    final sbt = await _sbtService();
    return sbt.verifiedCount(EthereumAddress.fromHex(userAddress));
  }

  static Uint8List _hexToBytes(String hex) {
    final clean = hex.startsWith('0x') ? hex.substring(2) : hex;
    final out = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

/// Result of a successful KYC submission.
///
/// Note: the symmetric key is deliberately NOT returned here. The user reveals
/// it on demand via the profile screen (re-derived with [KycFlowService
/// .deriveUserKey]), so the master key never travels through navigation/result
/// state. See README threat-model notes on production key-wrapping.
class KycSubmitResult {
  KycSubmitResult({required this.cid, required this.txHash});

  final String cid;
  final String txHash;
}
