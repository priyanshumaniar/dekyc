import 'dart:typed_data';

import 'package:de_kyc/services/sbt_contract_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web3dart/web3dart.dart';
import 'package:web3dart/crypto.dart' show keccakUtf8;

/// Unit tests for SbtContractService ABI handling and calldata encoding.
void main() {
  const abi = '''
  [
    {"type":"function","name":"attest","stateMutability":"nonpayable",
     "inputs":[{"name":"subject","type":"address"},{"name":"expiresAt","type":"uint64"},{"name":"uri","type":"string"}],
     "outputs":[{"name":"tokenId","type":"uint256"}]},
    {"type":"function","name":"revokeAttestation","stateMutability":"nonpayable",
     "inputs":[{"name":"subject","type":"address"}],"outputs":[]},
    {"type":"function","name":"isVerifiedBy","stateMutability":"view",
     "inputs":[{"name":"issuer","type":"address"},{"name":"subject","type":"address"}],
     "outputs":[{"name":"","type":"bool"}]},
    {"type":"function","name":"balanceOf","stateMutability":"view",
     "inputs":[{"name":"owner","type":"address"}],"outputs":[{"name":"","type":"uint256"}]}
  ]
  ''';

  const address = '0x1111111111111111111111111111111111111111';
  late SbtContractService service;

  setUp(() {
    service = SbtContractService.fromAbiString(abi, address: address);
  });

  Uint8List selectorOf(String signature) => keccakUtf8(signature).sublist(0, 4);

  test('encodeAttest matches attest(address,uint64,string) selector', () {
    final subject =
        EthereumAddress.fromHex('0x2222222222222222222222222222222222222222');
    final data = service.encodeAttest(
      subject,
      DateTime.fromMillisecondsSinceEpoch(1900000000 * 1000),
      'ipfs://x',
    );
    expect(
      data.sublist(0, 4),
      equals(selectorOf('attest(address,uint64,string)')),
    );
  });

  test('encodeRevokeAttestation matches revokeAttestation(address) selector',
      () {
    final subject =
        EthereumAddress.fromHex('0x3333333333333333333333333333333333333333');
    final data = service.encodeRevokeAttestation(subject);
    expect(
      data.sublist(0, 4),
      equals(selectorOf('revokeAttestation(address)')),
    );
    expect(data.length, equals(4 + 32));
  });

  test('read calls without a client throw a clear error', () async {
    await expectLater(
      service.verifiedCount(EthereumAddress.fromHex(address)),
      throwsStateError,
    );
  });
}
