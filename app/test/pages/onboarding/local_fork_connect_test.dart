import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/pages/onboarding/local_fork_connect.dart';

void main() {
  testWidgets('retries the local identity and hands off once it exists', (tester) async {
    var attempts = 0;
    var connected = false;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LocalForkConnectView(
            connect: () async {
              attempts++;
              return attempts > 1;
            },
            onConnected: () async {
              connected = true;
            },
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();

    expect(attempts, 1);
    expect(connected, isFalse);
    expect(find.text('Try Again'), findsOneWidget);

    await tester.tap(find.text('Try Again'));
    await tester.pump();
    await tester.pump();

    expect(attempts, 2);
    expect(connected, isTrue);
  });
}
