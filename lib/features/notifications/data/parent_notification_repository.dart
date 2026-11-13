import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth_family/application/family_providers.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';
import '../../wrong_questions/data/question_media_repository.dart';
import '../../wrong_questions/data/offline_question_media_repository.dart';
import '../domain/parent_notification.dart';

abstract interface class ParentNotificationRepository {
  Future<ParentDelivery> delivery(String familyId);
  Future<void> markDelivered(String familyId, List<String> keys);
  Future<ParentInbox> load(String familyId);
  Future<ParentNotificationSettings> save(
    String familyId,
    ParentNotificationSettings settings,
  );
  Future<void> markRead(String familyId, List<String> keys);
}

class SupabaseParentNotificationRepository
    implements ParentNotificationRepository {
  SupabaseParentNotificationRepository(this.client);
  final SupabaseClient client;
  @override
  Future<ParentDelivery> delivery(String familyId) async {
    final result = ParentDelivery.fromJson(
      await _rpc('parent_notification_delivery', {
        'target_family_id': familyId,
      }),
    );
    if (result.familyId != familyId) throw StateError('提醒所属家庭不匹配');
    return result;
  }

  @override
  Future<void> markDelivered(String familyId, List<String> keys) =>
      _ack(familyId, keys, 'delivered');
  Future<Map<String, dynamic>> _rpc(
    String name,
    Map<String, dynamic> params,
  ) async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('请先登录');
    final result = await client
        .rpc<Map<String, dynamic>>(name, params: params)
        .timeout(const Duration(seconds: 15));
    if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    return result;
  }

  @override
  Future<ParentInbox> load(String familyId) async {
    final result = ParentInbox.fromJson(
      await _rpc('parent_notification_inbox', {'target_family_id': familyId}),
    );
    if (result.familyId != familyId) throw StateError('消息所属家庭不匹配');
    return result;
  }

  @override
  Future<ParentNotificationSettings> save(
    String familyId,
    ParentNotificationSettings settings,
  ) async {
    final config = settings.toConfig();
    final saved = ParentNotificationSettings.fromJson(
      await _rpc('save_parent_notification_settings', {
        'target_family_id': familyId,
        'config': config,
        'expected_version': settings.version,
      }),
    );
    final confirmed = saved.toConfig();
    if (saved.version != settings.version + 1 ||
        !config.keys.every((key) => config[key] == confirmed[key])) {
      throw StateError('通知设置回执不匹配，请刷新核对');
    }
    return saved;
  }

  @override
  Future<void> markRead(String familyId, List<String> keys) async {
    await _ack(familyId, keys, 'read');
  }

  Future<void> _ack(
    String familyId,
    List<String> keys,
    String operation,
  ) async {
    final frozen = List<String>.unmodifiable(keys);
    if (frozen.isEmpty ||
        frozen.length > 200 ||
        frozen.toSet().length != frozen.length) {
      throw const FormatException('请选择1至200条不同消息');
    }
    final result = await _rpc('ack_parent_notifications', {
      'target_family_id': familyId,
      'keys': frozen,
      'operation': operation,
    });
    final saved = result['keys'];
    if (result['operation'] != operation ||
        saved is! List ||
        saved.length != frozen.length ||
        saved.toSet().length != frozen.length ||
        !saved.every(frozen.contains)) {
      throw StateError('消息已读回执不匹配，请刷新核对');
    }
  }
}

final parentNotificationRepositoryProvider =
    Provider<ParentNotificationRepository>((ref) {
      final client = taskSupabaseClient(ref.watch(taskRepositoryProvider));
      if (client == null) throw StateError('请配置 Supabase');
      return SupabaseParentNotificationRepository(client);
    });
final parentInboxProvider = FutureProvider.autoDispose
    .family<ParentInbox, String>((ref, family) {
      if (ref.watch(activeParentFamilyProvider) != family) {
        throw StateError('请验证家长 PIN');
      }
      return ref.watch(parentNotificationRepositoryProvider).load(family);
    });

final parentSyncIssuesProvider = FutureProvider.autoDispose
    .family<List<ParentSyncIssue>, String>((ref, family) async {
      if (ref.watch(activeParentFamilyProvider) != family) {
        throw StateError('请验证家长 PIN');
      }
      ref.watch(taskSyncStateProvider);
      final tasks = ref.watch(taskRepositoryProvider);
      if (tasks is! OfflineTaskRepository) return [];
      ref.watch(imageDraftChangesProvider);
      final media = ref.watch(questionMediaRepositoryProvider);
      final owner = tasks.accountId(),
          generation = tasks.store.privacyGeneration;
      final families = await ref.watch(familiesProvider.future);
      final children = families
          .where((f) => f.id == family)
          .expand((f) => f.children);
      final result = <ParentSyncIssue>[];
      for (final child in children) {
        final diagnostic = await tasks.diagnostics(child.id);
        final drafts = media is OfflineQuestionMediaRepository
            ? await media.drafts(child.id, family)
            : <Map<String, dynamic>>[];
        final issue = ParentSyncIssue(
          child.id,
          taskFailures: diagnostic.groups
              .expand((g) => g.operations)
              .where((o) => o.attempts > 0 && !o.conflict)
              .length,
          conflicts: diagnostic.conflicts,
          images: drafts
              .where(
                (d) => const {
                  'retry',
                  'blocked',
                  'needs_authorization',
                }.contains(d['stage']),
              )
              .length,
        );
        if (issue.needsAttention) result.add(issue);
      }
      if (tasks.accountId() != owner ||
          tasks.store.privacyGeneration != generation) {
        throw StateError('账号或本机资料已变化');
      }
      return result;
    });
