import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/offline/offline_store.dart';

class FamilyCreationDraft {
  FamilyCreationDraft(Map<String, dynamic> value)
    : _value = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  final Map<String, dynamic> _value;
  String get requestId => _value['request_id'] as String;
  String get status => _value['status'] as String;
  String get childId => command['child_id'] as String;
  String get familyId => command['family_id'] as String;
  Map<String, dynamic> get command =>
      (jsonDecode(jsonEncode(_value['command'])) as Map)
          .cast<String, dynamic>();
  Map<String, dynamic> toJson() =>
      (jsonDecode(jsonEncode(_value)) as Map).cast<String, dynamic>();
}

abstract interface class FamilyCreationAccess {
  FamilyCreationRepository get creations;
}

abstract interface class FamilyCreationRemote {
  Future<Map<String, dynamic>> resolve(
    FamilyCreationDraft draft,
    String operation,
  );
}

class SupabaseFamilyCreationRemote implements FamilyCreationRemote {
  SupabaseFamilyCreationRemote(this.client);
  final SupabaseClient client;
  @override
  Future<Map<String, dynamic>> resolve(
    FamilyCreationDraft draft,
    String operation,
  ) async => await client
      .rpc<Map<String, dynamic>>(
        'resolve_family_creation',
        params: {
          'request_id': draft.requestId,
          'command': draft.command,
          'operation': operation,
        },
      )
      .timeout(const Duration(seconds: 15));
}

/// One unresolved intent per account and creation screen. Network requests are
/// explicit; a persisted request never creates children in the background.
class FamilyCreationRepository {
  FamilyCreationRepository({
    required this.store,
    required this.accountId,
    required this.remote,
  });
  final OfflineStore store;
  final String? Function() accountId;
  final FamilyCreationRemote remote;
  Future<void> _queue = Future.value();

  String _key(String? familyId) =>
      familyId == null ? 'creation:family' : 'creation:child:$familyId';
  String _owner() => accountId() ?? (throw StateError('请先登录'));
  Future<void> _check(String owner) async {
    if (accountId() != owner) throw StateError('登录账号已变化');
    final deleted = await store.accountDeletionJob(owner);
    if (accountId() != owner) throw StateError('登录账号已变化');
    if (deleted != null) {
      throw StateError('账号已申请注销');
    }
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final future = _queue.then((_) => operation());
    _queue = future.then<void>((_) {}, onError: (Object _) {});
    return future;
  }

  Future<FamilyCreationDraft?> pending(String? familyId) async {
    final owner = _owner();
    await _check(owner);
    final value = await store.read(owner, _key(familyId));
    await _check(owner);
    return value == null ? null : FamilyCreationDraft(value);
  }

  Future<FamilyCreationDraft> prepare({
    String? familyId,
    String? familyName,
    String timezone = 'Asia/Shanghai',
    required String nickname,
    required int grade,
    required Map<String, String> textbookLabels,
    required String avatarKey,
  }) {
    final owner = _owner();
    final labels = Map<String, String>.from(textbookLabels);
    return _serialize(
      () => store.transaction(() async {
        await _check(owner);
        final key = _key(familyId);
        if (await store.read(owner, key) != null) {
          throw StateError('已有待确认的创建请求，请先核对原请求');
        }
        final childId = const Uuid().v4();
        final draft = FamilyCreationDraft({
          'request_id': const Uuid().v4(),
          'child_id': childId,
          'status': 'pending',
          'command': {
            'kind': familyId == null ? 'family' : 'child',
            'family_id': familyId ?? const Uuid().v4(),
            'child_id': childId,
            if (familyId == null) 'family_name': familyName?.trim(),
            if (familyId == null) 'timezone': timezone,
            'nickname': nickname.trim(),
            'grade': grade,
            'preferences': {'avatar_key': avatarKey, 'textbook_labels': labels},
          },
        });
        await store.write(owner, key, draft.toJson());
        return draft;
      }),
    );
  }

  Future<FamilyCreationDraft> resolve(
    String? familyId,
    String requestId,
    String operation,
  ) {
    final owner = _owner();
    return _serialize(() async {
      await _check(owner);
      final key = _key(familyId);
      final saved = await store.read(owner, key);
      if (saved == null || saved['request_id'] != requestId) {
        throw StateError('该创建请求已处理或清理，请重新打开');
      }
      final draft = FamilyCreationDraft(saved);
      if (await store.isChildDeleted(draft.childId)) {
        throw StateError('孩子档案已删除');
      }
      await _check(owner);
      final receipt = await remote.resolve(draft, operation);
      await _check(owner);
      if (receipt['request_id'] != requestId ||
          receipt['child_id'] != draft.childId ||
          receipt['family_id'] != draft.familyId ||
          !const [
            'unknown',
            'created',
            'cancelled',
            'unavailable',
          ].contains(receipt['status'])) {
        throw StateError('创建回执不匹配，已保留原请求');
      }
      final result = FamilyCreationDraft({
        ...saved,
        'status': receipt['status'] == 'unknown'
            ? 'pending'
            : receipt['status'],
      });
      await store.transaction(() async {
        await _check(owner);
        final current = await store.read(owner, key);
        if (current == null || current['request_id'] != requestId) {
          throw StateError('该创建请求已清理，不能恢复');
        }
        if (result.status == 'unavailable') {
          // The server has confirmed deletion or lost access. Retain its
          // server-side UUID barrier, but erase this account's profile text.
          await store.remove(owner, key);
        } else {
          await store.write(owner, key, result.toJson());
        }
      });
      return result;
    });
  }

  /// Only a terminal receipt may be dismissed. For 'created', the UI first
  /// verifies that the family list contains the returned child.
  Future<void> dismiss(String? familyId, String requestId) {
    final owner = _owner();
    return _serialize(
      () => store.transaction(() async {
        await _check(owner);
        final key = _key(familyId),
            saved = await store.read(owner, _key(familyId));
        if (saved == null) return;
        if (saved['request_id'] != requestId || saved['status'] == 'pending') {
          throw StateError('请先联网核对这次创建结果');
        }
        await store.remove(owner, key);
      }),
    );
  }
}
