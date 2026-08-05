import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme/app_theme.dart';
import '../theme/components.dart';

/// The "how do I actually DO this?" tour.
///
/// The other guide ([UserGuideScreen]) explains what DeKYC *is*. This one
/// explains the hand-off: who gives what to whom, in what order. That is the
/// part people get stuck on, because DeKYC has no on-chain "request" call —
/// the verifier cannot pull anything, so nothing happens until the USER grants.
/// And there are TWO separate things to hand over, which is the real trip-up:
///
///   * the verifier's WALLET ADDRESS unlocks the on-chain pointer (grantAccess)
///   * the verifier's WRAPPING KEY unlocks the documents (the wrapped key)
///
/// Either one alone is useless, so both perspectives spell that out.
class HowToUseScreen extends StatefulWidget {
  const HowToUseScreen({super.key, this.role});

  /// Perspective to open on. Defaults to the signed-in role, then Individual.
  final UserRole? role;

  @override
  State<HowToUseScreen> createState() => _HowToUseScreenState();
}

class _Step {
  const _Step({
    required this.emoji,
    required this.title,
    required this.body,
    this.tip,
    this.handoff,
  });

  final String emoji;
  final String title;
  final String body;
  final String? tip;

  /// Optional "who gives what" table rendered under the body.
  final List<_HandoffRow>? handoff;
}

class _HandoffRow {
  const _HandoffRow(this.what, this.unlocks, this.how);
  final String what;
  final String unlocks;
  final String how;
}

class _HowToUseScreenState extends State<HowToUseScreen> {
  late UserRole _role =
      widget.role ?? AuthService.instance.role ?? UserRole.individual;

  final PageController _controller = PageController();
  int _page = 0;

  @override
  void didUpdateWidget(HowToUseScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // `_role` is seeded once from the widget, so a rebuild carrying a different
    // role would otherwise keep showing the old perspective — and, worse, keep
    // the old page index against a different step list.
    final incoming = widget.role;
    if (incoming != null && incoming != oldWidget.role && incoming != _role) {
      _role = incoming;
      _page = 0;
      if (_controller.hasClients) _controller.jumpToPage(0);
    }
  }

  // ---------------------------------------------------------------------------
  // Individual — "how do I share my documents?"
  // ---------------------------------------------------------------------------
  static const List<_Step> _individualSteps = [
    _Step(
      emoji: '📤',
      title: 'First, upload once',
      body: 'Dashboard → Upload. Pick your four documents. They are encrypted '
          'on your device, the encrypted file goes to IPFS, and only a '
          'fingerprint is written on-chain.\n\n'
          'You do this ONCE. Every verifier after that reuses the same upload.',
      tip: 'Nothing is shared yet. Uploading does not give anybody access — '
          'you have not named a single person so far.',
    ),
    _Step(
      emoji: '📥',
      title: 'Ask the verifier for two things',
      body: 'Nothing happens until YOU act. There is no "request" button on '
            'their side — the bank cannot pull your documents, so they have '
            'to send you these first:',
      handoff: [
        _HandoffRow(
          'Their wallet address',
          'the on-chain pointer',
          'starts with 0x…, 42 characters',
        ),
        _HandoffRow(
          'Their wrapping key',
          'the documents themselves',
          'starts with 02 or 03, 66 characters',
        ),
      ],
      tip: 'Both are public values. It is safe for them to email you either '
          'one — neither can be used against you on its own.',
    ),
    _Step(
      emoji: '✅',
      title: 'Step 1 — Grant their address',
      body: 'Dashboard → Access. Paste their WALLET ADDRESS, tap Add, then tap '
          'the green ✓ to Grant.\n\n'
          'This is a real transaction, so your wallet will ask you to sign. It '
          'gives that one address permission to read your pointer for 7 days.',
      tip: 'This alone is not enough. They can now find your encrypted file — '
          'but it is still scrambled, and they cannot read a word of it.',
    ),
    _Step(
      emoji: '🔐',
      title: 'Step 2 — Wrap your key for them',
      body: 'On the same row, tap the 🔐 icon. Paste their WRAPPING KEY. Your '
          'wallet asks for one free signature, and you get a long blob back.\n\n'
          'Send that blob to them. It is your document key, locked so that only '
          'their device can open it.',
      tip: 'Because it is locked to them, you can send it over ordinary email '
          'or chat. Anyone else who sees it gets nothing.',
    ),
    _Step(
      emoji: '🧩',
      title: 'Why it takes both',
      body: 'Think of it as an address and a key to the door.\n\n'
          '• Address only → they arrive at your file and cannot open it.\n'
          '• Wrapped key only → they can open it, but cannot find it.\n\n'
          'Give both and they are in. Withhold either and they are not.',
      tip: 'Do NOT use "Reveal raw key" unless you have a reason. That gives '
          'out an unlocked key that works for anyone who sees it, forever.',
    ),
    _Step(
      emoji: '🛑',
      title: 'Taking it back',
      body: 'Tap the red ✗ to Revoke — their next read fails immediately. '
          'Grants also expire on their own after 7 days.\n\n'
          'And if you upload new documents, every existing grant lapses '
          'automatically. Nobody keeps access to a file you have replaced.',
      tip: 'One honest caveat: revoking stops FUTURE reads. It cannot un-see '
          'documents somebody already downloaded.',
    ),
  ];

