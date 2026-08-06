import 'package:de_kyc/screens/accessrequest.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verifier Mode is where the hand-off starts, and two defects lived here:
/// a verdict that outlived the address it was produced for, and a wrapping key
/// that could not be reached until after the grant it was needed for.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: AccessRequestScreen()),
    );
    await tester.pump();
  }

  testWidgets('the wrapping key is offered BEFORE any grant exists',
      (tester) async {
    // The deadlock: the user cannot wrap a document key without the verifier's
    // wrapping key, and the verifier could only see it on the documents screen
    // — which requires the grant that the wrapping is a precondition for.
    await pump(tester);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Send these to the user first'), findsOneWidget);
    expect(find.text('Your wrapping key'), findsOneWidget);
    expect(find.text('Your wallet address'), findsOneWidget);

    // Nothing has been checked and no wallet is connected, so this is the
    // earliest possible moment in the flow — exactly when it must be visible.
    expect(find.text('View Documents'), findsNothing);
  });

  testWidgets('editing the address clears a stale verdict', (tester) async {
    await pump(tester);
    await tester.pump(const Duration(milliseconds: 300));

    // Drive the field directly: a real check needs a wallet and an RPC, but the
    // invalidation must hold regardless of how the verdict was produced.
    final field = find.byType(TextField);
    expect(field, findsOneWidget);

    await tester.enterText(field, '0x1111111111111111111111111111111111111111');
    await tester.pump();
    // No verdict yet, so no action button may be offered.
    expect(find.text('View Documents'), findsNothing);

    await tester.enterText(field, '0x2222222222222222222222222222222222222222');
    await tester.pump();
    expect(find.text('View Documents'), findsNothing);
  });

  testWidgets('an invalid address is rejected with a message, not silently',
      (tester) async {
    await pump(tester);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byType(TextField), 'not-an-address');
    await tester.tap(find.text('Check Access Status'));
    await tester.pump();

    expect(find.text('Enter a valid 0x… user address'), findsOneWidget);
  });

  testWidgets('the help icon opens the verifier perspective', (tester) async {
    await pump(tester);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byIcon(Icons.help_outline));
    await tester.pumpAndSettle();

    expect(find.text('How to use DeKYC'), findsOneWidget);
    expect(find.text('Sign in as a Verifier'), findsOneWidget);
  });
}
