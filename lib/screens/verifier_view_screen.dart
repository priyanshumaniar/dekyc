import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/chain_config.dart';
import '../services/kyc_flow_service.dart';
import '../services/wallet_service.dart';
import '../theme/app_theme.dart';
import '../theme/components.dart';

/// USER-side screen: your on-chain guest list. Add a verifier's wallet
/// address, grant them time-boxed access (a real transaction) and share your
/// decryption key with them; revoke any time. There is no on-chain "request"
/// — YOU decide who gets in.
class VerifierViewScreen extends StatefulWidget {
  const VerifierViewScreen({super.key});

  @override
  State<VerifierViewScreen> createState() => _VerifierViewScreenState();
}

class _VerifierViewScreenState extends State<VerifierViewScreen> {
  final WalletService _wallet = WalletService.instance;
  final KycFlowService _flow = KycFlowService();
  final TextEditingController _addrCtrl = TextEditingController();
  final List<String> _verifiers = [];
  String? _busyAddr;

  @override
  void dispose() {
    _addrCtrl.dispose();
    super.dispose();
  }

  // A well-formed Ethereum address: 0x followed by exactly 40 hex chars.
  static final RegExp _addressPattern = RegExp(r'^0x[0-9a-fA-F]{40}$');

  void _addRequest() {
    final addr = _addrCtrl.text.trim();
    // Validate the FULL address (not just length/prefix) at add time, so a
    // malformed entry is rejected here in the UI rather than failing later at
    // transaction time inside EthereumAddress.fromHex.
    if (!_addressPattern.hasMatch(addr)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid 0x… wallet address')),
      );
      return;
    }
    setState(() {
      if (!_verifiers.contains(addr)) _verifiers.add(addr);
      _addrCtrl.clear();
    });
  }

  Future<void> _grant(String verifier) async {
    setState(() => _busyAddr = verifier);
    try {
      final tx = await _flow.grantAccess(verifier, const Duration(days: 7));
      if (!mounted) return;
      _showTx('Access granted', tx);
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busyAddr = null);
    }
  }

  Future<void> _revoke(String verifier) async {
    setState(() => _busyAddr = verifier);
    try {
      final tx = await _flow.revokeAccess(verifier);
      if (!mounted) return;
      _showTx('Access revoked', tx);
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busyAddr = null);
    }
  }

  Future<void> _shareKey() async {
    try {
      final key = await _flow.deriveUserKey();
      final hex = key
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Decryption key'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Share this with the verifier over a secure channel so they '
                'can decrypt your documents. The key — not the chain — is '
                "what actually unlocks them, so only share it with someone "
                'you granted access to.',
              ),
              const SizedBox(height: 12),
              SelectableText(hex, style: const TextStyle(fontSize: 12)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: hex));
                Navigator.pop(context);
              },
              child: const Text('Copy'),
            ),
          ],
        ),
      );
    } catch (e) {
      _showError(e);
    }
  }

  void _showTx(String title, String tx) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SelectableText(ChainConfig.txUrl(tx)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$e')));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final connected = _wallet.isConnected;
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Access')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!connected)
                  Text(
                    'Connect your wallet first to manage access.',
                    style: TextStyle(color: p.danger),
                  )
                else
                  Center(
                      child: DeUI.addressPill(context, _wallet.address!)),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _addrCtrl,
                        decoration: const InputDecoration(
                          labelText: "Verifier wallet address (0x…)",
                          prefixIcon: Icon(Icons.badge_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 84,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            minimumSize: const Size(0, 52)),
                        onPressed: _addRequest,
                        child: const Text('Add'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: connected ? _shareKey : null,
                    icon: const Icon(Icons.key, size: 18),
                    label: const Text('Reveal decryption key'),
                  ),
                ),
                Divider(color: p.hairline),
                const SizedBox(height: 6),
                DeUI.sectionHeader(context, 'Your guest list'),
                const SizedBox(height: 10),
                Expanded(
                  child: _verifiers.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              DeUI.iconChip(
                                  context, Icons.rule_outlined,
                                  size: 52, color: p.muted),
                              const SizedBox(height: 12),
                              Text(
                                'Nobody has access yet.\nAdd a verifier\'s '
                                'address above, then Grant.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: p.muted, height: 1.5),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          itemCount: _verifiers.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (_, i) {
                            final v = _verifiers[i];
                            final busy = _busyAddr == v;
                            return DeUI.card(
                              context,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              child: Row(
                                children: [
                                  DeUI.iconChip(
                                      context, Icons.apartment_outlined),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          DeUI.shortAddress(v),
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700),
                                        ),
                                        const SizedBox(height: 2),
                                        Text('Verifier',
                                            style: TextStyle(
                                                color: p.muted,
                                                fontSize: 12.5)),
                                      ],
                                    ),
                                  ),
                                  if (busy)
                                    const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  else ...[
                                    IconButton(
                                      tooltip: 'Grant 7-day access',
                                      icon: Icon(Icons.check_circle,
                                          color: p.success),
                                      onPressed: connected
                                          ? () => _grant(v)
                                          : null,
                                    ),
                                    IconButton(
                                      tooltip: 'Revoke access',
                                      icon: Icon(Icons.cancel,
                                          color: p.danger),
                                      onPressed: connected
                                          ? () => _revoke(v)
                                          : null,
                                    ),
                                  ],
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
