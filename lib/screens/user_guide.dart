import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/components.dart';

/// A fun, swipeable 2-minute tour that explains the whole app: wallet
/// identity, sign-in, encryption, IPFS, access control, soulbound badges and
/// key safety. Linked from the dashboard ("homepage") for new users.
class UserGuideScreen extends StatefulWidget {
  const UserGuideScreen({super.key});

  @override
  State<UserGuideScreen> createState() => _UserGuideScreenState();
}

class _GuideStep {
  const _GuideStep({
    required this.emoji,
    required this.title,
    required this.body,
    this.funFact,
  });

  final String emoji;
  final String title;
  final String body;
  final String? funFact;
}

class _UserGuideScreenState extends State<UserGuideScreen> {
  final PageController _controller = PageController();
  int _page = 0;

  static const List<_GuideStep> _steps = [
    _GuideStep(
      emoji: '🪪',
      title: 'Meet your new ID',
      body: 'Your crypto wallet IS your identity here. No usernames, no '
          'passwords, no "Forgot password?" button — because there is '
          'nothing to forget. If you control the wallet, you ARE you.',
      funFact: 'Fun fact: DeKYC has no user database. There is literally '
          'nothing for hackers to steal from a server.',
    ),
    _GuideStep(
      emoji: '✍️',
      title: 'Sign in by… signing',
      body: 'Logging in means signing one free message with your wallet — '
          'like an autograph that proves the wallet is really yours. '
          'It costs nothing and sends no transaction. You also pick a role: '
          'Individual (that’s probably you) or Verifier (banks & co).',
      funFact: 'Your session lasts 24 hours, then we politely ask for a new '
          'autograph.',
    ),
    _GuideStep(
      emoji: '🔐',
      title: 'Your docs get a bodyguard',
      body: 'Before anything leaves your device, your documents are '
          'encrypted with AES-256 — the same family of encryption banks '
          'use. The secret key is derived from your wallet signature, so '
          'only YOUR wallet can ever recreate it.',
      funFact: 'Not even DeKYC can read your documents. We checked. '
          'We really can’t.',
    ),
    _GuideStep(
      emoji: '🌐',
      title: 'Off to IPFS, fingerprint on-chain',
      body: 'The encrypted bundle is pinned to IPFS — a worldwide '
          'decentralized file network. Only a tiny fingerprint of it '
          '(a CID) is written to the Ethereum blockchain, where nobody '
          'can secretly swap or delete it.',
      funFact: 'IPFS addresses files by WHAT they are, not WHERE they are. '
          'Change one byte and the fingerprint changes completely.',
    ),
    _GuideStep(
      emoji: '🤝',
      title: 'You hold the guest list',
      body: 'A bank wants to verify you? YOU grant them access on-chain '
          'and YOU hand them the decryption key. The key — not the chain — '
          'is what actually unlocks your documents, so only share it with '
          'a verifier you granted. Revoke the grant any time.',
      funFact: 'Grants expire automatically. Forgetting to revoke is not '
          'a catastrophe — time does it for you.',
    ),
    _GuideStep(
      emoji: '🏅',
      title: 'Verified once, trusted everywhere',
      body: 'After checking your documents, a verifier mints a Soulbound '
          'badge to your wallet: a special token that can never be '
          'transferred, sold or faked. The next app can just look at the '
          'badge instead of asking for your documents all over again. '
          'Find yours under Status → "My badges", with who issued each one '
          'and the dates it is valid.',
      funFact: '"Soulbound" is a real Ethereum standard (ERC-5192). Yes, '
          'the name comes from video games.',
    ),
    _GuideStep(
      emoji: '🛡️',
      title: 'The two golden rules',
      body: 'Rule 1: your wallet seed phrase IS your documents — lose it '
          'and nobody in the universe can decrypt them again. Back it up. '
          'Rule 2: only share your decryption key with a verifier you have '
          'actually granted access to. That’s it. You’re a pro now.',
      funFact: 'DeKYC runs on the Sepolia test network — perfect for '
          'trying everything with zero real-money risk.',
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
        title: const Text('How DeKYC works'),
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
              Expanded(
                child: PageView.builder(
                  controller: _controller,
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
                          margin:
                              const EdgeInsets.symmetric(horizontal: 3),
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
                        child:
                            Text(isLast ? 'Got it — let’s go! 🚀' : 'Next'),
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

  Widget _stepPage(_GuideStep step, int index) {
    final p = context.pal;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 12),
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
          const SizedBox(height: 20),
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              color: p.surface,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(step.emoji, style: const TextStyle(fontSize: 42)),
          ),
          const SizedBox(height: 18),
          Text(
            step.title,
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 14),
          Text(
            step.body,
            style: const TextStyle(fontSize: 16, height: 1.6),
          ),
          if (step.funFact != null) ...[
            const SizedBox(height: 20),
            DeUI.card(
              context,
              color: p.surfaceAlt,
              padding: const EdgeInsets.all(14),
              child: Text(
                step.funFact!,
                style:
                    TextStyle(color: p.muted, fontSize: 13.5, height: 1.5),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
