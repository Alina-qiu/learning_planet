import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/task_repository.dart';
import '../data/offline_task_repository.dart';
import '../domain/task_sync_state.dart';
import '../domain/task_item.dart';
import '../domain/wallet_summary.dart';

final taskFamilyTimezoneProvider = FutureProvider.family<String?, String>((
  ref,
  child,
) {
  ref.watch(taskSyncStateProvider);
  final repository = ref.watch(taskRepositoryProvider);
  return repository is OfflineTaskRepository
      ? repository.cachedFamilyTimezone(child)
      : null;
});

final familyTodayProvider = FutureProvider.family<DateTime, String>((
  ref,
  childId,
) async {
  final repository = ref.watch(taskRepositoryProvider);
  if (repository is OfflineTaskRepository) {
    ref.watch(taskSyncStateProvider);
    return repository.today(childId);
  }
  if (repository is SupabaseTaskRepository) {
    return DateTime.parse(
      await repository.client.rpc<String>(
        'family_today',
        params: {'target_child_id': childId},
      ),
    );
  }
  return DateTime.now();
});

final walletProvider = FutureProvider.family<WalletSummary, String>((
  ref,
  childId,
) {
  ref.watch(taskSyncStateProvider);
  return ref.watch(taskRepositoryProvider).loadWallet(childId);
});

final taskRepositoryProvider = Provider<TaskRepository>(
  (ref) => throw UnimplementedError('TaskRepository must be overridden.'),
);

final tasksProvider = FutureProvider.family<List<TaskItem>, String>((
  ref,
  childId,
) {
  ref.watch(taskSyncStateProvider);
  return ref.watch(taskRepositoryProvider).loadTasks(childId);
});

final taskSyncStateProvider = StreamProvider<TaskSyncState>((ref) async* {
  final repository = ref.watch(taskRepositoryProvider);
  if (repository is OfflineTaskRepository) {
    yield repository.state;
    yield* repository.changes;
  } else {
    yield const TaskSyncState();
  }
});

final remotelyDeletedChildProvider = StreamProvider<String>((ref) {
  final repository = ref.watch(taskRepositoryProvider);
  return repository is OfflineTaskRepository
      ? repository.remoteDeletions
      : const Stream<String>.empty();
});
