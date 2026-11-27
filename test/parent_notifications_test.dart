import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Family;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/core/offline/offline_media_store.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/domain/family.dart';
import 'package:learning_planet/features/notifications/domain/parent_notification.dart';
import 'package:learning_planet/features/notifications/domain/offline_notification_policy.dart';
import 'package:learning_planet/features/notifications/data/parent_notification_repository.dart';
import 'package:learning_planet/features/notifications/data/parent_notification_device.dart';
import 'package:learning_planet/features/notifications/presentation/parent_notifications_screen.dart';
import 'package:learning_planet/features/tasks/data/notification_scheduler.dart';
import 'package:learning_planet/features/tasks/data/offline_task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_repository.dart';
import 'package:learning_planet/features/tasks/data/task_sync_remote.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/wrong_questions/data/question_media_repository.dart';
import 'package:learning_planet/features/wrong_questions/data/offline_question_media_repository.dart';
import 'support/mock_supabase.dart';
import 'remote_parent_push_test.dart' as push_test;
import 'package:learning_planet/features/notifications/data/remote_parent_push.dart';

class _Remote extends Mock implements TaskSyncRemote {}

class _Media extends Mock implements QuestionMediaRepository {}

Map<String, dynamic> _settings({bool enabled = true, bool sync = false}) => {
  'enabled': enabled,
  'redemptions': true,
  'sync_errors': sync,
  'weekly_reports': true,
  'quiet_start': '21:00:00',
  'quiet_end': '07:00:00',
  'version': 2,
};
Map<String, dynamic> _message(
  String key, {
  String child = 'child',
  String kind = 'redemption',
  bool read = false,
}) => {
  'notification_key': key,
  'child_id': child,
  'kind': kind,
  'created_at': '2026-11-02T01:00:00Z',
  'anchor_date': kind == 'weekly' ? '2026-11-01' : null,
  'read_at': read ? '2026-11-02T02:00:00Z' : null,
};
Map<String, dynamic> _inbox({List<Map<String, dynamic>>? items}) => {
  'family_id': 'family',
  'timezone': 'Asia/Shanghai',
  'settings': _settings(),
  'items': items ?? [_message('redeem'), _message('week', kind: 'weekly')],
};
ParentDelivery _delivery({
  bool enabled = true,
  bool quiet = false,
  bool sync = false,
  List<Map<String, dynamic>>? items,
  Map<String, dynamic>? policy,
}) => ParentDelivery.fromJson({
  'family_id': 'family',
  'quiet': quiet,
  'settings': _settings(enabled: enabled, sync: sync),
  'offline_policy': policy,
  'items': items ?? [_message('redeem'), _message('week', kind: 'weekly')],
});

Map<String, dynamic> _policy({
  DateTime? issued,
  String timezone = 'Asia/Shanghai',
  List<String> children = const ['child'],
  Map<String, dynamic>? settings,
}) {
  final start = issued ?? DateTime.utc(2026, 11, 4);
  return {
    'schema': 1,
    'purpose': 'local_sync_notice',
    'family_id': 'family',
    'timezone': timezone,
    'settings': settings ?? _settings(sync: true),
    'child_ids': children,
    'issued_at': start.toIso8601String(),
    'expires_at': start.add(const Duration(days: 7)).toIso8601String(),
  };
}

class _Repository implements ParentNotificationRepository {
  ParentInbox inbox = ParentInbox.fromJson(_inbox());
  ParentDelivery feed = _delivery();
  final read = <List<String>>[], delivered = <List<String>>[];
  ParentNotificationSettings? saved;
  bool failAck = false;
  Object? loadFailure, deliveryFailure, saveFailure;
  Completer<ParentInbox>? loadWaiting;
  Completer<ParentNotificationSettings>? saveWaiting;
  Completer<void>? saveEntered;
  Completer<ParentDelivery>? waiting;
  Completer<void>? entered;
  @override
  Future<ParentInbox> load(String familyId) async {
    if (loadFailure case final error?) throw error;
    return loadWaiting == null ? inbox : await loadWaiting!.future;
  }

  @override
  Future<ParentDelivery> delivery(String familyId) async {
    if (deliveryFailure case final error?) throw error;
    if (waiting == null) return feed;
    if (entered != null && !entered!.isCompleted) entered!.complete();
    return await waiting!.future;
  }

  @override
  Future<ParentNotificationSettings> save(
    String familyId,
    ParentNotificationSettings settings,
  ) async {
    saved = settings;
    if (saveFailure case final error?) throw error;
    if (saveWaiting != null) {
      saveEntered?.complete();
      return await saveWaiting!.future;
    }
    return settings;
  }

  @override
  Future<void> markRead(String familyId, List<String> keys) async {
    if (failAck) throw StateError('response lost');
    read.add(List.of(keys));
    inbox = ParentInbox.fromJson(
      _inbox(
        items: [
          _message('redeem', read: true),
          _message('week', kind: 'weekly'),
        ],
      ),
    );
  }

  @override
  Future<void> markDelivered(String familyId, List<String> keys) async {
    delivered.add(List.of(keys));
    if (failAck) throw StateError('response lost');
  }
}

