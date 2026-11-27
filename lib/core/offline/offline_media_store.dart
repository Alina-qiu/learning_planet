import 'dart:convert';
import 'package:drift/drift.dart';
import 'offline_store.dart';

class PendingImageSelection implements Exception {
  const PendingImageSelection(this.requestId);
  final String requestId;
}

extension OfflineMediaStore on OfflineStore {
  static const _pickerKey = 'native-image-picker';

  /// Android has one lost-result slot for the entire installation. Only the
  /// scope that opened the picker may consume it, even after a process restart.
  Future<String> openImagePicker(
    String owner,
    String family,
    String child,
    String requestId, {
    required bool childInput,
    required bool recover,
    String? replaceRequest,
    required Future<void> Function() discardUnclaimed,
  }) => transaction(() async {
    final pending = await customSelect(
      'SELECT owner FROM offline_cache WHERE cache_key=? LIMIT 1',
      variables: [Variable(_pickerKey)],
    ).getSingleOrNull();
    if (pending != null) {
      final previousOwner = pending.read<String>('owner');
      final previous = await read(previousOwner, _pickerKey);
      if (previous != null) {
        if (recover &&
            previousOwner == owner &&
            previous['family_id'] == family &&
            previous['child_id'] == child &&
            previous['child_input'] == childInput) {
          return previous['request_id'] as String;
        }
        if (recover) throw StateError('请在上次选图的账号、孩子和录入模式中恢复图片');
        if (replaceRequest == null) {
          throw PendingImageSelection(previous['request_id'] as String);
        }
        if (replaceRequest != previous['request_id']) {
          throw StateError('本机选图状态已变化，请重新选择');
        }
      }
      // The old scope is no longer accessible, or replacement was confirmed.
      await remove(previousOwner, _pickerKey);
    }
    if (recover) throw StateError('没有属于当前账号、孩子和录入模式的图片选择，请重新选图');
    // The new scope is not committed until the old native receipt is drained.
    await write(owner, _pickerKey, {
      'family_id': family,
      'child_id': child,
      'child_input': childInput,
      'request_id': requestId,
    });
    await discardUnclaimed();
    return requestId;
  });

  Future<void> finishImagePicker(
    String owner,
    String requestId,
  ) => customStatement(
    "DELETE FROM offline_cache WHERE owner=? AND cache_key=? AND json_extract(payload,'\$.request_id')=?",
    [owner, _pickerKey, requestId],
  );

  static const _directoryVisible = """NOT EXISTS (SELECT 1 FROM offline_cache h
    WHERE h.owner=d.owner AND h.cache_key IN
      ('directory-hidden:child:' || d.child_id, 'directory-hidden:family:' || d.family_id))""";

  Future<void> updateImageDraftMetadata(
    String owner,
    String child,
    String family,
    String id,
    Map<String, dynamic> metadata,
  ) => transaction(() async {
    if (await accountDeletionJob(owner) != null ||
        await isChildDeleted(child) ||
        await familyAccessRevoked(owner, familyId: family, childId: child)) {
      throw StateError('账号或孩子已删除');
    }
    final encoded = jsonEncode(metadata);
    if (utf8.encode(encoded).length > 2097152) throw StateError('草稿文字过大');
    final mode = await customSelect(
      "SELECT json_extract(metadata,'\$.requires_parent_review') mode FROM image_drafts WHERE owner=? AND draft_id=?",
      variables: [Variable(owner), Variable(id)],
    ).getSingleOrNull();
    if (mode != null &&
        (mode.data['mode'] == 1) !=
            (metadata['requires_parent_review'] == true)) {
      throw StateError('草稿录入模式不能更改');
    }
    final count = await customUpdate(
      "UPDATE image_drafts SET metadata=?,updated_at=? WHERE owner=? AND child_id=? AND family_id=? AND draft_id=? AND stage='editing'",
      variables: [
        Variable(encoded),
        Variable(DateTime.now().millisecondsSinceEpoch),
        Variable(owner),
        Variable(child),
        Variable(family),
        Variable(id),
      ],
    );
    if (count != 1) throw StateError('草稿已移除或已进入上传队列');
  });
  Future<List<Map<String, dynamic>>> imageDrafts(
    String owner, {
    String? childId,
  }) async {
    if (await accountDeletionJob(owner) != null) return [];
    final rows = await customSelect(
      "SELECT owner,draft_id,child_id,family_id,stage,attempts,next_attempt,error,updated_at,json_extract(metadata,'\$.requires_parent_review') requires_parent_review,json_extract(metadata,'\$.import_index') import_index,json_extract(metadata,'\$.import_count') import_count FROM image_drafts d WHERE owner=? AND $_directoryVisible${childId == null ? '' : ' AND child_id=?'} ORDER BY coalesce(json_extract(metadata,'\$.import_created_at'),updated_at),json_extract(metadata,'\$.import_batch'),import_index,draft_id",
      variables: [Variable(owner), if (childId != null) Variable(childId)],
    ).get();
    return [for (final row in rows) row.data];
  }

  Future<bool> hasImageDraft(String owner, String id) async =>
      await customSelect(
        'SELECT draft_id FROM image_drafts WHERE owner=? AND draft_id=?',
        variables: [Variable(owner), Variable(id)],
      ).getSingleOrNull() !=
      null;

