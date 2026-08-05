import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/kyc_flow_service.dart';
import '../services/wallet_service.dart';
import '../theme/app_theme.dart';
import '../theme/components.dart';
import 'how_to_use.dart';

/// VERIFIER-side screen. A verifier (bank / exchange / employer) enters a
/// user's wallet address and checks whether the user has granted them access.
/// On-chain there is no "request" call — the verifier simply polls
/// `hasAccess(user, verifier)`. Once granted, they proceed to read the docs.
class AccessRequestScreen extends StatefulWidget {
  const AccessRequestScreen({super.key});

  @override
  State<AccessRequestScreen> createState() => _AccessRequestScreenState();
}

class _AccessRequestScreenState extends State<AccessRequestScreen> {
  final WalletService _wallet = WalletService.instance;
  final KycFlowService _flow = KycFlowService();
  final TextEditingController _userCtrl = TextEditingController();

  bool _checking = false;
  bool? _hasAccess;
  String? _status;

  @override
  void dispose() {
    _userCtrl.dispose();
    super.dispose();
  }

  /// Acting as a verifier requires a signed Verifier session — the verifier's
  /// address ends up in on-chain access checks, so prove key control first.
  Future<bool> _ensureVerifierSession() async {
    final auth = AuthService.instance;
    if (!auth.isAuthenticated) {
      await Navigator.pushNamed(context, '/login');
      if (!mounted || !auth.isAuthenticated) return false;
    }
    if (auth.role != UserRole.verifier) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You are signed in as an Individual. Switch role '
                'to Verifier (Dashboard → Switch role) to verify users.'),
          ),
        );
      }
      return false;
    }
    return true;
  }

  Future<void> _checkStatus() async {
    final user = _userCtrl.text.trim();
    if (user.length != 42 || !user.startsWith('0x')) {
      setState(() => _status = 'Enter a valid 0x… user address');
      return;
    }
    if (!await _ensureVerifierSession()) return;
    if (!_wallet.isConnected) {
      // Every other failure branch here reports itself; this one used to
      // return silently, so the button looked broken.
      setState(() => _status = 'Connect your wallet to check access.');
      return;
    }

    setState(() {
      _checking = true;
      _status = null;
      _hasAccess = null;
    });
    try {
      final hasRecord = await _flow.hasRecord(user);
      if (!hasRecord) {
        setState(() => _status = 'This address has no KYC on record.');
        return;
      }
      final granted = await _flow.hasAccess(user, _wallet.address!);
      setState(() {
        _hasAccess = granted;
        _status = granted
            ? 'Access granted! You may now read the documents.'
            : 'Pending — ask the user to grant access to your address.';
      });
    } catch (e) {
      setState(() => _status = 'Error: $e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Verifier Mode'),
        actions: [
          IconButton(
            tooltip: 'How verifying works',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const HowToUseScreen(role: UserRole.verifier),
              ),
            ),
            icon: const Icon(Icons.help_outline),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                if (_wallet.isConnected)
                  DeUI.addressPill(context, _wallet.address!)
                else
                  Text(
                    'Sign in as a Verifier to identify yourself.',
                    style: TextStyle(color: p.muted, fontSize: 12.5),
                  ),
                const SizedBox(height: 20),
                TextField(
                  controller: _userCtrl,
                  decoration: const InputDecoration(
                    labelText: "User's wallet address (0x…)",
                    prefixIcon: Icon(Icons.person_search_outlined),
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _checking ? null : _checkStatus,
                  child: _checking
                      ? SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: p.onAccent),
                        )
                      : const Text('Check Access Status'),
                ),
                const SizedBox(height: 24),
                if (_status != null)
                  DeUI.card(
                    context,
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        DeUI.iconChip(
                          context,
                          _hasAccess == true
                              ? Icons.check_circle_outline
                              : Icons.hourglass_top,
                          color:
                              _hasAccess == true ? p.success : p.muted,
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Text(_status!)),
                        if (_hasAccess == true) ...[
                          const SizedBox(width: 8),
                          DeUI.statusChip(context, 'Granted', p.success),
                        ],
                      ],
                    ),
                  ),
                const Spacer(),
                if (_hasAccess == true)
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pushNamed(
                        context,
                        '/accessgranted',
                        arguments: {
                          'userAddress': _userCtrl.text.trim(),
                          'verifierAddress': _wallet.address,
                        },
                      );
                    },
                    icon: const Icon(Icons.folder_open, size: 20),
                    label: const Text('View Documents'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
