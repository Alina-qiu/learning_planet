import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as image;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/offline_task_repository.dart';
import '../data/review_repository.dart';
import '../../auth_family/application/family_providers.dart';
import 'offline_question_media_repository.dart';
import '../domain/ocr_fields.dart';
import 'question_catalog.dart';

abstract interface class QuestionImageService {
  Future<Uint8List?> pick(bool camera);
  Future<List<Uint8List>> pickMany();
  Future<List<Uint8List>> recover();
  Future<Uint8List> process(
    Uint8List original,
    int turns,
    List<double> crop, {
    bool enhance = false,
  });
  Future<Map<String, dynamic>> recognize(Uint8List processed);
}

final questionImageServiceProvider = Provider<QuestionImageService>(
  (_) => DeviceQuestionImageService(),
);
final questionMediaRepositoryProvider = Provider<QuestionMediaRepository>((
  ref,
) {
  final tasks = ref.watch(taskRepositoryProvider);
  final client = taskSupabaseClient(tasks);
  if (client == null) throw StateError('请配置 Supabase');
  final live = SupabaseQuestionMediaRepository(
    client,
    ref.watch(reviewRepositoryProvider),
  );
  if (tasks is! OfflineTaskRepository) return live;
  final repository = OfflineQuestionMediaRepository(
    store: tasks.store,
    live: live,
    accountId: tasks.accountId,
    parentFamily: () => ref.read(activeParentFamilyProvider),
    onUploaded: (child) {
      ref.invalidate(questionCatalogRepositoryProvider);
      ref.invalidate(reviewQuestionsProvider(child));
      ref.invalidate(reviewOverviewProvider(child));
    },
  );
  ref.onDispose(() => unawaited(repository.dispose()));
  return repository;
});

final imageDraftChangesProvider = StreamProvider<int>((ref) async* {
  final repository = ref.watch(questionMediaRepositoryProvider);
  if (repository is OfflineQuestionMediaRepository) {
    yield repository.revision;
    yield* repository.changes;
  }
});
final imageDraftsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, ({String child, String family})>((
      ref,
      scope,
    ) {
      ref.watch(imageDraftChangesProvider);
      ref.watch(activeParentFamilyProvider);
      final repository = ref.watch(questionMediaRepositoryProvider);
      return repository is OfflineQuestionMediaRepository
          ? repository.drafts(
              scope.child,
              scope.family,
              includeChildDrafts: true,
            )
          : Future.value([]);
    });

/// Runs in a worker isolate; normalized crop follows the rotated image.
final questionProvenanceProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>(
      (ref, id) => ref.watch(questionMediaRepositoryProvider).provenance(id),
    );
final questionImageUrlProvider = FutureProvider.autoDispose
    .family<String, String>(
      (ref, path) => ref.watch(questionMediaRepositoryProvider).imageUrl(path),
    );

void validateQuestionImage(Uint8List bytes) {
  if (bytes.length > 10485760 || !isQuestionImage(bytes)) {
    throw ArgumentError('图片须为不超过10MB的JPEG/PNG');
  }
  final info = image.findDecoderForData(bytes)?.startDecode(bytes);
  if (info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > 24000000) {
    throw ArgumentError('图片无效或超过2400万像素，请选择较小图片');
  }
}

Uint8List processQuestionImage(Map<String, dynamic> input) {
  final bytes = input['bytes'] as Uint8List;
  if (bytes.length > 10 * 1024 * 1024) throw ArgumentError('图片不得超过10MB');
  if (!isQuestionImage(bytes)) throw ArgumentError('仅支持 JPEG/PNG');
  final decoder = image.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null || info.width * info.height > 24000000) {
    throw ArgumentError('图片无效或超过2400万像素，请选择较小图片');
  }
  var decoded = decoder!.decodeFrame(0);
  if (decoded == null) throw ArgumentError('图片解码失败');
  decoded = image.bakeOrientation(decoded);
  final turns = input['turns'] as int;
  if (turns % 4 != 0) {
    decoded = image.copyRotate(decoded, angle: (turns % 4) * 90);
  }
  final crop = (input['crop'] as List).cast<double>();
  if (crop.length != 4 ||
      crop.any((v) => !v.isFinite || v < 0 || v > 1) ||
      crop[2] <= crop[0] ||
      crop[3] <= crop[1]) {
    throw ArgumentError('裁剪范围无效');
  }
  final x = (crop[0] * decoded.width).floor();
  final y = (crop[1] * decoded.height).floor();
  final width = ((crop[2] - crop[0]) * decoded.width).floor();
  final height = ((crop[3] - crop[1]) * decoded.height).floor();
  if (width < 16 || height < 16) throw ArgumentError('裁剪范围太小');
  decoded = image.copyCrop(decoded, x: x, y: y, width: width, height: height);
  if (input['enhance'] == true) {
    decoded = image.adjustColor(decoded, contrast: 1.2);
  }
  if (decoded.width > 2048 || decoded.height > 2048) {
    decoded = image.copyResize(
      decoded,
      width: decoded.width >= decoded.height ? 2048 : null,
      height: decoded.height > decoded.width ? 2048 : null,
    );
  }
  // Rebuild pixels rather than carrying EXIF/GPS into the processed image.
  final clean = image.Image(width: decoded.width, height: decoded.height);
  // PNGs from scanners/exports can have a transparent background. JPEG has
  // no alpha: flatten onto white so black text does not become black-on-black.
  image.fill(clean, color: image.ColorRgb8(255, 255, 255));
  image.compositeImage(clean, decoded);
  return Uint8List.fromList(image.encodeJpg(clean, quality: 90));
}

