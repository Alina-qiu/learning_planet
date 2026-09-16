import 'task.dart';

class TaskTimingState {
  const TaskTimingState({
    required this.status,
    this.activeStartedAt,
    this.accumulated = Duration.zero,
  });

  final TaskStatus status;
  final DateTime? activeStartedAt;
  final Duration accumulated;

  Duration elapsedAt(DateTime now) {
    if (status != TaskStatus.inProgress || activeStartedAt == null) {
      return accumulated;
    }
    return accumulated + now.difference(activeStartedAt!);
  }
}

class TaskStateMachine {
  const TaskStateMachine();

  TaskTimingState start(TaskTimingState state, DateTime now) {
    if (state.status != TaskStatus.ready &&
        state.status != TaskStatus.scheduled) {
      throw StateError('Only a ready task can be started.');
    }
    return TaskTimingState(
      status: TaskStatus.inProgress,
      activeStartedAt: now,
      accumulated: state.accumulated,
    );
  }

  TaskTimingState pause(TaskTimingState state, DateTime now) {
    if (state.status != TaskStatus.inProgress ||
        state.activeStartedAt == null) {
      throw StateError('Only an active task can be paused.');
    }
    return TaskTimingState(
      status: TaskStatus.paused,
      accumulated: state.elapsedAt(now),
    );
  }

  TaskTimingState resume(TaskTimingState state, DateTime now) {
    if (state.status != TaskStatus.paused) {
      throw StateError('Only a paused task can be resumed.');
    }
    return TaskTimingState(
      status: TaskStatus.inProgress,
      activeStartedAt: now,
      accumulated: state.accumulated,
    );
  }

  TaskTimingState complete(TaskTimingState state, DateTime now) {
    if (state.status != TaskStatus.inProgress &&
        state.status != TaskStatus.paused) {
      throw StateError('Only a started task can be completed.');
    }
    return TaskTimingState(
      status: TaskStatus.completed,
      accumulated: state.elapsedAt(now),
    );
  }
}
