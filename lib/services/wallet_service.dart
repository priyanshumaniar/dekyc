import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:reown_walletkit/reown_walletkit.dart';

import '../config/chain_config.dart';
import 'injected_wallet.dart';

/// Connects the app to a mobile wallet (MetaMask / Trust / Rainbow) over
/// WalletConnect v2 (Reown), and proxies message-signing and transaction
/// sending to that wallet. The private key NEVER touches this app.
///
/// Singleton: use [WalletService.instance].
class WalletService extends ChangeNotifier {
  WalletService._();
  static final WalletService instance = WalletService._();

  ReownSignClient? _client;
  SessionData? _session;
  String? _address; // cached connected address (checksummed lower-case hex)

  final InjectedWallet _injected = InjectedWallet();
  bool _useInjected = false; // true when connected via browser extension
  bool _injectedListenerOn = false;

  /// Keep the cached address in sync when the user switches MetaMask accounts.
  void _watchInjectedAccount() {
    if (_injectedListenerOn) return;
    _injectedListenerOn = true;
    _injected.onAccountsChanged((addr) {
      if (!_useInjected) return;
      _address = addr;
      if (addr == null) _useInjected = false;
      notifyListeners();
    });
  }

  /// Whether a browser wallet extension (window.ethereum) is available.
  bool get injectedAvailable => InjectedWallet.isAvailable;

  /// eip155 method set we ask the wallet to authorize.
  static const List<String> _methods = [
    'eth_sendTransaction',
    'personal_sign',
    'eth_signTypedData_v4',
  ];

  String? get address => _address;
  bool get isConnected =>
      _address != null && (_useInjected || _session != null);
  String get _topic => _session!.topic;

