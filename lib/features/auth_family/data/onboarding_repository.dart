import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';
import '../../tasks/domain/schedule_config.dart';

abstract interface class OnboardingRepository {
  Future<Map<String, dynamic>> load(String childId);
  Future<void> configure(
    String childId,
    String preset,
    int dailyLimit,
    List<String> rewards,
  );
  Future<void> advance(String childId, int step, String? selection);
  Future<void> firstTask(String childId, ScheduleConfig config);
  Future<void> finish(String childId);
}

final onboardingRepositoryProvider = Provider<OnboardingRepository>((ref) {
  final client = taskSupabaseClient(ref.watch(taskRepositoryProvider));
  if (client == null) throw StateError('请配置 Supabase');
  return SupabaseOnboardingRepository(client);
});
final onboardingProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>(
      (ref, id) => ref.watch(onboardingRepositoryProvider).load(id),
    );

class SupabaseOnboardingRepository implements OnboardingRepository {
  SupabaseOnboardingRepository(this.client);
  final SupabaseClient client;
  @override
  Future<Map<String, dynamic>> load(String childId) async {
    final owner = client.auth.currentUser?.id;
    final data = await client
        .rpc<Map<String, dynamic>>(
          'onboarding_overview',
          params: {'target_child_id': childId},
        )
        .timeout(const Duration(seconds: 15));
    if (owner == null || client.auth.currentUser?.id != owner) {
      throw StateError('登录账号已变化');
    }
    return data;
  }

  @override
  Future<void> configure(
    String childId,
    String preset,
    int dailyLimit,
    List<String> rewards,
  ) => client
      .rpc<void>(
        'configure_starter_rules',
        params: {
          'target_child_id': childId,
          'preset': preset,
          'daily_limit': dailyLimit,
          'reward_keys': rewards,
        },
      )
      .timeout(const Duration(seconds: 15));
  @override
  Future<void> advance(String childId, int step, String? selection) => client
      .rpc<void>(
        'advance_child_guide',
        params: {
          'target_child_id': childId,
          'expected_step': step,
          'selection': selection,
        },
      )
      .timeout(const Duration(seconds: 15));
  @override
  Future<void> firstTask(String childId, ScheduleConfig config) => client
      .rpc<void>(
        'create_starter_task',
        params: {'target_child_id': childId, 'config': config.toJson()},
      )
      .timeout(const Duration(seconds: 15));
  @override
  Future<void> finish(String childId) => client
      .rpc<void>('finish_onboarding', params: {'target_child_id': childId})
      .timeout(const Duration(seconds: 15));
}
