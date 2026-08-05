import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/kyc_flow_service.dart';
import '../services/wallet_service.dart';
import '../theme/app_theme.dart';
import '../theme/components.dart';

/// Wallet-style home (MetaMask-inspired). Account pill up top, a big identity
/// hero where a wallet would show its balance, a row of action tiles, and
/// role-aware sections below. Signed-out visitors get a sign-in banner.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _IdentitySnapshot {
  const _IdentitySnapshot({this.hasRecord, this.verifiedCount});
  final bool? hasRecord;
  final int? verifiedCount;
}

class _DashboardScreenState extends State<DashboardScreen> {
  final WalletService _wallet = WalletService.instance;
  final AuthService _auth = AuthService.instance;
  final KycFlowService _flow = KycFlowService();

  late final Listenable _listenable = Listenable.merge([_wallet, _auth]);

  bool _tourDismissed = false;

  // Identity snapshot is fetched once per address (not on every rebuild).
  String? _snapshotAddress;
  Future<_IdentitySnapshot>? _snapshot;

  Future<_IdentitySnapshot> _loadSnapshot(String address) async {
    try {
      final hasRecord = await _flow.hasRecord(address);
      final count = await _flow.verifiedCount(address);
      return _IdentitySnapshot(hasRecord: hasRecord, verifiedCount: count);
    } catch (_) {
      return const _IdentitySnapshot(); // RPC missing/down → quiet fallback
    }
  }

