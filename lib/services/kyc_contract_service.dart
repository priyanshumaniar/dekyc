import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:web3dart/web3dart.dart';
import 'package:web3dart/crypto.dart' show keccakUtf8;

import '../config/contract_address.dart';

/// Thin wrapper around the on-chain `KYCRegistry` contract using web3dart.
///
/// - Read calls (`getKYC`, `hasAccess`, ...) go straight to the RPC node.
/// - Write calls are NOT signed here: WalletConnect signs them in the user's
///   wallet. This service only ABI-encodes the calldata via [encodeSubmitKyc],
///   [encodeGrantAccess] and [encodeRevokeAccess]; `WalletService` ships the
///   resulting bytes to the wallet as an `eth_sendTransaction`.
class KycContractService {
  KycContractService._(this._contract, {Web3Client? client})
      : _client = client;

  final DeployedContract _contract;
  final Web3Client? _client;

  /// Doc-type set this app submits, hashed for the on-chain pointer.
  static final Uint8List docTypeHash =
      keccakUtf8('aadhaar_front,aadhaar_back,pan,photo');

  /// Build from the ABI asset bundled with the app (used at runtime).
  static Future<KycContractService> load({
    Web3Client? client,
    String? addressOverride,
  }) async {
    final abi =
        await rootBundle.loadString('assets/contracts/KYCRegistry.abi.json');
    return fromAbiString(
      abi,
      address: addressOverride ?? kKycRegistryAddress,
      client: client,
    );
  }

  /// Build from a raw ABI JSON string (used by unit tests — no asset bundle).
  static KycContractService fromAbiString(
    String abiJson, {
    required String address,
    Web3Client? client,
  }) {
    final contract = DeployedContract(
      ContractAbi.fromJson(abiJson, 'KYCRegistry'),
      EthereumAddress.fromHex(address),
    );
    return KycContractService._(contract, client: client);
  }

  EthereumAddress get contractAddress => _contract.address;

  // ---------------------------------------------------------------------------
  // Calldata encoders (handed to the wallet for signing)
  // ---------------------------------------------------------------------------

  Uint8List encodeSubmitKyc(String cid, {Uint8List? docTypeHashOverride}) {
    final fn = _contract.function('submitKYC');
    return fn.encodeCall([cid, docTypeHashOverride ?? docTypeHash]);
  }

  Uint8List encodeGrantAccess(EthereumAddress verifier, DateTime expiresAt) {
    final fn = _contract.function('grantAccess');
    final expiry = BigInt.from(expiresAt.millisecondsSinceEpoch ~/ 1000);
    return fn.encodeCall([verifier, expiry]);
  }

  Uint8List encodeRevokeAccess(EthereumAddress verifier) {
    final fn = _contract.function('revokeAccess');
    return fn.encodeCall([verifier]);
  }

  // ---------------------------------------------------------------------------
  // Read calls
  // ---------------------------------------------------------------------------

  /// Read a user's KYC pointer. [caller] is used as `msg.sender` so the
  /// contract's access gate behaves correctly (defaults to the user).
  Future<KycPointer> getKyc(
    EthereumAddress user, {
    EthereumAddress? caller,
  }) async {
    final fn = _contract.function('getKYC');
    final result = await _requireClient().call(
      contract: _contract,
      function: fn,
      params: [user],
      sender: caller ?? user,
    );
    return KycPointer(
      cid: result[0] as String,
      submittedAt: DateTime.fromMillisecondsSinceEpoch(
        (result[1] as BigInt).toInt() * 1000,
      ),
    );
  }

  Future<bool> hasAccess(
    EthereumAddress user,
    EthereumAddress verifier,
  ) async {
    final fn = _contract.function('hasAccess');
    final result = await _requireClient()
        .call(contract: _contract, function: fn, params: [user, verifier]);
    return result.first as bool;
  }

  Future<bool> hasRecord(EthereumAddress user) async {
    final fn = _contract.function('hasRecord');
    final result = await _requireClient()
        .call(contract: _contract, function: fn, params: [user]);
    return result.first as bool;
  }

  Future<DateTime?> accessExpiry(
    EthereumAddress user,
    EthereumAddress verifier,
  ) async {
    final fn = _contract.function('accessExpiry');
    final result = await _requireClient()
        .call(contract: _contract, function: fn, params: [user, verifier]);
    final ts = (result.first as BigInt).toInt();
    return ts == 0 ? null : DateTime.fromMillisecondsSinceEpoch(ts * 1000);
  }

  /// How many times [user] has submitted KYC. 0 = never.
  Future<int> recordVersion(EthereumAddress user) async {
    final fn = _contract.function('recordVersion');
    final result = await _requireClient()
        .call(contract: _contract, function: fn, params: [user]);
    return (result.first as BigInt).toInt();
  }

  /// The record version [verifier]'s grant was issued against. 0 = no grant.
  /// A value that differs from [recordVersion] means the user re-uploaded
  /// after granting, which lapses the grant on-chain.
  Future<int> grantVersion(
    EthereumAddress user,
    EthereumAddress verifier,
  ) async {
    final fn = _contract.function('grantVersion');
    final result = await _requireClient()
        .call(contract: _contract, function: fn, params: [user, verifier]);
    return (result.first as BigInt).toInt();
  }

  Web3Client _requireClient() {
    final c = _client;
    if (c == null) {
      throw StateError('KycContractService was built without a Web3Client.');
    }
    return c;
  }
}

/// Decoded on-chain KYC pointer.
class KycPointer {
  KycPointer({required this.cid, required this.submittedAt});
  final String cid;
  final DateTime submittedAt;
}
