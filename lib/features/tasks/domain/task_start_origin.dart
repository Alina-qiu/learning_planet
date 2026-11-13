enum TaskStartOrigin {
  unknown('unknown'),
  childMode('child_mode'),
  parentAssisted('parent_assisted');

  const TaskStartOrigin(this.wire);
  final String wire;

  static TaskStartOrigin forMode({
    required String? familyId,
    required bool parentMode,
    required String? parentFamilyId,
  }) {
    if (familyId == null || familyId.isEmpty) return unknown;
    if (!parentMode) return childMode;
    return parentFamilyId == familyId ? parentAssisted : unknown;
  }
}

/// Captures the UI mode at the initial action; it does not grant permissions.
abstract interface class AttributedTaskStarter {
  Future<void> startWithOrigin(String taskId, TaskStartOrigin origin);
}
