import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/offline/family_access_state.dart';
import '../data/family_access_repository.dart';
import '../data/offline_family_repository.dart';
import 'family_providers.dart';

final familyAccessChangesProvider =
    StreamProvider.autoDispose<FamilyAccessChange>((ref) {
      final family = ref.watch(familyRepositoryProvider);
      final access = family is OfflineFamilyRepository ? family.access : null;
      if (access == null) return const Stream.empty();
      final observer = _FamilyAccessObserver(access);
      ref.onDispose(observer.dispose);
      return access.changes;
    });

class _FamilyAccessObserver with WidgetsBindingObserver {
  _FamilyAccessObserver(this.repository) {
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _refresh());
    scheduleMicrotask(_refresh);
  }
  final FamilyAccessRepository repository;
  late final Timer _timer;
  bool _disposed = false;
  void _refresh() {
    final state = WidgetsBinding.instance.lifecycleState;
    if (_disposed || state != null && state != AppLifecycleState.resumed) {
      return;
    }
    unawaited(repository.refresh().catchError((Object _) {}));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  void dispose() {
    _disposed = true;
    _timer.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}
