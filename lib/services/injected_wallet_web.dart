import 'dart:js_interop';

/// Web implementation backed by the injected EIP-1193 provider
/// (`window.ethereum`, e.g. the MetaMask browser extension). No QR needed.
class InjectedWallet {
  /// True when a browser wallet extension has injected `window.ethereum`.
  static bool get isAvailable => _ethereum != null;

  /// Sepolia chain id as the hex string EIP-3326 expects.
  static const String _sepoliaHex = '0xaa36a7'; // 11155111

  _Ethereum get _provider {
    final e = _ethereum;
    if (e == null) {
      throw StateError('No injected wallet found (window.ethereum is null).');
    }
    return e;
  }

  /// Prompt the extension and return the selected account address.
  Future<String> connect() async {
    final res = await _provider
        .request(_Req(method: 'eth_requestAccounts'.toJS))
        .toDart;
    final accounts = (res as JSArray).toDart;
    if (accounts.isEmpty) {
      throw StateError('No accounts returned by the wallet.');
    }
    return (accounts.first as JSString).toDart;
  }

  /// Already-authorized accounts WITHOUT prompting (eth_accounts). Returns
  /// null when the site isn't connected yet. Used for silent session restore.
  Future<String?> connectedAccount() async {
    try {
      final res =
          await _provider.request(_Req(method: 'eth_accounts'.toJS)).toDart;
      final accounts = (res as JSArray).toDart;
      if (accounts.isEmpty) return null;
      return (accounts.first as JSString).toDart;
    } catch (_) {
      return null;
    }
  }

  /// Subscribe to MetaMask account switches. [handler] receives the new
  /// primary address, or null when the user disconnected the site.
  void onAccountsChanged(void Function(String?) handler) {
    final cb = (JSArray accounts) {
      final list = accounts.toDart;
      handler(list.isEmpty ? null : (list.first as JSString).toDart);
    }.toJS;
    _provider.on('accountsChanged'.toJS, cb);
  }

  /// Ask the wallet to switch to Sepolia; if it isn't added, add it. Failures
  /// are swallowed so the caller can continue (user may switch manually).
  Future<void> ensureSepolia() async {
    try {
      await _provider
          .request(_Req(
            method: 'wallet_switchEthereumChain'.toJS,
            params: [_ChainId(chainId: _sepoliaHex.toJS)].toJS,
          ))
          .toDart;
    } catch (_) {
      try {
        await _provider
            .request(_Req(
              method: 'wallet_addEthereumChain'.toJS,
              params: [
                _AddChain(
                  chainId: _sepoliaHex.toJS,
                  chainName: 'Sepolia'.toJS,
                  rpcUrls: ['https://rpc.sepolia.org'.toJS].toJS,
                  blockExplorerUrls: ['https://sepolia.etherscan.io'.toJS].toJS,
                  nativeCurrency: _NativeCurrency(
                    name: 'Sepolia Ether'.toJS,
                    symbol: 'ETH'.toJS,
                    decimals: 18.toJS,
                  ),
                ),
              ].toJS,
            ))
            .toDart;
      } catch (_) {
        // Leave it to the user to switch networks in the wallet.
      }
    }
  }

  /// The wallet's currently selected chain id as a 0x-hex string
  /// (EIP-695 `eth_chainId`). Used to guard transactions against being sent
  /// on the wrong network.
  Future<String> currentChainHex() async {
    final res =
        await _provider.request(_Req(method: 'eth_chainId'.toJS)).toDart;
    return (res as JSString).toDart.toLowerCase();
  }

  /// personal_sign. [hexMessage] must be 0x-hex; returns the 0x-hex signature.
  Future<String> personalSign(String hexMessage, String address) async {
    final res = await _provider
        .request(_Req(
          method: 'personal_sign'.toJS,
          params: [hexMessage.toJS, address.toJS].toJS,
        ))
        .toDart;
    return (res as JSString).toDart;
  }

  /// eth_sendTransaction. Returns the tx hash.
  Future<String> sendTransaction({
    required String from,
    required String to,
    required String data,
    String? value,
  }) async {
    final tx = _Tx(
      from: from.toJS,
      to: to.toJS,
      data: data.toJS,
      value: value?.toJS,
    );
    final res = await _provider
        .request(_Req(method: 'eth_sendTransaction'.toJS, params: [tx].toJS))
        .toDart;
    return (res as JSString).toDart;
  }
}

@JS('window.ethereum')
external _Ethereum? get _ethereum;

extension type _Ethereum(JSObject _) implements JSObject {
  external JSPromise<JSAny?> request(_Req args);
  external void on(JSString event, JSFunction callback);
}

extension type _Req._(JSObject _) implements JSObject {
  external factory _Req({required JSString method, JSArray<JSAny?>? params});
}

extension type _ChainId._(JSObject _) implements JSObject {
  external factory _ChainId({required JSString chainId});
}

extension type _Tx._(JSObject _) implements JSObject {
  external factory _Tx({
    required JSString from,
    required JSString to,
    required JSString data,
    JSString? value,
  });
}

extension type _NativeCurrency._(JSObject _) implements JSObject {
  external factory _NativeCurrency({
    required JSString name,
    required JSString symbol,
    required JSNumber decimals,
  });
}

extension type _AddChain._(JSObject _) implements JSObject {
  external factory _AddChain({
    required JSString chainId,
    required JSString chainName,
    required JSArray<JSString> rpcUrls,
    required JSArray<JSString> blockExplorerUrls,
    required _NativeCurrency nativeCurrency,
  });
}
