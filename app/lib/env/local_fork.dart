/// LOCAL ADAPT: the 小蜗 mobile build has no account UI.
///
/// Defaults to false so upstream builds and tests keep the upstream behavior.
/// The local-fork APK is built with `--dart-define=OMI_LOCAL_FORK=true`.
const bool localFork = bool.fromEnvironment('OMI_LOCAL_FORK');

/// The invisible fixed identity the local-fork build runs as.
const String localForkUid = 'local-dev-user';
