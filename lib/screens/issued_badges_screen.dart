import 'package:flutter/material.dart';

import '../services/badge.dart';
import '../services/kyc_flow_service.dart';
import '../services/tx_errors.dart';
import '../services/wallet_service.dart';
import '../theme/app_theme.dart';
import '../theme/components.dart';
import 'badge_widgets.dart';
import 'wallet_connect_screen.dart';

/// VERIFIER-side registry: every badge the connected wallet has issued, with
/// who it went to, when, until when, and whether it still counts. Read
/// straight from the chain (`badgesIssuedBy`), so it is the same on any device
/// and needs no admin: anyone can read any issuer's list.
class IssuedBadgesScreen extends StatefulWidget {
  const IssuedBadgesScreen({super.key});

  @override
  State<IssuedBadgesScreen> createState() => _IssuedBadgesScreenState();
}

class _IssuedBadgesScreenState extends State<IssuedBadgesScreen> {
  final WalletService _wallet = WalletService.instance;
  final KycFlowService _flow = KycFlowService();

  bool _loading = false;
  String? _error;
  List<KycBadge> _badges = const [];

  /// Subject address of the row currently being revoked.
  String? _revoking;

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
      final rows = await _flow.badgesIssuedBy(addr);
      if (!mounted) return;
      setState(() => _badges = rows);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not read your badges: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _revoke(KycBadge b) async {
    final subject = b.subject.hexEip55;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke this badge?'),
        content: Text(
          'The badge you issued to ${DeUI.shortAddress(subject)} stops '
          'counting straight away, for everyone who checks it. It stays listed '
          'as "Revoked" so the history is visible.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep it'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _revoking = subject);
    try {
      final tx = await _flow.revokeAttestation(subject);
      await _flow.awaitConfirmation(tx);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Badge revoked.')));
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Badge not revoked. ${describeTxError(e)}')));
    } finally {
      if (mounted) setState(() => _revoking = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Badges I issued'),
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
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Connect your verifier wallet to see the '
                            'badges it issued.'),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _ensureWalletThenRefresh,
                          child: const Text('Connect Wallet'),
                        ),
                      ],
                    ),
                  )
                : _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                        ? Center(
                            child: Text(_error!,
                                style: TextStyle(color: p.danger)))
                        : _body(),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    final p = context.pal;
    final valid = _badges.where((b) => b.counts).length;
    return ListView(
      children: [
        Center(child: DeUI.addressPill(context, _wallet.address!)),
        const SizedBox(height: 20),
        DeUI.row(
          context,
          icon: Icons.workspace_premium_outlined,
          iconColor: valid > 0 ? p.success : p.muted,
          title: _badges.isEmpty
              ? 'No badges issued yet'
              : '${_badges.length} user${_badges.length == 1 ? '' : 's'} '
                  'verified, $valid badge${valid == 1 ? '' : 's'} still valid',
          subtitle: 'One row per user: the latest badge you gave them. This '
              'list is public on the blockchain, so anyone can check which '
              'badges an organisation has issued.',
        ),
        const SizedBox(height: 22),
        BadgeListSection(
          title: 'Issued by me',
          badges: _badges,
          side: BadgeSide.issued,
          me: _wallet.address,
          emptyText: 'Open a user\'s documents from Verify and tap "Mark as '
              'Verified" to issue your first badge.',
          actionFor: (b) => b.counts
              ? TextButton(
                  onPressed: _revoking == null ? () => _revoke(b) : null,
                  child: Text(_revoking == b.subject.hexEip55
                      ? 'Revoking…'
                      : 'Revoke'),
                )
              : null,
        ),
      ],
    );
  }
}
