enum TaskSyncPhase { synced, syncing, offline, conflict }

class TaskSyncState {
  const TaskSyncState({
    this.phase = TaskSyncPhase.synced,
    this.pending = 0,
    this.conflicts = const [],
    this.message,
    this.revision = 0,
    int? dataRevision,
    this.pendingTaskIds = const {},
  }) : dataRevision = dataRevision ?? revision;
  final TaskSyncPhase phase;
  final int pending;
  final List<Map<String, dynamic>> conflicts;
  final String? message;
  final int revision;

  /// Advances on possible cache, queue, access or error changes.
  final int dataRevision;
  final Set<String> pendingTaskIds;
}
