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

  /// Read the Nth 32-byte ABI word (after the 4-byte selector) as an integer.
  BigInt wordAt(Uint8List data, int i) {
    var v = BigInt.zero;
    for (final b in data.sublist(4 + i * 32, 4 + (i + 1) * 32)) {
      v = (v << 8) | BigInt.from(b);
    }
    return v;
  }

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

  test('encodeGrantAccess encodes expiry in SECONDS, not milliseconds', () {
    // Selector and length are identical whether or not `~/ 1000` is applied,
    // so asserting only those lets a unit bug through that turns a 7-day grant
    // into one lasting until roughly the year 62,000 — the contract only
    // requires expiresAt > block.timestamp, so it is accepted silently.
    final verifier =
        EthereumAddress.fromHex('0x2222222222222222222222222222222222222222');
    final data = service.encodeGrantAccess(
      verifier,
      DateTime.fromMillisecondsSinceEpoch(1900000000 * 1000),
    );
    expect(wordAt(data, 0), equals(BigInt.parse('0x2222222222222222222222222222222222222222')));
    expect(wordAt(data, 1), equals(BigInt.from(1900000000)));
  });

  test('encodeSubmitKyc encodes the CID and the real docTypeHash', () {
    final data = service.encodeSubmitKyc('bafyTestCid');
    // Dynamic string => head is [offset, docTypeHash]; hash is the 2nd word.
    expect(
      wordAt(data, 1),
      equals(
        BigInt.parse(
          '0x${KycContractService.docTypeHash.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
        ),
      ),
    );
    // ...and it really is keccak of the documented doc-type set.
    expect(
      KycContractService.docTypeHash,
      equals(keccakUtf8('aadhaar_front,aadhaar_back,pan,photo')),
    );
    // The CID round-trips through the tail as UTF-8.
    expect(String.fromCharCodes(data.sublist(data.length - 32).takeWhile((b) => b != 0)),
        equals('bafyTestCid'));
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

  test('encodeForgetVerifier matches forgetVerifier(address) selector', () {
    final abiWithForget = abi.replaceFirst(
      '[',
      '[{"type":"function","name":"forgetVerifier","stateMutability":"nonpayable",'
          '"inputs":[{"name":"verifier","type":"address"}],"outputs":[]},',
    );
    final svc =
        KycContractService.fromAbiString(abiWithForget, address: address);
    final verifier =
        EthereumAddress.fromHex('0x4444444444444444444444444444444444444444');
    final data = svc.encodeForgetVerifier(verifier);
    expect(
      data.sublist(0, 4),
      equals(selectorOf('forgetVerifier(address)')),
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
