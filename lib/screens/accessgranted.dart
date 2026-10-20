import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/chain_config.dart';
import '../services/badge.dart';
import '../services/key_wrap_service.dart';
import '../services/kyc_flow_service.dart';
import '../services/transport_key_store.dart';
import '../services/tx_errors.dart';
import '../theme/app_theme.dart';
import '../theme/components.dart';
import 'badge_widgets.dart';
// Inline PDF viewer: real iframe-backed preview on web, placeholder elsewhere.
import '../services/doc_view/doc_view_stub.dart'
    if (dart.library.js_interop) '../services/doc_view/doc_view_web.dart';

/// VERIFIER-side screen. With access granted on-chain, the verifier pastes the
/// decryption key (shared by the user out-of-band) to fetch the CID, download
/// the encrypted bundle from IPFS, decrypt it locally and view the documents.
class AccessGranted extends StatefulWidget {
  const AccessGranted({super.key});

  @override
  State<AccessGranted> createState() => _AccessGrantedState();
}

class _AccessGrantedState extends State<AccessGranted> {
  final KycFlowService _flow = KycFlowService();
  final TextEditingController _keyCtrl = TextEditingController();
  final TransportKeyStore _keyStore = TransportKeyStore.instance;

  /// This verifier's ECIES transport keypair — the public half is what the
  /// user needs in order to wrap their document key to us.
  WrapKeyPair? _transportKeys;

  bool _loading = false;
  String? _error;
  Map<String, Uint8List>? _docs;

  @override
  void initState() {
    super.initState();
    _loadTransportKeys();
  }

  Future<void> _loadTransportKeys() async {
    try {
      final keys = await _keyStore.loadOrCreate();
      if (!mounted) return;
      setState(() => _transportKeys = keys);
    } catch (_) {
      // Wrapping is unavailable; the legacy raw-key path still works.
    }
  }

  bool _attesting = false;
  String _attestLabel = '';

  /// Badges, read from the chain once the documents are open.
  /// [_myBadge] is the latest badge THIS verifier gave the user (any status),
  /// [_userBadges] every badge the user holds from anyone.
  bool _badgesLoaded = false;
  String? _badgesError;
  KycBadge? _myBadge;
  List<KycBadge> _userBadges = const [];
  bool _revoking = false;

  static const Map<String, String> _labels = {
    'aadhaar_front': 'Aadhaar (Front)',
    'aadhaar_back': 'Aadhaar (Back)',
    'pan': 'PAN Card',
    'photo': 'Photo',
  };

