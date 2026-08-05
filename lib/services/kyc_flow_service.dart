import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web3dart/web3dart.dart';

import '../config/chain_config.dart';
import 'encryption_service.dart';
import 'ipfs_service.dart';
import 'key_wrap_service.dart';
import 'kyc_contract_service.dart';
import 'sbt_contract_service.dart';
import 'wallet_service.dart';

/// Waits for a broadcast transaction to be mined; throws if it reverted.
typedef TxConfirmer = Future<void> Function(String txHash);

/// End-to-end orchestration: encrypt → pin to IPFS → write CID on-chain, and
/// the reverse path for a verifier. Keeps the UI screens thin.
class KycFlowService {
  KycFlowService({
    WalletService? wallet,
    IpfsService? ipfs,
    EncryptionService? encryption,
    TxConfirmer? confirmer,
  })  : _wallet = wallet ?? WalletService.instance,
        _ipfs = ipfs ?? IpfsService(),
        _encryption = encryption ?? EncryptionService(),
        _confirmer = confirmer;

  final WalletService _wallet;
  final IpfsService _ipfs;
  final EncryptionService _encryption;

  /// Overrides receipt polling. Injected by tests so the pipeline can be
  /// exercised without an RPC endpoint; null in production, where
  /// [awaitConfirmation] does the real thing.
  final TxConfirmer? _confirmer;

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
  /// canonical key-derivation message. Deterministic: same account → same key.
  ///
  /// The message embeds the connected address, so the derivation is bound to
  /// the account that signed it.
  Future<Uint8List> deriveUserKey() async {
    final address = _wallet.address;
    if (address == null) {
      throw StateError('Connect a wallet before deriving your encryption key.');
    }
    final signature = await _wallet
        .signMessage(EncryptionService.buildKeyDerivationMessage(address));
    return EncryptionService.deriveKeyFromSignature(signature);
  }

  /// [awaitConfirmation], unless a test injected a substitute.
  Future<void> _confirm(String txHash) async {
    final override = _confirmer;
    if (override != null) return override(txHash);
    await awaitConfirmation(txHash);
  }

  /// Block until [txHash] is mined, then assert it did not revert.
  ///
  /// `eth_sendTransaction` only returns a hash — it says the transaction was
  /// BROADCAST, not that it succeeded. Reporting success off the hash alone
  /// makes a reverted `attest`/`grantAccess` look like it worked. Every screen
  /// that claims an on-chain action completed must go through here first.
  Future<TransactionReceipt> awaitConfirmation(
    String txHash, {
    Duration timeout = const Duration(minutes: 3),
    Duration pollInterval = const Duration(seconds: 3),
  }) async {
    final client = _client ??= Web3Client(ChainConfig.rpcUrl, http.Client());
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      TransactionReceipt? receipt;
      try {
        receipt = await client.getTransactionReceipt(txHash);
      } catch (_) {
        // Transient RPC hiccup — keep polling until the deadline.
      }
      if (receipt != null) {
        // status == false means the EVM reverted the call.
        if (receipt.status == false) {
          throw TransactionRevertedException(txHash);
        }
        return receipt;
      }
      await Future<void>.delayed(pollInterval);
    }
    throw TransactionPendingException(txHash, timeout);
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

    await report(0.75, 'Writing CID on-chain (sign in your wallet)…');
    final contract = await _contractService();
    final txHash = await _wallet.sendTransaction(
      to: contract.contractAddress.hexEip55,
      data: contract.encodeSubmitKyc(cid),
    );

    // Broadcast != mined. Wait for the receipt so the "done" screen only ever
    // appears for a transaction that actually landed and did not revert.
    await report(0.85, 'Waiting for Sepolia to confirm…');
    await _confirm(txHash);

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

  /// The on-chain expiry of [verifierAddress]'s grant over [userAddress]'s
  /// KYC, or null when no grant exists. This is the source of truth for the
  /// "who can see my documents" list — not any client-side bookkeeping.
  Future<DateTime?> accessExpiry(
    String userAddress,
    String verifierAddress,
  ) async {
    final contract = await _contractService();
    return contract.accessExpiry(
      EthereumAddress.fromHex(userAddress),
      EthereumAddress.fromHex(verifierAddress),
    );
  }

