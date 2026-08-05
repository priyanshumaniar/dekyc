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
  /// `balanceOf` — excludes expired badges (expiry does not burn the token).
  ///
  /// Errors propagate deliberately. This used to fall back to `balanceOf`
  /// inside a bare `catch (_)`, which silently turned any RPC failure into a
  /// number that OVER-counts by including expired badges — the exact defect
  /// `validBadgeCount` exists to fix. A visible error beats a quietly wrong
  /// count on a screen about identity verification.
  ///
  /// NOTE: attestation is permissionless, so this is a COUNT, not a vetted
  /// trust score — anyone can mint a badge. Trust must be decided per issuer
  /// via [isVerifiedBy]. The UI labels this accordingly.
  Future<int> verifiedCount(
    EthereumAddress subject, {
    int pageSize = 50,
  }) async {
    final client = _requireClient();

    // Page rather than calling the unbounded `validBadgeCount`. Attestation is
    // permissionless, so the issuer list is attacker-growable: a subject spammed
    // with thousands of badges would make the single-shot call exceed the RPC's
    // eth_call gas cap and fail outright. Paging keeps each call small and
    // bounded no matter how long the list gets.
    final countFn = _contract.function('subjectIssuerCount');
    final countResult = await client
        .call(contract: _contract, function: countFn, params: [subject]);
    final total = (countResult.first as BigInt).toInt();
    if (total == 0) return 0;

    final rangeFn = _contract.function('validBadgeCountRange');
    var valid = 0;
    for (var start = 0; start < total; start += pageSize) {
      final end = (start + pageSize) > total ? total : start + pageSize;
      final page = await client.call(
        contract: _contract,
        function: rangeFn,
        params: [subject, BigInt.from(start), BigInt.from(end)],
      );
      valid += (page.first as BigInt).toInt();
    }
    return valid;
  }

  /// How many DISTINCT issuers have ever attested to [subject] — the page
  /// bound behind [verifiedCount], exposed for diagnostics.
  Future<int> issuerCount(EthereumAddress subject) async {
    final fn = _contract.function('subjectIssuerCount');
    final result = await _requireClient()
        .call(contract: _contract, function: fn, params: [subject]);
    return (result.first as BigInt).toInt();
  }

  Web3Client _requireClient() {
    final c = _client;
    if (c == null) {
      throw StateError('SbtContractService was built without a Web3Client.');
    }
    return c;
  }
}