class DeviceQuestionImageService implements QuestionImageService {
  DeviceQuestionImageService({ImagePicker? picker})
    : _picker = picker ?? ImagePicker();
  final ImagePicker _picker;
  static const batchLimit = 10;

  Future<List<Uint8List>> _readSelection(List<XFile> files) async {
    // Platforms may ignore the native picker's limit. Never silently truncate
    // recovered files or allocate an unbounded collection of image bytes.
    if (files.length > batchLimit) throw StateError('每次最多导入10张图片，请减少选择');
    final result = <Uint8List>[];
    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      if (await file.length() > 10485760) {
        throw StateError('第${index + 1}张图片超过10MB，本次未导入');
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > 10485760 || !isQuestionImage(bytes)) {
        throw StateError('第${index + 1}张图片须为不超过10MB的JPEG/PNG，本次未导入');
      }
      try {
        await compute(validateQuestionImage, bytes);
      } catch (_) {
        throw StateError('第${index + 1}张图片无效或超过2400万像素，本次未导入');
      }
      result.add(bytes);
    }
    return result;
  }

  @override
  Future<List<Uint8List>> pickMany() async => _readSelection(
    await _picker.pickMultiImage(limit: batchLimit, requestFullMetadata: false),
  );

  @override
  Future<List<Uint8List>> recover() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return [];
    final response = await _picker.retrieveLostData();
    if (response.exception != null) throw response.exception!;
    return _readSelection(
      response.files ?? [if (response.file != null) response.file!],
    );
  }

  @override
  Future<Uint8List?> pick(bool camera) async {
    final file = await _picker.pickImage(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      requestFullMetadata: false,
    );
    if (file == null) return null;
    if (await file.length() > 10 * 1024 * 1024) throw StateError('图片不得超过10MB');
    final bytes = await file.readAsBytes();
    // Original bytes remain untouched; only JPEG/PNG can be uploaded.
    if (!isQuestionImage(bytes)) throw StateError('请选择 JPEG 或 PNG 图片');
    return bytes;
  }

  @override
  Future<Uint8List> process(
    Uint8List original,
    int turns,
    List<double> crop, {
    bool enhance = false,
  }) => compute(processQuestionImage, {
    'bytes': original,
    'turns': turns,
    'crop': crop,
    'enhance': enhance,
  });
  @override
  Future<Map<String, dynamic>> recognize(Uint8List processed) async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
      throw StateError('设备端 OCR 仅支持 Android/iOS，可转手工录入');
    }
    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}/question-ocr-${const Uuid().v4()}.jpg',
    );
    final recognizer = TextRecognizer(script: TextRecognitionScript.chinese);
    try {
      await file.writeAsBytes(processed, flush: true);
      final result = await recognizer.processImage(
        InputImage.fromFilePath(file.path),
      );
      if (result.text.trim().isEmpty) throw StateError('未识别到文字，请重拍、裁剪或手工录入');
      return structureQuestionOcr({
        'provider': 'mlkit-device-chinese',
        'text': result.text,
        'lines': [
          for (final block in result.blocks)
            for (final line in block.lines)
              {
                'text': line.text,
                'confidence': line.confidence,
                'box': [
                  line.boundingBox.left,
                  line.boundingBox.top,
                  line.boundingBox.right,
                  line.boundingBox.bottom,
                ],
              },
        ],
      });
    } finally {
      try {
        await recognizer.close();
      } finally {
        if (await file.exists()) await file.delete();
      }
    }
  }
}

bool isQuestionImage(Uint8List bytes) =>
    bytes.length >= 8 &&
    ((bytes[0] == 255 && bytes[1] == 216 && bytes[2] == 255) ||
        (bytes[0] == 137 &&
            bytes[1] == 80 &&
            bytes[2] == 78 &&
            bytes[3] == 71 &&
            bytes[4] == 13 &&
            bytes[5] == 10 &&
            bytes[6] == 26 &&
            bytes[7] == 10));

abstract interface class QuestionMediaRepository {
  Future<void> save(
    String childId,
    String draftId,
    Uint8List original,
    Uint8List processed,
    Map<String, dynamic>? recognition,
    Map<String, dynamic> config,
  );
  Future<Map<String, dynamic>?> provenance(String questionId);
  Future<String> imageUrl(String path);
  Future<void> archiveMany(String childId, List<String> ids, bool enabled);
}

