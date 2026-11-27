import 'dart:async';
import 'package:flutter/widgets.dart';
import '../data/remote_parent_push.dart';

/// Revocation also runs on the signed-out screen, using only its restricted
/// installation capability. Foreground checks stop when the app is backgrounded.
class RemotePushLifecycle extends StatefulWidget {
  const RemotePushLifecycle({
    required this.controller,
    required this.child,
    super.key,
  });
  final RemoteParentPush? controller;
  final Widget child;
  @override
  State<RemotePushLifecycle> createState() => _RemotePushLifecycleState();
}

class _RemotePushLifecycleState extends State<RemotePushLifecycle>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _foreground = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    if (widget.controller != null) {
      _timer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (_foreground) unawaited(widget.controller?.flushRevocation());
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) widget.controller?.resumed();
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
