import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/family.dart';

abstract interface class FamilyRepository {
  Future<List<Family>> loadFamilies();

  Future<void> createFamilyWithChild({
    required String familyName,
    required String timezone,
    required String childNickname,
    required int grade,
  });

  Future<void> createChild({
    required String familyId,
    required String nickname,
    required int grade,
  });

  Future<void> updateChild({
    required String childId,
    required String nickname,
    required int grade,
  });

  Future<void> deleteChild(String childId);

  Future<void> setParentPin({required String familyId, required String pin});

  Future<void> inviteParent({
    required String familyId,
    required String email,
  });

  Future<ParentPinVerification> verifyParentPin({
    required String familyId,
    required String pin,
  });
}

class SupabaseFamilyRepository implements FamilyRepository {
  SupabaseFamilyRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<Family>> loadFamilies() async {
    await _client.rpc<void>('accept_family_invitations');
    final familyRows = await _client
        .from('families')
        .select('id, name, timezone')
        .order('created_at');
    final childRows = await _client
        .from('children')
        .select('id, family_id, nickname, grade')
        .order('created_at');

    final childrenByFamily = <String, List<ChildProfile>>{};
    for (final row in childRows) {
      final familyId = row['family_id'] as String;
      childrenByFamily.putIfAbsent(familyId, () => []).add(
            ChildProfile(
              id: row['id'] as String,
              familyId: familyId,
              nickname: row['nickname'] as String,
              grade: row['grade'] as int,
            ),
          );
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
  }) async {
    await _client.rpc<void>(
      'onboard_family',
      params: {
        'family_name': familyName,
        'family_timezone': timezone,
        'child_nickname': childNickname,
        'child_grade': grade,
      },
    );
  }

  @override
  Future<void> createChild({
    required String familyId,
    required String nickname,
    required int grade,
  }) async {
    await _client.rpc<void>(
      'create_child',
      params: {
        'target_family_id': familyId,
        'child_nickname': nickname,
        'child_grade': grade,
      },
    );
  }

  @override
  Future<void> updateChild({
    required String childId,
    required String nickname,
    required int grade,
  }) async {
    await _client.rpc<void>(
      'update_child',
      params: {
        'target_child_id': childId,
        'child_nickname': nickname,
        'child_grade': grade,
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
      retryAt: row['retry_at'] == null
          ? null
          : DateTime.parse(row['retry_at'] as String),
    );
  }
}

class UnconfiguredFamilyRepository implements FamilyRepository {
  const UnconfiguredFamilyRepository();

  Future<void> _fail() => Future<void>.error(
        StateError('开发环境尚未配置 Supabase。'),
      );

  @override
  Future<List<Family>> loadFamilies() async => const [];

  @override
  Future<void> createFamilyWithChild({
    required String familyName,
    required String timezone,
    required String childNickname,
    required int grade,
  }) =>
      _fail();

  @override
  Future<void> createChild({
    required String familyId,
    required String nickname,
    required int grade,
  }) =>
      _fail();

  @override
  Future<void> updateChild({
    required String childId,
    required String nickname,
    required int grade,
  }) =>
      _fail();

  @override
  Future<void> deleteChild(String childId) => _fail();

  @override
  Future<void> setParentPin({
    required String familyId,
    required String pin,
  }) =>
      _fail();

  @override
  Future<void> inviteParent({
    required String familyId,
    required String email,
  }) =>
      _fail();

  @override
  Future<ParentPinVerification> verifyParentPin({
    required String familyId,
    required String pin,
  }) =>
      Future<ParentPinVerification>.error(
        StateError('开发环境尚未配置 Supabase。'),
      );
}
