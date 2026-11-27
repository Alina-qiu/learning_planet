import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/offline/network_failure.dart';
import '../../../core/offline/offline_store.dart';
import '../domain/economy_page.dart';

/// Read-only snapshots of the four first pages. Pending commands never change
/// their balances, availability or history; any write retires the old snapshot.
class EconomySnapshots {
  EconomySnapshots({
    required this.accountId,
    required this.isCurrent,
    this.store,
  });
  final String? Function() accountId;
  final bool Function() isCurrent;
  final OfflineStore? store;
  final _reads = <String, int>{};
  int _version = 0, _changing = 0;

  Future<int> _revision(String owner) async => store == null
      ? _version
      : (await store!.read(owner, 'economy-cache-version'))?['value'] as int? ??
            0;

  void _guard(String owner, int? privacy) {
    if (!isCurrent() ||
        accountId() != owner ||
        store?.privacyGeneration != privacy) {
      throw StateError('账号或本机资料已变化，请重新打开奖励页面');
    }
  }

  Map<String, dynamic> _validate(
    Map<String, dynamic> data,
    String owner,
    String child,
    String family,
    bool parent, {
    required bool offline,
  }) {
    final overview = data['overview'];
    if (data['schema'] != 1 ||
        data['owner_id'] != owner ||
        data['child_id'] != child ||
        data['family_id'] != family ||
        data['include_inactive'] != parent ||
        data['family_timezone'] != null && data['family_timezone'] is! String ||
        data['fetched_at'] is! String ||
        DateTime.tryParse(data['fetched_at'] as String) == null ||
        overview is! Map ||
        overview['child_id'] != child ||
        overview['reconciled'] is! bool ||
        data['cursors'] is! Map ||
        data['page_days'] is! Map) {
      throw const FormatException('奖励记录范围或格式不正确');
    }
    for (final field in [
      'coin_balance',
      'frozen_balance',
      'xp',
      'pending_coins',
      'daily_soft_limit',
      'month_income',
      'month_spent',
    ]) {
      if (overview[field] is! int || (overview[field] as int) < 0) {
        throw const FormatException('钱包记录格式不正确');
      }
    }
    for (final section in ['rewards', 'redemptions', 'pending', 'ledger']) {
      EconomyPage.fromJson(
        {
          'owner_id': owner,
          'child_id': child,
          'family_id': family,
          'section': section,
          'include_inactive': parent,
          'family_today': (data['page_days'] as Map)[section],
          'items': data[section],
          'next_cursor': (data['cursors'] as Map)[section],
        },
        owner: owner,
        child: child,
        family: family,
        section: section,
        includeInactive: parent,
      );
    }
    return {...data, 'offline': offline};
  }

  Future<Map<String, dynamic>> load({
    required String child,
    required String family,
    required bool parent,
    required bool Function() currentParent,
    required Future<void> Function(String owner, int? privacy) checkAccess,
    required Future<Map<String, dynamic>> Function() fetch,
  }) async {
    final owner = accountId(), privacy = store?.privacyGeneration;
    if (owner == null) throw StateError('请先登录');
    final key = 'economy-view:$child:$family:${parent ? 'parent' : 'child'}';
    final sequence = (_reads[key] ?? 0) + 1;
    _reads[key] = sequence;
    final revision = await _revision(owner);
    Future<void> check() async {
      _guard(owner, privacy);
      await checkAccess(owner, privacy);
      if (_changing != 0 ||
          _reads[key] != sequence ||
          currentParent() != parent ||
          await _revision(owner) != revision) {
        throw StateError('奖励记录或显示范围已变化，请刷新');
      }
      _guard(owner, privacy);
    }

    await check();
    try {
      final data = await fetch();
      await check();
      if (store == null) return {...data, 'offline': false};
      final snapshot = _validate(
        {
          ...data,
          'schema': 1,
          'owner_id': owner,
          'child_id': child,
          'family_id': family,
          'include_inactive': parent,
        },
        owner,
        child,
        family,
        parent,
        offline: false,
      );
      await store!.transaction(() async {
        await check();
        await store!.write(owner, key, {
          ...snapshot,
          'cache_version': revision,
        });
        await check();
      });
      return snapshot;
    } catch (error) {
      await check();
      if (error is PostgrestException && error.code == '42501') {
        for (final mode in ['parent', 'child']) {
          await store?.remove(owner, 'economy-view:$child:$family:$mode');
        }
      }
      if (!isNetworkFailure(error) || store == null) rethrow;
      final cached = await store!.read(owner, key);
      await check();
      if (cached == null || cached['cache_version'] != revision) rethrow;
      return _validate(cached, owner, child, family, parent, offline: true);
    }
  }

  Future<T> change<T>(Future<T> Function() action) async {
    final owner = accountId(), privacy = store?.privacyGeneration;
    if (owner == null) throw StateError('请先登录');
    Future<void> retire() async {
      _guard(owner, privacy);
      _version++;
      await store?.invalidateEconomyViews(owner);
      _guard(owner, privacy);
    }

    _changing++;
    try {
      await retire();
      try {
        final result = await action();
        _guard(owner, privacy);
        return result;
      } finally {
        await retire();
      }
    } finally {
      _changing--;
    }
  }
}
