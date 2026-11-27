import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/offline/offline_store.dart';

class FamilyMember {
  FamilyMember(Map<String, dynamic> value)
    : userId = value['user_id'] as String,
      email = value['email'] as String? ?? '邮箱未提供',
      role = value['role'] as String,
      isSelf = value['is_self'] as bool,
      isOwner = value['is_owner'] as bool,
      version = (value['version'] as num?)?.toInt() ?? 0,
      canRemove = value['can_remove'] == true;
  final String userId, email, role;
  final bool isSelf, isOwner;
  final int version;
  final bool canRemove;
}

class FamilyInvitation {
  FamilyInvitation(Map<String, dynamic> value)
    : id = value['id'] as String,
      email = value['email'] as String,
      version = (value['version'] as num).toInt(),
      expiresAt = DateTime.parse(value['expires_at'] as String),
      expired = value['expired'] as bool;
  final String id, email;
  final int version;
  final DateTime expiresAt;
  final bool expired;
}

class FamilyMembers {
  FamilyMembers(Map<String, dynamic> value)
    : familyId = value['family_id'] as String,
      viewerId = value['viewer_id'] as String,
      canManage = value['can_manage'] as bool,
      members = List.unmodifiable([
        for (final row in value['members'] as List)
          FamilyMember((row as Map).cast<String, dynamic>()),
      ]),
      invitations = List.unmodifiable([
        for (final row in value['invitations'] as List)
          FamilyInvitation((row as Map).cast<String, dynamic>()),
      ]);
  final String familyId, viewerId;
  final bool canManage;
  final List<FamilyMember> members;
  final List<FamilyInvitation> invitations;
}

class FamilyInvitationRequest {
  FamilyInvitationRequest(Map<String, dynamic> value)
    : _value = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  final Map<String, dynamic> _value;
  String get requestId => _value['request_id'] as String;
  String get familyId => _value['family_id'] as String;
  String get status => _value['status'] as String;
  String? get displayLabel => _value['display_label'] as String?;
  Map<String, dynamic> get command =>
      (jsonDecode(jsonEncode(_value['command'])) as Map)
          .cast<String, dynamic>();
  Map<String, dynamic> toJson() =>
      (jsonDecode(jsonEncode(_value)) as Map).cast<String, dynamic>();
}

abstract interface class FamilyMembersRemote {
  Future<Map<String, dynamic>> load(String familyId);
  Future<Map<String, dynamic>> resolve(
    FamilyInvitationRequest request,
    String operation,
  );
}

class SupabaseFamilyMembersRemote implements FamilyMembersRemote {
  SupabaseFamilyMembersRemote(this.client);
  final SupabaseClient client;
  @override
  Future<Map<String, dynamic>> load(String familyId) => client
      .rpc<Map<String, dynamic>>(
        'load_family_members',
        params: {'target_family_id': familyId},
      )
      .timeout(const Duration(seconds: 15));
  @override
  Future<Map<String, dynamic>> resolve(
    FamilyInvitationRequest request,
    String operation,
  ) => client
      .rpc<Map<String, dynamic>>(
        request.command['kind'] == 'remove'
            ? 'resolve_family_member_removal'
            : 'resolve_family_invitation',
        params: {
          'target_family_id': request.familyId,
          'request_id': request.requestId,
          'command': request.command,
          'operation': operation,
        },
      )
      .timeout(const Duration(seconds: 15));
}

/// Only the unresolved intent is persisted, inside the encrypted account store.
/// No roster cache, background submission, PIN or authorization token is saved.
class FamilyMembersRepository {
  FamilyMembersRepository({
    required this.store,
    required this.remote,
    required this.accountId,
    required this.isAuthorized,
    required this.authorizationRevision,
  });
  final OfflineStore store;
  final FamilyMembersRemote remote;
  final String? Function() accountId;
  final bool Function(String) isAuthorized;
  final int Function() authorizationRevision;
  Future<void> _queue = Future.value();

  String _key(String family) => 'invitation-command:$family';
  ({String owner, int revision, int privacy}) _scope(String family) {
    final owner = accountId();
    if (owner == null || !isAuthorized(family)) throw StateError('请重新验证家长 PIN');
    return (
      owner: owner,
      revision: authorizationRevision(),
      privacy: store.privacyGeneration,
    );
  }

