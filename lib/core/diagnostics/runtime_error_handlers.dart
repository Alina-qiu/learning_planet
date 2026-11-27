import 'dart:ui';
import 'package:flutter/widgets.dart';
import 'runtime_diagnostics.dart';

void installRuntimeErrorHandlers(RuntimeDiagnostics diagnostics) {
  FlutterError.onError = (details) {
    diagnostics.record(DiagnosticOperation.framework, error: details.exception);
    // The default presenter may include private exception messages or widget
    // diagnostics. Its replacement emits only the fixed event/code above.
  };
  PlatformDispatcher.instance.onError = (error, _) {
    diagnostics.record(DiagnosticOperation.async, error: error);
    return true;
  };
}

class RuntimeDiagnosticsLifecycle extends StatefulWidget {
  const RuntimeDiagnosticsLifecycle({
    required this.diagnostics,
    required this.child,
    super.key,
  });
  final RuntimeDiagnostics diagnostics;
  final Widget child;
  @override
  State<RuntimeDiagnosticsLifecycle> createState() =>
      _RuntimeDiagnosticsLifecycleState();
}

class _RuntimeDiagnosticsLifecycleState
    extends State<RuntimeDiagnosticsLifecycle>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    widget.diagnostics.setForeground(
      state == null || state == AppLifecycleState.resumed,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      widget.diagnostics.setForeground(state == AppLifecycleState.resumed);
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.diagnostics.setForeground(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
