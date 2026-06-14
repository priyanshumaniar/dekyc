import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/wallet_service.dart';
import '../theme/app_theme.dart';
import '../theme/components.dart';

/// Shown when no wallet is connected. One-click MetaMask connect on web
/// (injected provider); WalletConnect QR + deeplinks on mobile.
///
/// Pops `true` once a session is established.
class WalletConnectScreen extends StatefulWidget {
  const WalletConnectScreen({super.key});

  @override
  State<WalletConnectScreen> createState() => _WalletConnectScreenState();
}

class _WalletConnectScreenState extends State<WalletConnectScreen> {
  final WalletService _wallet = WalletService.instance;
  String? _uri;
  String? _error;
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    // Only spin up the WalletConnect QR when there's no browser extension.
    if (!_wallet.injectedAvailable) {
      _startPairing();
    }
  }

  Future<void> _connectInjected() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final address = await _wallet.connectInjected();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connected: ${DeUI.shortAddress(address)}')),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _startPairing() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final pairing = await _wallet.createPairing();
      setState(() {
        _uri = pairing.uri?.toString();
      });
      // Wait for the wallet to approve in the background.
      final address = await _wallet.awaitSession(pairing);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connected: ${DeUI.shortAddress(address)}')),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _openInWallet(String scheme) async {
    final uri = _uri;
    if (uri == null) return;
    final encoded = Uri.encodeComponent(uri);
    final deeplink = Uri.parse('$scheme$encoded');
    if (await canLaunchUrl(deeplink)) {
      await launchUrl(deeplink, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Scaffold(
      appBar: AppBar(title: const Text('Connect Wallet')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  DeUI.logoMark(context, size: 56),
                  const SizedBox(height: 18),
                  Text(
                    _wallet.injectedAvailable
                        ? 'Connect your wallet'
                        : 'Scan with your wallet',
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Your wallet address is your DeKYC identity.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: p.muted),
                  ),
                  const SizedBox(height: 24),
                  // Preferred path on web: one-click connect to the extension.
                  if (_wallet.injectedAvailable) ...[
                    if (_error != null)
                      _ErrorBox(message: _error!, onRetry: _connectInjected)
                    else
                      ElevatedButton.icon(
                        onPressed: _connecting ? null : _connectInjected,
                        icon: _connecting
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: p.onAccent),
                              )
                            : const Icon(Icons.account_balance_wallet,
                                size: 20),
                        label: Text(_connecting
                            ? 'Check your wallet…'
                            : 'Connect MetaMask'),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      'A wallet popup will ask you to connect and switch to '
                      'Sepolia.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: p.muted, fontSize: 12),
                    ),
                  ] else if (_error != null)
                    _ErrorBox(message: _error!, onRetry: _startPairing)
                  else if (_uri == null)
                    const Padding(
                      padding: EdgeInsets.all(40),
                      child: CircularProgressIndicator(),
                    )
                  else ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white, // QR needs a light quiet zone
                        borderRadius:
                            BorderRadius.circular(AppTheme.radius),
                      ),
                      child: QrImageView(
                        data: _uri!,
                        version: QrVersions.auto,
                        size: 230,
                      ),
                    ),
                    const SizedBox(height: 12),
                    DeUI.card(
                      context,
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline,
                              size: 18, color: p.muted),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Enable "Show test networks" and select '
                              'Sepolia in your wallet before scanning — '
                              'DeKYC runs on Sepolia only.',
                              style: TextStyle(
                                  color: p.muted, fontSize: 12.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _uri!));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Pairing URI copied')),
                        );
                      },
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('Copy URI'),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      alignment: WrapAlignment.center,
                      children: [
                        _walletButton('MetaMask', 'metamask://wc?uri='),
                        _walletButton('Trust', 'trust://wc?uri='),
                        _walletButton('Rainbow', 'rainbow://wc?uri='),
                      ],
                    ),
                    if (_connecting) ...[
                      const SizedBox(height: 20),
                      Text('Waiting for wallet approval…',
                          style: TextStyle(color: p.muted)),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _walletButton(String label, String scheme) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
      onPressed: () => _openInWallet(scheme),
      child: Text(label),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Column(
      children: [
        Icon(Icons.error_outline, color: p.danger, size: 48),
        const SizedBox(height: 12),
        Text(message,
            textAlign: TextAlign.center,
            style: TextStyle(color: p.danger)),
        const SizedBox(height: 12),
        ElevatedButton(
          onPressed: onRetry,
          child: const Text('Retry'),
        ),
      ],
    );
  }
}
