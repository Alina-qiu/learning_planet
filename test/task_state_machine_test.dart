import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/features/tasks/domain/task.dart';
import 'package:learning_planet/features/tasks/domain/task_state_machine.dart';

void main() {
  const machine = TaskStateMachine();
  final startAt = DateTime.utc(2026, 9, 16, 8);

  test('开始、暂停、继续和完成会累计实际时长', () {
    var state = const TaskTimingState(status: TaskStatus.ready);
    state = machine.start(state, startAt);
    state = machine.pause(state, startAt.add(const Duration(minutes: 12)));
    expect(state.accumulated, const Duration(minutes: 12));

    state = machine.resume(state, startAt.add(const Duration(minutes: 20)));
    state = machine.complete(state, startAt.add(const Duration(minutes: 28)));

    expect(state.status, TaskStatus.completed);
    expect(state.accumulated, const Duration(minutes: 20));
  });

  test('非法状态转换会被拒绝', () {
    const ready = TaskTimingState(status: TaskStatus.ready);
    const completed = TaskTimingState(status: TaskStatus.completed);

    expect(() => machine.pause(ready, startAt), throwsStateError);
    expect(() => machine.resume(ready, startAt), throwsStateError);
    expect(() => machine.start(completed, startAt), throwsStateError);
  });
}
