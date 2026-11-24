import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/family.dart';
import '../domain/parent_authorization_clock.dart';

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

  Session? get currentSession => _client.auth.currentSession;

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
    final owner = _client.auth.currentUser?.id;
    void checkOwner() {
      if (_client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    }

    await _client.rpc<void>('accept_family_invitations');
    checkOwner();
    const pageSize = 1000;
    const childColumns =
        'id,created_at,family_id,nickname,grade,textbook_labels,avatar_key,'
        'profile_version,guide_step,starter_task_preset,starter_rules_at,onboarding_completed_at';
    // Timestamps can tie. Use the same descending pair for ordering and the
    // cursor, so deletions before a later page do not shift its start.
    String olderThan(Map<String, dynamic> row) =>
        'created_at.lt.${row['created_at']},and(created_at.eq.${row['created_at']},id.lt.${row['id']})';

    final families = <Family>[];
    Map<String, dynamic>? lastFamily;
    while (true) {
      var query = _client
          .from('families')
          .select('id,created_at,name,timezone,children($childColumns)');
      if (lastFamily != null) query = query.or(olderThan(lastFamily));
      final rows = await query
          .order('created_at')
          .order('id')
          .order('created_at', referencedTable: 'children')
          .order('id', referencedTable: 'children')
          .limit(pageSize)
          .limit(pageSize, referencedTable: 'children');
      checkOwner();
      for (final row in rows) {
        final id = row['id'] as String;
        var page = (row['children'] as List).cast<Map<String, dynamic>>();
        final children = <ChildProfile>[];
        while (true) {
          for (final profile in page) {
            if (profile['family_id'] != id) throw StateError('孩子资料与家庭不一致');
            children.add(ChildProfile.fromJson(profile));
          }
          // PostgREST also caps each embedded collection. Only a full child
          // page needs a separate read, always scoped to this visible family.
          if (page.length < pageSize) break;
          page = await _client
              .from('children')
              .select(childColumns)
              .eq('family_id', id)
              .or(olderThan(page.last))
              .order('created_at')
              .order('id')
              .limit(pageSize);
          checkOwner();
        }
        families.add(
          Family(
            id: id,
            name: row['name'] as String,
            timezone: row['timezone'] as String,
            children: children,
          ),
        );
      }
      if (rows.length < pageSize) return families;
      lastFamily = rows.last;
    }
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
    final requestStart = ParentAuthorizationClock.device.now();
    final owner = _client.auth.currentUser?.id;
    final response = await _client.rpc<List<dynamic>>(
      'verify_parent_pin_timed',
      params: {'target_family_id': familyId, 'candidate_pin': pin},
    );
    if (_client.auth.currentUser?.id != owner) {
      throw StateError('登录状态已变化，请重新验证');
    }
    final row = response.single as Map<String, dynamic>;
    return ParentPinVerification(
      verified: row['verified'] as bool,
      remainingAttempts: row['remaining_attempts'] as int,
      authorizedUntil: row['authorized_until'] == null
          ? null
          : ParentAuthorizationClock.deadline(requestStart, row),
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