  /// The live grant state for a (user, verifier) pair: expiry plus whether the
  /// grant still matches the current record version.
  Future<GrantState> grantState(
    String userAddress,
    String verifierAddress,
  ) async {
    final contract = await _contractService();
    final user = EthereumAddress.fromHex(userAddress);
    final verifier = EthereumAddress.fromHex(verifierAddress);
    final results = await Future.wait([
      contract.accessExpiry(user, verifier),
      contract.recordVersion(user),
      contract.grantVersion(user, verifier),
    ]);
    return GrantState(
      expiresAt: results[0] as DateTime?,
      recordVersion: results[1] as int,
      grantVersion: results[2] as int,
    );
  }

  /// Whether [userAddress] has ever submitted a KYC record.
  Future<bool> hasRecord(String userAddress) async {
    final contract = await _contractService();
    return contract.hasRecord(EthereumAddress.fromHex(userAddress));
  }

  /// Wrap the user's document key to [verifierPublicKeyHex] (ECIES), so the
  /// secret that travels to the verifier is useless to anyone else.
  ///
  /// Returns the hex blob the user hands over. Requires one wallet signature
  /// to re-derive the key.
  Future<String> wrapKeyForVerifier(String verifierPublicKeyHex) async {
    final recipient = KeyWrapService.fromHex(verifierPublicKeyHex);
    if (!KeyWrapService.isValidPublicKey(recipient)) {
      throw ArgumentError(
        "That is not a valid verifier key. Ask them for the 'wrapping key' "
        'shown on their Verify screen (66 hex characters).',
      );
    }
    final key = await deriveUserKey();
    return KeyWrapService.toHex(await KeyWrapService.wrap(key, recipient));
  }

  /// Verifier path: fetch + decrypt a user's KYC bundle.
  ///
  /// [keyMaterial] is what the user handed over — either an ECIES blob wrapped
  /// to [transportPrivateKey] (preferred), or a bare 32-byte hex key (legacy
  /// path, kept so a user who only has the raw key is not stranded).
  Future<Map<String, Uint8List>> readKyc({
    required String userAddress,
    required String callerAddress,
    required String keyMaterial,
    Uint8List? transportPrivateKey,
  }) async {
    final key = await resolveDocumentKey(
      keyMaterial: keyMaterial,
      transportPrivateKey: transportPrivateKey,
    );

    final contract = await _contractService();
    final user = EthereumAddress.fromHex(userAddress);
    final caller = EthereumAddress.fromHex(callerAddress);

    final pointer = await contract.getKyc(user, caller: caller);
    final cipherBytes = await _ipfs.downloadBytes(pointer.cid);
    final plain = await _encryption.decryptBytes(cipherBytes, key);
    final bundle = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    final docs = (bundle['docs'] as Map<String, dynamic>);
    return docs.map(
      (k, v) => MapEntry(k, base64Decode(v as String)),
    );
  }

  /// Turn whatever the verifier pasted into the 32-byte document key.
  ///
  /// A bare key is exactly 32 bytes; a wrapped blob is version-tagged and much
  /// longer, so the two are distinguishable without asking the user which they
  /// have.
  Future<Uint8List> resolveDocumentKey({
    required String keyMaterial,
    Uint8List? transportPrivateKey,
  }) async {
    final bytes = KeyWrapService.fromHex(keyMaterial);
    if (bytes.length == 32) return bytes; // legacy raw key
    if (transportPrivateKey == null) {
      throw ArgumentError(
        'This looks like a wrapped key, but no transport key is available to '
        'unwrap it.',
      );
    }
    return KeyWrapService.unwrap(bytes, transportPrivateKey);
  }

  // ---------------------------------------------------------------------------
  // Soulbound KYC attestations (verify once, reuse everywhere)
  // ---------------------------------------------------------------------------

