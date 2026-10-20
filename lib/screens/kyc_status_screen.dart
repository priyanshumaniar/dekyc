import 'package:flutter/material.dart';

import '../services/badge.dart';
import '../services/kyc_flow_service.dart';
import '../services/wallet_service.dart';
import '../theme/app_theme.dart';
import '../theme/components.dart';
import 'badge_widgets.dart';
import 'wallet_connect_screen.dart';

/// USER-side screen. Shows whether the connected wallet has submitted KYC and
/// every reusable soulbound "Verified" badge it holds: who issued it, when,
/// and until when it is valid. The "verify once, reuse everywhere" status.
class KycStatusScreen extends StatefulWidget {
  const KycStatusScreen({super.key});

  @override
  State<KycStatusScreen> createState() => _KycStatusScreenState();
}

class _KycStatusScreenState extends State<KycStatusScreen> {
  final WalletService _wallet = WalletService.instance;
  final KycFlowService _flow = KycFlowService();

  bool _loading = false;
  String? _error;
  bool? _hasRecord;
  List<KycBadge> _badges = const [];

  @override
  void initState() {
    super.initState();
    if (_wallet.isConnected) _refresh();
  }

  Future<void> _ensureWalletThenRefresh() async {
    if (!_wallet.isConnected) {
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const WalletConnectScreen()),
      );
    }
    if (_wallet.isConnected) _refresh();
  }

  Future<void> _refresh() async {
    final addr = _wallet.address;
    if (addr == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final record = await _flow.hasRecord(addr);
      final badges = await _flow.badgesOf(addr);
      setState(() {
        _hasRecord = record;
        _badges = badges;
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Scaffold(
      appBar: AppBar(
        title: const Text('KYC Status'),
        actions: [
          if (_wallet.isConnected)
            IconButton(
              onPressed: _loading ? null : _refresh,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: !_wallet.isConnected
                ? _connectPrompt()
                : _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                        ? Center(
                            child: Text(_error!,
                                style: TextStyle(color: p.danger)))
                        : _statusBody(),
          ),
        ),
      ),
    );
  }

  Widget _connectPrompt() {
    final p = context.pal;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DeUI.iconChip(context, Icons.account_balance_wallet_outlined,
              size: 52, color: p.muted),
          const SizedBox(height: 14),
          const Text('Connect your wallet to see your status.'),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _ensureWalletThenRefresh,
            child: const Text('Connect Wallet'),
          ),
        ],
      ),
    );
  }

  Widget _statusBody() {
    final p = context.pal;
    final count = _badges.where((b) => b.counts).length;
    return ListView(
      children: [
        Center(child: DeUI.addressPill(context, _wallet.address!)),
        const SizedBox(height: 20),
        DeUI.row(
          context,
          icon: _hasRecord == true
              ? Icons.cloud_done_outlined
              : Icons.cloud_off_outlined,
          iconColor: _hasRecord == true ? p.success : p.muted,
          title: _hasRecord == true ? 'KYC submitted' : 'No KYC on-chain yet',
          subtitle: _hasRecord == true
              ? 'Your encrypted documents are pinned to IPFS and referenced '
                  'on-chain.'
              : 'Upload your documents from the dashboard to get started.',
          trailing: _hasRecord == true
              ? DeUI.statusChip(context, 'On-chain', p.success)
              : null,
        ),
        const SizedBox(height: 10),
        DeUI.row(
          context,
          icon: count > 0 ? Icons.verified : Icons.verified_outlined,
          iconColor: count > 0 ? p.success : p.muted,
          title: count > 0
              ? '$count valid verification badge${count == 1 ? '' : 's'}'
              : 'No valid badges right now',
          subtitle: 'A badge is a reusable, non-transferable proof that an '
              'organisation checked your KYC. Each one lists who issued it '
              'and how long it is valid.',
          trailing: count > 0
              ? DeUI.statusChip(context, '$count', p.success)
              : null,
        ),
        const SizedBox(height: 22),
        BadgeListSection(
          title: 'My badges',
          badges: _badges,
          side: BadgeSide.held,
          me: _wallet.address,
          emptyText: 'No badges yet. After a verifier approves your KYC they '
              'can issue you a badge, and it will appear here with its dates.',
        ),
      ],
    );
  }
}
