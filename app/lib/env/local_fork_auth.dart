import 'package:firebase_auth/firebase_auth.dart';

import 'package:omi/env/local_fork.dart';
import 'package:omi/services/auth_service.dart';

/// What the startup sign-in must do with the persisted Firebase user.
enum LocalForkIdentityAction { reuse, replace, create }

/// Pure decision seam so both branches stay testable without Firebase.
LocalForkIdentityAction localForkIdentityAction({required bool localFork, required String? currentUid}) {
  if (!localFork) return LocalForkIdentityAction.reuse;
  if (currentUid == null) return LocalForkIdentityAction.create;
  return currentUid == localForkUid ? LocalForkIdentityAction.reuse : LocalForkIdentityAction.replace;
}

/// LOCAL ADAPT: build the invisible local identity the 小蜗 mobile build runs as.
///
/// Returns false instead of throwing so a cold start with the local backend down
/// reaches the onboarding retry screen instead of a login page or a crash.
Future<bool> ensureLocalForkSignedIn() async {
  if (!localFork) return false;

  try {
    final current = FirebaseAuth.instance.currentUser;
    switch (localForkIdentityAction(localFork: localFork, currentUid: current?.uid)) {
      case LocalForkIdentityAction.reuse:
        return current != null;
      case LocalForkIdentityAction.replace:
        await AuthService.instance.signOut();
        break;
      case LocalForkIdentityAction.create:
        break;
    }

    final credential = await AuthService.instance.signInWithLocalDevToken(uid: localForkUid);
    return credential?.user != null;
  } catch (_) {
    return false;
  }
}