  void _ensureSnapshot() {
    final addr = _wallet.address;
    if (addr == null) {
      _snapshotAddress = null;
      _snapshot = null;
      return;
    }
    if (addr != _snapshotAddress) {
      _snapshotAddress = addr;
      _snapshot = _loadSnapshot(addr);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return ListenableBuilder(
      listenable: _listenable,
      builder: (context, _) {
        final session = _auth.isAuthenticated ? _auth.session : null;
        final role = session?.role;
        _ensureSnapshot();
        return Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: const Text('DeKYC'),
            leading: IconButton(
              tooltip: ThemeController.instance.isDark
                  ? 'Switch to light mode'
                  : 'Switch to dark mode',
              icon: Icon(
                ThemeController.instance.isDark
                    ? Icons.light_mode_outlined
                    : Icons.dark_mode_outlined,
                size: 21,
              ),
              onPressed: () => ThemeController.instance.toggle(),
            ),
            actions: [
              IconButton(
                tooltip: 'Profile',
                icon: const Icon(Icons.person_outline, size: 22),
                onPressed: () => Navigator.pushNamed(context, '/profile'),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
                children: [
                  // Account pill (like the wallet's "Account 1" chip).
                  Center(
                    child: _wallet.address == null
                        ? DeUI.statusChip(context, 'Not connected', p.muted)
                        : Column(
                            children: [
                              DeUI.addressPill(context, _wallet.address!,
                                  onTap: () => Navigator.pushNamed(
                                      context, '/profile')),
                              if (role != null) ...[
                                const SizedBox(height: 8),
                                DeUI.statusChip(
                                  context,
                                  role == UserRole.individual
                                      ? 'Individual'
                                      : 'Verifier',
                                  p.accent,
                                ),
                              ],
                            ],
                          ),
                  ),
                  const SizedBox(height: 22),
                  _identityHero(role),
                  const SizedBox(height: 24),
                  _actionRow(role),
                  const SizedBox(height: 20),
                  if (session == null) ...[
                    _signInBanner(context),
                    const SizedBox(height: 12),
                  ],
                  if (!_tourDismissed) ...[
                    _tourBanner(context),
                    const SizedBox(height: 24),
                  ] else
                    const SizedBox(height: 12),
                  DeUI.sectionHeader(context, 'Account'),
                  const SizedBox(height: 10),
                  DeUI.row(
                    context,
                    icon: Icons.person_outline,
                    title: 'Profile',
                    subtitle: 'Wallet, network, contracts, encryption key.',
                    onTap: () => Navigator.pushNamed(context, '/profile'),
                  ),
                  if (session != null) ...[
                    const SizedBox(height: 10),
                    DeUI.row(
                      context,
                      icon: Icons.swap_horiz_rounded,
                      title: 'Switch role',
                      subtitle: role == UserRole.individual
                          ? 'Signed in as Individual — switch to Verifier.'
                          : 'Signed in as Verifier — switch to Individual.',
                      onTap: () => Navigator.pushNamed(context, '/login'),
                    ),
                  ],
                  const SizedBox(height: 10),
                  DeUI.row(
                    context,
                    icon: Icons.rocket_launch_outlined,
                    title: 'How DeKYC works',
                    subtitle: 'The 2-minute tour — fun, zero jargon.',
                    onTap: () => Navigator.pushNamed(context, '/guide'),
                  ),
                  const SizedBox(height: 10),
                  DeUI.row(
                    context,
                    icon: Icons.menu_book_outlined,
                    title: 'How to use it',
                    // The concrete hand-off, which the concept tour does not
                    // cover: who sends what, in what order.
                    subtitle: role == UserRole.verifier
                        ? 'Checking someone — what to send them, what to ask for.'
                        : 'Sharing your documents — what to ask for, what to send.',
                    onTap: () => Navigator.pushNamed(context, '/howto'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// The "balance" of this wallet app: your identity status, big and bold.
  Widget _identityHero(UserRole? role) {
    final p = context.pal;

    if (_wallet.address == null) {
      return Column(
        children: [
          const Text('Welcome to DeKYC',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text('One encrypted KYC. Every verifier.',
              textAlign: TextAlign.center,
              style: TextStyle(color: p.muted, fontSize: 14)),
        ],
      );
    }

    if (role == UserRole.verifier) {
      return Column(
        children: [
          const Text('Verifier Desk',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text('Check access · read documents · mint badges',
              textAlign: TextAlign.center,
              style: TextStyle(color: p.muted, fontSize: 14)),
        ],
      );
    }

    return FutureBuilder<_IdentitySnapshot>(
      future: _snapshot,
      builder: (context, snap) {
        final s = snap.data;
        final waiting = snap.connectionState != ConnectionState.done;
        String big;
        String small;
        Color bigColor = p.text;
        if (waiting) {
          big = '· · ·';
          small = 'Reading your identity on-chain…';
        } else if (s == null || s.hasRecord == null) {
          big = '—';
          small = 'On-chain status unavailable right now.';
        } else if (s.hasRecord != true) {
          big = 'Not submitted';
          small = 'Upload your encrypted KYC to get started.';
        } else if ((s.verifiedCount ?? 0) > 0) {
          big = 'Submitted ✓';
          bigColor = p.success;
          final n = s.verifiedCount!;
          // Honest framing: badges are a count, not a vetted trust score —
          // anyone may attest, so trust is decided per issuer.
          small = '$n reusable verification badge${n == 1 ? '' : 's'} held — '
              'each trusted per its issuer.';
        } else {
          big = 'Submitted';
          small = 'Encrypted on IPFS, anchored on Sepolia.';
        }
        return Column(
          children: [
            Text(big,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                    color: bigColor,
                    letterSpacing: -0.5)),
            const SizedBox(height: 6),
            Text(small,
                textAlign: TextAlign.center,
                style: TextStyle(color: p.muted, fontSize: 13.5)),
          ],
        );
      },
    );
  }

  /// The Buy/Swap/Send/Receive-style action tiles, role-aware.
  Widget _actionRow(UserRole? role) {
    final tiles = <Widget>[];
    void add(IconData icon, String label, String routeName) {
      tiles.add(Expanded(
        child: DeUI.actionTile(
          context,
          icon: icon,
          label: label,
          onTap: () => Navigator.pushNamed(context, routeName),
        ),
      ));
    }

    if (role == UserRole.verifier) {
      add(Icons.travel_explore_outlined, 'Verify', '/accessrequest');
      add(Icons.history_outlined, 'Status', '/kycstatus');
      add(Icons.swap_horiz_rounded, 'Switch', '/login');
    } else {
      add(Icons.upload_rounded, 'Upload', '/kycupload');
      add(Icons.verified_outlined, 'Status', '/kycstatus');
      add(Icons.key_outlined, 'Access', '/verifier');
      if (role == null) {
        add(Icons.travel_explore_outlined, 'Verify', '/accessrequest');
      }
    }

    final spaced = <Widget>[];
    for (var i = 0; i < tiles.length; i++) {
      if (i > 0) spaced.add(const SizedBox(width: 10));
      spaced.add(tiles[i]);
    }
    return Row(children: spaced);
  }

  /// Promo-style dismissible banner for the tour (like wallet promo cards).
  Widget _tourBanner(BuildContext context) {
    final p = context.pal;
    return DeUI.card(
      context,
      onTap: () => Navigator.pushNamed(context, '/guide'),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          const Text('🚀', style: TextStyle(fontSize: 26)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('New here? Take the 2-minute tour',
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  'Wallets, encryption, badges — explained without the jargon.',
                  style: TextStyle(
                      color: p.muted, fontSize: 12.5, height: 1.35),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Dismiss',
            icon: Icon(Icons.close, size: 18, color: p.muted),
            onPressed: () => setState(() => _tourDismissed = true),
          ),
        ],
      ),
    );
  }

  Widget _signInBanner(BuildContext context) {
    final p = context.pal;
    return DeUI.card(
      context,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          DeUI.iconChip(context, Icons.lock_outline, color: p.warning),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              "You're browsing. Sign in with your wallet to act.",
              style: TextStyle(fontSize: 13.5, height: 1.4),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(0, 42),
              padding: const EdgeInsets.symmetric(horizontal: 18),
            ),
            onPressed: () => Navigator.pushNamed(context, '/login'),
            child: const Text('Sign in'),
          ),
        ],
      ),
    );
  }
}
