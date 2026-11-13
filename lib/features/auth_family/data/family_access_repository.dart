import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/offline/offline_store.dart';
import '../../../core/offline/family_access_state.dart';

class FamilyAccessRepository {
  FamilyAccessRepository({
    required this.store,
    required this.accountId,
    required this.load,
    required this.cancelNotifications,
  });
  final OfflineStore store;
  final String? Function() accountId;
  final Future<Map<String, dynamic>> Function() load;
  final Future<void> Function(FamilyAccessChange) cancelNotifications;
  final _changes = StreamController<FamilyAccessChange>.broadcast();
  Stream<FamilyAccessChange> get changes => _changes.stream;
  Future<void>? _flight;
  String? _flightOwner;
  bool _disposed = false;

  static Future<Map<String, dynamic>> fetch(SupabaseClient client) => client
      .rpc<Map<String, dynamic>>('family_membership_access')
      .timeout(const Duration(seconds: 15));

  Future<void> refresh() {
    final owner = accountId();
    if (owner == null || _disposed) return Future.value();
    if (_flight != null) {
      if (_flightOwner == owner) return _flight!;
      return _flight!.then(
        (_) => refresh(),
        onError: (Object _, StackTrace __) => refresh(),
      );
    }
    _flightOwner = owner;
    return _flight = _refresh(owner).whenComplete(() {
      _flight = null;
      _flightOwner = null;
    });
  }

  Future<void> _refresh(String owner) async {
    void check() {
      if (_disposed || accountId() != owner) throw StateError('登录账号已变化');
    }

    if (await store.accountDeletionJob(owner) != null) return;
    check();
    // Retry the durable native cleanup first, even if the next network read fails.
    await _deliver(owner, check);
    final response = await load();
    check();
    if (response['owner_id'] != owner) throw StateError('家庭权限归属不匹配');
    final states = [
      for (final value in response['states'] as List)
        FamilyAccessState.fromJson((value as Map).cast<String, dynamic>()),
    ];
    await store.applyFamilyAccess(owner, states);
    check();
    await _deliver(owner, check);
  }

  Future<void> _deliver(String owner, void Function() check) async {
    for (final change in await store.pendingFamilyAccessChanges(owner)) {
      check();
      _changes.add(change);
      await cancelNotifications(change);
      check();
      await store.acknowledgeFamilyAccessChange(change);
      check();
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _changes.close();
  }
}
