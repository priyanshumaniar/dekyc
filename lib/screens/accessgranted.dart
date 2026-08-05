import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/chain_config.dart';
import '../services/key_wrap_service.dart';
import '../services/kyc_flow_service.dart';
import '../services/transport_key_store.dart';
import '../theme/app_theme.dart';
import '../theme/components.dart';
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
  String? _attestTx;

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
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
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
                  Expanded(child: _buildDocList()),
                  const SizedBox(height: 8),
                  _buildAttestBar(userAddress),
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

  Future<void> _attest(String subject) async {
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
      setState(() => _attestTx = tx);
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Attestation failed: $e')));
    } finally {
      if (mounted) setState(() => _attesting = false);
    }
  }

  Widget _buildAttestBar(String subject) {
    final p = context.pal;
    if (_attestTx != null) {
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
                'You issued a reusable Verified badge to this user.',
                style: TextStyle(color: p.success),
              ),
            ),
          ],
        ),
      );
    }
    return ElevatedButton.icon(
      onPressed: _attesting ? null : () => _attest(subject),
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
          : 'Mark as Verified (mint Soulbound proof)'),
    );
  }

  Widget _buildDocList() {
    final entries = _docs!.entries.toList();
    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 16),
      itemBuilder: (_, i) {
        final e = entries[i];
        return Column(
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
        );
      },
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
