import 'package:flutter_test/flutter_test.dart';

import 'package:omi/providers/usage_provider.dart';

void main() {
  test('local fork never shows subscription UI', () {
    expect(showSubscriptionUiFor(localFork: true, storefrontFlag: true), isFalse);
    expect(showSubscriptionUiFor(localFork: true, storefrontFlag: null), isFalse);
  });

  test('upstream build follows the storefront flag', () {
    expect(showSubscriptionUiFor(localFork: false, storefrontFlag: true), isTrue);
    expect(showSubscriptionUiFor(localFork: false, storefrontFlag: null), isTrue);
    expect(showSubscriptionUiFor(localFork: false, storefrontFlag: false), isFalse);
  });
}
