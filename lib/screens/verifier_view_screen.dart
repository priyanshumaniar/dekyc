import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/chain_config.dart';
import '../services/auth_service.dart';
import '../services/guest_list.dart';
import '../services/key_wrap_service.dart';
import '../services/kyc_contract_service.dart' show VerifierGrant;
import '../services/kyc_flow_service.dart';
import '../services/verifier_list_store.dart';
import '../services/wallet_service.dart';
import 'how_to_use.dart';
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

  /// The guest list, mirroring `KYCRegistry.grantsOf`. The chain is the source
  /// of truth; a locally-typed address sits here only until it is granted.
  final List<String> _verifiers = [];

  /// address → the row as the registry reports it (absent = not yet read).
  /// Keyed by [_canon] form, matching what `grantsOf` returns.
  final Map<String, VerifierGrant> _state = {};

  /// Addresses the user has typed but not yet granted. They have no on-chain
  /// row, so the chain sync must merge them in rather than drop them.
  final Set<String> _pending = {};

  String? _busyAddr;
  bool _refreshing = false;

  static const Duration _grantDuration = Duration(days: 7);

  final VerifierListStore _listStore = VerifierListStore.instance;

  /// The owner whose list is currently loaded, so an account switch can be
  /// detected and the list swapped rather than left showing the wrong one.
  String? _loadedOwner;

  @override
  void initState() {
    super.initState();
    _wallet.addListener(_onWalletChanged);
    _restoreList();
  }

  void _onWalletChanged() {
    if (_wallet.address == _loadedOwner) return;
    // Switching accounts means a different guest list. Drop the old rows
    // immediately so they cannot be mistaken for the new account's grants.
    setState(() {
      _verifiers.clear();
      _state.clear();
      _pending.clear();
      _loadedOwner = null;
    });
    _restoreList();
  }

  /// Paint the cached list immediately, then replace it with the chain's.
  ///
  /// The CHAIN is the source of truth: `KYCRegistry.grantsOf` returns the guest
  /// list with each row's status already resolved, so this screen is correct on
  /// a device that has never seen the account. The local cache exists only so
  /// the list is on screen before the RPC round-trip completes.
  Future<void> _restoreList() async {
    final owner = _wallet.address;
    if (owner == null) return;
    _loadedOwner = owner;

    final cached = await _listStore.load(owner);
    // Guard against an account switch that landed while this read was in
    // flight — otherwise the previous account's list would be applied.
    if (!mounted || owner != _wallet.address) return;
    if (cached.isNotEmpty) {
      setState(() {
        for (final entry in cached) {
          // Older cache entries predate canonicalisation, so normalise on read.
          final v = _canon(entry);
          if (!_verifiers.contains(v)) {
            _verifiers.add(v);
            // Treated as pending until the chain says otherwise; the sync
            // promotes it the moment a matching grant turns up.
            _pending.add(v);
          }
        }
      });
    }
    await _syncFromChain();
  }

  /// Merge the registry's rows over the local ones.
  ///
  /// The chain is authoritative for STATUS, but it is not the whole list: an
  /// address the user has typed but not yet granted does not exist on-chain, so
  /// replacing the list outright made a freshly-added row vanish about a second
  /// after it appeared — and then persisted that removal to the cache. Chain
  /// rows first (they carry status), then any pending address not among them.
  Future<void> _syncFromChain() async {
    final owner = _wallet.address;
    if (owner == null) return;
    setState(() => _refreshing = true);
    try {
      final grants = await _flow.listGrants(owner);
      if (!mounted || owner != _wallet.address) return;
      final merged = GuestList.merge(chain: grants, pending: _pending);
      setState(() {
        _state
          ..clear()
          ..addEntries(
              grants.map((g) => MapEntry(GuestList.canon(g.address), g)));
        _pending
          ..clear()
          ..addAll(merged.pending);
        _verifiers
          ..clear()
          ..addAll(merged.rows);
      });
      await _listStore.save(owner, _verifiers);
    } catch (_) {
      // Chain unreachable — leave the rows we have rather than blanking the
      // screen; _accessLabel reports them as status-unknown.
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  void dispose() {
    _wallet.removeListener(_onWalletChanged);
    _addrCtrl.dispose();
    super.dispose();
  }

  // A well-formed Ethereum address: 0x followed by exactly 40 hex chars.
  static final RegExp _addressPattern = RegExp(r'^0x[0-9a-fA-F]{40}$');

  void _addRequest() {
    final raw = _addrCtrl.text.trim();
    // Validate the FULL address (not just length/prefix) at add time, so a
    // malformed entry is rejected here in the UI rather than failing later at
    // transaction time inside EthereumAddress.fromHex.
    if (!_addressPattern.hasMatch(raw)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid 0x… wallet address')),
      );
      return;
    }
    final addr = _canon(raw);

    if (_verifiers.contains(addr)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That verifier is already on your list')),
      );
      setState(() => _addrCtrl.clear());
      return;
    }

    setState(() {
      // Pending until a grant for it actually appears on-chain.
      _pending.add(addr);
      _verifiers.add(addr);
      _addrCtrl.clear();
    });

    final owner = _wallet.address;
    if (owner != null) {
      // Persist immediately, so the row survives leaving this screen even if
      // the user never gets as far as granting.
      _listStore.add(owner, addr);
      _syncFromChain();
    }
  }

  /// Canonical (EIP-55 checksummed) form — see [GuestList.canon].
  static String _canon(String address) => GuestList.canon(address);

  /// Drop a verifier from the guest list ON-CHAIN.
  ///
  /// The contract refuses while the grant is live, so this is housekeeping and
  /// can never be mistaken for revoking. A row that was only added locally
  /// (never granted) is not on-chain at all, so it is just dropped from the
  /// cache without a transaction.
  Future<void> _forget(String verifier) async {
    if (_hasLiveGrant(verifier)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This verifier still has live access. Revoke first, then remove.',
          ),
        ),
      );
      return;
    }

    final owner = _wallet.address;
    final onChain = _state.containsKey(verifier);

    if (!onChain) {
      // Never granted — nothing on-chain to forget.
      if (owner != null) await _listStore.remove(owner, verifier);
      if (!mounted) return;
      setState(() {
        _verifiers.remove(verifier);
        _pending.remove(verifier);
      });
      return;
    }

    setState(() => _busyAddr = verifier);
    try {
      final tx = await _flow.forgetVerifier(verifier);
      await _flow.awaitConfirmation(tx);
      if (owner != null) await _listStore.remove(owner, verifier);
      if (!mounted) return;
      _showTx('Removed from your list', tx);
      await _syncFromChain();
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busyAddr = null);
    }
  }

  Future<void> _grant(String verifier) async {
    setState(() => _busyAddr = verifier);
    try {
      final tx = await _flow.grantAccess(verifier, _grantDuration);
      // Only claim the grant landed once it is actually mined — otherwise a
      // reverted tx would leave the guest list showing access that isn't there.
      await _flow.awaitConfirmation(tx);
      if (!mounted) return;
      _showTx('Access granted', tx);
      await _syncFromChain();
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
      await _flow.awaitConfirmation(tx);
      if (!mounted) return;
      _showTx('Access revoked', tx);
      await _syncFromChain();
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busyAddr = null);
    }
  }

  /// Wrap the document key to a verifier's public key (ECIES).
  ///
  /// Preferred over revealing the raw key: the blob produced here is readable
  /// only by the holder of that verifier's private key, so it can safely cross
  /// an ordinary channel (email, chat) that a bare key could not.
  Future<void> _wrapKeyFor(String verifier) async {
    final pubKey = await showDialog<String>(
      context: context,
      builder: (_) => const _WrappingKeyPrompt(),
    );
    if (pubKey == null || !mounted) return;

    setState(() => _busyAddr = verifier);
    try {
      final wrapped = await _flow.wrapKeyForVerifier(pubKey);
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Wrapped key ready'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Send this to the verifier. Only they can unwrap it, so it is '
                'safe to send over an ordinary channel. It unlocks the bundle '
                'you have uploaded — grant access on-chain as well, or they '
                'still cannot read the pointer.',
              ),
              const SizedBox(height: 12),
              SelectableText(wrapped,
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: wrapped));
                Navigator.pop(context);
              },
              child: const Text('Copy'),
            ),
          ],
        ),
      );
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busyAddr = null);
    }
  }

  /// Escape hatch: reveal the raw key. Kept because a verifier running an
  /// older build has no wrapping key to offer, but it is deliberately the
  /// secondary path and says why.
  Future<void> _revealRawKey() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reveal the raw key?'),
        content: const Text(
          'A raw key is readable by anyone who sees it — a screenshot, a chat '
          'log, or a clipboard manager is enough, and revoking on-chain does '
          'not take it back.\n\n'
          'Prefer "Wrap key for…" on a verifier row, which encrypts the key so '
          'only that verifier can read it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reveal anyway'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    try {
      final key = await _flow.deriveUserKey();
      final hex = KeyWrapService.toHex(key);
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Decryption key (raw)'),
          content: SelectableText(hex, style: const TextStyle(fontSize: 12)),
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

  /// True when the chain says this verifier currently holds usable access.
  bool _hasLiveGrant(String verifier) => _state[verifier]?.live ?? false;

  /// A row is stale when the grant has NOT expired yet but is still not live.
  ///
  /// `hasAccess` is "unexpired AND version-current", so a future expiry that is
  /// nonetheless dead can only mean the record version moved — i.e. the user
  /// re-uploaded after granting. No extra chain read needed to tell them apart.
  bool _isStale(String verifier) {
    final s = _state[verifier];
    return s != null &&
        !s.live &&
        s.expiresAt != null &&
        s.expiresAt!.isAfter(DateTime.now());
  }

  /// Human-readable on-chain access state for a row.
  String _accessLabel(String verifier) {
    final s = _state[verifier];
    if (s == null) {
      // Added here but with no on-chain row: the user has not granted yet.
      // Distinguished from a genuine read failure, which leaves it unknown.
      return _pending.contains(verifier)
          ? 'Not granted yet — tap ✓ to give access'
          : 'Access status unknown';
    }
    if (s.expiresAt == null) return 'No access (revoked)';
    if (_isStale(verifier)) {
      // Reported before expiry: it is the more actionable of the two, and the
      // fix is different (re-grant, not wait).
      return 'Lapsed — you re-uploaded since granting. Grant again to '
          're-share.';
    }
    if (!s.live) return 'Access expired';
    final left = s.expiresAt!.difference(DateTime.now());
    if (left.inDays >= 1) {
      return 'Access until ${_fmtDate(s.expiresAt!)} (${left.inDays}d left)';
    }
    if (left.inHours >= 1) return 'Access expires in ${left.inHours}h';
    return 'Access expires in ${left.inMinutes}m';
  }

  static String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

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
      appBar: AppBar(
        title: const Text('Manage Access'),
        actions: [
          IconButton(
            tooltip: 'How sharing works',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    const HowToUseScreen(role: UserRole.individual),
              ),
            ),
            icon: const Icon(Icons.help_outline),
          ),
          IconButton(
            tooltip: 'Re-read access status from the chain',
            onPressed:
                (!connected || _refreshing || _verifiers.isEmpty)
                    ? null
                    : _syncFromChain,
            icon: _refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
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
                    onPressed: connected ? _revealRawKey : null,
                    icon: const Icon(Icons.key, size: 18),
                    label: const Text('Reveal raw key (not recommended)'),
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
                                        Text(
                                          _accessLabel(v),
                                          style: TextStyle(
                                            color: _hasLiveGrant(v)
                                                ? p.success
                                                : _isStale(v)
                                                    ? p.warning
                                                    : p.muted,
                                            fontSize: 12.5,
                                          ),
                                        ),
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
                                      tooltip: 'Wrap my key for this verifier',
                                      icon: Icon(Icons.enhanced_encryption,
                                          color: p.accent),
                                      onPressed: connected
                                          ? () => _wrapKeyFor(v)
                                          : null,
                                    ),
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
                                    IconButton(
                                      tooltip: 'Remove from list (does not '
                                          'revoke)',
                                      icon: Icon(Icons.close,
                                          size: 18, color: p.muted),
                                      onPressed: () => _forget(v),
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

/// Collects a verifier's ECIES public key, validating it before the caller
/// spends a wallet signature deriving the document key.
class _WrappingKeyPrompt extends StatefulWidget {
  const _WrappingKeyPrompt();

  @override
  State<_WrappingKeyPrompt> createState() => _WrappingKeyPromptState();
}

class _WrappingKeyPromptState extends State<_WrappingKeyPrompt> {
  final TextEditingController _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _ctrl.text.trim();
    // Validate here rather than after signing: an invalid key would otherwise
    // cost the user a wallet popup before failing.
    try {
      if (!KeyWrapService.isValidPublicKey(KeyWrapService.fromHex(text))) {
        throw ArgumentError('not a curve point');
      }
    } catch (_) {
      setState(() => _error =
          "That is not a valid wrapping key. It is 66 hex characters and "
          "starts with 02 or 03 — copy it from the verifier's screen.");
      return;
    }
    Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Verifier's wrapping key"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Ask the verifier for the "wrapping key" shown on their KYC '
            'Documents screen, then paste it here. Your document key is '
            'encrypted to it, so only they can read it.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: 'Wrapping key (66 hex chars)',
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _submit, child: const Text('Wrap key')),
      ],
    );
  }
}
