import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/offline/offline_media_store.dart';
import '../../../core/offline/network_failure.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';
import '../../tasks/data/notification_scheduler.dart';
import 'parent_notification_repository.dart';
import 'remote_parent_push.dart';
import '../domain/parent_notification.dart';
import '../domain/offline_notification_policy.dart';

final parentNotificationDeviceProvider = Provider<ParentNotificationDevice?>((
  ref,
) {
  final tasks = ref.watch(taskRepositoryProvider);
  return tasks is OfflineTaskRepository
      ? ParentNotificationDevice(
          tasks,
          ref.watch(parentNotificationRepositoryProvider),
          ref.watch(notificationSchedulerProvider),
          remotePush: ref.watch(remoteParentPushProvider),
        )
      : null;
});
final parentNotificationDeviceRevisionProvider = StateProvider<int>((_) => 0);
final parentNotificationDeviceModeProvider = FutureProvider.autoDispose
    .family<bool, String>((ref, family) {
      ref.watch(parentNotificationDeviceRevisionProvider);
      return ref
              .watch(parentNotificationDeviceProvider)
              ?.isParentMode(family) ??
          Future.value(false);
    });

/// Foreground delivery only. Device mode and retry suppression use the same
/// encrypted, account-scoped store as business queues, in independent cache rows.
class ParentNotificationDevice {
  ParentNotificationDevice(
    this.tasks,
    this.repository,
    this.scheduler, {
    DateTime Function()? clock,
    this.remotePush,
  }) : clock = clock ?? DateTime.now;
  final OfflineTaskRepository tasks;
  final ParentNotificationRepository repository;
  final NotificationScheduler scheduler;
  final DateTime Function() clock;
  final RemoteParentPush? remotePush;
  int _generation = 0;
  final _changing = <String>{};
  String _modeKey(String family) => 'parent-notification-mode:$family';
  String _seenKey(String family) => 'parent-notification-seen:$family';
  String _policyKey(String family) => 'parent-notification-policy:$family';
  bool _current(String? owner, int generation, int privacy) =>
      owner != null &&
      tasks.accountId() == owner &&
      generation == _generation &&
      privacy == tasks.store.privacyGeneration;
  Future<bool> isParentMode(String family) async {
    final owner = tasks.accountId(),
        generation = _generation,
        privacy = tasks.store.privacyGeneration;
    if (owner == null) return false;
    final value = await tasks.store.read(owner, _modeKey(family));
    if (!_current(owner, generation, privacy)) throw StateError('提醒范围已变化');
    return value?['enabled'] == true;
  }

  Future<bool> setParentMode(
    String family,
    bool enabled, {
    bool Function()? canConfigure,
  }) async {
    final owner = tasks.accountId(),
        generation = ++_generation,
        privacy = tasks.store.privacyGeneration;
    if (owner == null) throw StateError('请先登录');
    if (canConfigure != null && !canConfigure()) {
      throw StateError('请重新验证家长 PIN');
    }
    if (enabled &&
        (scheduler is! ParentMessageScheduler ||
            !await scheduler.requestPermission())) {
      return false;
    }
    if (!_current(owner, generation, privacy)) throw StateError('提醒范围已变化');
    if (canConfigure != null && !canConfigure()) {
      throw StateError('请重新验证家长 PIN');
    }
    await scheduler.setScope(null);
    if (!_current(owner, generation, privacy)) throw StateError('提醒范围已变化');
    await tasks.store.transaction(() async {
      if (!_current(owner, generation, privacy)) throw StateError('提醒范围已变化');
      if (canConfigure != null && !canConfigure()) {
        throw StateError('请重新验证家长 PIN');
      }
      await tasks.store.write(owner, _modeKey(family), {'enabled': enabled});
      await tasks.store.remove(owner, _policyKey(family));
      if (!_current(owner, generation, privacy) ||
          (canConfigure != null && !canConfigure())) {
        throw StateError('提醒授权已变化');
      }
    });
    return true;
  }

