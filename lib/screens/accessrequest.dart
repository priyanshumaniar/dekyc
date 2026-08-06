import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_service.dart';
import '../services/key_wrap_service.dart';
import '../services/kyc_flow_service.dart';
import '../services/transport_key_store.dart';
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
  bool _isSelf = false;
  String? _status;

  /// The address the current verdict actually applies to.
  ///
  /// The verdict must never be read against whatever happens to be in the text
  /// field at the moment a button is pressed: checking A, then typing B, would
  /// otherwise carry A's "granted" straight into a read of B.
  String? _checkedUser;

  /// This verifier's ECIES transport keypair, shown here so the user can wrap
  /// a key to it. It has to be reachable BEFORE any grant exists — the user
  /// cannot wrap without it, so gating it behind access deadlocks the handoff.
  WrapKeyPair? _transportKeys;

  @override
  void initState() {
    super.initState();
    _loadTransportKeys();
    // Editing the address invalidates the verdict it was produced for.
    _userCtrl.addListener(_onAddressEdited);
  }

  Future<void> _loadTransportKeys() async {
    try {
      final keys = await TransportKeyStore.instance.loadOrCreate();
      if (!mounted) return;
      setState(() => _transportKeys = keys);
    } catch (_) {
      // Wrapping is unavailable; the legacy raw-key path still works.
    }
  }

  void _onAddressEdited() {
    if (_checkedUser == null) return;
    if (_userCtrl.text.trim().toLowerCase() == _checkedUser!.toLowerCase()) {
      return;
    }
    setState(() {
      _hasAccess = null;
      _isSelf = false;
      _status = null;
      _checkedUser = null;
    });
  }

  @override
  void dispose() {
    _userCtrl.removeListener(_onAddressEdited);
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
      // Must be reset too: otherwise a later "no record" or error verdict about
      // a DIFFERENT address is still drawn with the self-access styling and the
      // "Your own" chip.
      _isSelf = false;
      _checkedUser = null;
    });
    try {
      final hasRecord = await _flow.hasRecord(user);
      if (!hasRecord) {
        setState(() => _status = 'This address has no KYC on record.');
        return;
      }

      // Self-access is deliberate — you can always read your OWN record, no
      // grant required. Left unlabelled it looks alarming: testing with one
      // MetaMask account for both roles makes it seem like any verifier can
      // read any user, when the contract is doing exactly what it should.
      final isSelf =
          user.toLowerCase() == _wallet.address!.toLowerCase();
      if (isSelf) {
        setState(() {
          _isSelf = true;
          _hasAccess = true;
          _checkedUser = user;
          _status = 'This is your OWN address — you always have access to your '
              'own record, no grant needed. To test the real verifier flow, '
              'switch to a second wallet account.';
        });
        return;
      }

      final granted = await _flow.hasAccess(user, _wallet.address!);
      setState(() {
        _isSelf = false;
        _hasAccess = granted;
        _checkedUser = user;
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

  /// The two values the verifier must hand the user BEFORE anything can
  /// happen, both public and safe to send in the clear.
  ///
  /// This lives here, on the pre-grant screen, deliberately. The wrapping key
  /// used to be rendered only on the documents screen, which is unreachable
  /// until the user has already granted — so the documented order (send your
  /// two values, then wait for the grant) was impossible to follow, and the
  /// handoff deadlocked: the user cannot wrap a key without this, and the
  /// verifier could not see it without a grant.
  Widget _sendToUserCard() {
    final p = context.pal;
    final keys = _transportKeys;

    Widget line(String label, String? value, String emptyHint) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(label,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 13)),
                ),
                if (value != null)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 30),
                    ),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: value));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('$label copied')),
                      );
                    },
                    icon: const Icon(Icons.copy, size: 15),
                    label: const Text('Copy'),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            value == null
                ? Text(emptyHint, style: TextStyle(color: p.muted, fontSize: 12))
                : SelectableText(
                    value,
                    style: const TextStyle(
                        fontSize: 11, fontFamily: 'monospace', height: 1.4),
                  ),
          ],
        ),
      );
    }

    return DeUI.card(
      context,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.outbox_outlined, size: 18, color: p.accent),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Send these to the user first',
                    style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'They cannot grant you anything until they have both. Neither is '
            'secret — email or chat is fine.',
            style: TextStyle(color: p.muted, fontSize: 12.5, height: 1.35),
          ),
          line('Your wallet address', _wallet.address,
              'Connect your wallet to see it.'),
          line('Your wrapping key', keys?.publicKeyHex, 'Preparing…'),
          if (keys != null && !TransportKeyStore.instance.isPersisted) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, size: 15, color: p.warning),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'This wrapping key could not be saved and will change if '
                    'you reload — finish the handoff in this session.',
                    style: TextStyle(
                        color: p.warning, fontSize: 11.5, height: 1.3),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
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
                const SizedBox(height: 16),
                _sendToUserCard(),
                const SizedBox(height: 16),
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
                          _isSelf
                              ? Icons.person_outline
                              : _hasAccess == true
                                  ? Icons.check_circle_outline
                                  : Icons.hourglass_top,
                          color: _isSelf
                              ? p.warning
                              : _hasAccess == true
                                  ? p.success
                                  : p.muted,
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Text(_status!)),
                        if (_isSelf) ...[
                          const SizedBox(width: 8),
                          DeUI.statusChip(context, 'Your own', p.warning),
                        ] else if (_hasAccess == true) ...[
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
                          // The address the verdict was produced for — NOT the
                          // live field, which may have been edited since.
                          'userAddress': _checkedUser,
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
