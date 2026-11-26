import 'package:flutter_test/flutter_test.dart';

import 'package:omi/env/local_fork.dart';
import 'package:omi/env/local_fork_auth.dart';

void main() {
  test('reuses the matching local identity', () {
    expect(
      localForkIdentityAction(localFork: true, currentUid: localForkUid),
      LocalForkIdentityAction.reuse,
    );
  });

  test('replaces a different persisted identity', () {
    expect(
      localForkIdentityAction(localFork: true, currentUid: 'someone-else'),
      LocalForkIdentityAction.replace,
    );
  });

  test('creates when no identity exists', () {
    expect(
      localForkIdentityAction(localFork: true, currentUid: null),
      LocalForkIdentityAction.create,
    );
  });

  test('upstream build never touches the identity', () {
    expect(
      localForkIdentityAction(localFork: false, currentUid: 'someone-else'),
      LocalForkIdentityAction.reuse,
    );
  });
}
