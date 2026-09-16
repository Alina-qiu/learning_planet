import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/task_repository.dart';
import '../domain/task_item.dart';

final taskRepositoryProvider = Provider<TaskRepository>(
  (ref) => throw UnimplementedError('TaskRepository must be overridden.'),
);

final tasksProvider = FutureProvider.family<List<TaskItem>, String>(
  (ref, childId) => ref.watch(taskRepositoryProvider).loadTasks(childId),
);
