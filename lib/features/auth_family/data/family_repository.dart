import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/family.dart';

abstract interface class FamilyRepository {
  Future<void> revokeParentAuthorization();
  Future<List<Family>> loadFamilies();

  Future<void> createFamilyWithChild({
    required String familyName,
    required String timezone,
    required String childNickname,
    required int grade,
    Map<String, String> textbookLabels = const {},
    String avatarKey = 'star',
  });

  Future<void> createChild({
    required String familyId,
    required String nickname,
    required int grade,
    Map<String, String> textbookLabels = const {},
    String avatarKey = 'star',
  });

  Future<void> updateChild({
    required String childId,
    required String nickname,
    required int grade,
    Map<String, String> textbookLabels = const {},
    String avatarKey = 'star',
    int expectedVersion = 0,
  });

  Future<void> deleteChild(String childId);

  Future<void> setParentPin({required String familyId, required String pin});

  Future<void> inviteParent({required String familyId, required String email});

  Future<ParentPinVerification> verifyParentPin({
    required String familyId,
    required String pin,
  });
}

class SupabaseFamilyRepository implements FamilyRepository {
  SupabaseFamilyRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<void> revokeParentAuthorization() =>
      _client.rpc<void>('revoke_parent_authorization');

  Future<List<String>> loadDeletedChildIds() async {
    final ids = <String>[];
    for (var offset = 0; ; offset += 500) {
      final rows = await _client
          .from('child_deletion_tombstones')
          .select('child_id')
          .order('child_id')
          .range(offset, offset + 499);
      ids.addAll(rows.map((row) => row['child_id'] as String));
      if (rows.length < 500) break;
    }
    for (var offset = 0; ; offset += 500) {
      final rows = await _client
          .from('family_access_revocations')
          .select('family_id, child_ids')
          .order('family_id')
          .range(offset, offset + 499);
      for (final row in rows) {
        ids.addAll((row['child_ids'] as List).cast<String>());
      }
      if (rows.length < 500) return ids;
    }
  }

  @override
  Future<List<Family>> loadFamilies() async {
    await _client.rpc<void>('accept_family_invitations');
    final familyRows = await _client
        .from('families')
        .select('id, name, timezone')
        .order('created_at');
    final childRows = await _client
        .from('children')
        .select(
          'id, family_id, nickname, grade, textbook_labels, avatar_key, profile_version, guide_step, starter_task_preset, starter_rules_at, onboarding_completed_at',
        )
        .order('created_at');

    final childrenByFamily = <String, List<ChildProfile>>{};
    for (final row in childRows) {
      final familyId = row['family_id'] as String;
      childrenByFamily
          .putIfAbsent(familyId, () => [])
          .add(ChildProfile.fromJson(row));
    }

    return [
      for (final row in familyRows)
        Family(
          id: row['id'] as String,
          name: row['name'] as String,
          timezone: row['timezone'] as String,
          children: childrenByFamily[row['id'] as String] ?? const [],
        ),
    ];
  }

  @override
  Future<void> createFamilyWithChild({
    required String familyName,
    required String timezone,
    required String childNickname,
    required int grade,
    Map<String, String> textbookLabels = const {},
    String avatarKey = 'star',
  }) async {
    await _client.rpc<void>(
      'onboard_family_profile',
      params: {
        'family_name': familyName,
        'family_timezone': timezone,
        'child_nickname': childNickname,
        'child_grade': grade,
        'preferences': {
          'textbook_labels': textbookLabels,
          'avatar_key': avatarKey,
        },
      },
    );
  }

  @override
  Future<void> createChild({
    required String familyId,
    required String nickname,
    required int grade,
    Map<String, String> textbookLabels = const {},
    String avatarKey = 'star',
  }) async {
    await _client.rpc<void>(
      'create_child_profile',
      params: {
        'target_family_id': familyId,
        'child_nickname': nickname,
        'child_grade': grade,
        'preferences': {
          'textbook_labels': textbookLabels,
          'avatar_key': avatarKey,
        },
      },
    );
  }

  @override
  Future<void> updateChild({
    required String childId,
    required String nickname,
    required int grade,
    Map<String, String> textbookLabels = const {},
    String avatarKey = 'star',
    int expectedVersion = 0,
  }) async {
    await _client.rpc<void>(
      'update_child_profile',
      params: {
        'target_child_id': childId,
        'expected_version': expectedVersion,
        'child_nickname': nickname,
        'child_grade': grade,
        'preferences': {
          'textbook_labels': textbookLabels,
          'avatar_key': avatarKey,
        },
      },
    );
  }

  @override
  Future<void> deleteChild(String childId) async {
    await _client.rpc<void>(
      'delete_child',
      params: {'target_child_id': childId},
    );
  }

  @override
  Future<void> setParentPin({
    required String familyId,
    required String pin,
  }) async {
    await _client.rpc<void>(
      'set_parent_pin',
      params: {'target_family_id': familyId, 'new_pin': pin},
    );
  }

  @override
  Future<void> inviteParent({
    required String familyId,
    required String email,
  }) async {
    await _client.rpc<void>(
      'invite_family_parent',
      params: {'target_family_id': familyId, 'parent_email': email},
    );
  }

  @override
  Future<ParentPinVerification> verifyParentPin({
    required String familyId,
    required String pin,
  }) async {
    final response = await _client.rpc<List<dynamic>>(
      'verify_parent_pin',
      params: {'target_family_id': familyId, 'candidate_pin': pin},
    );
    final row = response.single as Map<String, dynamic>;
    return ParentPinVerification(
      verified: row['verified'] as bool,
      remainingAttempts: row['remaining_attempts'] as int,
      authorizedUntil: row['authorized_until'] == null
          ? null
          : DateTime.parse(row['authorized_until'] as String),
      retryAt: row['retry_at'] == null
          ? null
          : DateTime.parse(row['retry_at'] as String),
    );
  }
}

class UnconfiguredFamilyRepository implements FamilyRepository {
  @override
  Future<void> revokeParentAuthorization() async {}
  const UnconfiguredFamilyRepository();

  Future<void> _fail() => Future<void>.error(StateError('开发环境尚未配置 Supabase。'));

  @override
  Future<List<Family>> loadFamilies() async => const [];

  @override
  Future<void> createFamilyWithChild({
    required String familyName,
    required String timezone,
    required String childNickname,
    required int grade,
    Map<String, String> textbookLabels = const {},
    String avatarKey = 'star',
  }) => _fail();

  @override
  Future<void> createChild({
    required String familyId,
    required String nickname,
    required int grade,
    Map<String, String> textbookLabels = const {},
    String avatarKey = 'star',
  }) => _fail();

  @override
  Future<void> updateChild({
    required String childId,
    required String nickname,
    required int grade,
    Map<String, String> textbookLabels = const {},
    String avatarKey = 'star',
    int expectedVersion = 0,
  }) => _fail();

  @override
  Future<void> deleteChild(String childId) => _fail();

  @override
  Future<void> setParentPin({required String familyId, required String pin}) =>
      _fail();

  @override
  Future<void> inviteParent({
    required String familyId,
    required String email,
  }) => _fail();

  @override
  Future<ParentPinVerification> verifyParentPin({
    required String familyId,
    required String pin,
  }) => Future<ParentPinVerification>.error(StateError('开发环境尚未配置 Supabase。'));
}
