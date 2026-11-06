class ChildProfile {
  const ChildProfile({
    required this.id,
    required this.familyId,
    required this.nickname,
    required this.grade,
    this.textbookLabels = const {},
    this.avatarKey = 'star',
    this.profileVersion = 0,
    this.guideStep = 0,
    this.starterTaskPreset = 'study20',
    this.starterRulesAt,
    this.onboardingCompletedAt,
  });

  final String id;
  final String familyId;
  final String nickname;
  final int grade;
  final Map<String, String> textbookLabels;
  final String avatarKey, starterTaskPreset;
  final int profileVersion, guideStep;
  final DateTime? starterRulesAt, onboardingCompletedAt;
  factory ChildProfile.fromJson(Map<String, dynamic> value) => ChildProfile(
    id: value['id'] as String,
    familyId: value['family_id'] as String,
    nickname: value['nickname'] as String,
    grade: value['grade'] as int,
    textbookLabels: (value['textbook_labels'] as Map? ?? {})
        .cast<String, String>(),
    avatarKey: value['avatar_key'] as String? ?? 'star',
    profileVersion: (value['profile_version'] as num?)?.toInt() ?? 0,
    guideStep: (value['guide_step'] as num?)?.toInt() ?? 0,
    starterTaskPreset: value['starter_task_preset'] as String? ?? 'study20',
    starterRulesAt: value['starter_rules_at'] == null
        ? null
        : DateTime.parse(value['starter_rules_at'] as String),
    onboardingCompletedAt: value['onboarding_completed_at'] == null
        ? null
        : DateTime.parse(value['onboarding_completed_at'] as String),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'family_id': familyId,
    'nickname': nickname,
    'grade': grade,
    'textbook_labels': textbookLabels,
    'avatar_key': avatarKey,
    'profile_version': profileVersion,
    'guide_step': guideStep,
    'starter_task_preset': starterTaskPreset,
    'starter_rules_at': starterRulesAt?.toIso8601String(),
    'onboarding_completed_at': onboardingCompletedAt?.toIso8601String(),
  };
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
    this.authorizedUntil,
  });

  final bool verified;
  final int remainingAttempts;
  final DateTime? retryAt;
  final DateTime? authorizedUntil;
}
