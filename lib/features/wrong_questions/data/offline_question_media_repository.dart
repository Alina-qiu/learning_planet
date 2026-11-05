import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../../core/offline/network_failure.dart';
import '../../../core/diagnostics/runtime_diagnostics.dart';
import '../../../core/offline/offline_media_store.dart';
import '../../../core/offline/offline_store.dart';
import 'question_media_repository.dart';

/// Images and approved upload payloads survive restarts; PINs never enter SQLite.
class OfflineQuestionMediaRepository implements QuestionMediaRepository {
  OfflineQuestionMediaRepository({
    required this.store,
    required this.live,
    required this.accountId,
    required this.parentFamily,
    bool autoSync = true,
    this.onUploaded,
    RuntimeDiagnostics? diagnostics,
  }) : automatic = autoSync,
       diagnostics = diagnostics ?? runtimeDiagnostics {
    if (autoSync) {
      _timer = Timer.periodic(const Duration(seconds: 15), (_) => kick());
    }
  }
  final OfflineStore store;
  final bool automatic;
  final QuestionMediaRepository live;
  final RuntimeDiagnostics diagnostics;
  final String? Function() accountId, parentFamily;
  final void Function(String childId)? onUploaded;
  final _events = StreamController<int>.broadcast();
  Stream<int> get changes => _events.stream;
  int revision = 0;
  bool _disposed = false, _foreground = true;
  Timer? _timer;
  Future<void>? _sync;
  Future<void> _tail = Future.value();
  String _owner() {
    final owner = accountId();
    if (_disposed || owner == null) throw StateError('请先登录');
    return owner;
  }

  void _check(
    String owner,
    String family, {
    bool childInput = false,
    int? privacy,
  }) {
    if (_disposed || accountId() != owner) throw StateError('登录账号已变化');
    if (!childInput && parentFamily() != family) {
      throw StateError('请重新验证家长 PIN，草稿仍保留在本机');
    }
    if (privacy != null && privacy != store.privacyGeneration) {
      throw StateError('本机资料已清理，请重新打开');
    }
  }

  void _emit() {
    if (!_disposed) _events.add(++revision);
  }

  Future<T> _locked<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<List<Map<String, dynamic>>> drafts(
    String child,
    String family, {
    bool includeChildDrafts = false,
  }) async {
    final owner = _owner(), privacy = store.privacyGeneration;
    _check(owner, family, childInput: includeChildDrafts);
    final rows = await store.imageDrafts(owner, childId: child);
    _check(owner, family, childInput: includeChildDrafts, privacy: privacy);
    return rows
        .where(
          (r) =>
              r['family_id'] == family &&
              (parentFamily() == family || r['requires_parent_review'] == 1),
        )
        .toList();
  }

  Future<Map<String, dynamic>> draft(
    String id,
    String family, {
    bool childInput = false,
  }) async {
    final owner = _owner(), privacy = store.privacyGeneration;
    _check(owner, family, childInput: childInput);
    final row = await store.imageDraft(owner, id);
    _check(owner, family, childInput: childInput, privacy: privacy);
    if (row == null || row['family_id'] != family) {
      throw StateError('草稿已移除或已上传');
    }
    if (childInput &&
        (row['metadata'] as Map)['requires_parent_review'] != true) {
      throw StateError('家长草稿需验证PIN后查看');
    }
    return row;
  }

  /// Capture scope before opening the native picker. A delayed selection must
  /// not be imported into a different login or after privacy cleanup.
  Future<List<String>> importImages(
    String child,
    String family,
    Future<List<Uint8List>> Function() select, {
    bool childInput = false,
  }) async {
    final owner = _owner(), generation = store.privacyGeneration;
    void guard() {
      _check(owner, family, childInput: childInput);
      if (generation != store.privacyGeneration) {
        throw StateError('本机资料已清理，请重新选择图片');
      }
    }

    guard();
    final originals = await select();
    guard();
    if (originals.isEmpty) return [];
    if (originals.length > DeviceQuestionImageService.batchLimit ||
        originals.any(
          (bytes) => bytes.length > 10485760 || !isQuestionImage(bytes),
        )) {
      throw StateError('每次最多10张JPEG/PNG，每张不超过10MB，本次未导入');
    }
    final batch = const Uuid().v4();
    final importedAt = DateTime.now().millisecondsSinceEpoch;
    final ids = [for (final _ in originals) const Uuid().v4()];
    await _locked(
      () => store.transaction(() async {
        guard();
        for (var index = 0; index < originals.length; index++) {
          await store.writeImageDraft(
            owner,
            child,
            family,
            ids[index],
            {
              if (childInput) 'requires_parent_review': true,
              'consent': false,
              'turns': 0,
              'enhance': false,
              'crop': [0.0, 0.0, 1.0, 1.0],
              'import_batch': batch,
              'import_created_at': importedAt,
              'import_index': index + 1,
              'import_count': originals.length,
            },
            originals[index],
            null,
          );
          // Also checked inside the transaction so an expired PIN, deleted child
          // or quota failure cannot leave a silently imported partial batch.
          guard();
        }
      }),
    );
    _emit();
    return ids;
  }

