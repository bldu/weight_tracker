// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:weight_tracker/main.dart';

void main() {
  testWidgets('shows sign-in entry point', (WidgetTester tester) async {
    await tester.pumpWidget(const WeightTrackerApp());

    expect(find.text('Weight Tracker'), findsOneWidget);
    expect(find.text('Sign in with Google'), findsOneWidget);
  });
}
