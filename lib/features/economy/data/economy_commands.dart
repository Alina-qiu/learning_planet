import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../../core/offline/offline_store.dart';
import '../../auth_family/application/family_providers.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';

class EconomyCommand {
  EconomyCommand(Map<String, dynamic> value)
    : _value = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  final Map<String, dynamic> _value;
  String get requestId => _value['request_id'] as String;
  String get childId => _value['child_id'] as String;
  String get familyId => _value['family_id'] as String;
  String get kind => _value['kind'] as String;
  String get status => _value['status'] as String;
  bool get locked => status == 'locked';
  Map<String, dynamic> get command =>
      Map<String, dynamic>.from(_value['command'] as Map? ?? {});
  Map<String, dynamic> get display =>
      Map<String, dynamic>.from(_value['display'] as Map? ?? {});
  Map<String, dynamic> toJson() =>
      jsonDecode(jsonEncode(_value)) as Map<String, dynamic>;
}

abstract interface class EconomyCommandRemote {
  Future<Map<String, dynamic>> resolve(
    EconomyCommand request,
    String operation,
  );
}

class SupabaseEconomyCommandRemote implements EconomyCommandRemote {
  SupabaseEconomyCommandRemote(this.client);
  final SupabaseClient client;
  @override
  Future<Map<String, dynamic>> resolve(
    EconomyCommand request,
    String operation,
  ) => client
      .rpc<Map<String, dynamic>>(
        'resolve_economy_command',
        params: {
          'target_child_id': request.childId,
          'request_id': request.requestId,
          'command': request.command,
          'operation': operation,
        },
      )
      .timeout(const Duration(seconds: 15));
}

final economyCommandsProvider = Provider<EconomyCommands?>((ref) {
  final tasks = ref.watch(taskRepositoryProvider);
  final client = taskSupabaseClient(tasks);
  if (tasks is! OfflineTaskRepository || client == null) return null;
  return EconomyCommands(
    store: tasks.store,
    remote: SupabaseEconomyCommandRemote(client),
    owner: () => client.auth.currentUser?.id,
    authorized: (family) => ref.read(activeParentFamilyProvider) == family,
    authorizationRevision: () => ref.read(parentAuthorizationRevisionProvider),
  );
});
typedef EconomyScope = ({String owner, int privacy, int revision, bool parent});

final pendingEconomyCommandProvider = FutureProvider.autoDispose
    .family<EconomyCommand?, ({String childId, String familyId})>((ref, scope) {
      ref.watch(activeParentFamilyProvider);
      ref.watch(parentAuthorizationRevisionProvider);
      return ref
          .watch(economyCommandsProvider)
          ?.pending(scope.childId, scope.familyId);
    });

/// One unresolved financial intent per account/child. Explicit actions only;
/// loading a page or resuming the app never submits money-changing operations.
class EconomyCommands {
  EconomyCommands({
    required this.store,
    required this.remote,
    required this.owner,
    required this.authorized,
    required this.authorizationRevision,
  });
  final OfflineStore store;
  final EconomyCommandRemote remote;
  final String? Function() owner;
  final bool Function(String) authorized;
  final int Function() authorizationRevision;
  Future<void> _queue = Future.value();
  String _key(String child) => 'economy-command:$child';
  EconomyScope capture(String family, {bool parent = false}) {
    final account = owner();
    if (account == null || parent && !authorized(family)) {
      throw StateError('请重新登录或验证家长 PIN');
    }
    return (
      owner: account,
      privacy: store.privacyGeneration,
      revision: authorizationRevision(),
      parent: parent,
    );
  }

  Future<void> check(String child, String family, EconomyScope scope) async {
    void guard() {
      if (owner() != scope.owner ||
          store.privacyGeneration != scope.privacy ||
          scope.parent &&
              (!authorized(family) ||
                  authorizationRevision() != scope.revision)) {
        throw StateError('账号、家长授权或本机资料已变化');
      }
    }

    guard();
    if (await store.accountDeletionJob(scope.owner) != null ||
        await store.isChildDeleted(child) ||
        await store.familyAccessRevoked(
          scope.owner,
          familyId: family,
          childId: child,
        )) {
      throw StateError('该账号或孩子已不可访问');
    }
    guard();
  }