  /// Verifier action: mint a soulbound "Verified" badge to [subjectAddress],
  /// valid for [duration]. Returns the tx hash.
  ///
  /// Pins a real ERC-721 metadata document for this specific attestation and
  /// mints against its CID, so `tokenURI` resolves to something meaningful in
  /// any NFT viewer. Pass [uriOverride] to skip pinning.
  Future<String> attestUser(
    String subjectAddress, {
    Duration duration = const Duration(days: 365),
    String? uriOverride,
  }) async {
    final sbt = await _sbtService();
    final subject = EthereumAddress.fromHex(subjectAddress);
    final expiresAt = DateTime.now().add(duration);

    final uri = uriOverride ??
        await _pinAttestationMetadata(
          issuer: _wallet.address ?? '',
          subject: subjectAddress,
          expiresAt: expiresAt,
        );

    return _wallet.sendTransaction(
      to: sbt.contractAddress.hexEip55,
      data: sbt.encodeAttest(subject, expiresAt, uri),
    );
  }

  /// Build + pin the badge's public metadata, returning `ipfs://<cid>`.
  ///
  /// PUBLIC BY CONSTRUCTION: this document is unencrypted and world-readable,
  /// so it carries only facts that are already public on-chain — the two wallet
  /// addresses and the validity window. It must never include document bytes,
  /// the CID of the KYC bundle, or the doc-type hash, all of which would leak
  /// information the registry deliberately keeps behind its access gate.
  Future<String> _pinAttestationMetadata({
    required String issuer,
    required String subject,
    required DateTime expiresAt,
  }) async {
    final metadata = jsonEncode({
      'name': 'DeKYC Verified',
      'description':
          'Non-transferable (ERC-5192) attestation that the issuer completed '
              'a KYC review of the subject. Trust is per-issuer: verify the '
              'issuer address before relying on this badge.',
      'attributes': [
        {'trait_type': 'Issuer', 'value': issuer},
        {'trait_type': 'Subject', 'value': subject},
        {
          'trait_type': 'Expires',
          'display_type': 'date',
          'value': expiresAt.toUtc().millisecondsSinceEpoch ~/ 1000,
        },
        {'trait_type': 'Network', 'value': ChainConfig.networkName},
      ],
    });
    final cid = await _ipfs.uploadBytes(
      Uint8List.fromList(utf8.encode(metadata)),
      filename: 'dekyc_attestation.json',
    );
    return 'ipfs://$cid';
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

}

/// Live on-chain state of one verifier's access to one user's KYC.
class GrantState {
  const GrantState({
    required this.expiresAt,
    required this.recordVersion,
    required this.grantVersion,
  });

  /// Raw expiry from the chain. Null when no grant was ever issued.
  final DateTime? expiresAt;

  /// How many bundles the user has submitted.
  final int recordVersion;

  /// Which bundle version this grant was issued against.
  final int grantVersion;

  bool get exists => expiresAt != null;

  bool get isExpired =>
      expiresAt != null && !expiresAt!.isAfter(DateTime.now());

  /// The grant was issued against an older bundle: the user has re-uploaded
  /// since. On-chain this lapses the grant, and the fix is to grant again —
  /// not to wait for an expiry that will never help.
  bool get isStale => exists && grantVersion != recordVersion;

  /// Mirrors `KYCRegistry.hasAccess`.
  bool get isLive => exists && !isExpired && !isStale;
}

/// The transaction was mined but the EVM reverted it.
class TransactionRevertedException implements Exception {
  TransactionRevertedException(this.txHash);
  final String txHash;
  @override
  String toString() =>
      'The transaction was rejected on-chain (reverted). '
      'See ${ChainConfig.txUrl(txHash)}';
}

/// The transaction never appeared in a block within the wait window. It may
/// still confirm later — we simply stopped waiting.
class TransactionPendingException implements Exception {
  TransactionPendingException(this.txHash, this.waited);
  final String txHash;
  final Duration waited;
  @override
  String toString() =>
      'Still pending after ${waited.inMinutes} min. It may yet confirm — '
      'check ${ChainConfig.txUrl(txHash)}';
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
