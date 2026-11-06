import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth_family/application/family_providers.dart';
import '../data/configuration_time_recorder.dart';
import '../domain/configuration_session.dart';
export '../domain/configuration_session.dart' show ConfigurationKind;

final configurationElapsedProvider = Provider<Duration Function()>((ref) {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
});

/// Wrap the editable route/dialog, leaving loading and save HTTP requests outside.
class ConfigurationTimeScope extends ConsumerStatefulWidget {
  const ConfigurationTimeScope({
    required this.childId,
    required this.familyId,
    required this.kind,
    required this.child,
    super.key,
  });
  final String childId, familyId;
  final ConfigurationKind kind;
  final Widget child;
  static void activity(BuildContext context) => context
      .findAncestorStateOfType<_ConfigurationTimeScopeState>()
      ?._session
      ?.activity();
  @override
  ConsumerState<ConfigurationTimeScope> createState() =>
      _ConfigurationTimeScopeState();
}

class _ConfigurationTimeScopeState extends ConsumerState<ConfigurationTimeScope>
    with WidgetsBindingObserver {
  ConfigurationSession? _session;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final recorder = ref.read(configurationTimeRecorderProvider);
      if (recorder == null) return;
      final scope = recorder.capture(
        widget.childId,
        widget.familyId,
        widget.kind,
      );
      _session = ConfigurationSession(
        startedAt: recorder.now,
        elapsed: ref.read(configurationElapsedProvider),
        onInterval: (start, end) =>
            unawaited(recorder.record(scope, start, end)),
      );
      _session!.setEnabled(
        ref.read(activeParentFamilyProvider) == widget.familyId,
      );
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      _session!.setForeground(
        lifecycle == null || lifecycle == AppLifecycleState.resumed,
      );
      _timer = Timer.periodic(
        const Duration(seconds: 15),
        (_) => _session?.sample(),
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _session?.setForeground(state == AppLifecycleState.resumed);
  @override
  void dispose() {
    _timer?.cancel();
    _session?.close();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      activeParentFamilyProvider,
      (_, family) => _session?.setEnabled(family == widget.familyId),
    );
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _session?.activity(),
      onPointerMove: (_) => _session?.activity(),
      onPointerSignal: (_) => _session?.activity(),
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: (_, _) {
          _session?.activity();
          return KeyEventResult.ignored;
        },
        child: PopScope(
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) _session?.close();
          },
          child: widget.child,
        ),
      ),
    );
  }
}
