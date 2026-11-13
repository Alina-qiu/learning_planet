import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';
import '../../../core/offline/offline_store.dart';
import 'growth_snapshots.dart';

abstract interface class GrowthRepository {
  Future<Map<String, dynamic>> load(String childId);
  Future<void> equip(String childId, String slot, String? selection);
  Future<void> challenge(
    String childId,
    String commandId,
    String title,
    int minimumSeconds,
  );
  Future<void> award(
    String childId,
    String commandId,
    Map<String, dynamic> config,
  );
  Future<List<Map<String, dynamic>>> history(String childId);
}

final growthRepositoryProvider = Provider<GrowthRepository>((ref) {
  final tasks = ref.watch(taskRepositoryProvider);
  final client = taskSupabaseClient(tasks);
  if (client == null) throw StateError('请配置 Supabase');
  final repository = SupabaseGrowthRepository(
    client,
    store: tasks is OfflineTaskRepository ? tasks.store : null,
  );
  ref.onDispose(repository.snapshots.dispose);
  return repository;
});
final growthProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, childId) {
      // Task completion, offline synchronization and parent awards invalidate wallet.
      ref.watch(walletProvider(childId));
      return ref.watch(growthRepositoryProvider).load(childId);
    });
final learningEventsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, childId) {
      return ref.watch(growthRepositoryProvider).history(childId);
    });

class SupabaseGrowthRepository implements GrowthRepository {
  SupabaseGrowthRepository(
    this.client, {
    OfflineStore? store,
    String? Function()? accountId,
  }) : snapshots = GrowthSnapshots(client, store: store, accountId: accountId);
  final SupabaseClient client;
  final GrowthSnapshots snapshots;
  @override
  Future<Map<String, dynamic>> load(String childId) => snapshots.load(childId);

  @override
  Future<void> equip(String childId, String slot, String? selection) =>
      snapshots.change(
        childId,
        () => client
            .rpc<void>(
              'set_growth_slot',
              params: {
                'target_child_id': childId,
                'slot': slot,
                'selection': selection,
              },
            )
            .timeout(const Duration(seconds: 15)),
      );
  @override
  Future<void> challenge(
    String childId,
    String commandId,
    String title,
    int minimumSeconds,
  ) => client
      .rpc<void>(
        'create_daily_challenge',
        params: {
          'target_child_id': childId,
          'command_id': commandId,
          'title': title,
          'minimum_seconds': minimumSeconds,
        },
      )
      .timeout(const Duration(seconds: 15));
  @override
  Future<void> award(
    String childId,
    String commandId,
    Map<String, dynamic> config,
  ) => snapshots.change(
    childId,
    () => client
        .rpc<void>(
          'award_learning_event',
          params: {
            'target_child_id': childId,
            'command_id': commandId,
            'config': config,
          },
        )
        .timeout(const Duration(seconds: 15)),
  );
  @override
  Future<List<Map<String, dynamic>>> history(String childId) async {
    final owner = client.auth.currentUser?.id;
    final result = await client
        .from('learning_events')
        .select('id,kind,event_date,reference,coin_reward,xp_reward,payload')
        .eq('child_id', childId)
        .order('created_at', ascending: false)
        .order('id')
        .limit(50)
        .timeout(const Duration(seconds: 15));
    if (owner == null || client.auth.currentUser?.id != owner) {
      throw StateError('登录账号已变化');
    }
    return result;
  }
}
