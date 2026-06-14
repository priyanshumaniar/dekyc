import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/wallet_service.dart';
import '../theme/app_theme.dart';
import '../theme/components.dart';
import 'wallet_connect_screen.dart';

/// Role-based wallet login. The user picks WHO they are (Individual or
/// Verifier), connects a wallet, and signs a free challenge message that
/// proves key control. The signed role shapes the dashboard.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final WalletService _wallet = WalletService.instance;
  final AuthService _auth = AuthService.instance;

  UserRole _role = UserRole.individual;
  bool _busy = false;
  String? _error;

  Future<void> _continueWithWallet() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // 1) Connect a wallet if none is connected yet.
      if (!_wallet.isConnected) {
        final connected = await Navigator.of(context).push<bool>(
          MaterialPageRoute(builder: (_) => const WalletConnectScreen()),
        );
        if (connected != true && !_wallet.isConnected) {
          setState(() => _busy = false);
          return;
        }
      }
      // 2) Prove control of the key: one free signature, verified locally.
      await _auth.signIn(_role);
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/dashboard');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                'Choose your role',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                'Your wallet is your login — no email, no password. '
                'You will sign one free message to prove the wallet is yours.',
                style: TextStyle(color: p.muted, height: 1.5, fontSize: 13.5),
              ),
              const SizedBox(height: 22),
              _roleCard(
                role: UserRole.individual,
                icon: Icons.badge_outlined,
                title: 'Individual',
                subtitle: 'Submit KYC once, control who can read it, '
                    'collect reusable Verified badges.',
              ),
              const SizedBox(height: 12),
              _roleCard(
                role: UserRole.verifier,
                icon: Icons.travel_explore_outlined,
                title: 'Verifier',
                subtitle: 'Bank, exchange or employer: check access, read '
                    'documents, mint Verified badges.',
              ),
              const SizedBox(height: 26),
              ElevatedButton.icon(
                onPressed: _busy ? null : _continueWithWallet,
                icon: _busy
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: p.onAccent),
                      )
                    : const Icon(Icons.account_balance_wallet_outlined,
                        size: 20),
                label: Text(
                    _busy ? 'Check your wallet…' : 'Continue as ${_role.label}'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.danger, fontSize: 13),
                ),
              ],
              const SizedBox(height: 12),
              Center(
                child: Text(
                  'Signing costs nothing and sends no transaction.',
                  style: TextStyle(color: p.muted, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _roleCard({
    required UserRole role,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final p = context.pal;
    final selected = _role == role;
    return InkWell(
      onTap: _busy ? null : () => setState(() => _role = role),
      borderRadius: BorderRadius.circular(AppTheme.radius),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: p.surface,
          border: Border.all(
            color: selected ? p.accent : p.hairline,
            width: selected ? 1.6 : 1,
          ),
          borderRadius: BorderRadius.circular(AppTheme.radius),
        ),
        child: Row(
          children: [
            DeUI.iconChip(context, icon,
                color: selected ? p.accent : p.muted),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(subtitle,
                      style: TextStyle(
                          color: p.muted, fontSize: 12.5, height: 1.4)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: selected ? p.accent : p.hairline,
            ),
          ],
        ),
      ),
    );
  }
}
