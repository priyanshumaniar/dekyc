import 'package:de_kyc/services/kyc_flow_service.dart'
    show TransactionRevertedException;
import 'package:de_kyc/services/tx_errors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web3dart/crypto.dart' show bytesToHex, keccakUtf8;

String _sel(String signature) =>
    bytesToHex(keccakUtf8(signature).sublist(0, 4));

void main() {
  const cancelled =
      'You cancelled the request in your wallet. Nothing was sent.';

  test('EIP-1193 code 4001 reads as a cancel, not "[object Object]"', () {
    const e = WalletRequestException(
        code: 4001, message: 'MetaMask Tx Signature: User denied.');
    expect(describeTxError(e), cancelled);
  });

  test('a cancel worded only in text (WalletConnect) is still a cancel', () {
    expect(describeTxError(Exception('User rejected the request.')),
        cancelled);
  });

  test('a known contract revert is explained in plain words', () {
    final e = WalletRequestException(
      code: -32603,
      message: 'execution reverted',
      data: '0x${_sel('AlreadyAttested(address,address)')}'
          '${'0' * 128}',
    );
    expect(describeTxError(e), contains('already verified this user'));
  });

  test('running out of Sepolia ETH says so', () {
    const e = WalletRequestException(
        code: -32000, message: 'insufficient funds for gas * price + value');
    expect(describeTxError(e), contains('enough Sepolia ETH'));
  });

  test('a bare "[object Object]" never reaches the user', () {
    expect(describeTxError(_JsLike()), isNot(contains('[object Object]')));
  });

  test('anything else passes its own message through', () {
    expect(describeTxError(TransactionRevertedException('0xabc')),
        contains('reverted'));
  });
}

/// Mimics what a raw JS error object prints as.
class _JsLike {
  @override
  String toString() => '[object Object]';
}
