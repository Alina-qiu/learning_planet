import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/offline/offline_store.dart';
import '../../../core/offline/network_failure.dart';
import '../domain/schedule_snapshot.dart';

class ScheduleSnapshots {
  ScheduleSnapshots(this.client, {this.store, String? Function()? accountId})
    : accountId = accountId ?? (() => client.auth.currentUser?.id);
  final SupabaseClient client;
  final OfflineStore? store;
  final String? Function() accountId;
  final _changing = <String>{};
  final _versions = <String, int>{};
  final _loads = <String, int>{};

  Future<int> _version(String owner, String child) async => store == null
      ? _versions['$owner:$child'] ?? 0
      : (await store!.read(owner, 'schedule-version:$child'))?['value']
                as int? ??
            0;

  Future<void> _check(String owner, String child, int? privacy) async {
    void guard() {
      if (accountId() != owner || store?.privacyGeneration != privacy) {
        throw StateError('账号或本机资料已变化，请重新打开计划');
      }
    }

    guard();
    if (store != null &&
        (await store!.accountDeletionJob(owner) != null ||
            await store!.isChildDeleted(child) ||
            await store!.familyAccessRevoked(owner, childId: child))) {
      throw StateError('账号或孩子已不可访问');
    }
    guard();
  }

  Future<ScheduleSnapshot> load(String child) async {
    final owner = accountId(), privacy = store?.privacyGeneration;
    if (owner == null) throw StateError('请先登录');
    final loadKey = '$owner:$child';
    final load = (_loads[loadKey] ?? 0) + 1;
    _loads[loadKey] = load;
    await _check(owner, child, privacy);
    final version = await _version(owner, child);
    Future<void> check() async {
      await _check(owner, child, privacy);
      if (_loads[loadKey] != load ||
          _changing.contains('$owner:$child') ||
          await _version(owner, child) != version) {
        throw StateError('计划已变更，请重新读取');
      }
      await _check(owner, child, privacy);
    }

    await check();
    try {
      final rows = <Map<String, dynamic>>[], seenCursors = <String>{};
      Map<String, dynamic>? cursor, first;
      do {
        final page = await client
            .rpc<Map<String, dynamic>>(
              'task_schedule_page',
              params: {
                'target_child_id': child,
                'page_size': 100,
                'after_created_at': cursor?['created_at'],
                'after_id': cursor?['id'],
              },
            )
            .timeout(const Duration(seconds: 10));
        await check();
        first ??= page;
        if (page['child_id'] != child ||
            page['family_id'] != first['family_id'] ||
            page['family_today'] != first['family_today']) {
          throw const FormatException('计划范围或日期已变化，请刷新');
        }
        rows.addAll((page['items'] as List).cast<Map<String, dynamic>>());
        final next = page['next_cursor'];
        cursor = next == null ? null : (next as Map).cast<String, dynamic>();
        if (cursor != null) {
          if (cursor['created_at'] is! String ||
              cursor['id'] is! String ||
              (page['items'] as List).isEmpty ||
              !seenCursors.add('${cursor['created_at']}:${cursor['id']}')) {
            throw const FormatException('计划分页未前进，请刷新');
          }
        }
      } while (cursor != null);
      final data = {
        'schema': 1,
        'child_id': child,
        'family_id': first['family_id'],
        'family_today': first['family_today'],
        'fetched_at': first['fetched_at'],
        'items': rows,
        'version': version,
      };
      final snapshot = ScheduleSnapshot.fromJson(data, child);
      await check();
      if (store != null) {
        await store!.transaction(() async {
          await check();
          await store!.write(owner, 'schedules:$child', data);
          await check();
        });
      }
      return snapshot;
    } catch (error) {
      await check();
      if (error is PostgrestException && error.code == '42501') {
        await store?.remove(owner, 'schedules:$child');
      }
      if (!isNetworkFailure(error) || store == null) rethrow;
      final cached = await store!.read(owner, 'schedules:$child');
      await check();
      if (cached == null || cached['version'] != version) rethrow;
      return ScheduleSnapshot.fromJson(cached, child, offline: true);
    }
  }

  // Fence both in-flight reads and cached content before a write. A lost reply
  // leaves the list unavailable offline until an authoritative reload succeeds.
  Future<T> change<T>(String child, Future<T> Function() action) async {
    final owner = accountId(), privacy = store?.privacyGeneration;
    if (owner == null) throw StateError('请先登录');
    final key = '$owner:$child';
    if (!_changing.add(key)) throw StateError('计划正在更新');
    Future<void> retire() async {
      await _check(owner, child, privacy);
      if (store == null) {
        _versions[key] = (_versions[key] ?? 0) + 1;
      } else {
        await store!.transaction(() async {
          final next = await _version(owner, child) + 1;
          await _check(owner, child, privacy);
          await store!.write(owner, 'schedule-version:$child', {'value': next});
          await store!.remove(owner, 'schedules:$child');
          await _check(owner, child, privacy);
        });
      }
    }

    try {
      await retire();
      await _check(owner, child, privacy);
      try {
        final result = await action();
        await _check(owner, child, privacy);
        return result;
      } finally {
        await retire();
      }
    } finally {
      _changing.remove(key);
    }
  }
}
