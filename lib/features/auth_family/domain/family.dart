class ChildProfile {
  const ChildProfile({
    required this.id,
    required this.familyId,
    required this.nickname,
    required this.grade,
  });

  final String id;
  final String familyId;
  final String nickname;
  final int grade;
}

class Family {
  const Family({
    required this.id,
    required this.name,
    required this.timezone,
    required this.children,
  });

  final String id;
  final String name;
  final String timezone;
  final List<ChildProfile> children;
}

class ParentPinVerification {
  const ParentPinVerification({
    required this.verified,
    required this.remainingAttempts,
    this.retryAt,
  });

  final bool verified;
  final int remainingAttempts;
  final DateTime? retryAt;
}
