import 'package:de_kyc/screens/user_guide.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('tour starts at step 1 and Next advances pages',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: UserGuideScreen()));

    expect(find.text('Step 1 of 7'), findsOneWidget);
    expect(find.text('Meet your new ID'), findsOneWidget);

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Step 2 of 7'), findsOneWidget);
    expect(find.text('Sign in by… signing'), findsOneWidget);
  });

  testWidgets('Skip closes the tour', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const UserGuideScreen()),
              ),
              child: const Text('open tour'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open tour'));
    await tester.pumpAndSettle();
    expect(find.text('Meet your new ID'), findsOneWidget);

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.text('open tour'), findsOneWidget); // back home
  });
}
