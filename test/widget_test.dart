import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:crypto_wallet/app/app.dart';

void main() {
  testWidgets('app builds', (WidgetTester tester) async {
    await tester.pumpWidget(const CryptoWalletApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
