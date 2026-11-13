import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/offline/network_failure.dart';
import '../../../core/offline/offline_store.dart';
import '../domain/question_filter.dart';
import 'review_repository.dart';

typedef QuestionCatalogScope = ({
  String child,
  String family,
  String kind,
  String subject,
  String mastery,
  String archive,
  String keyword,
});
Map<String, dynamic> catalogFilters(QuestionCatalogScope s) => {
  'kind': s.kind,
  'subject': s.subject,
  'mastery': s.mastery,
  'archive': s.archive,
  'keyword': s.keyword.trim(),
};
typedef CatalogFetch =
    Future<Map<String, dynamic>> Function(
      String child,
      Map<String, dynamic> filters,
      Map<String, dynamic>? cursor,
    );

class QuestionCatalogPage {
  const QuestionCatalogPage({
    required this.items,
    required this.syncedAt,
    this.next,
    this.offline = false,
    this.loadingMore = false,
    this.error,
  });
  final List<Map<String, dynamic>> items;
  final DateTime syncedAt;
  final Map<String, dynamic>? next;
  final bool offline, loadingMore;
  final String? error;
}

abstract interface class QuestionCatalogRepository {
  Future<QuestionCatalogPage> page(
    QuestionCatalogScope scope, [
    Map<String, dynamic>? cursor,
  ]);
  void dispose();
}

/// Adapter for injected in-memory repositories; production uses the bounded RPC.
class MemoryQuestionCatalog implements QuestionCatalogRepository {
  MemoryQuestionCatalog(this.review);
  final ReviewRepository review;
  @override
  void dispose() {}
  @override
  Future<QuestionCatalogPage> page(
    QuestionCatalogScope s, [
    Map<String, dynamic>? cursor,
  ]) async => QuestionCatalogPage(
    items: (await review.questions(s.child))
        .where(
          (r) =>
              (r['review_kind'] == 'pinyin') == (s.kind == 'pinyin') &&
              matchesQuestion(
                r,
                keyword: s.keyword,
                subject: s.subject,
                mastery: s.mastery,
                archive: s.archive,
              ),
        )
        .toList(),
    syncedAt: DateTime.now(),
  );
}

final questionCatalogRepositoryProvider = Provider<QuestionCatalogRepository>((
  ref,
) {
  final review = ref.watch(reviewRepositoryProvider);
  final live = review is CachedReviewRepository ? review.live : review;
  if (live is! SupabaseReviewRepository) return MemoryQuestionCatalog(review);
  final client = live.client;
  final repo = ScopedQuestionCatalog(
    store: review is CachedReviewRepository ? review.store : null,
    owner: () => client.auth.currentUser?.id,
    fetch: (child, filters, cursor) => client
        .rpc<Map<String, dynamic>>(
          'question_catalog_page',
          params: {
            'target_child_id': child,
            'filters': filters,
            'cursor': cursor,
          },
        )
        .timeout(const Duration(seconds: 15)),
  );
  ref.onDispose(repo.dispose);
  return repo;
});
final questionCatalogProvider = StateNotifierProvider.autoDispose
    .family<
      QuestionCatalogController,
      AsyncValue<QuestionCatalogPage>,
      QuestionCatalogScope
    >(
      (ref, scope) => QuestionCatalogController(
        ref.watch(questionCatalogRepositoryProvider),
        scope,
      ),
    );

