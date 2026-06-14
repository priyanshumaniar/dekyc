import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/chain_config.dart';
import '../config/contract_address.dart';
import '../services/auth_service.dart';
import '../services/kyc_flow_service.dart';
import '../services/wallet_service.dart';
import '../theme/app_theme.dart';
import '../theme/components.dart';
import 'wallet_connect_screen.dart';

/// Wallet identity, appearance, network details, encryption-key tools and
/// sign-out.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final WalletService _wallet = WalletService.instance;
  final KycFlowService _flow = KycFlowService();
  bool _revealing = false;

  Future<void> _connect() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const WalletConnectScreen()),
    );
    if (mounted) setState(() {});
  }

  Future<void> _signOut() async {
    final p = context.pal;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
            'This ends your session and disconnects the wallet. You can sign '
            'back in at any time. Your on-chain data is unaffected.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Sign out', style: TextStyle(color: p.danger)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await AuthService.instance.signOut();
    if (!mounted) return;
    Navigator.of(context)
        .pushNamedAndRemoveUntil('/onboarding', (route) => false);
  }

  Future<void> _revealKey() async {
    setState(() => _revealing = true);
    try {
      final key = await _flow.deriveUserKey();
      final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      if (!mounted) return;
      final p = context.pal;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Decryption key'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Derived from your wallet signature — never stored anywhere. '
                'Share it only with a verifier you have granted access to.',
              ),
              const SizedBox(height: 12),
              SelectableText(hex,
                  style: TextStyle(fontSize: 12, color: p.text)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: hex));
                Navigator.pop(context);
              },
              child: const Text('Copy & close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _revealing = false);
    }
  }

  Future<void> _openEtherscan(String address) async {
    final uri = Uri.parse(ChainConfig.addressUrl(address));
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListenableBuilder(
        listenable: _wallet,
        builder: (context, _) {
          final address = _wallet.address;
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: address == null
                  ? _disconnectedView()
                  : _profileBody(address),
            ),
          );
        },
      ),
    );
  }

  Widget _profileBody(String address) {
    final p = context.pal;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // Identity card
        DeUI.card(
          context,
          padding: const EdgeInsets.all(22),
          child: Column(
            children: [
              DeUI.logoMark(context, size: 56),
              const SizedBox(height: 14),
              Text(
                DeUI.shortAddress(address),
                style: const TextStyle(
                    fontSize: 19, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text('Your wallet is your identity',
                  style: TextStyle(color: p.muted, fontSize: 13)),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 46)),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: address));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Address copied')),
                        );
                      },
                      icon: const Icon(Icons.copy, size: 17),
                      label: const Text('Copy'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 46)),
                      onPressed: () => _openEtherscan(address),
                      icon: const Icon(Icons.open_in_new, size: 17),
                      label: const Text('Etherscan'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        DeUI.sectionHeader(context, 'Session'),
        const SizedBox(height: 10),
        _sessionCard(),
        const SizedBox(height: 18),
        DeUI.sectionHeader(context, 'Appearance'),
        const SizedBox(height: 10),
        ListenableBuilder(
          listenable: ThemeController.instance,
          builder: (context, _) => DeUI.row(
            context,
            icon: ThemeController.instance.isDark
                ? Icons.dark_mode_outlined
                : Icons.light_mode_outlined,
            title: ThemeController.instance.isDark
                ? 'Dark mode'
                : 'Light mode',
            subtitle: 'Default is dark — like any good wallet.',
            trailing: Switch(
              value: ThemeController.instance.isDark,
              onChanged: (_) => ThemeController.instance.toggle(),
            ),
          ),
        ),
        const SizedBox(height: 18),
        DeUI.sectionHeader(context, 'Network & contracts'),
        const SizedBox(height: 10),
        DeUI.row(
          context,
          icon: Icons.lan_outlined,
          title: 'Network',
          subtitle:
              '${ChainConfig.networkName} · chainId ${ChainConfig.chainId}',
        ),
        const SizedBox(height: 10),
        DeUI.row(
          context,
          icon: Icons.description_outlined,
          title: 'KYC Registry contract',
          subtitle: DeUI.shortAddress(kKycRegistryAddress),
          trailing: Icon(Icons.open_in_new, size: 16, color: p.muted),
          onTap: () => _openEtherscan(kKycRegistryAddress),
        ),
        const SizedBox(height: 10),
        DeUI.row(
          context,
          icon: Icons.verified_outlined,
          title: 'Soulbound badge contract',
          subtitle: DeUI.shortAddress(kKycSbtAddress),
          trailing: Icon(Icons.open_in_new, size: 16, color: p.muted),
          onTap: () => _openEtherscan(kKycSbtAddress),
        ),
        const SizedBox(height: 18),
        DeUI.sectionHeader(context, 'Security'),
        const SizedBox(height: 10),
        DeUI.row(
          context,
          icon: Icons.key_outlined,
          title: 'Reveal decryption key',
          subtitle: _revealing
              ? 'Check your wallet for a signature request…'
              : 'Re-derive your AES key from a wallet signature.',
          onTap: _revealing ? null : _revealKey,
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: p.danger,
            side: BorderSide(color: p.danger.withValues(alpha: 0.6)),
          ),
          onPressed: _signOut,
          icon: const Icon(Icons.logout, size: 18),
          label: const Text('Sign out'),
        ),
      ],
    );
  }

  /// Session details: role + remaining validity, or a sign-in nudge when the
  /// wallet is connected but no signed session exists.
  Widget _sessionCard() {
    final p = context.pal;
    final session = AuthService.instance.session;
    if (session == null || session.isExpired) {
      return DeUI.row(
        context,
        icon: Icons.lock_open_outlined,
        iconColor: p.warning,
        title: 'Not signed in',
        subtitle: 'Wallet connected, but no signed session. Sign in to act.',
        onTap: () => Navigator.pushNamed(context, '/login'),
      );
    }
    final remaining = session.expiresAt.difference(DateTime.now().toUtc());
    final hours = remaining.inHours;
    final minutes = remaining.inMinutes % 60;
    return DeUI.row(
      context,
      icon: session.role == UserRole.individual
          ? Icons.badge_outlined
          : Icons.travel_explore_outlined,
      iconColor: p.success,
      title: 'Session — ${session.role.label}',
      subtitle: 'Signature-verified · expires in ${hours}h ${minutes}m.',
    );
  }

  Widget _disconnectedView() {
    final p = context.pal;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DeUI.iconChip(context, Icons.account_balance_wallet_outlined,
                size: 56, color: p.muted),
            const SizedBox(height: 16),
            const Text('No wallet connected',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              'Connect a wallet to manage your DeKYC identity.',
              textAlign: TextAlign.center,
              style: TextStyle(color: p.muted),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _connect,
              child: const Text('Connect Wallet'),
            ),
          ],
        ),
      ),
    );
  }
}
