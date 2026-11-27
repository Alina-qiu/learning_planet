import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/offline/offline_store.dart';
import '../../../core/offline/network_failure.dart';

/// Authoritative growth only: pending task rewards never unlock local assets.
class GrowthSnapshots {
  GrowthSnapshots(this.client, {this.store, String? Function()? accountId})
    : accountId = accountId ?? (() => client.auth.currentUser?.id);
  final SupabaseClient client;
  final OfflineStore? store;
  final String? Function() accountId;
  final _reads = <String, int>{}, _versions = <String, int>{};
  final _changing = <String>{};
  bool _closed = false;
  void dispose() => _closed = true;

  Future<void> _check(String owner, String child, int? privacy) async {
    void guard() {
      if (_closed ||
          accountId() != owner ||
          store?.privacyGeneration != privacy) {
        throw StateError('账号或本机资料已变化，请重新打开成长记录');
      }
    }

    guard();
    if (store != null &&
        (await store!.accountDeletionJob(owner) != null ||
            await store!.isChildDeleted(child) ||
            await store!.familyAccessRevoked(owner, childId: child))) {
      throw StateError('成长记录已不可访问');
    }
    guard();
  }

  Future<int> _version(String owner, String child) async => store == null
      ? _versions['$owner:$child'] ?? 0
      : (await store!.read(owner, 'growth-version:$child'))?['value'] as int? ??
            0;

  Map<String, dynamic> _validate(
    Map<String, dynamic> value,
    String child, {
    required bool offline,
  }) {
    bool count(Object? v) => v is int && v >= 0;
    final appearance = value['appearance'],
        assets = value['assets'],
        milestones = value['milestones'];
    if (value['schema'] != 1 ||
        value['child_id'] != child ||
        value['family_id'] is! String ||
        (value['family_id'] as String).isEmpty ||
        value['fetched_at'] is! String ||
        DateTime.tryParse(value['fetched_at'] as String) == null ||
        value['today'] is! String ||
        DateTime.tryParse(value['today'] as String) == null ||
        !count(value['xp']) ||
        !count(value['streak']) ||
        value['checkin_today'] is! bool ||
        appearance is! Map ||
        !const ['astronaut', 'explorer'].contains(appearance['avatar']) ||
        assets is! List ||
        milestones is! List ||
        milestones.any((v) => !const [3, 7, 30].contains(v))) {
      throw const FormatException('成长记录范围或格式不正确');
    }
    final keys = <String>{};
    for (final asset in assets) {
      if (asset is! Map ||
          asset['key'] is! String ||
          !keys.add(asset['key'] as String) ||
          asset['title'] is! String ||
          !const ['pet', 'badge', 'outfit'].contains(asset['kind']) ||
          asset['unlocked'] is! bool ||
          asset['minimum_level'] != null &&
              (asset['minimum_level'] is! int ||
                  (asset['minimum_level'] as int) < 1 ||
                  (asset['minimum_level'] as int) > 50)) {
        throw const FormatException('成长物品格式不正确');
      }
    }
    for (final slot in ['pet', 'badge', 'outfit']) {
      final selection = appearance[slot];
      if (selection != null &&
          !assets.any(
            (a) =>
                a['key'] == selection &&
                a['kind'] == slot &&
                a['unlocked'] == true,
          )) {
        throw const FormatException('角色物品与解锁记录不匹配');
      }
    }
    return {...value, 'offline': offline};
  }

  Future<Map<String, dynamic>> load(String child) async {
    final owner = accountId(), privacy = store?.privacyGeneration;
    if (owner == null) throw StateError('请先登录');
    final key = '$owner:$child', sequence = (_reads['$owner:$child'] ?? 0) + 1;
    _reads[key] = sequence;
    await _check(owner, child, privacy);
    final version = await _version(owner, child);
    Future<void> check() async {
      await _check(owner, child, privacy);
      if (_reads[key] != sequence ||
          _changing.contains(key) ||
          await _version(owner, child) != version) {
        throw StateError('成长记录已变化，请刷新');
      }
      await _check(owner, child, privacy);
    }

    await check();
    try {
      final result = await client
          .rpc<Map<String, dynamic>>(
            'growth_overview',
            params: {'target_child_id': child},
          )
          .timeout(const Duration(seconds: 15));
      await check();
      final value = _validate(result, child, offline: false);
      if (store != null) {
        await store!.transaction(() async {
          await check();
          await store!.write(owner, 'growth:$child', {
            'family_id': value['family_id'],
            'version': version,
            'data': value,
          });
          await check();
        });
      }
      return value;
    } catch (error) {
      await check();
      if (error is PostgrestException && error.code == '42501') {
        await store?.remove(owner, 'growth:$child');
      }
      if (!isNetworkFailure(error) || store == null) rethrow;
      final cached = await store!.read(owner, 'growth:$child');
      await check();
      if (cached == null || cached['version'] != version) rethrow;
      return _validate(
        (cached['data'] as Map).cast<String, dynamic>(),
        child,
        offline: true,
      );
    }
  }

  Future<T> change<T>(String child, Future<T> Function() action) async {
    final owner = accountId(), privacy = store?.privacyGeneration;
    if (owner == null) throw StateError('请先登录');
    final key = '$owner:$child';
    if (!_changing.add(key)) throw StateError('成长记录正在更新');
    Future<void> retire() async {
      await _check(owner, child, privacy);
      if (store == null) {
        _versions[key] = (_versions[key] ?? 0) + 1;
      } else {
        await store!.transaction(() async {
          final next = await _version(owner, child) + 1;
          await _check(owner, child, privacy);
          await store!.write(owner, 'growth-version:$child', {'value': next});
          await store!.remove(owner, 'growth:$child');
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