  Future<Map<String, dynamic>?> imageDraft(String owner, String id) =>
      _findImageDraft(owner, id, includeHidden: false);

  Future<Map<String, dynamic>?> _findImageDraft(
    String owner,
    String id, {
    required bool includeHidden,
  }) async {
    if (await accountDeletionJob(owner) != null) return null;
    final row = await customSelect(
      "SELECT * FROM image_drafts d WHERE owner=? AND draft_id=?${includeHidden ? '' : ' AND $_directoryVisible'}",
      variables: [Variable(owner), Variable(id)],
    ).getSingleOrNull();
    return row == null
        ? null
        : {...row.data, 'metadata': jsonDecode(row.read<String>('metadata'))};
  }

  Future<void> writeImageDraft(
    String owner,
    String child,
    String family,
    String id,
    Map<String, dynamic> metadata,
    Uint8List? original,
    Uint8List? processed, {
    bool queue = false,
  }) => transaction(() async {
    if (await accountDeletionJob(owner) != null ||
        await isChildDeleted(child) ||
        await familyAccessRevoked(owner, familyId: family, childId: child)) {
      throw StateError('账号或孩子已删除');
    }
    if (await customSelect(
          'SELECT draft_id FROM discarded_image_drafts WHERE owner=? AND draft_id=?',
          variables: [Variable(owner), Variable(id)],
        ).getSingleOrNull() !=
        null) {
      throw StateError('本机草稿已删除');
    }
    final old = await _findImageDraft(owner, id, includeHidden: true);
    if (old != null &&
        (old['child_id'] != child || old['family_id'] != family)) {
      throw StateError('草稿不属于当前孩子');
    }
    if (old != null &&
        ((old['metadata'] as Map)['requires_parent_review'] == true) !=
            (metadata['requires_parent_review'] == true)) {
      throw StateError('草稿录入模式不能更改');
    }
    final encoded = jsonEncode(metadata);
    if (utf8.encode(encoded).length > 2097152) throw StateError('草稿文字过大');
    if (old != null && old['stage'] != 'editing') {
      bool same(Uint8List? a, Uint8List? b) {
        if (a == null || b == null) return a == b;
        if (a.length != b.length) return false;
        for (var i = 0; i < a.length; i++) {
          if (a[i] != b[i]) return false;
        }
        return true;
      }

      if (queue &&
          encoded == jsonEncode(old['metadata']) &&
          same(original, old['original'] as Uint8List?) &&
          same(processed, old['processed'] as Uint8List?)) {
        return;
      }
      throw StateError('已加入上传队列的草稿不能改写，请查看上传状态');
    }
    final bytes = original ?? old?['original'] as Uint8List?;
    if (bytes == null ||
        bytes.length > 10485760 ||
        (processed?.length ?? 0) > 10485760) {
      throw StateError('请选择有效且不超过10MB的图片');
    }
    final totals = await customSelect(
      'SELECT count(*) count,coalesce(sum(length(original)+coalesce(length(processed),0)),0) size FROM image_drafts WHERE owner=? AND draft_id<>?',
      variables: [Variable(owner), Variable(id)],
    ).getSingle();
    if (totals.read<int>('count') >= 50 ||
        totals.read<int>('size') + bytes.length + (processed?.length ?? 0) >
            104857600) {
      throw StateError('本机草稿已达50条或100MB，请上传或清理后再保存');
    }
    if (queue &&
        (processed == null ||
            metadata['consent'] != true ||
            ((metadata['config'] as Map?)?['requires_parent_review'] == true) !=
                (metadata['requires_parent_review'] == true) ||
            (metadata['config'] as Map?)?['ocr_confirmed'] != true)) {
      throw StateError('请完成图片校对并同意上传');
    }
    await customStatement(
      'INSERT INTO image_drafts(owner,draft_id,child_id,family_id,stage,metadata,original,processed,updated_at) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(owner,draft_id) DO UPDATE SET stage=excluded.stage,metadata=excluded.metadata,processed=excluded.processed,updated_at=excluded.updated_at',
      [
        owner,
        id,
        child,
        family,
        queue ? 'queued' : 'editing',
        encoded,
        bytes,
        processed,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  });
  Future<void> updateImageDraftState(
    String owner,
    String id,
    String stage, {
    String? error,
    int attempts = 0,
    int nextAttempt = 0,
  }) => customStatement(
    "UPDATE image_drafts SET stage=?,error=?,attempts=?,next_attempt=?,updated_at=? WHERE owner=? AND draft_id=? AND stage<>'editing'",
    [
      stage,
      error,
      attempts,
      nextAttempt,
      DateTime.now().millisecondsSinceEpoch,
      owner,
      id,
    ],
  );
  Future<void> discardImageDraft(String owner, String id) =>
      transaction(() async {
        await customStatement(
          'INSERT OR IGNORE INTO discarded_image_drafts VALUES(?,?)',
          [owner, id],
        );
        await customStatement(
          'DELETE FROM image_drafts WHERE owner=? AND draft_id=?',
          [owner, id],
        );
      });
  // Successful upload erases local image/answer bytes and leaves a replay barrier.
  Future<void> confirmImageDraft(String owner, String id) =>
      discardImageDraft(owner, id);
}
