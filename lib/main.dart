import 'package:de_kyc/screens/accessgranted.dart';
import 'package:de_kyc/screens/accessrequest.dart';
import 'package:de_kyc/screens/dashboard.dart';
import 'package:de_kyc/screens/kycdone.dart';
import 'package:de_kyc/screens/kycupload.dart';
import 'package:de_kyc/screens/login.dart';
import 'package:de_kyc/screens/onboarding.dart';
import 'package:de_kyc/screens/wallet_connect_screen.dart';
import 'package:de_kyc/screens/verifier_view_screen.dart';
import 'package:de_kyc/screens/kyc_status_screen.dart';
import 'package:de_kyc/screens/profile_screen.dart';
import 'package:de_kyc/screens/how_to_use.dart';
import 'package:de_kyc/screens/issued_badges_screen.dart';
import 'package:de_kyc/screens/user_guide.dart';
import 'package:de_kyc/services/auth_service.dart';
import 'package:de_kyc/theme/app_theme.dart';
import 'package:de_kyc/theme/components.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Load secrets from .env. Don't crash if it's missing — screens surface
  // clear errors when a required value is absent.
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    // .env not bundled yet; continue with empty config.
  }
  // Restore the saved theme WITHOUT blocking first paint: the app starts in
  // dark (the default) immediately and rebuilds if a light preference loads.
  unawaited(ThemeController.instance.load());
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeController.instance,
      builder: (context, _) => MaterialApp(
        title: 'DeKYC',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeController.instance.mode,
        home: const SplashScreen(),
        routes: {
          '/onboarding': (context) => const OnboardingScreen(),
          '/login': (context) => const LoginScreen(),
          '/dashboard': (context) => const DashboardScreen(),
          '/kycupload': (context) => const KYCUploadScreen(),
          '/kycdone': (context) => const KYCDoneScreen(),
          '/accessgranted': (context) => const AccessGranted(),
          '/accessrequest': (context) => const AccessRequestScreen(),
          '/verifier': (context) => const VerifierViewScreen(),
          '/kycstatus': (context) => const KycStatusScreen(),
          '/profile': (context) => const ProfileScreen(),
          '/walletconnect': (context) => const WalletConnectScreen(),
          '/guide': (context) => const UserGuideScreen(),
          '/howto': (context) => const HowToUseScreen(),
          '/issuedbadges': (context) => const IssuedBadgesScreen(),
        },
      ),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    // Branding beat + silent auth-session restore in parallel. The auth
    // restore also restores the wallet connection and re-verifies the stored
    // session signature (see AuthService.restore). A hard timeout guarantees
    // the splash never hangs if a wallet extension stalls on eth_accounts.
    final results = await Future.wait<dynamic>([
      Future.delayed(const Duration(milliseconds: 1600)),
      AuthService.instance.restore().timeout(
        const Duration(seconds: 8),
        onTimeout: () => false,
      ),
    ]);
    if (!mounted) return;
    final restored = results[1] == true;
    Navigator.pushReplacementNamed(
      context,
      restored ? '/dashboard' : '/onboarding',
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DeUI.logoMark(context, size: 84),
            const SizedBox(height: 24),
            const Text(
              'DeKYC',
              style: TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Your identity. Your keys.',
              style: TextStyle(color: p.muted, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
