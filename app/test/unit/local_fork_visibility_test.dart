import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/pages/settings/settings_search_index.dart';

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const scope = SettingsSearchScope(deviceConnected: true, supportLinks: true, android: true);

  test('local fork hides every account and cloud destination', () {
    for (final destination in localForkHiddenDestinations) {
      expect(settingsDestinationHidden(destination, localFork: true), isTrue);
    }
  });

  test('upstream build hides nothing', () {
    for (final destination in SettingsDestination.values) {
      expect(settingsDestinationHidden(destination, localFork: false), isFalse);
    }
  });

  test('local fork search skips hidden destinations', () {
    expect(searchSettings(en, en.account, scope, localFork: true), isEmpty);
    expect(searchSettings(en, en.planAndUsage, scope, localFork: true), isEmpty);
    expect(searchSettings(en, en.integrations, scope, localFork: true), isEmpty);
    expect(searchSettings(en, en.connectAnAgent, scope, localFork: true), isEmpty);
    expect(
      searchSettings(en, en.memories, scope, localFork: true).map((e) => e.destination),
      contains(SettingsDestination.memories),
    );
  });

  test('upstream search still finds account rows', () {
    expect(
      searchSettings(en, en.account, scope, localFork: false).map((e) => e.destination),
      contains(SettingsDestination.profile),
    );
    expect(
      searchSettings(en, en.deleteAccountTitle, scope, localFork: false).map((e) => e.destination),
      contains(SettingsDestination.deleteAccount),
    );
  });
}