  // ---------------------------------------------------------------------------
  // Verifier — "how do I check someone?"
  // ---------------------------------------------------------------------------
  static const List<_Step> _verifierSteps = [
    _Step(
      emoji: '🪪',
      title: 'Sign in as a Verifier',
      body: 'Dashboard → Switch role → Verifier, and sign the free message. '
          'Your wallet address is your identity as an institution — it is what '
          'the user will grant access to, and what gets recorded on-chain as '
          'the issuer of any badge you mint.',
      tip: 'Use a wallet you can keep. Change wallets and every grant you were '
          'given stops working.',
    ),
    _Step(
      emoji: '📨',
      title: 'Send the user two things',
      body: 'You cannot request documents from inside the app — there is no '
          'on-chain request, so the user has to act first. Send them:',
      handoff: [
        _HandoffRow(
          'Your wallet address',
          'lets them grant you the pointer',
          'copy from the account pill',
        ),
        _HandoffRow(
          'Your wrapping key',
          'lets them lock the key to you',
          'Verify → View Documents → Copy',
        ),
      ],
      tip: 'Your wrapping key lives on the KYC Documents screen. It is a public '
          'key — safe to send in the clear.',
    ),
    _Step(
      emoji: '⏳',
      title: 'Wait for the grant, then check',
      body: 'Dashboard → Verify. Paste the USER\'S address and tap Check Access '
          'Status.\n\n'
          '"Pending" means they have not granted you yet — nudge them. Once '
          'they grant, the same button turns it to granted and View Documents '
          'appears.',
      tip: 'Checking is a free read. Press it as often as you like; it costs '
          'no gas and sends no transaction.',
    ),
    _Step(
      emoji: '📂',
      title: 'Open the documents',
      body: 'Tap View Documents, paste the wrapped key the user sent you, and '
          'tap Decrypt & Load.\n\n'
          'The app fetches the encrypted file from IPFS and unwraps it on your '
          'device. The documents are never decrypted on any server.',
      tip: 'If nothing loads, read the error — it tells you which half failed '
          'and what to ask for. See the last step.',
    ),
    _Step(
      emoji: '🏅',
      title: 'Issue a reusable badge',
      body: 'Happy with what you saw? Tap "Mark as Verified" to mint a '
          'Soulbound badge to the user\'s wallet — a token that cannot be '
          'transferred or sold.\n\n'
          'Other institutions can then see that YOU vouched for this user, and '
          'skip repeating the whole check.',
      tip: 'Anyone can mint a badge, so a badge count is not a trust score. '
          'Always check WHICH issuer signed it before relying on one.',
    ),
    _Step(
      emoji: '🩺',
      title: 'When it does not work',
      body: 'Two different failures, two different fixes:\n\n'
          '• "Wrapped to a DIFFERENT wrapping key" → they wrapped to the wrong '
          'key, or yours changed. Resend yours and ask them to wrap again.\n\n'
          '• "Does not decrypt this bundle" → the key is fine but the file was '
          'encrypted with a different one. Ask them to re-upload.',
      tip: 'Access lapsing on its own usually means the user re-uploaded — '
          'their old grant to you expired the moment they did. Ask them to '
          'grant again.',
    ),
  ];