  /// Remove the old policy before changing preferences, including when the save
  /// response is lost. A timer cannot re-cache pre-save settings in the meantime.
  Future<ParentNotificationSettings> saveSettings(
    String family,
    ParentNotificationSettings settings, {
    required bool Function() canConfigure,
  }) async {
    if (_changing.contains(family)) throw StateError('通知设置正在保存');
    final owner = tasks.accountId(),
        generation = ++_generation,
        privacy = tasks.store.privacyGeneration;
    if (owner == null || !canConfigure()) throw StateError('请验证家长 PIN');
    _changing.add(family);
    try {
      final parentMode = await isParentMode(family);
      final hadRemote =
          remotePush != null &&
          await remotePush!.status(family) == RemotePushStatus.enabled;
      await tasks.store.transaction(() async {
        if (!_current(owner, generation, privacy) || !canConfigure()) {
          throw StateError('提醒授权已变化');
        }
        await tasks.store.remove(owner, _policyKey(family));
      });
      if (!_current(owner, generation, privacy) || !canConfigure()) {
        throw StateError('提醒授权已变化');
      }
      if (parentMode) await scheduler.setScope(null);
      if (!_current(owner, generation, privacy) || !canConfigure()) {
        throw StateError('提醒授权已变化');
      }
      final saved = await repository.save(family, settings);
      if (!_current(owner, generation, privacy) || !canConfigure()) {
        throw StateError('提醒授权已变化');
      }
      if (hadRemote && parentMode && saved.enabled) {
        await remotePush!.enable(
          family,
          saved,
          canConfigure: () =>
              _current(owner, generation, privacy) && canConfigure(),
        );
      }
      return saved;
    } finally {
      _generation++;
      _changing.remove(family);
    }
  }

  /// Timezone changes affect child alarms and parent quiet hours together.
  /// Stop native delivery before mutation; old in-flight reads are fenced.
  Future<T> changeFamilyTimezone<T>(
    String family,
    Future<T> Function() action, {
    required bool Function() canConfigure,
  }) async {
    if (_changing.contains(family)) throw StateError('提醒设置正在保存');
    final owner = tasks.accountId(),
        generation = ++_generation,
        privacy = tasks.store.privacyGeneration;
    void check() {
      if (!_current(owner, generation, privacy) || !canConfigure()) {
        throw StateError('提醒授权已变化');
      }
    }

    check();
    _changing.add(family);
    try {
      final parentMode = await isParentMode(family);
      final hadRemote =
          remotePush != null &&
          await remotePush!.status(family) == RemotePushStatus.enabled;
      check();
      await tasks.store.remove(owner!, _policyKey(family));
      check();
      await scheduler.setScope(null);
      check();
      if (hadRemote) {
        await remotePush!.disableFamilyAccess(owner, family);
        check();
      }
      final result = await action();
      check();
      if (hadRemote && parentMode) {
        final settings = (await repository.load(family)).settings;
        check();
        if (settings.enabled) {
          await remotePush!.enable(
            family,
            settings,
            canConfigure: () =>
                _current(owner, generation, privacy) && canConfigure(),
          );
          check();
        }
      }
      return result;
    } finally {
      _generation++;
      _changing.remove(family);
    }
  }

  Future<CachedNotificationPolicy?> _rememberPolicy(
    String owner,
    String family,
    ParentDelivery delivery,
    DateTime started,
    DateTime received,
    bool Function() current,
  ) async {
    CachedNotificationPolicy? cached;
    if (delivery.offlinePolicy case final raw?) {
      final policy = OfflineNotificationPolicy.fromJson(raw);
      final config = delivery.settings.toConfig(),
          confirmed = policy.settings.toConfig();
      if (policy.familyId != family ||
          policy.settings.version != delivery.settings.version ||
          !config.keys.every((k) => config[k] == confirmed[k])) {
        throw const FormatException('离线提醒范围不匹配');
      }
      cached = CachedNotificationPolicy(
        policy: policy,
        requestStartedAt: started,
        receivedAt: received,
      );
      for (final id in policy.childIds) {
        if (await tasks.store.isChildDeleted(id)) {
          cached = null;
          break;
        }
      }
    }
    await tasks.store.transaction(() async {
      if (!current()) return;
      if (cached == null) {
        await tasks.store.remove(owner, _policyKey(family));
      } else {
        await tasks.store.write(owner, _policyKey(family), cached.toJson());
      }
      if (!current()) throw StateError('提醒范围已变化');
    });
    return cached;
  }

  Future<CachedNotificationPolicy?> _offlinePolicy(
    String owner,
    String family,
    DateTime now,
    bool Function() current,
  ) async {
    return tasks.store.transaction(() async {
      if (!current()) return null;
      final row = await tasks.store.read(owner, _policyKey(family));
      if (row == null) return null;
      CachedNotificationPolicy? result;
      try {
        final parsed = CachedNotificationPolicy.fromJson(row);
        if (parsed.policy.familyId == family && parsed.validAt(now)) {
          result = parsed;
        }
      } catch (_) {
        /* A corrupt or unsupported policy cannot authorize notices. */
      }
      if (!current()) return null;
      if (result == null) {
        await tasks.store.remove(owner, _policyKey(family));
      } else {
        await tasks.store.write(
          owner,
          _policyKey(family),
          result.toJson(observed: now),
        );
      }
      if (!current()) throw StateError('提醒范围已变化');
      return result == null
          ? null
          : CachedNotificationPolicy(
              policy: result.policy,
              requestStartedAt: result.requestStartedAt,
              receivedAt: result.receivedAt,
              observedAt: now,
            );
    });
  }