  Future<void> _check(
    String family,
    ({String owner, int revision, int privacy}) scope,
  ) async {
    void check() {
      if (accountId() != scope.owner ||
          !isAuthorized(family) ||
          authorizationRevision() != scope.revision ||
          store.privacyGeneration != scope.privacy) {
        throw StateError('账号、家长授权或本机资料已变化');
      }
    }

    check();
    final deleted = await store.accountDeletionJob(scope.owner);
    check();
    if (deleted != null) throw StateError('账号已申请注销');
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final future = _queue.then((_) => operation());
    _queue = future.then<void>((_) {}, onError: (Object _) {});
    return future;
  }

  Future<FamilyMembers> load(String family) async {
    final scope = _scope(family);
    await _check(family, scope);
    final result = FamilyMembers(await remote.load(family));
    await _check(family, scope);
    if (result.familyId != family || result.viewerId != scope.owner) {
      throw StateError('成员列表归属不匹配');
    }
    return result;
  }

  Future<FamilyInvitationRequest?> pending(String family) async {
    final scope = _scope(family);
    await _check(family, scope);
    final saved = await store.read(scope.owner, _key(family));
    await _check(family, scope);
    return saved == null ? null : FamilyInvitationRequest(saved);
  }

  Future<FamilyInvitationRequest> prepare(
    String family,
    Map<String, dynamic> command, {
    String? displayLabel,
  }) {
    final scope = _scope(family);
    final request = FamilyInvitationRequest({
      'family_id': family,
      'request_id': const Uuid().v4(),
      'status': 'pending',
      'command': command,
      if (displayLabel != null) 'display_label': displayLabel,
    });
    return _serialize(
      () => store.transaction(() async {
        await _check(family, scope);
        if (await store.read(scope.owner, _key(family)) != null) {
          throw StateError('请先核对上次邀请操作');
        }
        await _check(family, scope);
        await store.write(scope.owner, _key(family), request.toJson());
        await _check(family, scope);
        return request;
      }),
    );
  }

  Future<FamilyInvitationRequest> resolve(
    String family,
    String requestId,
    String operation,
  ) {
    final scope = _scope(family);
    if (!const ['inspect', 'submit', 'cancel'].contains(operation)) {
      throw ArgumentError('Invalid operation');
    }
    return _serialize(() async {
      await _check(family, scope);
      final saved = await store.read(scope.owner, _key(family));
      if (saved == null || saved['request_id'] != requestId) {
        throw StateError('请求已清理，请刷新');
      }
      final request = FamilyInvitationRequest(saved);
      await _check(family, scope);
      final receipt = await remote.resolve(request, operation);
      await _check(family, scope);
      if (receipt['request_id'] != requestId ||
          receipt['family_id'] != family ||
          receipt['kind'] != request.command['kind'] ||
          !const [
            'unknown',
            'applied',
            'abandoned',
            'already_member',
            'conflict',
          ].contains(receipt['status'])) {
        throw StateError('回执不匹配，已保留原请求');
      }
      final result = FamilyInvitationRequest({
        ...saved,
        'status': receipt['status'] == 'unknown'
            ? 'pending'
            : receipt['status'],
      });
      await store.transaction(() async {
        await _check(family, scope);
        final current = await store.read(scope.owner, _key(family));
        if (current == null || current['request_id'] != requestId) {
          throw StateError('请求已清理，不能恢复');
        }
        await store.write(scope.owner, _key(family), result.toJson());
        await _check(family, scope);
      });
      return result;
    });
  }

  Future<void> dismiss(String family, String requestId) {
    final scope = _scope(family);
    return _serialize(
      () => store.transaction(() async {
        await _check(family, scope);
        final saved = await store.read(scope.owner, _key(family));
        if (saved == null) return;
        if (saved['request_id'] != requestId || saved['status'] == 'pending') {
          throw StateError('请先联网核对结果');
        }
        await _check(family, scope);
        await store.remove(scope.owner, _key(family));
      }),
    );
  }
}