  Future<T> _serialize<T>(Future<T> Function() work) {
    final result = _queue.then((_) => work());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<EconomyCommand?> pending(String child, String family) async {
    final scope = capture(family);
    await check(child, family, scope);
    final saved = await store.read(scope.owner, _key(child));
    await check(child, family, scope);
    if (saved == null) return null;
    if (saved['family_id'] != family || saved['child_id'] != child) {
      throw StateError('请求归属不匹配');
    }
    if (saved['kind'] == 'adjust' && !authorized(family)) {
      return EconomyCommand({
        'request_id': saved['request_id'],
        'child_id': child,
        'family_id': family,
        'kind': 'adjust',
        'status': 'locked',
      });
    }
    return EconomyCommand(saved);
  }

  Future<EconomyCommand> prepare(
    String child,
    String family,
    Map<String, dynamic> command,
    Map<String, dynamic> display,
  ) {
    if (!const ['redeem', 'adjust'].contains(command['kind'])) {
      throw ArgumentError('Invalid kind');
    }
    final scope = capture(family, parent: command['kind'] == 'adjust');
    final request = EconomyCommand({
      'child_id': child,
      'family_id': family,
      'request_id': const Uuid().v4(),
      'status': 'pending',
      'kind': command['kind'],
      'command': command,
      'display': display,
    });
    return _serialize(
      () => store.transaction(() async {
        await check(child, family, scope);
        if (await store.read(scope.owner, _key(child)) != null) {
          throw StateError('请先核对上次操作');
        }
        await check(child, family, scope);
        await store.write(scope.owner, _key(child), request.toJson());
        await check(child, family, scope);
        return request;
      }),
    );
  }

  Future<EconomyCommand> resolve(
    String child,
    String family,
    String requestId,
    String operation,
  ) {
    if (!const ['submit', 'inspect', 'cancel'].contains(operation)) {
      throw ArgumentError('Invalid operation');
    }
    final initial = capture(family);
    return _serialize(() async {
      await check(child, family, initial);
      final saved = await store.read(initial.owner, _key(child));
      if (saved == null ||
          saved['request_id'] != requestId ||
          saved['family_id'] != family) {
        throw StateError('请求已清理，请刷新');
      }
      final request = EconomyCommand(saved);
      final scope = (
        owner: initial.owner,
        privacy: initial.privacy,
        revision: initial.revision,
        parent: request.kind == 'adjust',
      );
      await check(child, family, scope);
      // The command may commit even when its reply is lost. Never retain a
      // pre-command wallet/catalog as the latest confirmed economy snapshot.
      final mutating = operation != 'inspect';
      if (mutating) await store.invalidateEconomyViews(scope.owner);
      late final Map<String, dynamic> receipt;
      try {
        receipt = await remote.resolve(request, operation);
      } finally {
        if (mutating) {
          await check(child, family, scope);
          await store.invalidateEconomyViews(scope.owner);
        }
      }
      await check(child, family, scope);
      if (receipt['owner_id'] != scope.owner ||
          receipt['request_id'] != requestId ||
          receipt['family_id'] != family ||
          receipt['child_id'] != child ||
          receipt['kind'] != request.kind ||
          !const [
            'unknown',
            'applied',
            'abandoned',
          ].contains(receipt['status'])) {
        throw StateError('回执不匹配，已保留原请求');
      }
      if (!mutating && receipt['status'] == 'applied') {
        await store.invalidateEconomyViews(scope.owner);
      }
      final result = EconomyCommand({
        ...saved,
        'status': receipt['status'] == 'unknown'
            ? 'pending'
            : receipt['status'],
        if (receipt['redemption_id'] != null)
          'redemption_id': receipt['redemption_id'],
      });
      await store.transaction(() async {
        await check(child, family, scope);
        final current = await store.read(scope.owner, _key(child));
        if (current?['request_id'] != requestId) throw StateError('请求已清理，不能恢复');
        await store.write(scope.owner, _key(child), result.toJson());
        await check(child, family, scope);
      });
      return result;
    });
  }

  Future<void> acknowledge(String child, String family, String requestId) {
    final initial = capture(family);
    return _serialize(
      () => store.transaction(() async {
        await check(child, family, initial);
        final saved = await store.read(initial.owner, _key(child));
        if (saved == null) return;
        if (saved['request_id'] != requestId ||
            saved['family_id'] != family ||
            saved['child_id'] != child ||
            !const ['applied', 'abandoned'].contains(saved['status'])) {
          throw StateError('请先联网核对结果');
        }
        final scope = (
          owner: initial.owner,
          privacy: initial.privacy,
          revision: initial.revision,
          parent: saved['kind'] == 'adjust',
        );
        await check(child, family, scope);
        await store.remove(scope.owner, _key(child));
        await check(child, family, scope);
      }),
    );
  }
}
