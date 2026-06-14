import 'dart:typed_data';

import 'package:de_kyc/services/kyc_contract_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web3dart/web3dart.dart';
import 'package:web3dart/crypto.dart' show keccakUtf8;

/// Unit tests for KycContractService's ABI handling and calldata encoding,
/// built on web3dart primitives (DeployedContract / ContractFunction). No
/// network access — we assert the encoded selectors match the Solidity ABI.
void main() {
  const abi = '''
  [
    {"type":"function","name":"submitKYC","stateMutability":"nonpayable",
     "inputs":[{"name":"cid","type":"string"},{"name":"docTypeHash","type":"bytes32"}],"outputs":[]},
    {"type":"function","name":"grantAccess","stateMutability":"nonpayable",
     "inputs":[{"name":"verifier","type":"address"},{"name":"expiresAt","type":"uint256"}],"outputs":[]},
    {"type":"function","name":"revokeAccess","stateMutability":"nonpayable",
     "inputs":[{"name":"verifier","type":"address"}],"outputs":[]},
    {"type":"function","name":"hasAccess","stateMutability":"view",
     "inputs":[{"name":"user","type":"address"},{"name":"verifier","type":"address"}],
     "outputs":[{"name":"","type":"bool"}]}
  ]
  ''';

  const address = '0x1111111111111111111111111111111111111111';

  late KycContractService service;

  setUp(() {
    service = KycContractService.fromAbiString(abi, address: address);
  });

  Uint8List selectorOf(String signature) => keccakUtf8(signature).sublist(0, 4);

  test('parses the ABI and exposes the contract address', () {
    expect(
      service.contractAddress,
      equals(EthereumAddress.fromHex(address)),
    );
  });

  test('encodeSubmitKyc starts with the submitKYC(string,bytes32) selector',
      () {
    final data = service.encodeSubmitKyc('bafyTestCid');
    expect(
      data.sublist(0, 4),
      equals(selectorOf('submitKYC(string,bytes32)')),
    );
    // string + bytes32 → calldata longer than just the selector.
    expect(data.length, greaterThan(4 + 32));
  });

  test('encodeGrantAccess matches grantAccess(address,uint256) selector', () {
    final verifier =
        EthereumAddress.fromHex('0x2222222222222222222222222222222222222222');
    final data = service.encodeGrantAccess(
      verifier,
      DateTime.fromMillisecondsSinceEpoch(1900000000 * 1000),
    );
    expect(
      data.sublist(0, 4),
      equals(selectorOf('grantAccess(address,uint256)')),
    );
    // selector + 2 * 32-byte words
    expect(data.length, equals(4 + 32 + 32));
  });

  test('encodeRevokeAccess matches revokeAccess(address) selector', () {
    final verifier =
        EthereumAddress.fromHex('0x3333333333333333333333333333333333333333');
    final data = service.encodeRevokeAccess(verifier);
    expect(
      data.sublist(0, 4),
      equals(selectorOf('revokeAccess(address)')),
    );
    expect(data.length, equals(4 + 32));
  });

  test('read calls without a client throw a clear error', () async {
    await expectLater(
      service.hasAccess(
        EthereumAddress.fromHex(address),
        EthereumAddress.fromHex(address),
      ),
      throwsStateError,
    );
  });
}
