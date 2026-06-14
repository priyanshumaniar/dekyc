import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:web3dart/web3dart.dart';

import '../config/contract_address.dart';

/// Wraps the on-chain `KYCSoulboundToken` (ERC-5192) contract via web3dart.
///
/// Like [KycContractService], write calls are ABI-encoded here and signed by
/// the wallet; read calls go straight to the RPC node.
class SbtContractService {
  SbtContractService._(this._contract, {Web3Client? client}) : _client = client;

  final DeployedContract _contract;
  final Web3Client? _client;

  static Future<SbtContractService> load({
    Web3Client? client,
    String? addressOverride,
  }) async {
    final abi = await rootBundle
        .loadString('assets/contracts/KYCSoulboundToken.abi.json');
    return fromAbiString(
      abi,
      address: addressOverride ?? kKycSbtAddress,
      client: client,
    );
  }

  static SbtContractService fromAbiString(
    String abiJson, {
    required String address,
    Web3Client? client,
  }) {
    final contract = DeployedContract(
      ContractAbi.fromJson(abiJson, 'KYCSoulboundToken'),
      EthereumAddress.fromHex(address),
    );
    return SbtContractService._(contract, client: client);
  }

  EthereumAddress get contractAddress => _contract.address;

  // --- calldata encoders (signed by the wallet) ---------------------------

  Uint8List encodeAttest(
    EthereumAddress subject,
    DateTime expiresAt,
    String uri,
  ) {
    final fn = _contract.function('attest');
    final expiry = BigInt.from(expiresAt.millisecondsSinceEpoch ~/ 1000);
    return fn.encodeCall([subject, expiry, uri]);
  }

  Uint8List encodeRevokeAttestation(EthereumAddress subject) {
    final fn = _contract.function('revokeAttestation');
    return fn.encodeCall([subject]);
  }

  // --- read calls ----------------------------------------------------------

  Future<bool> isVerifiedBy(
    EthereumAddress issuer,
    EthereumAddress subject,
  ) async {
    final fn = _contract.function('isVerifiedBy');
    final result = await _requireClient()
        .call(contract: _contract, function: fn, params: [issuer, subject]);
    return result.first as bool;
  }

  /// Number of CURRENTLY-VALID badges held by [subject] (unrevoked AND
  /// unexpired). Uses the contract's `validBadgeCount`, which — unlike
  /// `balanceOf` — excludes expired badges. Falls back to `balanceOf` only if
  /// the deployed contract predates `validBadgeCount` (i.e. not yet redeployed).
  ///
  /// NOTE: attestation is permissionless, so this is a COUNT, not a vetted
  /// trust score — anyone can mint a badge. Trust must be decided per issuer
  /// via [isVerifiedBy]. The UI labels this accordingly.
  Future<int> verifiedCount(EthereumAddress subject) async {
    final client = _requireClient();
    try {
      final fn = _contract.function('validBadgeCount');
      final result = await client
          .call(contract: _contract, function: fn, params: [subject]);
      return (result.first as BigInt).toInt();
    } catch (_) {
      // Older deployment without validBadgeCount — degrade to balanceOf.
      final fn = _contract.function('balanceOf');
      final result = await client
          .call(contract: _contract, function: fn, params: [subject]);
      return (result.first as BigInt).toInt();
    }
  }

  Web3Client _requireClient() {
    final c = _client;
    if (c == null) {
      throw StateError('SbtContractService was built without a Web3Client.');
    }
    return c;
  }
}
