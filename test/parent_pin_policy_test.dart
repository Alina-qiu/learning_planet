import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/features/auth_family/domain/parent_pin_policy.dart';

void main() {
  const policy = ParentPinPolicy();
  final now = DateTime.utc(2026, 9, 16, 8);

  test('前四次失败只累计次数', () {
    var state = const ParentPinAttemptState();

    for (var attempt = 1; attempt <= 4; attempt++) {
      state = policy.registerFailure(state, now);
      expect(state.failedAttempts, attempt);
      expect(state.lockedUntil, isNull);
    }
  });

  test('第五次失败锁定十分钟', () {
    var state = const ParentPinAttemptState(failedAttempts: 4);

    state = policy.registerFailure(state, now);

    expect(state.failedAttempts, 5);
    expect(state.lockedUntil, now.add(const Duration(minutes: 10)));
    expect(state.isLockedAt(now.add(const Duration(minutes: 9))), isTrue);
    expect(state.isLockedAt(now.add(const Duration(minutes: 10))), isFalse);
  });

  test('锁定期间的失败不会延长锁定时间', () {
    final locked = ParentPinAttemptState(
      failedAttempts: 5,
      lockedUntil: now.add(const Duration(minutes: 10)),
    );

    final result = policy.registerFailure(
      locked,
      now.add(const Duration(minutes: 5)),
    );

    expect(result.failedAttempts, locked.failedAttempts);
    expect(result.lockedUntil, locked.lockedUntil);
  });

  test('锁定到期后重新开始计数，成功后清零', () {
    final expired = ParentPinAttemptState(
      failedAttempts: 5,
      lockedUntil: now.subtract(const Duration(seconds: 1)),
    );

    final retried = policy.registerFailure(expired, now);
    final cleared = policy.registerSuccess();

    expect(retried.failedAttempts, 1);
    expect(retried.lockedUntil, isNull);
    expect(cleared.failedAttempts, 0);
    expect(cleared.lockedUntil, isNull);
  });
}