  List<_Step> get _steps =>
      _role == UserRole.verifier ? _verifierSteps : _individualSteps;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _switchRole(UserRole role) {
    if (role == _role) return;
    setState(() {
      _role = role;
      _page = 0;
    });
    // The PageView keeps its offset across a content swap; snap it back so the
    // dots and the visible page cannot disagree.
    _controller.jumpToPage(0);
  }

  void _next() {
    if (_page == _steps.length - 1) {
      Navigator.pop(context);
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final isLast = _page == _steps.length - 1;
    return Scaffold(
      appBar: AppBar(
        title: const Text('How to use DeKYC'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Skip'),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: _perspectiveToggle(),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _controller,
                  // Rebuild the whole PageView when the perspective changes so
                  // it cannot show a cached page from the other role.
                  key: ValueKey(_role),
                  itemCount: _steps.length,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemBuilder: (_, i) => _stepPage(_steps[i], i),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(_steps.length, (i) {
                        final active = i == _page;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          width: active ? 22 : 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: active ? p.accent : p.surfaceAlt,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _next,
                        child: Text(isLast ? 'Got it 👍' : 'Next'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The two roles see genuinely different instructions, so the perspective is
  /// switchable rather than inferred once — a user often needs to read the
  /// other side to understand what to ask for.
  Widget _perspectiveToggle() {
    final p = context.pal;
    Widget tab(UserRole role, String label) {
      final selected = _role == role;
      return Expanded(
        child: GestureDetector(
          onTap: () => _switchRole(role),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: selected ? p.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                color: selected ? p.onAccent : p.muted,
                fontWeight: FontWeight.w700,
                fontSize: 13.5,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          tab(UserRole.individual, "I'm sharing my documents"),
          tab(UserRole.verifier, "I'm verifying someone"),
        ],
      ),
    );
  }

  Widget _stepPage(_Step step, int index) {
    final p = context.pal;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Step ${index + 1} of ${_steps.length}',
            style: TextStyle(
                color: p.muted,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6),
          ),
          const SizedBox(height: 18),
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(color: p.surface, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Text(step.emoji, style: const TextStyle(fontSize: 42)),
          ),
          const SizedBox(height: 18),
          Text(
            step.title,
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 14),
          Text(step.body, style: const TextStyle(fontSize: 16, height: 1.6)),
          if (step.handoff != null) ...[
            const SizedBox(height: 18),
            ...step.handoff!.map(_handoffCard),
          ],
          if (step.tip != null) ...[
            const SizedBox(height: 20),
            DeUI.card(
              context,
              color: p.surfaceAlt,
              padding: const EdgeInsets.all(14),
              child: Text(
                step.tip!,
                style: TextStyle(color: p.muted, fontSize: 13.5, height: 1.5),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _handoffCard(_HandoffRow row) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DeUI.card(
        context,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.arrow_forward_rounded, size: 16, color: p.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    row.what,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('Unlocks: ${row.unlocks}',
                style: TextStyle(color: p.success, fontSize: 13)),
            const SizedBox(height: 2),
            Text(row.how,
                style: TextStyle(color: p.muted, fontSize: 12.5)),
          ],
        ),
      ),
    );
  }
}
