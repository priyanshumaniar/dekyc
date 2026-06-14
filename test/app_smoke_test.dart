import 'package:de_kyc/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('boots: splash brand → onboarding CTAs', (tester) async {
    await tester.pumpWidget(const MyApp());

    // Splash branding.
    expect(find.text('DeKYC'), findsOneWidget);
    expect(find.text('Your identity. Your keys.'), findsOneWidget);

    // Let the splash delay elapse. On the test VM the secure-storage read
    // never completes (no platform backend), so we also pump past the 4 s
    // restore timeout — then the app falls through to onboarding.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(find.text('Get Started'), findsOneWidget);
    expect(find.text('How does it work? 🚀'), findsOneWidget);
  });

  testWidgets('onboarding → role-based login route works', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Get Started'));
    await tester.pumpAndSettle();

    // Role-based login screen.
    expect(find.text('Choose your role'), findsOneWidget);
    expect(find.text('Individual'), findsOneWidget);
    expect(find.text('Verifier'), findsOneWidget);
    expect(find.text('Continue as Individual'), findsOneWidget);
  });
}
