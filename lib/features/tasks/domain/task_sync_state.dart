enum TaskSyncPhase { synced, syncing, offline, conflict }

class TaskSyncState {
  const TaskSyncState({
    this.phase = TaskSyncPhase.synced,
    this.pending = 0,
    this.conflicts = const [],
    this.message,
    this.revision = 0,
    this.pendingTaskIds = const {},
  });
  final TaskSyncPhase phase;
  final int pending;
  final List<Map<String, dynamic>> conflicts;
  final String? message;
  final int revision;
  final Set<String> pendingTaskIds;
}
