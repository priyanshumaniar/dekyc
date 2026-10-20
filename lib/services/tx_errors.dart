import 'package:web3dart/crypto.dart' show bytesToHex, keccakUtf8;

/// An error returned by the wallet for a request (EIP-1193 / WalletConnect).
///
/// The browser wallet rejects its promise with a plain JS object
/// (`{code: 4001, message: "User rejected the request."}`). Thrown as-is it
/// prints as "[object Object]", so the web bridge converts it into this.
class WalletRequestException implements Exception {
  const WalletRequestException({this.code, required this.message, this.data});

  /// EIP-1193 code when the wallet gave one. 4001 = user rejected.
  final int? code;
  final String message;

  /// Revert data (0x...) when the wallet included it.
  final String? data;

  bool get isUserRejection =>
      code == 4001 || looksLikeUserRejection(message);

  @override
  String toString() => message;
}

/// Wallets word a cancel differently; WalletConnect wallets often send no
/// EIP-1193 code at all, only text.
bool looksLikeUserRejection(String text) {
  final t = text.toLowerCase();
  return t.contains('user rejected') ||
      t.contains('user denied') ||
      t.contains('rejected by user') ||
      t.contains('user cancel') ||
      t.contains('request rejected');
}

/// Custom errors the DeKYC contracts can revert with, keyed by 4-byte
/// selector, with the sentence a person should see instead.
final Map<String, String> _knownReverts = {
  for (final e in const {
    'AlreadyAttested(address,address)':
        'You have already verified this user, and that badge is still valid.',
    'NoAttestation(address,address)':
        'There is no badge from you for this user to revoke.',
    'SelfAttest()': 'A wallet cannot issue a badge to itself.',
    'InvalidExpiry()': 'The badge expiry date must be in the future.',
    'ZeroSubject()': 'The user address is empty.',
    'NotAuthorized(address,address)':
        'This wallet does not have access to that record.',
  }.entries)
    _selector(e.key): e.value,
};

String _selector(String signature) =>
    bytesToHex(keccakUtf8(signature).sublist(0, 4));

/// A plain-language sentence for any error from a wallet transaction.
String describeTxError(Object error) {
  if (error is WalletRequestException && error.isUserRejection) {
    return 'You cancelled the request in your wallet. Nothing was sent.';
  }
  final text = error.toString();
  if (looksLikeUserRejection(text)) {
    return 'You cancelled the request in your wallet. Nothing was sent.';
  }

  final haystack = [
    text,
    if (error is WalletRequestException) error.data ?? '',
  ].join(' ').toLowerCase();
  for (final entry in _knownReverts.entries) {
    if (haystack.contains(entry.key)) return entry.value;
  }
  if (haystack.contains('insufficient funds')) {
    return 'This wallet does not have enough Sepolia ETH to pay the network '
        'fee. Top it up from a Sepolia faucet and try again.';
  }
  if (text == '[object Object]' || text.trim().isEmpty) {
    return 'The wallet returned an error without a message. Check the wallet '
        'and try again.';
  }
  return text;
}