class _Scheduler implements NotificationScheduler, ParentMessageScheduler {
  final scopes = <String?>[], batches = <Set<String>>[];
  bool permission = true, success = true;
  Completer<bool>? permissionResult;
  Completer<void>? permissionEntered;
  @override
  Future<bool> requestPermission() async {
    permissionEntered?.complete();
    return permissionResult == null
        ? permission
        : await permissionResult!.future;
  }

  @override
  Future<void> setScope(String? scope) async {
    scopes.add(scope);
  }

  @override
  Future<void> synchronize(
    String child,
    List<Map<String, dynamic>> rows,
  ) async {}
  @override
  Future<bool> showParentMessages(String scope, Set<String> kinds) async {
    batches.add(Set.of(kinds));
    return success;
  }
}

class _Device extends Fake implements ParentNotificationDevice {
  bool enabled = true;
  final changes = <bool>[];
  @override
  Future<bool> isParentMode(String family) async => enabled;
  @override
  Future<bool> setParentMode(
    String family,
    bool value, {
    bool Function()? canConfigure,
  }) async {
    if (canConfigure?.call() == false) {
      throw StateError('authorization expired');
    }
    changes.add(value);
    enabled = value;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'offline policy uses family quiet hours across midnight, daylight saving and network uncertainty',
    () {
      final p = OfflineNotificationPolicy.fromJson(_policy());
      expect(p.quietAt(DateTime.utc(2026, 11, 4, 12, 59)), isFalse);
      expect(p.quietAt(DateTime.utc(2026, 11, 4, 13)), isTrue);
      expect(p.quietAt(DateTime.utc(2026, 11, 4, 22, 59)), isTrue);
      expect(p.quietAt(DateTime.utc(2026, 11, 4, 23)), isFalse);
      final ny = OfflineNotificationPolicy.fromJson(
        _policy(
          timezone: 'America/New_York',
          settings: {
            ..._settings(sync: true),
            'quiet_start': '01:00',
            'quiet_end': '02:00',
          },
        ),
      );
      expect(ny.quietAt(DateTime.utc(2026, 11, 1, 5, 30)), isTrue);
      expect(ny.quietAt(DateTime.utc(2026, 11, 1, 6, 30)), isTrue);
      final skipped = OfflineNotificationPolicy.fromJson(
        _policy(
          timezone: 'America/New_York',
          settings: {
            ..._settings(sync: true),
            'quiet_start': '02:00',
            'quiet_end': '03:00',
          },
        ),
      );
      expect(skipped.quietAt(DateTime.utc(2026, 3, 8, 6, 59)), isFalse);
      expect(skipped.quietAt(DateTime.utc(2026, 3, 8, 7)), isFalse);
      final daytime = OfflineNotificationPolicy.fromJson(
        _policy(
          settings: {
            ..._settings(sync: true),
            'quiet_start': '09:00',
            'quiet_end': '17:00',
          },
        ),
      );
      expect(daytime.quietAt(DateTime.utc(2026, 11, 4, 1)), isTrue);
      expect(daytime.quietAt(DateTime.utc(2026, 11, 4, 9)), isFalse);
      final noQuiet = OfflineNotificationPolicy.fromJson(
        _policy(
          settings: {
            ..._settings(sync: true),
            'quiet_start': '00:00',
            'quiet_end': '00:00',
          },
        ),
      );
      expect(noQuiet.quietAt(DateTime.utc(2026, 11, 4)), isFalse);
      final started = DateTime.utc(2001),
          received = DateTime.utc(2001).add(const Duration(seconds: 10));
      for (final hour in [12, 22]) {
        final nearBoundary = OfflineNotificationPolicy.fromJson(
          _policy(issued: DateTime.utc(2026, 11, 4, hour, 59, 55)),
        );
        final cached = CachedNotificationPolicy(
          policy: nearBoundary,
          requestStartedAt: started,
          receivedAt: received,
        );
        expect(cached.validAt(received), isTrue);
        expect(cached.allowsSync('family', 'child', received), isFalse);
      }
    },
  );
  test(
    'offline policy rejects unsupported, expired or corrupt leases and backwards clocks',
    () {
      final baseline = _policy(), issued = DateTime.utc(2026, 11, 4);
      for (final raw in [
        {...baseline, 'schema': 2},
        {...baseline, 'purpose': 'reward_approval'},
        {
          ...baseline,
          'expires_at': issued.add(const Duration(days: 8)).toIso8601String(),
        },
        {...baseline, 'expires_at': issued.toIso8601String()},
        {...baseline, 'issued_at': '2026-11-04T00:00:00'},
        {...baseline, 'timezone': 'Unknown/Place'},
        {
          ...baseline,
          'child_ids': ['child', 'child'],
        },
        {
          ...baseline,
          'settings': {..._settings(sync: true), 'quiet_start': '24:00'},
        },
        {
          ...baseline,
          'settings': {..._settings(sync: true), 'quiet_end': '07:00:30'},
        },
      ]) {
        expect(
          () => OfflineNotificationPolicy.fromJson(raw),
          throwsA(anything),
        );
      }
      final p = OfflineNotificationPolicy.fromJson(baseline);
      final cached = CachedNotificationPolicy(
        policy: p,
        requestStartedAt: issued,
        receivedAt: issued,
        observedAt: issued.add(const Duration(hours: 2)),
      );
      expect(cached.validAt(issued.add(const Duration(hours: 1))), isFalse);
      expect(cached.validAt(issued.add(const Duration(days: 7))), isFalse);
      expect(
        cached.allowsSync(
          'other',
          'child',
          issued.add(const Duration(hours: 3)),
        ),
        isFalse,
      );
      expect(
        cached.allowsSync(
          'family',
          'other',
          issued.add(const Duration(hours: 3)),
        ),
        isFalse,
      );
      expect(
        () => CachedNotificationPolicy(
          policy: p,
          requestStartedAt: issued,
          receivedAt: issued.add(const Duration(seconds: 31)),
        ),
        throwsFormatException,
      );
      expect(
        () => CachedNotificationPolicy(
          policy: p,
          requestStartedAt: issued,
          receivedAt: issued.subtract(const Duration(seconds: 1)),
        ),
        throwsFormatException,
      );
      final restored = CachedNotificationPolicy.fromJson(cached.toJson());
      expect(restored.policy.childIds, {'child'});
      expect(restored.policy.toJson(), p.toJson());
    },
  );
  test(
    'settings validate time, parse categories and expose exact week without private notification text',
    () {
      final settings = ParentNotificationSettings.fromJson(_settings());
      expect(settings.toConfig()['quiet_start'], '21:00');
      expect(settings.version, 2);
      expect(
        () => const ParentNotificationSettings(quietStart: '24:00').toConfig(),
        throwsFormatException,
      );
      expect(
        () => const ParentNotificationSettings(quietEnd: '8:00').toConfig(),
        throwsFormatException,
      );
      final inbox = ParentInbox.fromJson(_inbox());
      expect(inbox.unread, 2);
      expect(inbox.items.last.detail, contains('2026-11-01'));
      expect(inbox.items.first.detail, contains('不会审批'));
      expect(
        () => ParentMessage.fromJson({
          ..._message('x', kind: 'weekly'),
          'anchor_date': null,
        }),
        throwsFormatException,
      );
      expect(
        () => ParentMessage.fromJson(_message('x', kind: 'click')),
        throwsArgumentError,
      );
      expect(
        const ParentSyncIssue(
          'c',
          taskFailures: 0,
          conflicts: 0,
          images: 0,
        ).needsAttention,
        isFalse,
      );
      expect(
        const ParentSyncIssue(
          'c',
          taskFailures: 1,
          conflicts: 2,
          images: 3,
        ).summary,
        contains('冲突任务 2'),
      );
    },
  );
  group('real Supabase transport', () {
    late MockSupabase backend;
    late SupabaseParentNotificationRepository repository;
    setUp(() async {
      backend = MockSupabase();
      await backend.signIn();
      repository = SupabaseParentNotificationRepository(backend.client);
    });
    tearDown(() async {
      await backend.close();
    });
    test(
      'inbox, delivery, versioned settings and exact read/delivery receipts use expected RPCs',
      () async {
        backend.handle = (request) {
          final body = MockSupabase.body(request);
          expect(body['target_family_id'], 'family');
          if (request.url.path.endsWith('/parent_notification_inbox')) {
            return MockSupabase.json(request, _inbox());
          }
          if (request.url.path.endsWith('/parent_notification_delivery')) {
            return MockSupabase.json(request, {..._inbox(), 'quiet': false});
          }
          if (request.url.path.endsWith('/save_parent_notification_settings')) {
            expect(body['expected_version'], 2);
            expect((body['config'] as Map).length, 6);
            return MockSupabase.json(request, {..._settings(), 'version': 3});
          }
          return MockSupabase.json(request, {
            'keys': body['keys'],
            'operation': body['operation'],
          });
        };
        expect((await repository.load('family')).items.length, 2);
        expect((await repository.delivery('family')).quiet, isFalse);
        await repository.save(
          'family',
          ParentNotificationSettings.fromJson(_settings()),
        );
        await repository.markRead('family', ['redeem']);
        await repository.markDelivered('family', ['week']);
        expect(backend.calls.length, 5);
      },
    );
    test(
      'malformed and duplicate receipts, wrong family and invalid selection do not report success',
      () async {
        for (final receipt in [
          <String, dynamic>{},
          {
            'keys': ['other'],
            'operation': 'read',
          },
          {
            'keys': ['a', 'a'],
            'operation': 'read',
          },
          {
            'keys': ['a'],
            'operation': 'delivered',
          },
        ]) {
          backend.handle = (r) => MockSupabase.json(r, receipt);
          await expectLater(
            repository.markRead('family', ['a']),
            throwsStateError,
          );
        }
        await expectLater(
          repository.markRead('family', []),
          throwsFormatException,
        );
        await expectLater(
          repository.markRead('family', ['a', 'a']),
          throwsFormatException,
        );
        backend.handle = (r) => MockSupabase.json(r, {
          ..._inbox(),
          'family_id': 'foreign',
          'quiet': false,
        });
        await expectLater(repository.load('family'), throwsStateError);
        await expectLater(repository.delivery('family'), throwsStateError);
      },
    );
    test(
      'read inputs freeze before transport and an old account response is discarded',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        backend.handle = (r) async {
          entered.complete();
          await release.future;
          return MockSupabase.json(r, {
            'keys': ['a'],
            'operation': 'read',
          });
        };
        final keys = ['a'];
        final request = repository.markRead('family', keys);
        keys.add('b');
        await entered.future;
        expect(MockSupabase.body(backend.calls.single)['keys'], ['a']);
        final rejected = expectLater(request, throwsStateError);
        await backend.signIn(MockSupabase.secondUser);
        release.complete();
        await rejected;
        await backend.client.auth.signOut();
        await expectLater(repository.load('family'), throwsStateError);
      },
    );
  });
  group('encrypted device mode and foreground delivery', () {
    late OfflineStore store;
    late OfflineTaskRepository tasks;
    late _Repository repo;
    late _Scheduler scheduler;
    late ParentNotificationDevice device;
    String? owner;
    DateTime now = DateTime.utc(2026, 11, 4);
    setUp(() {
      owner = 'owner';
      now = DateTime.utc(2026, 11, 4);
      store = OfflineStore(NativeDatabase.memory());
      tasks = OfflineTaskRepository(
        store: store,
        remote: _Remote(),
        live: const UnconfiguredTaskRepository(),
        accountId: () => owner,
        autoSync: false,
      );
      repo = _Repository();
      scheduler = _Scheduler();
      device = ParentNotificationDevice(
        tasks,
        repo,
        scheduler,
        clock: () => now,
      );
    });
    tearDown(() async {
      await tasks.dispose();
      await store.close();
    });
    Future<void> failedCommand() async {
      await store.enqueue('owner', 'child', {
        'command_id': 'offline-op',
        'task_id': 'task',
        'kind': 'review_answer',
        'answer': 'PRIVATE ANSWER',
      });
      await store.customStatement(
        "update task_outbox set attempts=1 where command_id='offline-op'",
      );
    }

    test(
      'confirmed policy permits only local sync notices during network failure and keeps daily suppression',
      () async {
        await device.setParentMode('family', true);
        repo.feed = _delivery(sync: true, policy: _policy());
        await device.refresh('family', 'child', isCurrent: () => true);
        final cached = await store.read(
          'owner',
          'parent-notification-policy:family',
        );
        expect(cached?['policy'], isNotNull);
        expect(cached.toString(), isNot(contains('PRIVATE ANSWER')));
        scheduler.batches.clear();
        repo.delivered.clear();
        await failedCommand();
        repo.deliveryFailure = const SocketException('offline');
        await device.refresh('family', 'child', isCurrent: () => true);
        await device.refresh('family', 'child', isCurrent: () => true);
        expect(scheduler.batches, [
          {'sync'},
        ]);
        expect(repo.delivered, isEmpty);
        expect(repo.read, isEmpty);
        device = ParentNotificationDevice(
          tasks,
          repo,
          scheduler,
          clock: () => now,
        );
        await device.refresh('family', 'child', isCurrent: () => true);
        expect(scheduler.batches.length, 1);
        expect(
          (await store.commands('owner')).single['command']['answer'],
          'PRIVATE ANSWER',
        );
      },
    );
    test(
      'offline quiet hours and seven-day expiry follow server time even with a wrong device date',
      () async {
        now = DateTime.utc(2001, 1, 1);
        await device.setParentMode('family', true);
        repo.feed = _delivery(sync: true, items: [], policy: _policy());
        await device.refresh('family', 'child', isCurrent: () => true);
        await failedCommand();
        repo.deliveryFailure = const SocketException('offline');
        now = now.add(const Duration(hours: 13));
        await device.refresh('family', 'child', isCurrent: () => true);
        expect(scheduler.batches, isEmpty);
        now = DateTime.utc(2001, 1, 2);
        await device.refresh('family', 'child', isCurrent: () => true);
        expect(scheduler.batches, [
          {'sync'},
        ]);
        final seen = await store.read(
          'owner',
          'parent-notification-seen:family',
        );
        expect(seen!['keys'], contains('sync:child:2026-11-05'));
        now = DateTime.utc(2001, 1, 8);
        await expectLater(
          device.refresh('family', 'child', isCurrent: () => true),
          throwsA(isA<SocketException>()),
        );
        expect(
          await store.read('owner', 'parent-notification-policy:family'),
          isNull,
        );
        expect(scheduler.batches.length, 1);
      },
    );
    test(
      'known authorization or payload failure erases offline fallback before a later network outage',
      () async {
        await device.setParentMode('family', true);
        for (final error in [
          const PostgrestException(message: 'denied', code: '42501'),
          StateError('invalid response'),
        ]) {
          repo.deliveryFailure = null;
          repo.feed = _delivery(sync: true, items: [], policy: _policy());
          await device.refresh('family', 'child', isCurrent: () => true);
          repo.deliveryFailure = error;
          await expectLater(
            device.refresh('family', 'child', isCurrent: () => true),
            throwsA(same(error)),
          );
          expect(
            await store.read('owner', 'parent-notification-policy:family'),
            isNull,
          );
          expect(scheduler.scopes.last, isNull);
          repo.deliveryFailure = const SocketException('offline');
          await expectLater(
            device.refresh('family', 'child', isCurrent: () => true),
            throwsA(isA<SocketException>()),
          );
        }
        expect(scheduler.batches, isEmpty);
      },
    );
    test(
      'missing, corrupt or unsupported policies cannot keep an older offline permission alive',
      () async {
        await device.setParentMode('family', true);
        repo.feed = _delivery(sync: true, items: [], policy: _policy());
        await device.refresh('family', 'child', isCurrent: () => true);
        repo.feed = _delivery(sync: true, items: []);
        await device.refresh('family', 'child', isCurrent: () => true);
        expect(
          await store.read('owner', 'parent-notification-policy:family'),
          isNull,
        );
        repo.feed = _delivery(
          sync: true,
          items: [],
          policy: {..._policy(), 'family_id': 'wrong'},
        );
        await expectLater(
          device.refresh('family', 'child', isCurrent: () => true),
          throwsFormatException,
        );
        await store.write('owner', 'parent-notification-policy:family', {
          'policy': 'broken',
        });
        repo.deliveryFailure = const SocketException('offline');
        await expectLater(
          device.refresh('family', 'child', isCurrent: () => true),
          throwsA(isA<SocketException>()),
        );
        expect(
          await store.read('owner', 'parent-notification-policy:family'),
          isNull,
        );
      },
    );
    test(
      'a backwards device clock invalidates the persisted offline clock window',
      () async {
        await device.setParentMode('family', true);
        repo.feed = _delivery(sync: true, items: [], policy: _policy());
        await device.refresh('family', 'child', isCurrent: () => true);
        repo.deliveryFailure = const SocketException('offline');
        now = now.add(const Duration(hours: 2));
        await device.refresh('family', 'child', isCurrent: () => true);
        now = now.subtract(const Duration(hours: 1));
        await expectLater(
          device.refresh('family', 'child', isCurrent: () => true),
          throwsA(isA<SocketException>()),
        );
        expect(
          await store.read('owner', 'parent-notification-policy:family'),
          isNull,
        );
      },
    );
    test(
      'preference saves suspend refresh and cannot restore a policy after an unknown save response',
      () async {
        await device.setParentMode('family', true);
        repo.feed = _delivery(sync: true, items: [], policy: _policy());
        await device.refresh('family', 'child', isCurrent: () => true);
        repo.waiting = Completer<ParentDelivery>();
        repo.entered = Completer<void>();
        final oldRefresh = device.refresh(
          'family',
          'child',
          isCurrent: () => true,
        );
        await repo.entered!.future;
        repo.saveWaiting = Completer<ParentNotificationSettings>();
        repo.saveEntered = Completer<void>();
        final save = device.saveSettings(
          'family',
          const ParentNotificationSettings(),
          canConfigure: () => true,
        );
        await repo.saveEntered!.future;
        expect(
          await store.read('owner', 'parent-notification-policy:family'),
          isNull,
        );
        await expectLater(
          device.saveSettings(
            'family',
            const ParentNotificationSettings(),
            canConfigure: () => true,
          ),
          throwsStateError,
        );
        repo.waiting!.complete(repo.feed);
        await oldRefresh;
        repo.waiting = null;
        repo.deliveryFailure = const SocketException('offline');
        await device.refresh('family', 'child', isCurrent: () => true);
        final rejected = expectLater(save, throwsA(isA<TimeoutException>()));
        repo.saveWaiting!.completeError(TimeoutException('response lost'));
        await rejected;
        await expectLater(
          device.refresh('family', 'child', isCurrent: () => true),
          throwsA(isA<SocketException>()),
        );
        expect(scheduler.batches, isEmpty);
        expect(
          await store.read('owner', 'parent-notification-policy:family'),
          isNull,
        );
        repo.saveWaiting = null;
        repo.deliveryFailure = null;
        final updated = await device.saveSettings(
          'family',
          const ParentNotificationSettings(),
          canConfigure: () => true,
        );
        expect(updated.enabled, isFalse);
      },
    );
    test(
      'offline policy cannot cross child or account boundaries and is removed by child deletion or mode change',
      () async {
        await device.setParentMode('family', true);
        repo.feed = _delivery(
          sync: true,
          items: [],
          policy: _policy(children: ['sibling']),
        );
        await device.refresh('family', 'child', isCurrent: () => true);
        await failedCommand();
        repo.deliveryFailure = const SocketException('offline');
        await device.refresh('family', 'child', isCurrent: () => true);
        expect(scheduler.batches, isEmpty);
        owner = 'other';
        expect(
          await device.refresh('family', 'child', isCurrent: () => true),
          isFalse,
        );
        owner = 'owner';
        await store.removeChildData('unrelated');
        expect(
          await store.read('owner', 'parent-notification-policy:family'),
          isNotNull,
        );
        await store.removeChildData('sibling');
        expect(
          await store.read('owner', 'parent-notification-policy:family'),
          isNull,
        );
        repo.deliveryFailure = null;
        repo.feed = _delivery(sync: true, items: [], policy: _policy());
        await device.refresh('family', 'child', isCurrent: () => true);
        await device.setParentMode('family', false);
        expect(
          await store.read('owner', 'parent-notification-policy:family'),
          isNull,
        );
      },
    );
    test(
      'PIN expiry during system permission prompt cannot enable parent delivery',
      () async {
        var authorized = true;
        scheduler.permissionResult = Completer<bool>();
        scheduler.permissionEntered = Completer<void>();
        final operation = device.setParentMode(
          'family',
          true,
          canConfigure: () => authorized,
        );
        await scheduler.permissionEntered!.future;
        authorized = false;
        final rejected = expectLater(operation, throwsStateError);
        scheduler.permissionResult!.complete(true);
        await rejected;
        expect(await device.isParentMode('family'), isFalse);
        expect(scheduler.scopes, isEmpty);
      },
    );
    test(
      'family sync summary reads task failures and blocked image stages without replaying them',
      () async {
        await store.enqueue('owner', 'child', {
          'command_id': 'op',
          'task_id': 'task',
          'kind': 'review_answer',
          'answer': 'PRIVATE',
        });
        await store.enqueue('owner', 'sibling', {
          'command_id': 'other',
          'task_id': 'other',
          'kind': 'start',
        });
        await store.customStatement(
          "update task_outbox set attempts=1 where command_id='op'",
        );
        final bytes = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0]);
        await store.writeImageDraft(
          'owner',
          'child',
          'family',
          'draft',
          {},
          bytes,
          bytes,
        );
        await store.customStatement(
          "update image_drafts set stage='needs_authorization' where draft_id='draft'",
        );
        final media = OfflineQuestionMediaRepository(
          store: store,
          live: _Media(),
          accountId: () => owner,
          parentFamily: () => 'family',
          autoSync: false,
        );
        final container = ProviderContainer(
          overrides: [
            taskRepositoryProvider.overrideWithValue(tasks),
            questionMediaRepositoryProvider.overrideWithValue(media),
            activeParentFamilyProvider.overrideWithValue('family'),
            familiesProvider.overrideWith(
              (_) async => [
                const Family(
                  id: 'family',
                  name: 'f',
                  timezone: 'UTC',
                  children: [
                    ChildProfile(
                      id: 'child',
                      familyId: 'family',
                      nickname: 'PRIVATE',
                      grade: 1,
                    ),
                  ],
                ),
              ],
            ),
          ],
        );
        final subscription = container.listen(
          parentSyncIssuesProvider('family'),
          (_, _) {},
        );
        try {
          final issues = await container.read(
            parentSyncIssuesProvider('family').future,
          );
          expect(issues.length, 1);
          expect(issues.single.taskFailures, 1);
          expect(issues.single.images, 1);
          expect(issues.single.summary, isNot(contains('PRIVATE')));
          expect((await store.commands('owner')).length, 2);
        } finally {
          subscription.close();
          container.dispose();
          await media.dispose();
        }
      },
    );
    test(
      'permission and supported platform gate device mode; account mode does not carry over',
      () async {
        expect(await device.isParentMode('family'), isFalse);
        expect(
          await device.refresh('family', 'child', isCurrent: () => true),
          isFalse,
        );
        scheduler.permission = false;
        expect(await device.setParentMode('family', true), isFalse);
        scheduler.permission = true;
        expect(await device.setParentMode('family', true), isTrue);
        expect(await device.isParentMode('family'), isTrue);
        expect(scheduler.scopes.last, isNull);
        owner = 'other';
        expect(await device.isParentMode('family'), isFalse);
        owner = null;
        expect(await device.isParentMode('family'), isFalse);
        await expectLater(
          device.setParentMode('family', true),
          throwsStateError,
        );
        owner = 'owner';
        expect(await device.setParentMode('family', false), isTrue);
        expect(await device.isParentMode('family'), isFalse);
        final unsupported = ParentNotificationDevice(
          tasks,
          repo,
          const DisabledNotificationScheduler(),
        );
        expect(await unsupported.setParentMode('family', true), isFalse);
      },
    );
    test(
      'successful display persists suppression before a lost acknowledgement and survives controller restart',
      () async {
        await device.setParentMode('family', true);
        repo.failAck = true;
        await expectLater(
          device.refresh('family', 'child', isCurrent: () => true),
          throwsStateError,
        );
        expect(scheduler.batches.single, {'redemption', 'weekly'});
        repo.failAck = false;
        device = ParentNotificationDevice(tasks, repo, scheduler);
        await device.refresh('family', 'child', isCurrent: () => true);
        expect(scheduler.batches.length, 1);
        expect(repo.delivered.length, 2);
        expect(repo.read, isEmpty);
      },
    );
    test(
      'quiet time, disabled settings, revoked permission and background never acknowledge unseen notifications',
      () async {
        await device.setParentMode('family', true);
        expect(
          await device.refresh('family', 'child', isCurrent: () => false),
          isTrue,
        );
        repo.feed = _delivery(quiet: true);
        await device.refresh('family', 'child', isCurrent: () => true);
        repo.feed = _delivery(enabled: false);
        await device.refresh('family', 'child', isCurrent: () => true);
        expect(scheduler.scopes.last, isNull);
        expect(scheduler.batches, isEmpty);
        repo.feed = _delivery();
        scheduler.success = false;
        await device.refresh('family', 'child', isCurrent: () => true);
        expect(repo.delivered, isEmpty);
        scheduler.success = true;
        await device.refresh('family', 'child', isCurrent: () => true);
        expect(repo.delivered.length, 1);
      },
    );
    test(
      'late delivery after account, privacy or mode change produces no system notification',
      () async {
        for (final change in ['owner', 'privacy', 'mode', 'background']) {
          owner = 'owner';
          await device.setParentMode('family', true);
          var foreground = true;
          repo.waiting = Completer<ParentDelivery>();
          repo.entered = Completer<void>();
          final request = device.refresh(
            'family',
            'child',
            isCurrent: () => foreground,
          );
          await repo.entered!.future;
          if (change == 'owner') owner = 'other';
          if (change == 'privacy') await store.removeChildData('unrelated');
          if (change == 'mode') await device.setParentMode('family', false);
          if (change == 'background') foreground = false;
          repo.waiting!.complete(_delivery());
          await request;
          repo.waiting = null;
        }
        expect(scheduler.batches, isEmpty);
        expect(repo.delivered, isEmpty);
      },
    );
    test(
      'local failed commands notify once per UTC day without uploading answers',
      () async {
        await device.setParentMode('family', true);
        repo.feed = _delivery(sync: true, items: []);
        await store.enqueue('owner', 'child', {
          'command_id': 'op',
          'task_id': 'task',
          'kind': 'review_answer',
          'answer': 'PRIVATE ANSWER',
        });
        await store.customStatement(
          "update task_outbox set attempts=1 where command_id='op'",
        );
        await device.refresh('family', 'child', isCurrent: () => true);
        await device.refresh('family', 'child', isCurrent: () => true);
        expect(scheduler.batches, [
          {'sync'},
        ]);
        expect(repo.delivered, isEmpty);
        now = now.add(const Duration(days: 1));
        await device.refresh('family', 'child', isCurrent: () => true);
        expect(scheduler.batches.length, 2);
      },
    );
    test(
      'child deletion clears shared delivery suppression and rejects stale deleted-child events',
      () async {
        await device.setParentMode('family', true);
        await device.refresh('family', 'child', isCurrent: () => true);
        expect(
          await store.read('owner', 'parent-notification-seen:family'),
          isNotNull,
        );
        await store.removeChildData('child');
        expect(
          await store.read('owner', 'parent-notification-seen:family'),
          isNull,
        );
        scheduler.batches.clear();
        repo.delivered.clear();
        repo.feed = _delivery(sync: true);
        await device.refresh('family', 'child', isCurrent: () => true);
        expect(scheduler.batches, isEmpty);
        expect(repo.delivered, isEmpty);
      },
    );
    test(
      'large inbox batches delivery receipts without discarding events',
      () async {
        await device.setParentMode('family', true);
        repo.feed = _delivery(
          items: [for (var i = 0; i < 405; i++) _message('r$i')],
        );
        await device.refresh('family', 'child', isCurrent: () => true);
        expect(repo.delivered.map((x) => x.length), [200, 200, 5]);
        expect(scheduler.batches, [
          {'redemption'},
        ]);
      },
    );
  });

  test(
    'offline notification policy and suppression survive a real database close and reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'learning-planet-policy-',
      );
      final file = File(
        '${directory.path}${Platform.pathSeparator}cache.sqlite',
      );
      final repo = _Repository()
        ..feed = _delivery(sync: true, items: [], policy: _policy());
      final scheduler = _Scheduler();
      final now = DateTime.utc(2026, 11, 4);
      OfflineTaskRepository repository(OfflineStore db) =>
          OfflineTaskRepository(
            store: db,
            remote: _Remote(),
            live: const UnconfiguredTaskRepository(),
            accountId: () => 'owner',
            autoSync: false,
          );
      var store = OfflineStore(NativeDatabase(file));
      var tasks = repository(store);
      try {
        var device = ParentNotificationDevice(
          tasks,
          repo,
          scheduler,
          clock: () => now,
        );
        await device.setParentMode('family', true);
        await device.refresh('family', 'child', isCurrent: () => true);
        await store.enqueue('owner', 'child', {
          'command_id': 'pending',
          'task_id': 'task',
          'kind': 'start',
        });
        await store.customStatement(
          "update task_outbox set attempts=1 where command_id='pending'",
        );
        await tasks.dispose();
        await store.close();
        store = OfflineStore(NativeDatabase(file));
        tasks = repository(store);
        repo.deliveryFailure = const SocketException('offline after restart');
        device = ParentNotificationDevice(
          tasks,
          repo,
          scheduler,
          clock: () => now.add(const Duration(minutes: 1)),
        );
        await device.refresh('family', 'child', isCurrent: () => true);
        expect(scheduler.batches, [
          {'sync'},
        ]);
        expect(repo.delivered, isEmpty);
        expect((await store.commands('owner')).length, 1);
        await tasks.dispose();
        await store.close();
        store = OfflineStore(NativeDatabase(file));
        tasks = repository(store);
        device = ParentNotificationDevice(
          tasks,
          repo,
          scheduler,
          clock: () => now.add(const Duration(minutes: 2)),
        );
        await device.refresh('family', 'child', isCurrent: () => true);
        expect(scheduler.batches.length, 1);
      } finally {
        await tasks.dispose();
        await store.close();
        final root =
            '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}learning-planet-policy-';
        if (!directory.absolute.path.startsWith(root)) {
          throw StateError('Unexpected test directory');
        }
        await directory.delete(recursive: true);
      }
    },
  );

  const family = Family(
    id: 'family',
    name: '家庭',
    timezone: 'Asia/Shanghai',
    children: [
      ChildProfile(id: 'child', familyId: 'family', nickname: '小星', grade: 2),
    ],
  );
  testWidgets(
    'background opt-in controls follow device mode, native state and PIN',
    (tester) async {
      final h = push_test.Harness(), device = _Device()..enabled = false;
      final access = StateProvider<String?>((_) => 'family');
      final container = ProviderContainer(
        overrides: [
          activeParentFamilyProvider.overrideWith((ref) => ref.watch(access)),
          familiesProvider.overrideWith((_) async => [family]),
          parentNotificationRepositoryProvider.overrideWithValue(_Repository()),
          parentNotificationDeviceProvider.overrideWithValue(device),
          remoteParentPushProvider.overrideWithValue(h.push),
          parentSyncIssuesProvider.overrideWith((_, _) async => []),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: ParentNotificationsScreen(familyId: 'family'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final enable = find.widgetWithText(TextButton, '启用');
      expect(tester.widget<TextButton>(enable).onPressed, isNull);
      device.enabled = true;
      container.read(parentNotificationDeviceRevisionProvider.notifier).state++;
      await tester.pumpAndSettle();
      await tester.ensureVisible(enable);
      await tester.tap(enable);
      await tester.pumpAndSettle();
      expect(find.text('后台家长提醒：已启用'), findsOneWidget);
      expect(h.native.enabled, true);
      // A native/controller change outside this screen must refresh its status.
      h.remote.offline = true;
      await h.push.disable();
      await tester.pumpAndSettle();
      expect(find.text('本机已关闭提醒，联网后继续完成服务端撤销。'), findsOneWidget);
      container.read(access.notifier).state = null;
      await tester.pumpAndSettle();
      expect(find.text('启用'), findsNothing);
      expect(find.text('家长授权已到期，请返回首页重新验证 PIN'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'local sync remains usable while cloud messages load or fail, but known permission denial hides it',
    (tester) async {
      final repo = _Repository()..loadWaiting = Completer<ParentInbox>();
      final device = _Device();
      final container = ProviderContainer(
        overrides: [
          activeParentFamilyProvider.overrideWithValue('family'),
          familiesProvider.overrideWith((_) async => [family]),
          parentNotificationRepositoryProvider.overrideWithValue(repo),
          parentNotificationDeviceProvider.overrideWithValue(device),
          parentSyncIssuesProvider.overrideWith(
            (_, _) async => [
              const ParentSyncIssue(
                'child',
                taskFailures: 2,
                conflicts: 1,
                images: 1,
              ),
            ],
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: ParentNotificationsScreen(familyId: 'family'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('小星的本机同步需要关注'), findsOneWidget);
      repo.loadFailure = const SocketException('offline');
      repo.loadWaiting!.completeError(repo.loadFailure!);
      repo.loadWaiting = null;
      await tester.pumpAndSettle();
      expect(find.text('小星的本机同步需要关注'), findsOneWidget);
      expect(find.text('联网后重试家长消息'), findsOneWidget);
      await tester.tap(find.text('此设备切换为孩子提醒'));
      await tester.pumpAndSettle();
      expect(device.changes, [false]);
      expect(repo.saved, isNull);
      repo.loadFailure = const PostgrestException(
        message: 'denied',
        code: '42501',
      );
      container.invalidate(parentInboxProvider('family'));
      await tester.pumpAndSettle();
      expect(find.text('小星的本机同步需要关注'), findsNothing);
      expect(find.text('暂时无法读取家长消息'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'parent inbox supports independent read status and settings; PIN expiry closes nested access',
    (tester) async {
      final repo = _Repository(),
          access = StateProvider<String?>((_) => 'family');
      final container = ProviderContainer(
        overrides: [
          activeParentFamilyProvider.overrideWith((ref) => ref.watch(access)),
          familiesProvider.overrideWith((_) async => [family]),
          parentNotificationRepositoryProvider.overrideWithValue(repo),
          parentNotificationDeviceProvider.overrideWithValue(null),
          parentSyncIssuesProvider.overrideWith(
            (_, _) async => [
              const ParentSyncIssue(
                'child',
                taskFailures: 1,
                conflicts: 0,
                images: 0,
              ),
            ],
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: ParentNotificationsScreen(familyId: 'family'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('小星的本机同步需要关注'), findsOneWidget);
      await tester.ensureVisible(find.text('标为已读').first);
      await tester.tap(find.text('标为已读').first);
      await tester.pumpAndSettle();
      expect(repo.read, [
        ['redeem'],
      ]);
      expect(find.text('未读 1'), findsOneWidget);
      await tester.ensureVisible(find.text('家长通知偏好'));
      await tester.tap(find.text('家长通知偏好'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '安静开始 HH:mm'),
        '24:00',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('安静时段请使用 HH:mm，例如 21:00'), findsOneWidget);
      expect(repo.saved, isNull);
      await tester.enterText(
        find.widgetWithText(TextField, '安静开始 HH:mm'),
        '22:00',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(repo.saved?.quietStart, '22:00');
      expect(repo.saved?.version, 2);
      await tester.tap(find.text('家长通知偏好'));
      await tester.pumpAndSettle();
      container.read(access.notifier).state = null;
      await tester.pumpAndSettle();
      expect(find.text('家长授权已到期'), findsOneWidget);
      expect(find.text('接收家长提醒'), findsNothing);
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();
      expect(find.text('家长授权已到期，请返回首页重新验证 PIN'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
