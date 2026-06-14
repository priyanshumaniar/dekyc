import 'package:de_kyc/screens/dashboard.dart';
import 'package:de_kyc/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Regression guard: the signed-out dashboard once blanked the whole screen
  // because a full-width themed button sat in a Row (infinite width). Render
  // it under the real DARK theme (the default) and assert no layout blowup.
  testWidgets('signed-out dashboard lays out with no exception (dark)',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const DashboardScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    // Signed-out content actually rendered.
    expect(find.text('Welcome to DeKYC'), findsOneWidget);
    expect(find.text('New here? Take the 2-minute tour'), findsOneWidget);
    expect(find.text('Sign in'), findsWidgets);
  });

  testWidgets('signed-out dashboard also renders under the light theme',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: const DashboardScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Welcome to DeKYC'), findsOneWidget);
  });
}
