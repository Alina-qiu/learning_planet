import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';
import '../../tasks/domain/task_sync_state.dart';
import '../../../core/offline/offline_store.dart';
import '../../../core/offline/network_failure.dart';
import '../../auth_family/application/family_providers.dart';
import '../domain/economy_page.dart';
import 'economy_snapshots.dart';
import '../domain/wallet_adjustment_details.dart';

abstract interface class EconomyRepository {
  Future<Map<String, dynamic>> load(String childId, String familyId);
  Future<void> saveReward(
    String familyId,
    Map<String, dynamic> config, {
    String? rewardId,
  });
  Future<void> request(
    String childId,
    String rewardId,
    String key,
    int version,
  );
  Future<void> transition(String id, String operation, String reason);
  Future<void> adjust(String childId, Map<String, dynamic> command);
  Future<void> limit(String childId, int limit);
  Future<void> decide(String id, bool approve, String reason);
  Future<void> reconcile(String childId);
}

final economyRepositoryProvider = Provider<EconomyRepository>((ref) {
  final tasks = ref.watch(taskRepositoryProvider);
  final client = taskSupabaseClient(tasks);
  final parentFamily = ref.watch(activeParentFamilyProvider);
  ref.watch(parentAuthorizationRevisionProvider);
  if (client == null) throw StateError('请配置 Supabase');
  final repository = SupabaseEconomyRepository(
    client,
    store: tasks is OfflineTaskRepository ? tasks.store : null,
    includeInactive: (family) => parentFamily == family,
    authorizationRevision: () => ref.read(parentAuthorizationRevisionProvider),
  );
  ref.onDispose(repository.dispose);
  return repository;
});
final economyDataProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, ({String childId, String familyId})>((
      ref,
      scope,
    ) {
      ref.listen(taskSyncStateProvider, (_, next) {
        if (next.valueOrNull?.phase == TaskSyncPhase.synced &&
            ref.state.valueOrNull?['offline'] == true) {
          ref.invalidateSelf();
        }
      });
      return ref
          .watch(economyRepositoryProvider)
          .load(scope.childId, scope.familyId);
    });

abstract interface class PagedEconomyRepository implements EconomyRepository {
  Future<EconomyPage> page(
    String childId,
    String familyId,
    String section, {
    Map<String, dynamic>? after,
  });
}

abstract interface class AuditedEconomyRepository implements EconomyRepository {
  Future<WalletAdjustmentDetails> adjustmentDetails(
    String child,
    String family,
    String entryId,
  );
}

