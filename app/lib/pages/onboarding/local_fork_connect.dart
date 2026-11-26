import 'package:flutter/material.dart';

import 'package:omi/env/local_fork_auth.dart';
import 'package:omi/ui/ui.dart';
import 'package:omi/utils/l10n_extensions.dart';

/// LOCAL ADAPT: first-run gate for the account-free build.
///
/// The 小蜗 mobile build has no sign-in page. This view retries the invisible
/// local identity and hands off to onboarding once it exists.
class LocalForkConnectView extends StatefulWidget {
  const LocalForkConnectView({super.key, required this.onConnected, this.connect});

  final Future<void> Function() onConnected;
  final Future<bool> Function()? connect;

  @override
  State<LocalForkConnectView> createState() => _LocalForkConnectViewState();
}

class _LocalForkConnectViewState extends State<LocalForkConnectView> {
  bool _connecting = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _failed = false;
    });
    final ok = await (widget.connect ?? ensureLocalForkSignedIn)();
    if (!mounted) return;
    if (ok) {
      await widget.onConnected();
      return;
    }
    setState(() {
      _connecting = false;
      _failed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(OmiSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_connecting) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: OmiSpacing.lg),
              Text(l10n.loading, textAlign: TextAlign.center),
            ] else if (_failed) ...[
              Text(l10n.somethingWentWrong, textAlign: TextAlign.center),
              const SizedBox(height: OmiSpacing.lg),
              OmiButton(label: l10n.retry, onPressed: _connect),
            ],
          ],
        ),
      ),
    );
  }
}