  /// Silently restore a previous injected-wallet session (no popup). Returns
  /// true when an authorized account was found and cached.
  Future<bool> tryRestoreSession() async {
    if (!InjectedWallet.isAvailable) return false;
    try {
      final addr = await _injected.connectedAccount();
      if (addr == null || addr.isEmpty) return false;
      _address = addr;
      _useInjected = true;
      _watchInjectedAccount();
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Connect via the injected browser extension (MetaMask etc.). No QR.
  /// Returns the connected address.
  Future<String> connectInjected() async {
    if (!InjectedWallet.isAvailable) {
      throw StateError('No browser wallet detected.');
    }
    final addr = await _injected.connect();
    await _injected.ensureSepolia();
    _address = addr;
    _useInjected = true;
    _watchInjectedAccount();
    notifyListeners();
    return addr;
  }

  /// Initialise the underlying Reown sign client. Safe to call repeatedly.
  Future<void> init() async {
    if (_client != null) return;
    final projectId = dotenv.maybeGet('WALLETCONNECT_PROJECT_ID') ?? '';
    if (projectId.isEmpty || projectId == 'YOUR_WALLETCONNECT_PROJECT_ID') {
      throw StateError(
        'WALLETCONNECT_PROJECT_ID is not set. Add it to your .env.',
      );
    }
    _client = await ReownSignClient.createInstance(
      projectId: projectId,
      metadata: const PairingMetadata(
        name: 'DeKYC',
        description: 'Self-sovereign KYC on Ethereum',
        url: 'https://dekyc.example',
        icons: ['https://avatars.githubusercontent.com/u/37784886'],
        redirect: Redirect(native: 'dekyc://', universal: null),
      ),
    );
  }

  /// Begin a pairing. Returns the `wc:` URI to render as a QR / deeplink.
  /// Await [awaitSession] (or the returned completer) to finish the handshake.
  ///
  /// Reown 1.3.x treats every requested chain as *optional* (requiredNamespaces
  /// is deprecated and auto-converted), so the wallet only grants the networks
  /// it currently has enabled. If the wallet's "Show test networks" is off it
  /// will approve the session WITHOUT Sepolia, after which every request on
  /// `eip155:11155111` fails with ReownSignError code 5100 ("Unsupported
  /// chains"). [awaitSession] guards against that and reports it clearly.
  Future<ConnectResponse> createPairing() async {
    await init();
    final resp = await _client!.connect(
      optionalNamespaces: {
        'eip155': const RequiredNamespace(
          chains: [ChainConfig.caip2],
          methods: _methods,
          events: ['chainChanged', 'accountsChanged'],
        ),
      },
    );
    return resp;
  }

  /// Wait for the wallet to approve the session opened by [createPairing],
  /// then cache the connected address. Returns the address.
  ///
  /// Defends against a wallet that approves the session without the Sepolia
  /// chain: rather than letting the user hit a cryptic "Unsupported chains"
  /// error later at submit time, we surface an actionable message now.
  Future<String> awaitSession(ConnectResponse pairing) async {
    final session = await pairing.session.future;

    if (!_sessionHasSepolia(session)) {
      // Tear the half-formed session down so a retry starts clean.
      try {
        await _client!.disconnect(
          topic: session.topic,
          reason: ReownSignError(
            code: 6000,
            message: 'Sepolia not enabled',
          ),
        );
      } catch (_) {/* best-effort cleanup */}
      throw StateError(
        'Your wallet connected but did not enable the Sepolia test network. '
        'In your wallet, turn on "Show test networks" (Settings → Advanced), '
        'select Sepolia, then connect again.',
      );
    }

    _session = session;
    _address = _extractAddress(session);
    notifyListeners();
    return _address!;
  }

  /// True when the approved session actually grants an account on Sepolia.
  static bool _sessionHasSepolia(SessionData session) {
    final accounts = session.namespaces['eip155']?.accounts ?? const [];
    // Each account is "eip155:11155111:0xabc..." — match the chain prefix.
    return accounts.any((a) => a.startsWith('${ChainConfig.caip2}:'));
  }

  /// Ask the connected wallet to sign [message] with `personal_sign`.
  /// Returns the signature as a 0x-hex string.
  Future<String> signMessage(String message) async {
    _requireConnected();
    final hexMessage = '0x${_bytesToHex(utf8.encode(message))}';
    if (_useInjected) {
      return _injected.personalSign(hexMessage, _address!);
    }
    final result = await _client!.request(
      topic: _topic,
      chainId: ChainConfig.caip2,
      request: SessionRequestParams(
        method: 'personal_sign',
        params: [hexMessage, _address],
      ),
    );
    return result as String;
  }

  /// Send a transaction through the connected wallet. [data] is the ABI-encoded
  /// calldata (see `KycContractService` encoders). Returns the tx hash.
  Future<String> sendTransaction({
    required String to,
    required Uint8List data,
    BigInt? value,
  }) async {
    _requireConnected();
    final dataHex = '0x${_bytesToHex(data)}';
    final valueHex = value != null ? '0x${value.toRadixString(16)}' : null;
    if (_useInjected) {
      await _ensureSepoliaForTx();
      return _injected.sendTransaction(
        from: _address!,
        to: to,
        data: dataHex,
        value: valueHex,
      );
    }
    final tx = <String, dynamic>{
      'from': _address,
      'to': to,
      'data': dataHex,
      if (valueHex != null) 'value': valueHex,
    };
    final result = await _client!.request(
      topic: _topic,
      chainId: ChainConfig.caip2,
      request: SessionRequestParams(
        method: 'eth_sendTransaction',
        params: [tx],
      ),
    );
    return result as String;
  }

  /// Disconnect the current session and clear the cached address.
  Future<void> disconnect() async {
    if (_useInjected) {
      _useInjected = false;
      _address = null;
      notifyListeners();
      return;
    }
    final client = _client;
    final session = _session;
    if (client != null && session != null) {
      await client.disconnect(
        topic: session.topic,
        reason: ReownSignError(code: 6000, message: 'User disconnected'),
      );
    }
    _session = null;
    _address = null;
    notifyListeners();
  }

  // --- helpers -------------------------------------------------------------

  /// Sepolia chain id as 0x-hex (11155111 = 0xaa36a7).
  static final String _sepoliaHex = '0x${ChainConfig.chainId.toRadixString(16)}';

  /// Transaction chain guard (injected path): the user may have switched
  /// MetaMask to another network AFTER connecting. Sending then would target
  /// the wrong chain — on mainnet that can burn real ETH on a contract
  /// address that means something else. Re-check and re-switch before every
  /// transaction; abort with a clear error if the wallet stays elsewhere.
  Future<void> _ensureSepoliaForTx() async {
    String chain;
    try {
      chain = await _injected.currentChainHex();
    } catch (_) {
      return; // provider doesn't answer eth_chainId — let the tx proceed
    }
    if (chain == _sepoliaHex) return;
    await _injected.ensureSepolia();
    try {
      chain = await _injected.currentChainHex();
    } catch (_) {
      return;
    }
    if (chain != _sepoliaHex) {
      throw StateError(
        'Wrong network: your wallet is on chain $chain, but DeKYC only '
        'works on Sepolia ($_sepoliaHex). Switch networks in MetaMask and '
        'try again.',
      );
    }
  }

  void _requireConnected() {
    if (!isConnected) {
      throw StateError('No wallet connected. Call createPairing() first.');
    }
  }

  /// Pull the first eip155 account from a session and normalise to `0x...`.
  static String _extractAddress(SessionData session) {
    final ns = session.namespaces['eip155'];
    final accounts = ns?.accounts ?? const [];
    if (accounts.isEmpty) {
      throw StateError('Wallet returned no eip155 accounts.');
    }
    // Format: "eip155:11155111:0xabc...". Take the last segment.
    return accounts.first.split(':').last;
  }

  static String _bytesToHex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
