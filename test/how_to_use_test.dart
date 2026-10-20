import 'package:de_kyc/screens/how_to_use.dart';
import 'package:de_kyc/services/auth_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, {UserRole? role}) async {
    // Key by role: without it a second pumpWidget in the same test reuses the
    // existing State (same runtime type), so initState never re-runs and the
    // screen keeps the previous perspective AND page index.
    await tester.pumpWidget(MaterialApp(
      home: HowToUseScreen(key: ValueKey(role), role: role),
    ));
    await tester.pumpAndSettle();
  }

  /// Advance to the last step, collecting the visible body text as we go.
  Future<String> readAllSteps(WidgetTester tester) async {
    final buffer = StringBuffer();
    for (var i = 0; i < 12; i++) {
      for (final t in tester.widgetList<Text>(find.byType(Text))) {
        buffer.writeln(t.data ?? '');
      }
      final next = find.text('Next');
      if (next.evaluate().isEmpty) break;
      await tester.tap(next);
      await tester.pumpAndSettle();
    }
    return buffer.toString();
  }

  testWidgets('opens on the Individual perspective by default', (tester) async {
    await pump(tester, role: UserRole.individual);
    expect(find.text('Step 1 of 7'), findsOneWidget);
    expect(find.text('First, upload once'), findsOneWidget);
  });

  testWidgets('opens on the Verifier perspective when asked', (tester) async {
    await pump(tester, role: UserRole.verifier);
    expect(find.text('Sign in as a Verifier'), findsOneWidget);
  });

  testWidgets('Next advances through the steps', (tester) async {
    await pump(tester, role: UserRole.individual);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Step 2 of 7'), findsOneWidget);
    expect(find.text('Ask the verifier for two things'), findsOneWidget);
  });

  testWidgets('the perspective toggle swaps the content and resets to step 1',
      (tester) async {
    await pump(tester, role: UserRole.individual);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Step 2 of 7'), findsOneWidget);

    await tester.tap(find.text("I'm verifying someone"));
    await tester.pumpAndSettle();

    // Content swapped AND the position reset, so the dots cannot disagree with
    // the visible page.
    expect(find.text('Step 1 of 7'), findsOneWidget);
    expect(find.text('Sign in as a Verifier'), findsOneWidget);
    expect(find.text('First, upload once'), findsNothing);
  });

  testWidgets('the two roles give genuinely different instructions',
      (tester) async {
    await pump(tester, role: UserRole.individual);
    final individual = await readAllSteps(tester);

    await pump(tester, role: UserRole.verifier);
    final verifier = await readAllSteps(tester);

    expect(individual, isNot(equals(verifier)));
    // The user is told to ASK for the two values...
    expect(individual, contains('Ask the verifier for two things'));
    // ...and the verifier is told to SEND them.
    expect(verifier, contains('Send the user two things'));
  });

  testWidgets('BOTH perspectives spell out the two-part hand-off',
      (tester) async {
    // This is the question the guide exists to answer: is it the address, or
    // the key? Answer: both, and each unlocks a different half. If either
    // perspective stops saying so, the guide has lost its point.
    await pump(tester, role: UserRole.individual);
    final individual = await readAllSteps(tester);
    expect(individual.toLowerCase(), contains('wallet address'));
    expect(individual.toLowerCase(), contains('wrapping key'));
    expect(individual, contains('Why it takes both'));

    await pump(tester, role: UserRole.verifier);
    final verifier = await readAllSteps(tester);
    expect(verifier.toLowerCase(), contains('wallet address'));
    expect(verifier.toLowerCase(), contains('wrapping key'));
  });

  testWidgets('both perspectives say the user initiates, not the verifier',
      (tester) async {
    // The single most confusing thing about DeKYC: there is no on-chain
    // request, so nothing happens until the USER grants.
    await pump(tester, role: UserRole.individual);
    final individual = await readAllSteps(tester);
    expect(individual, contains('Nothing happens until YOU act'));

    await pump(tester, role: UserRole.verifier);
    final verifier = await readAllSteps(tester);
    expect(verifier, contains('cannot request documents'));
  });

  testWidgets('the verifier guide explains the two failure modes',
      (tester) async {
    await pump(tester, role: UserRole.verifier);
    final verifier = await readAllSteps(tester);
    expect(verifier, contains('Wrapped to a DIFFERENT wrapping key'));
    expect(verifier, contains('Does not decrypt this bundle'));
  });

  testWidgets('both perspectives say where to see badges, with dates',
      (tester) async {
    await pump(tester, role: UserRole.individual);
    final individual = await readAllSteps(tester);
    expect(individual, contains('See your badges'));
    expect(individual, contains('My badges'));

    await pump(tester, role: UserRole.verifier);
    final verifier = await readAllSteps(tester);
    expect(verifier, contains("This user's badges"));
    expect(verifier, contains('Dashboard → Badges'));
  });

  testWidgets('the last step closes the guide', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      const HowToUseScreen(role: UserRole.individual),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    for (var i = 0; i < 6; i++) {
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
    }
    expect(find.text('Got it 👍'), findsOneWidget);
    await tester.tap(find.text('Got it 👍'));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget); // back home
  });
}
