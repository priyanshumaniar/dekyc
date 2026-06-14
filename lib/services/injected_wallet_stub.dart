/// Non-web stub. There is no injected `window.ethereum` off the browser, so
/// [isAvailable] is false and the methods are never called.
class InjectedWallet {
  static bool get isAvailable => false;

  Future<String> connect() =>
      throw UnsupportedError('Injected wallet is web-only.');

  Future<String?> connectedAccount() async => null;

  void onAccountsChanged(void Function(String?) handler) {}

  Future<void> ensureSepolia() =>
      throw UnsupportedError('Injected wallet is web-only.');

  Future<String> currentChainHex() =>
      throw UnsupportedError('Injected wallet is web-only.');

  Future<String> personalSign(String hexMessage, String address) =>
      throw UnsupportedError('Injected wallet is web-only.');

  Future<String> sendTransaction({
    required String from,
    required String to,
    required String data,
    String? value,
  }) =>
      throw UnsupportedError('Injected wallet is web-only.');
}