  Future<void> saveDraft(
    String child,
    String family,
    String id,
    Map<String, dynamic> metadata,
    Uint8List? original,
    Uint8List? processed, {
    bool metadataOnly = false,
  }) async {
    final owner = _owner(), privacy = store.privacyGeneration;
    final childInput = metadata['requires_parent_review'] == true;
    return _locked(() async {
      _check(owner, family, childInput: childInput, privacy: privacy);
      if (metadataOnly) {
        await store.updateImageDraftMetadata(
          owner,
          child,
          family,
          id,
          metadata,
        );
      } else {
        await store.writeImageDraft(
          owner,
          child,
          family,
          id,
          metadata,
          original,
          processed,
        );
      }
      _check(owner, family, childInput: childInput, privacy: privacy);
      _emit();
    });
  }

  @override
  Future<void> save(
    String childId,
    String draftId,
    Uint8List original,
    Uint8List processed,
    Map<String, dynamic>? recognition,
    Map<String, dynamic> config,
  ) async {
    final owner = _owner(), privacy = store.privacyGeneration;
    await _locked(() async {
      final row = await store.imageDraft(owner, draftId);
      if (row == null || row['child_id'] != childId) {
        throw StateError('请先保存本机草稿');
      }
      _check(
        owner,
        row['family_id'] as String,
        childInput: (row['metadata'] as Map)['requires_parent_review'] == true,
        privacy: privacy,
      );
      if (!isQuestionImage(original) || !isQuestionImage(processed)) {
        throw StateError('图片格式无效');
      }
      await store.writeImageDraft(
        owner,
        childId,
        row['family_id'] as String,
        draftId,
        {
          ...row['metadata'] as Map<String, dynamic>,
          'config': config,
          'recognition': recognition,
        },
        original,
        processed,
        queue: true,
      );
      _emit();
    });
    kick();
  }

  void setForeground(bool value) {
    _foreground = value;
    if (value) kick();
  }

  void kick({bool retryBlocked = false}) {
    if (!_disposed && _foreground && automatic) {
      unawaited(
        synchronize(retryBlocked: retryBlocked).catchError((Object _) {}),
      );
    }
  }

  Future<void> synchronize({bool retryBlocked = false, String? childId}) {
    final existing = _sync;
    if (existing != null) {
      // A manual retry must not be lost behind an automatic run that skips
      // blocked rows. Capture the account so a delayed tap cannot cross login.
      final owner = accountId();
      return retryBlocked
          ? existing.then((_) async {
              if (accountId() == owner) {
                await synchronize(retryBlocked: true, childId: childId);
              }
            })
          : existing;
    }
    final work = _synchronize(
      retryBlocked,
      childId,
    ).whenComplete(() => _sync = null);
    _sync = work;
    return work;
  }