class SupabaseEconomyRepository
    implements PagedEconomyRepository, AuditedEconomyRepository {
  SupabaseEconomyRepository(
    this.client, {
    this.store,
    bool Function(String)? includeInactive,
    this.authorizationRevision = _defaultRevision,
  }) : includeInactive = includeInactive ?? ((_) => false);
  final SupabaseClient client;
  final OfflineStore? store;
  final bool Function(String) includeInactive;
  static int _defaultRevision() => 0;
  final int Function() authorizationRevision;
  bool _closed = false;
  late final snapshots = EconomySnapshots(
    accountId: () => client.auth.currentUser?.id,
    isCurrent: () => !_closed,
    store: store,
  );
  void dispose() => _closed = true;
  @override
  Future<WalletAdjustmentDetails> adjustmentDetails(
    String child,
    String family,
    String entryId,
  ) async {
    final owner = client.auth.currentUser?.id,
        privacy = store?.privacyGeneration;
    final revision = authorizationRevision();
    if (owner == null) throw StateError('请先登录');
    Future<void> check() async {
      await _check(owner, child, family, privacy);
      if (!includeInactive(family) || authorizationRevision() != revision) {
        throw StateError('请返回首页重新验证家长PIN');
      }
    }

    await check();
    final data = await client
        .rpc<Map<String, dynamic>>(
          'wallet_adjustment_details',
          params: {'target_child_id': child, 'target_ledger_id': entryId},
        )
        .timeout(const Duration(seconds: 15));
    await check();
    return WalletAdjustmentDetails.fromJson(
      data,
      owner: owner,
      child: child,
      family: family,
      entryId: entryId,
    );
  }

  @override
  Future<void> reconcile(String childId) => snapshots.change(
    () => client.rpc<void>(
      'reconcile_wallet',
      params: {'target_child_id': childId},
    ),
  );
  Future<void> _check(
    String owner,
    String child,
    String family,
    int? privacy,
  ) async {
    void guard() {
      if (_closed ||
          client.auth.currentUser?.id != owner ||
          store?.privacyGeneration != privacy) {
        throw StateError('账号或资料已变化，请重新打开奖励页面');
      }
    }

    guard();
    if (store != null &&
        (await store!.accountDeletionJob(owner) != null ||
            await store!.isChildDeleted(child) ||
            await store!.familyAccessRevoked(
              owner,
              familyId: family,
              childId: child,
            ))) {
      throw StateError('该孩子已不可访问');
    }
    guard();
  }

  @override
  Future<EconomyPage> page(
    String childId,
    String familyId,
    String section, {
    Map<String, dynamic>? after,
  }) async {
    final owner = client.auth.currentUser?.id,
        privacy = store?.privacyGeneration;
    if (owner == null) throw StateError('请先登录');
    if (!const [
      'rewards',
      'redemptions',
      'pending',
      'ledger',
    ].contains(section)) {
      throw ArgumentError('Invalid section');
    }
    final inactive = includeInactive(familyId);
    await _check(owner, childId, familyId, privacy);
    final data = await client
        .rpc<Map<String, dynamic>>(
          'economy_page',
          params: {
            'target_child_id': childId,
            'target_family_id': familyId,
            'section': section,
            'page_size': 50,
            'after_created_at': after?['created_at'],
            'after_id': after?['id'],
            'include_inactive': inactive,
          },
        )
        .timeout(const Duration(seconds: 15));
    await _check(owner, childId, familyId, privacy);
    if (inactive != includeInactive(familyId)) throw StateError('显示范围已变化，请刷新');
    return EconomyPage.fromJson(
      data,
      owner: owner,
      child: childId,
      family: familyId,
      section: section,
      includeInactive: inactive,
      after: after,
    );
  }

  @override
  Future<Map<String, dynamic>> load(String childId, String familyId) async {
    return snapshots.load(
      child: childId,
      family: familyId,
      parent: includeInactive(familyId),
      currentParent: () => includeInactive(familyId),
      checkAccess: (owner, privacy) =>
          _check(owner, childId, familyId, privacy),
      fetch: () => _loadOnline(childId, familyId),
    );
  }

  Future<Map<String, dynamic>> _loadOnline(
    String childId,
    String familyId,
  ) async {
    final owner = client.auth.currentUser?.id,
        privacy = store?.privacyGeneration;
    if (owner == null) throw StateError('请先登录');
    await _check(owner, childId, familyId, privacy);
    final overview = await client
        .rpc<Map<String, dynamic>>(
          'wallet_overview',
          params: {'target_child_id': childId},
        )
        .timeout(const Duration(seconds: 15));
    await _check(owner, childId, familyId, privacy);
    if (overview['child_id'] != childId) throw const FormatException('钱包归属不匹配');
    const sections = ['rewards', 'redemptions', 'pending', 'ledger'];
    Future<({EconomyPage? page, Object? error, StackTrace? stack})> readPage(
      String section,
    ) async {
      try {
        return (
          page: await page(childId, familyId, section),
          error: null,
          stack: null,
        );
      } catch (error, stack) {
        return (page: null, error: error, stack: stack);
      }
    }

    final results = await Future.wait([
      for (final section in sections) readPage(section),
    ]);
    await _check(owner, childId, familyId, privacy);
    // A concurrent permission/format rejection must not be masked by another
    // page's network failure and converted into a successful cache fallback.
    final errors = results.where((result) => result.error != null).toList();
    if (errors.isNotEmpty) {
      final failure = errors.firstWhere(
        (result) => !isNetworkFailure(result.error!),
        orElse: () => errors.first,
      );
      Error.throwWithStackTrace(failure.error!, failure.stack!);
    }
    final pages = [for (final result in results) result.page!];
    if (pages.any((page) => page.familyToday != pages.first.familyToday)) {
      throw const FormatException('家庭日期已变化，请刷新奖励记录');
    }
    if (pages.any(
      (page) => page.familyTimezone != pages.first.familyTimezone,
    )) {
      throw const FormatException('家庭时区已变化，请刷新奖励记录');
    }
    return {
      'fetched_at': pages.first.fetchedAt,
      'family_timezone': pages.first.familyTimezone,
      'overview': overview,
      for (var i = 0; i < sections.length; i++) sections[i]: pages[i].items,
      'cursors': {
        for (var i = 0; i < sections.length; i++)
          sections[i]: pages[i].nextCursor,
      },
      'page_days': {
        for (var i = 0; i < sections.length; i++)
          sections[i]: pages[i].familyToday,
      },
    };
  }

  @override
  Future<void> saveReward(
    String familyId,
    Map<String, dynamic> config, {
    String? rewardId,
  }) => snapshots.change(
    () => client.rpc<void>(
      'save_reward',
      params: {
        'target_family_id': familyId,
        'config': config,
        'target_reward_id': rewardId,
      },
    ),
  );
  @override
  Future<void> request(
    String childId,
    String rewardId,
    String key,
    int version,
  ) => snapshots.change(
    () => client.rpc<void>(
      'request_reward',
      params: {
        'target_child_id': childId,
        'target_reward_id': rewardId,
        'command_id': key,
        'expected_version': version,
      },
    ),
  );
  @override
  Future<void> transition(String id, String operation, String reason) =>
      snapshots.change(
        () => client.rpc<void>(
          'transition_redemption',
          params: {
            'target_redemption_id': id,
            'operation': operation,
            'reason': reason,
          },
        ),
      );
  @override
  Future<void> adjust(String childId, Map<String, dynamic> command) =>
      snapshots.change(
        () => client.rpc<void>(
          'adjust_wallet',
          params: {'target_child_id': childId, ...command},
        ),
      );
  @override
  Future<void> limit(String childId, int limit) => snapshots.change(
    () => client.rpc<void>(
      'set_daily_coin_limit',
      params: {'target_child_id': childId, 'daily_limit': limit},
    ),
  );
  @override
  Future<void> decide(String id, bool approve, String reason) =>
      snapshots.change(
        () => client.rpc<void>(
          'decide_pending_coins',
          params: {'target_award_id': id, 'approve': approve, 'reason': reason},
        ),
      );
}