abstract interface class GuardedQuestionMediaRepository {
  Future<void> saveGuarded(
    String childId,
    String draftId,
    Uint8List original,
    Uint8List processed,
    Map<String, dynamic>? recognition,
    Map<String, dynamic> config,
    Future<void> Function() guard,
  );
}

String mediaPayloadHash(Map<String, dynamic> input) {
  dynamic sorted(dynamic value) => value is Map
      ? {
          for (final key in value.keys.cast<String>().toList()..sort())
            key: sorted(value[key]),
        }
      : value is List
      ? value.map(sorted).toList()
      : value;
  return sha256
      .convert(
        utf8.encode(
          jsonEncode(
            sorted({
              ...input,
              'original': sha256
                  .convert(input['original'] as Uint8List)
                  .toString(),
              'processed': sha256
                  .convert(input['processed'] as Uint8List)
                  .toString(),
            }),
          ),
        ),
      )
      .toString();
}

class SupabaseQuestionMediaRepository
    implements QuestionMediaRepository, GuardedQuestionMediaRepository {
  SupabaseQuestionMediaRepository(this.client, this.review);
  final SupabaseClient client;
  final ReviewRepository review;
  @override
  Future<void> save(
    String childId,
    String draftId,
    Uint8List original,
    Uint8List processed,
    Map<String, dynamic>? recognition,
    Map<String, dynamic> config,
  ) => saveGuarded(
    childId,
    draftId,
    original,
    processed,
    recognition,
    config,
    () async {},
  );
  @override
  Future<void> saveGuarded(
    String childId,
    String draftId,
    Uint8List original,
    Uint8List processed,
    Map<String, dynamic>? recognition,
    Map<String, dynamic> config,
    Future<void> Function() guard,
  ) async {
    if (!isQuestionImage(original) ||
        !isQuestionImage(processed) ||
        original.length > 10485760 ||
        processed.length > 10485760) {
      throw StateError('图片格式或大小无效');
    }
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('请先登录');
    Future<void> check() async {
      if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
      await guard();
      if (client.auth.currentUser?.id != owner) throw StateError('登录账号已变化');
    }

    final fingerprint = await compute(mediaPayloadHash, {
      'child': childId,
      'original': original,
      'processed': processed,
      'recognition': recognition,
      'config': config,
    });
    final childInput = config['requires_parent_review'] == true;
    await check();
    final draft = await client
        .rpc<Map<String, dynamic>>(
          childInput
              ? 'begin_child_question_upload'
              : 'begin_question_media_upload',
          params: {
            'target_child_id': childId,
            'draft_id': draftId,
            'payload_hash': fingerprint,
          },
        )
        .timeout(const Duration(seconds: 15));
    await check();
    if (draft['status'] == 'pending') {
      Future<void> upload(String path, Uint8List bytes) async {
        await check();
        try {
          await client.storage
              .from('wrong-question-images')
              .uploadBinary(
                path,
                bytes,
                fileOptions: FileOptions(
                  contentType: bytes[0] == 137 ? 'image/png' : 'image/jpeg',
                  upsert: false,
                ),
              )
              .timeout(const Duration(seconds: 30));
        } on StorageException catch (error) {
          // Stable draft paths are insert-only. A lost response can safely retry.
          if (error.statusCode != '409' && error.error != 'Duplicate') rethrow;
        }
      }

      await upload(draft['original_path'] as String, original);
      await upload(draft['processed_path'] as String, processed);
      await check();
      if (!childInput) {
        await client
            .rpc<void>(
              recognition == null
                  ? 'manual_question_ocr'
                  : 'record_question_ocr',
              params: {
                'target_draft_id': draftId,
                if (recognition != null) 'result': recognition,
              },
            )
            .timeout(const Duration(seconds: 15));
      }
    }
    await check();
    if (childInput) {
      final receipt = await client
          .rpc<Map<String, dynamic>>(
            'submit_child_question',
            params: {
              'target_draft_id': draftId,
              'config': config,
              'recognition': recognition,
            },
          )
          .timeout(const Duration(seconds: 15));
      if (receipt['owner_id'] != owner ||
          receipt['child_id'] != childId ||
          receipt['draft_id'] != draftId ||
          !['pending', 'approved'].contains(receipt['state'])) {
        throw StateError('提交回执不匹配，请保留本机草稿并重试');
      }
    } else {
      await review
          .save(childId, {...config, 'ocr_draft_id': draftId})
          .timeout(const Duration(seconds: 15));
    }
    await check();
  }

  @override
  Future<Map<String, dynamic>?> provenance(String questionId) => client
      .from('question_ocr_drafts')
      .select()
      .eq('question_id', questionId)
      .maybeSingle();
  @override
  Future<String> imageUrl(String path) =>
      client.storage.from('wrong-question-images').createSignedUrl(path, 300);
  @override
  Future<void> archiveMany(String childId, List<String> ids, bool enabled) =>
      client.rpc<void>(
        'archive_review_questions',
        params: {
          'target_child_id': childId,
          'question_ids': ids,
          'enabled': enabled,
        },
      );
}