  Future<void> _synchronize(bool retryBlocked, String? childId) async {
    if (_disposed || !_foreground || accountId() == null) return;
    final owner = _owner();
    for (final item in await store.imageDrafts(owner, childId: childId)) {
      if (_disposed || !_foreground || accountId() != owner) return;
      if (item['stage'] == 'editing' ||
          (const {'blocked', 'needs_authorization'}.contains(item['stage']) &&
              !retryBlocked)) {
        continue;
      }
      final childInput = item['requires_parent_review'] == 1;
      if (!childInput && parentFamily() != item['family_id']) continue;
      if (!retryBlocked &&
          (item['next_attempt'] as int) >
              DateTime.now().millisecondsSinceEpoch) {
        continue;
      }
      final id = item['draft_id'] as String,
          family = item['family_id'] as String;
      final diagnosticScope = diagnostics.capture(),
          watch = Stopwatch()..start();
      Future<void> guard() async {
        _check(owner, family, childInput: childInput);
        if (await store.accountDeletionJob(owner) != null ||
            await store.isChildDeleted(item['child_id'] as String) ||
            await store.familyAccessRevoked(
              owner,
              familyId: family,
              childId: item['child_id'] as String,
            ) ||
            !await store.hasImageDraft(owner, id)) {
          throw StateError('草稿已清理');
        }
        _check(owner, family, childInput: childInput);
      }

      try {
        await guard();
        final row = await store.imageDraft(owner, id);
        if (row == null) continue;
        final metadata = row['metadata'] as Map<String, dynamic>;
        await store.updateImageDraftState(owner, id, 'uploading');
        _emit();
        if (live is GuardedQuestionMediaRepository) {
          await (live as GuardedQuestionMediaRepository).saveGuarded(
            item['child_id'] as String,
            id,
            row['original'] as Uint8List,
            row['processed'] as Uint8List,
            metadata['recognition'] as Map<String, dynamic>?,
            metadata['config'] as Map<String, dynamic>,
            guard,
          );
        } else {
          await live.save(
            item['child_id'] as String,
            id,
            row['original'] as Uint8List,
            row['processed'] as Uint8List,
            metadata['recognition'] as Map<String, dynamic>?,
            metadata['config'] as Map<String, dynamic>,
          );
        }
        await guard();
        await store.confirmImageDraft(owner, id);
        diagnostics.record(
          DiagnosticOperation.images,
          elapsed: watch.elapsed,
          scope: diagnosticScope,
        );
        _emit();
        onUploaded?.call(item['child_id'] as String);
      } catch (error) {
        if (_disposed || accountId() != owner) return;
        final authorization =
            !childInput && parentFamily() != family ||
            (error is PostgrestException && error.code == '42501');
        final network =
            isNetworkFailure(error) ||
            (error is StorageException &&
                const {'500', '502', '503', '504'}.contains(error.statusCode));
        diagnostics.record(
          DiagnosticOperation.images,
          outcome: authorization
              ? DiagnosticOutcome.authorization
              : error is StorageException &&
                    const {
                      '500',
                      '502',
                      '503',
                      '504',
                    }.contains(error.statusCode)
              ? DiagnosticOutcome.serverError
              : network
              ? diagnosticFailure(error)
              : DiagnosticOutcome.conflict,
          elapsed: watch.elapsed,
          error: error,
          scope: diagnosticScope,
        );
        final attempts = (item['attempts'] as int) + 1;
        await store.updateImageDraftState(
          owner,
          id,
          authorization
              ? 'needs_authorization'
              : network
              ? 'retry'
              : 'blocked',
          error: authorization
              ? childInput
                    ? '账号或家庭权限已变化，请重新登录核对'
                    : '需要重新验证家长 PIN'
              : network
              ? '网络中断，图片已保存本机，将自动重试'
              : '服务端未接受图片，请检查权限或清理记录后重试',
          attempts: attempts,
          nextAttempt: network
              ? DateTime.now()
                    .add(Duration(seconds: min(15, 2 << min(attempts - 1, 4))))
                    .millisecondsSinceEpoch
              : 0,
        );
        _emit();
        if (network || authorization) return;
      }
    }
  }

  Future<void> discard(
    String id,
    String family, {
    bool childInput = false,
  }) async {
    final owner = _owner();
    _check(owner, family, childInput: childInput);
    final row = await draft(id, family, childInput: childInput);
    _check(owner, row['family_id'] as String, childInput: childInput);
    await store.discardImageDraft(owner, id);
    _emit();
  }

  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    await _tail;
    await _events.close();
  }

  @override
  Future<Map<String, dynamic>?> provenance(String questionId) =>
      live.provenance(questionId);
  @override
  Future<String> imageUrl(String path) => live.imageUrl(path);
  @override
  Future<void> archiveMany(String childId, List<String> ids, bool enabled) =>
      live.archiveMany(childId, ids, enabled);
}
