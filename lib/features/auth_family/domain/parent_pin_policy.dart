class ParentPinAttemptState {
  const ParentPinAttemptState({
    this.failedAttempts = 0,
    this.lockedUntil,
  });

  final int failedAttempts;
  final DateTime? lockedUntil;

  bool isLockedAt(DateTime now) => lockedUntil?.isAfter(now) ?? false;
}

class ParentPinPolicy {
  const ParentPinPolicy({
    this.maximumAttempts = 5,
    this.lockDuration = const Duration(minutes: 10),
  }) : assert(maximumAttempts > 0);

  final int maximumAttempts;
  final Duration lockDuration;

  ParentPinAttemptState registerFailure(
    ParentPinAttemptState state,
    DateTime now,
  ) {
    if (state.isLockedAt(now)) return state;

    final previousAttempts =
        state.lockedUntil == null ? state.failedAttempts : 0;
    final failedAttempts = previousAttempts + 1;
    if (failedAttempts >= maximumAttempts) {
      return ParentPinAttemptState(
        failedAttempts: maximumAttempts,
        lockedUntil: now.add(lockDuration),
      );
    }

    return ParentPinAttemptState(failedAttempts: failedAttempts);
  }

  ParentPinAttemptState registerSuccess() => const ParentPinAttemptState();
}