  Future<bool> refresh(
    String family,
    String child, {
    required bool Function() isCurrent,
  }) async {
    final owner = tasks.accountId(),
        generation = _generation,
        privacy = tasks.store.privacyGeneration;
    bool current() => _current(owner, generation, privacy) && isCurrent();
    if (_changing.contains(family)) return true;
    if (!await isParentMode(family)) return false;
    if (_changing.contains(family)) return true;
    if (!current()) return true;
    final scope = 'parent:$owner:$family';
    await scheduler.setScope(scope);
    if (!current()) return true;
    ParentDelivery? delivery;
    CachedNotificationPolicy? cached;
    final started = clock().toUtc();
    try {
      delivery = await repository.delivery(family);
      if (!current()) return true;
      cached = await _rememberPolicy(
        owner!,
        family,
        delivery,
        started,
        clock().toUtc(),
        current,
      );
    } catch (error) {
      if (!current()) return true;
      if (!isNetworkFailure(error)) {
        await tasks.store.remove(owner!, _policyKey(family));
        if (current()) await scheduler.setScope(null);
        rethrow;
      }
      delivery = null;
      cached = await _offlinePolicy(owner!, family, clock().toUtc(), current);
      if (cached == null) rethrow;
    }
    if (!current()) return true;
    final now = clock().toUtc();
    final settings = delivery?.settings ?? cached!.policy.settings;
    if (!settings.enabled) {
      await scheduler.setScope(null);
      return true;
    }
    if (delivery != null && current()) {
      await remotePush?.refresh(family, settings);
      if (!current()) return true;
    }
    if (scheduler is! ParentMessageScheduler || delivery?.quiet == true) {
      return true;
    }
    if (delivery == null && !cached!.allowsSync(family, child, now)) {
      return true;
    }
    if (cached != null &&
        (!cached.validAt(now) ||
            cached.policy.quietAt(cached.earliestAt(now)) ||
            cached.policy.quietAt(cached.latestAt(now)))) {
      return true;
    }
    final saved = await tasks.store.read(owner, _seenKey(family));
    final seen = ((saved?['keys'] as List?) ?? []).whereType<String>().toSet();
    final selected = <ParentMessage>[];
    final deletionChecks = <String, Future<bool>>{};
    for (final message in delivery?.items ?? const <ParentMessage>[]) {
      final enabled = message.kind.name == 'redemption'
          ? settings.redemptions
          : settings.weeklyReports;
      if (enabled &&
          !await deletionChecks.putIfAbsent(
            message.childId,
            () => tasks.store.isChildDeleted(message.childId),
          )) {
        selected.add(message);
      }
    }
    final kinds = selected
        .where((m) => !seen.contains(m.key))
        .map((m) => m.kind.name)
        .toSet();
    String? syncKey;
    if (settings.syncErrors &&
        (cached == null || cached.policy.childIds.contains(child)) &&
        !await tasks.store.isChildDeleted(child)) {
      final diagnostics = await tasks.diagnostics(child);
      final drafts = await tasks.store.imageDrafts(owner, childId: child);
      if (diagnostics.conflicts > 0 ||
          diagnostics.groups.any(
            (g) => g.operations.any((o) => o.attempts > 0),
          ) ||
          drafts.any(
            (d) => const {
              'retry',
              'blocked',
              'needs_authorization',
            }.contains(d['stage']),
          )) {
        final trustedNow = cached?.latestAt(now) ?? now;
        syncKey =
            'sync:$child:${trustedNow.toIso8601String().substring(0, 10)}';
        if (!seen.contains(syncKey)) kinds.add('sync');
      }
    }
    if (!current()) return true;
    if (kinds.isNotEmpty &&
        !await (scheduler as ParentMessageScheduler).showParentMessages(
          scope,
          kinds,
        )) {
      return true;
    }
    if (!current()) return true;
    final keys = selected.map((m) => m.key).toList();
    seen.addAll(keys);
    if (syncKey != null) seen.add(syncKey);
    await tasks.store.transaction(() async {
      if (!current()) return;
      final bounded = seen.toList();
      await tasks.store.write(owner, _seenKey(family), {
        'keys': bounded
            .skip(bounded.length > 1000 ? bounded.length - 1000 : 0)
            .toList(),
      });
      if (!current()) throw StateError('提醒范围已变化');
    });
    for (var start = 0; start < keys.length; start += 200) {
      if (!current()) return true;
      await repository.markDelivered(
        family,
        keys.sublist(
          start,
          start + 200 < keys.length ? start + 200 : keys.length,
        ),
      );
    }
    return true;
  }
}
