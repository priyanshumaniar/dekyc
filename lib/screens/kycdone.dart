import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/chain_config.dart';
import '../theme/app_theme.dart';
import '../theme/components.dart';

class KYCDoneScreen extends StatelessWidget {
  const KYCDoneScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    // Optional on-chain details passed from the upload flow.
    final args =
        ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    final txHash = args?['txHash'] as String?;
    final cid = args?['cid'] as String?;

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: p.success.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.check_rounded, size: 56, color: p.success),
                ),
                const SizedBox(height: 24),
                const Text(
                  'KYC Submitted',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your documents were encrypted on this device, pinned to '
                  'IPFS, and the reference is anchored on-chain.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 14.5, color: p.muted, height: 1.5),
                ),
                if (txHash != null) ...[
                  const SizedBox(height: 24),
                  _OnChainCard(txHash: txHash, cid: cid),
                ],
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () {
                    Navigator.pushNamedAndRemoveUntil(
                        context, '/dashboard', (route) => false);
                  },
                  child: const Text('Go to Dashboard'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OnChainCard extends StatelessWidget {
  const _OnChainCard({required this.txHash, this.cid});
  final String txHash;
  final String? cid;

  String get _shortTx =>
      '${txHash.substring(0, 10)}…${txHash.substring(txHash.length - 8)}';

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return DeUI.card(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              DeUI.iconChip(context, Icons.receipt_long_outlined, size: 36),
              const SizedBox(width: 10),
              const Text('Transaction',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const Spacer(),
              DeUI.statusChip(context, 'Confirmed', p.success),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(_shortTx, style: TextStyle(color: p.muted)),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: 'Copy tx hash',
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: txHash)),
              ),
            ],
          ),
          if (cid != null) ...[
            const SizedBox(height: 8),
            const Text('IPFS CID',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            SelectableText(cid!,
                style: TextStyle(color: p.muted, fontSize: 13)),
          ],
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: () async {
              final uri = Uri.parse(ChainConfig.txUrl(txHash));
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('View on Etherscan'),
          ),
        ],
      ),
    );
  }
}
