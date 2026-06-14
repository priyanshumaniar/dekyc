import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/components.dart';

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                children: [
                  const Spacer(flex: 2),
                  DeUI.logoMark(context, size: 76),
                  const SizedBox(height: 22),
                  const Text(
                    'DeKYC',
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Self-sovereign KYC on Ethereum.\n'
                    'Encrypt once, verify anywhere — you hold the keys.',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: p.muted, fontSize: 15, height: 1.5),
                  ),
                  const Spacer(flex: 2),
                  _feature(context, Icons.lock_outline,
                      'Documents encrypted on your device'),
                  const SizedBox(height: 12),
                  _feature(context, Icons.hub_outlined,
                      'Stored on IPFS, anchored on-chain'),
                  const SizedBox(height: 12),
                  _feature(context, Icons.verified_outlined,
                      'Reusable soulbound verification'),
                  const Spacer(flex: 2),
                  ElevatedButton(
                    onPressed: () => Navigator.pushNamed(context, '/login'),
                    child: const Text('Get Started'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () => Navigator.pushNamed(context, '/guide'),
                    child: const Text('How does it work? 🚀'),
                  ),
                  const SizedBox(height: 28),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _feature(BuildContext context, IconData icon, String text) {
    final p = context.pal;
    return Row(
      children: [
        DeUI.iconChip(context, icon),
        const SizedBox(width: 14),
        Expanded(
          child: Text(text,
              style: TextStyle(fontSize: 14.5, color: p.text)),
        ),
      ],
    );
  }
}
