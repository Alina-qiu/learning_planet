import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/task_repository.dart';
import '../domain/task_item.dart';
import '../domain/wallet_summary.dart';

final familyTodayProvider = FutureProvider.family<DateTime, String>((
  ref,
  childId,
) async {
  final repository = ref.watch(taskRepositoryProvider);
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

final walletProvider = FutureProvider.family<WalletSummary, String>(
  (ref, childId) => ref.watch(taskRepositoryProvider).loadWallet(childId),
);

final taskRepositoryProvider = Provider<TaskRepository>(
  (ref) => throw UnimplementedError('TaskRepository must be overridden.'),
);

final tasksProvider = FutureProvider.family<List<TaskItem>, String>(
  (ref, childId) => ref.watch(taskRepositoryProvider).loadTasks(childId),
);