  @override
  void dispose() {
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _load(String userAddress, String verifierAddress) async {
    final key = _keyCtrl.text.trim();
    if (key.isEmpty) {
      setState(() => _error = 'Paste the wrapped key shared by the user.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final docs = await _flow.readKyc(
        userAddress: userAddress,
        callerAddress: verifierAddress,
        keyMaterial: key,
        transportPrivateKey: _transportKeys?.privateKey,
      );
      // readKyc is a multi-second on-chain + IPFS + decrypt round-trip; the
      // verifier may navigate away before it resolves. Guard both branches so
      // we never setState on a disposed State.
      if (!mounted) return;
      setState(() => _docs = docs);
      _loadBadges(userAddress, verifierAddress);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Reads this verifier's own badge for the user and the user's full badge
  /// list. Done before showing the mint button, so a verifier who already
  /// issued a valid badge is told so instead of being offered a mint the
  /// contract would refuse (AlreadyAttested).
  Future<void> _loadBadges(String userAddress, String verifierAddress) async {
    setState(() => _badgesError = null);
    try {
      final mine = await _flow.badgeFor(verifierAddress, userAddress);
      final all = await _flow.badgesOf(userAddress);
      if (!mounted) return;
      setState(() {
        _myBadge = mine;
        _userBadges = all;
        _badgesLoaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _badgesError = 'Could not read badges: $e';
        _badgesLoaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final args = ModalRoute.of(context)?.settings.arguments
        as Map<String, dynamic>?;
    final userAddress = args?['userAddress'] as String?;
    final verifierAddress = args?['verifierAddress'] as String?;

    // This screen only makes sense with a (user, verifier) pair from
    // Verifier Mode — anything else is a stray deep link.
    if (userAddress == null || verifierAddress == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('KYC Documents')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DeUI.iconChip(context, Icons.travel_explore_outlined,
                    size: 52, color: p.muted),
                const SizedBox(height: 14),
                Text(
                  'Open this screen from Verifier Mode after checking a '
                  "user's access status.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.muted, height: 1.5),
                ),
                const SizedBox(height: 18),
                ElevatedButton(
                  onPressed: () => Navigator.pushReplacementNamed(
                      context, '/accessrequest'),
                  child: const Text('Go to Verifier Mode'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('KYC Documents')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Column(
                    children: [
                      Text('USER',
                          style: TextStyle(
                              color: p.muted,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.1)),
                      const SizedBox(height: 5),
                      DeUI.addressPill(context, userAddress),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                if (_docs == null) ...[
                  _wrappingKeyCard(),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _keyCtrl,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Wrapped key from the user',
                      helperText: 'A bare 64-char key also works (legacy).',
                      prefixIcon: Icon(Icons.key_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: _loading
                        ? null
                        : () => _load(userAddress, verifierAddress),
                    child: _loading
                        ? SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: p.onAccent),
                          )
                        : const Text('Decrypt & Load Documents'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: p.danger)),
                  ],
                ] else ...[
                  Expanded(child: _buildDocList(verifierAddress)),
                  const SizedBox(height: 8),
                  _buildAttestBar(userAddress, verifierAddress),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Step 1 for the verifier: hand this public key to the user so they can
  /// encrypt their document key to us instead of sending it in the clear.
  Widget _wrappingKeyCard() {
    final p = context.pal;
    final keys = _transportKeys;
    return DeUI.card(
      context,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.enhanced_encryption_outlined, size: 18, color: p.accent),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Your wrapping key',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              if (keys != null)
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: keys.publicKeyHex));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Wrapping key copied')),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Send this to the user. They encrypt their document key to it, so '
            'the key that travels back is useless to anyone but you. Safe to '
            'share publicly — it is a public key.',
            style: TextStyle(color: p.muted, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 10),
          if (keys == null)
            Text('Preparing…', style: TextStyle(color: p.muted))
          else ...[
            SelectableText(
              keys.publicKeyHex,
              style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace'),
            ),
            if (!_keyStore.isPersisted) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, size: 16, color: p.warning),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'This wrapping key could not be saved, so it will change '
                      'if you reload. Finish the handoff in this session, or a '
                      'key wrapped to it will stop opening.',
                      style: TextStyle(color: p.warning, fontSize: 11.5,
                          height: 1.35),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  Future<void> _attest(String subject, String verifierAddress) async {
    setState(() {
      _attesting = true;
      _attestLabel = 'Sign in your wallet…';
    });
    try {
      final tx = await _flow.attestUser(subject);
      if (!mounted) return;
      // A hash means BROADCAST, not mined. Claiming success here would show
      // "badge minted ✓" for a transaction that went on to revert.
      setState(() => _attestLabel = 'Waiting for Sepolia to confirm…');
      await _flow.awaitConfirmation(tx);
      if (!mounted) return;
      _loadBadges(subject, verifierAddress);
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Soulbound badge minted ✓'),
          content: SelectableText(ChainConfig.txUrl(tx)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Badge not issued. ${describeTxError(e)}')));
    } finally {
      if (mounted) setState(() => _attesting = false);
    }
  }

  Future<void> _revoke(String subject, String verifierAddress) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke this badge?'),
        content: const Text(
          'The badge stops counting for this user straight away, for everyone '
          'who checks it. It stays listed as "Revoked" so the history is '
          'visible. You can issue a new badge later.',
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
    setState(() => _revoking = true);
    try {
      final tx = await _flow.revokeAttestation(subject);
      await _flow.awaitConfirmation(tx);
      if (!mounted) return;
      await _loadBadges(subject, verifierAddress);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Badge revoked.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Badge not revoked. ${describeTxError(e)}')));
    } finally {
      if (mounted) setState(() => _revoking = false);
    }
  }

  Widget _buildAttestBar(String subject, String verifierAddress) {
    final p = context.pal;
    final mine = _myBadge;

    // Until the chain has answered we do not know whether a mint would even
    // be accepted, so do not offer one.
    if (!_badgesLoaded) {
      return ElevatedButton.icon(
        onPressed: null,
        icon: const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2)),
        label: const Text('Checking existing badges…'),
      );
    }

    if (mine != null && mine.counts) {
      return DeUI.card(
        context,
        padding: const EdgeInsets.all(13),
        color: p.success.withValues(alpha: 0.10),
        child: Row(
          children: [
            Icon(Icons.verified, color: p.success),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'You verified this user on ${formatBadgeDate(mine.issuedAt)}. '
                'Your badge is valid until ${formatBadgeDate(mine.expiresAt)}.',
                style: TextStyle(color: p.success),
              ),
            ),
            TextButton(
              onPressed: _revoking
                  ? null
                  : () => _revoke(subject, verifierAddress),
              child: Text(_revoking ? 'Revoking…' : 'Revoke'),
            ),
          ],
        ),
      );
    }

    // No badge from this verifier, or only an expired/revoked one.
    return ElevatedButton.icon(
      onPressed:
          _attesting ? null : () => _attest(subject, verifierAddress),
      icon: _attesting
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: p.onAccent),
            )
          : const Icon(Icons.verified_user, size: 20),
      label: Text(_attesting
          ? _attestLabel
          : mine != null
              ? 'Issue a new badge (yours is '
                  '${badgeStatusLabel(mine.status).toLowerCase()})'
              : 'Mark as Verified (mint Soulbound proof)'),
    );
  }

  /// The user's existing badges, shown above the documents so a verifier can
  /// rely on checks other organisations already did.
  Widget _badgesSection(String verifierAddress) {
    final p = context.pal;
    if (!_badgesLoaded) return const SizedBox.shrink();
    if (_badgesError != null) {
      return Text(_badgesError!, style: TextStyle(color: p.danger));
    }
    return BadgeListSection(
      title: "This user's badges",
      badges: _userBadges,
      side: BadgeSide.held,
      me: verifierAddress,
      emptyText: 'This user holds no badges yet. If you approve their KYC, '
          'yours will be the first.',
    );
  }

  Widget _buildDocList(String verifierAddress) {
    final entries = _docs!.entries.toList();
    return ListView(
      children: [
        _badgesSection(verifierAddress),
        const SizedBox(height: 18),
        for (final e in entries) ...[
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_labels[e.key] ?? e.key,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _docPreview(e.key, e.value),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }

  /// Render a decrypted document by sniffing its magic bytes — the bundle
  /// stores raw bytes with no MIME, so we detect PDF vs image here. PDFs get
  /// the native inline viewer; JPG/JPEG/PNG render with [Image.memory].
  Widget _docPreview(String key, Uint8List bytes) {
    final p = context.pal;
    if (_isPdf(bytes)) {
      return buildPdfPreview(bytes, key);
    }
    return Container(
      color: p.surface,
      alignment: Alignment.center,
      child: Image.memory(
        bytes,
        height: 240,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => Container(
          height: 120,
          alignment: Alignment.center,
          color: p.surfaceAlt,
          child: const Text('Unsupported document format'),
        ),
      ),
    );
  }

  /// PDF files start with the ASCII bytes `%PDF`.
  static bool _isPdf(Uint8List b) =>
      b.length >= 4 &&
      b[0] == 0x25 &&
      b[1] == 0x50 &&
      b[2] == 0x44 &&
      b[3] == 0x46;
}