class ScopedQuestionCatalog implements QuestionCatalogRepository {
  ScopedQuestionCatalog({
    required this.store,
    required this.owner,
    required this.fetch,
  });
  final OfflineStore? store;
  final String? Function() owner;
  final CatalogFetch fetch;
  bool _closed = false;
  final _requests = <String, int>{};
  @override
  void dispose() => _closed = true;
  String cacheKey(QuestionCatalogScope s) =>
      'review-page:${s.child}:${sha256.convert(utf8.encode(jsonEncode(catalogFilters(s))))}';
  @override
  Future<QuestionCatalogPage> page(
    QuestionCatalogScope s, [
    Map<String, dynamic>? cursor,
  ]) async {
    final account = owner(),
        key = cacheKey(s),
        privacy = store?.privacyGeneration,
        generation = store?.reviewGeneration(owner() ?? '');
    if (_closed || account == null) throw StateError('请重新登录后打开错题本');
    final request = (_requests[key] ?? 0) + 1;
    _requests[key] = request;
    Future<void> check() async {
      void current() {
        if (_closed ||
            owner() != account ||
            store?.privacyGeneration != privacy ||
            store?.reviewGeneration(account) != generation ||
            _requests[key] != request) {
          throw StateError('账号、资料或读取请求已变化，请刷新');
        }
      }

      current();
      if (store != null &&
          (await store!.accountDeletionJob(account) != null ||
              await store!.isChildDeleted(s.child) ||
              await store!.familyAccessRevoked(
                account,
                familyId: s.family,
                childId: s.child,
              ))) {
        throw StateError('当前孩子资料已不可访问');
      }
      current();
    }

    await check();
    Map<String, dynamic> data;
    var offline = false;
    try {
      data = await fetch(s.child, catalogFilters(s), cursor);
      await check();
      _validate(data, s, account);
      if (store != null && cursor == null) {
        await store!.transaction(() async {
          await check();
          await store!.writeReviewCache(account, key, data, generation!);
          await check();
          // Keep at most 12 recent first pages per child, including empty searches.
          await store!.customStatement(
            "DELETE FROM offline_cache WHERE owner=? AND cache_key IN (SELECT cache_key FROM offline_cache WHERE owner=? AND cache_key LIKE ? ORDER BY json_extract(payload,'\$.server_time') DESC,cache_key LIMIT -1 OFFSET 12)",
            [account, account, 'review-page:${s.child}:%'],
          );
          await check();
        });
      }
    } catch (error) {
      await check();
      if (!isNetworkFailure(error)) {
        if (store != null) await store!.remove(account, key);
        rethrow;
      }
      if (cursor != null || store == null) rethrow;
      final cached = await store!.read(account, key);
      await check();
      if (cached == null) rethrow;
      _validate(cached, s, account);
      data = cached;
      offline = true;
    }
    await check();
    return QuestionCatalogPage(
      items: (data['items'] as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList(),
      syncedAt: DateTime.parse(data['server_time'] as String),
      next: offline || data['next_cursor'] == null
          ? null
          : Map<String, dynamic>.from(data['next_cursor'] as Map),
      offline: offline,
    );
  }

  void _validate(
    Map<String, dynamic> data,
    QuestionCatalogScope s,
    String account,
  ) {
    if (data['owner_id'] != account ||
        data['child_id'] != s.child ||
        data['family_id'] != s.family ||
        data['filters'] is! Map ||
        (data['filters'] as Map).length != 5 ||
        catalogFilters(
          s,
        ).entries.any((e) => data['filters'][e.key] != e.value) ||
        data['server_time'] is! String ||
        DateTime.tryParse(data['server_time'] as String) == null ||
        data['items'] is! List ||
        (data['items'] as List).length > 50) {
      throw StateError('错题分页范围或格式不匹配');
    }
    final seen = <String>{};
    for (final r in data['items'] as List) {
      if (r is! Map ||
          r['id'] is! String ||
          !seen.add(r['id'] as String) ||
          r['child_id'] != s.child ||
          r['final_text'] is! String ||
          r['archived'] is! bool ||
          r['deleting'] == true ||
          r['review_kind'] != s.kind ||
          !matchesQuestion(
            Map<String, dynamic>.from(r),
            keyword: s.keyword,
            subject: s.subject,
            mastery: s.mastery,
            archive: s.archive,
          ) ||
          (r['review_due_at'] != null &&
              (r['review_due_at'] is! String ||
                  DateTime.tryParse(r['review_due_at'] as String) == null))) {
        throw StateError('错题记录不属于当前筛选');
      }
    }
    final next = data['next_cursor'];
    if (next != null) {
      final items = data['items'] as List;
      if (next is! Map ||
          items.length != 50 ||
          next['id'] != items.last['id'] ||
          next['archived'] != items.last['archived'] ||
          next['due_at'] != items.last['review_due_at']) {
        throw StateError('错题分页游标无效');
      }
    }
  }
}

class QuestionCatalogController
    extends StateNotifier<AsyncValue<QuestionCatalogPage>> {
  QuestionCatalogController(this.repository, this.scope)
    : super(const AsyncLoading()) {
    load();
  }
  final QuestionCatalogRepository repository;
  final QuestionCatalogScope scope;
  int _epoch = 0;
  Future<void> load({bool more = false}) async {
    final before = state.valueOrNull;
    if (more && (before == null || before.next == null || before.loadingMore)) {
      return;
    }
    final epoch = ++_epoch;
    state = more
        ? AsyncData(
            QuestionCatalogPage(
              items: before!.items,
              syncedAt: before.syncedAt,
              next: before.next,
              offline: before.offline,
              loadingMore: true,
            ),
          )
        : const AsyncLoading();
    try {
      final page = await repository.page(scope, more ? before!.next : null);
      if (!mounted || epoch != _epoch) return;
      final seen = <String>{};
      state = AsyncData(
        QuestionCatalogPage(
          items: [
            for (final r in [if (more) ...before!.items, ...page.items])
              if (seen.add(r['id'] as String)) r,
          ],
          syncedAt: page.syncedAt,
          next: page.next,
          offline: page.offline,
        ),
      );
    } catch (error, stack) {
      if (!mounted || epoch != _epoch) return;
      state = more && isNetworkFailure(error)
          ? AsyncData(
              QuestionCatalogPage(
                items: before!.items,
                syncedAt: before.syncedAt,
                next: before.next,
                error: '后续记录读取失败，已加载的记录保留，请重试。',
              ),
            )
          : AsyncError(error, stack);
    }
  }

  @override
  void dispose() {
    _epoch++;
    super.dispose();
  }
}
