import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Family;
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/features/auth_family/application/auth_providers.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/data/auth_repository.dart';
import 'package:learning_planet/features/auth_family/domain/auth_session.dart';
import 'package:learning_planet/features/auth_family/domain/family.dart';
import 'package:learning_planet/features/auth_family/presentation/auth_gate.dart';
import 'package:learning_planet/features/data_management/data/account_deletion_repository.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';
import 'package:learning_planet/features/tasks/data/notification_scheduler.dart';

import 'widget_test.dart' as fixture;
import 'account_deletion_test.dart' show FakeAccountDeletion;

const _private = 'private-backend-payload-token';
const _denied = PostgrestException(
  message: '账号不可用 $_private',
  code: '42501',
  details: 'table/private-child $_private',
  hint: 'internal query $_private',
);

class _Auth implements AuthRepository {
  @override
  AuthSession? currentSession = const AuthSession(userId: 'parent-1');
  final changes = StreamController<AuthSession?>.broadcast();
  Object? error;
  int subscriptions = 0, exits = 0;
  @override
  Stream<AuthSession?> watchSession() async* {
    subscriptions++;
    if (error != null) throw error!;
    yield currentSession;
    yield* changes.stream;
  }

  @override
  Future<void> signOut() async {
    exits++;
    currentSession = null;
    changes.add(null);
  }

  @override
  Future<void> sendEmailOtp(String email) async {}
  @override
  Future<void> verifyEmailOtp(
    String email,
    String code, {
    required bool Function() isCurrent,
  }) async {}
}

class _Family extends fixture.FakeFamilyRepository {
  _Family() : super.withChild();
  Object? error;
  Completer<List<Family>>? waiting;
  int loads = 0;
  @override
  Future<List<Family>> loadFamilies() async {
    loads++;
    if (error != null) throw error!;
    return waiting?.future ?? super.loadFamilies();
  }
}

class _Notifications extends DisabledNotificationScheduler {
  int clears = 0;
  Completer<void>? waiting;
  @override
  Future<void> setScope(String? scope) async {
    if (scope == null) clears++;
    await waiting?.future;
  }
}

class _PendingAccountStatus extends FakeAccountDeletion {
  final reads = <Completer<Map<String, dynamic>?>>[];

  @override
  Future<Map<String, dynamic>?> status() {
    final request = Completer<Map<String, dynamic>?>();
    reads.add(request);
    return request.future;
  }
}

class _Harness {
  final auth = _Auth();
  final family = _Family();
  final notifications = _Notifications();
  Object? accountError;
  int accountReads = 0;
  late final ProviderContainer container;
  Future<void> mount(WidgetTester tester) async {
    final scope = ProviderScope(
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        familyRepositoryProvider.overrideWithValue(family),
        taskRepositoryProvider.overrideWithValue(fixture.FakeTaskRepository()),
        notificationSchedulerProvider.overrideWithValue(notifications),
        accountDeletionStatusProvider.overrideWith((ref) async {
          accountReads++;
          if (accountError != null) throw accountError!;
          return null;
        }),
      ],
      child: const MaterialApp(home: AuthGate()),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await auth.changes.close();
    });
    await tester.pumpWidget(scope);
    container = ProviderScope.containerOf(
      tester.element(find.byType(AuthGate)),
    );
    await tester.pumpAndSettle();
  }
}

void _expectNoRawFailure() {
  expect(find.textContaining(_private), findsNothing);
  expect(find.textContaining('PostgrestException'), findsNothing);
  expect(find.textContaining('AuthException'), findsNothing);
  expect(find.textContaining('42501'), findsNothing);
}

Future<void> _mountPendingAccount(
  WidgetTester tester,
  _Auth auth,
  _PendingAccountStatus status,
) async {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await auth.changes.close();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        accountDeletionRepositoryProvider.overrideWithValue(status),
        familyRepositoryProvider.overrideWithValue(_Family()),
        taskRepositoryProvider.overrideWithValue(fixture.FakeTaskRepository()),
        notificationSchedulerProvider.overrideWithValue(_Notifications()),
      ],
      child: const MaterialApp(home: AuthGate()),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets(
    'a periodic tick preserves a pending check and resume still rechecks deletion',
    (tester) async {
      final auth = _Auth(), status = _PendingAccountStatus();
      await _mountPendingAccount(tester, auth, status);
      final first = status.reads.single;
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(find.text('今日任务'), findsNothing);
      first.complete(null); // The repository completed its offline fallback.
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.text('今日任务'), findsOneWidget);
      expect(status.reads, hasLength(1));
      await tester.pumpAndSettle();

      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(status.reads, hasLength(2));
      final backgroundCheck = status.reads.last;
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(status.reads, hasLength(2));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(status.reads, hasLength(3));
      status.reads.last.complete({
        'id': 'job',
        'status': 'queued',
        'phase': 'files',
      });
      await tester.pumpAndSettle();
      expect(find.text('今日任务'), findsNothing);
      expect(find.text('注销已受理，正在清理'), findsOneWidget);
      backgroundCheck.complete(null);
      await tester.pumpAndSettle();
      expect(find.text('今日任务'), findsNothing);
      expect(find.text('注销已受理，正在清理'), findsOneWidget);
    },
  );

  testWidgets(
    'refreshing the same account while checking its status still opens home',
    (tester) async {
      final auth = _Auth(), status = _PendingAccountStatus();
      await _mountPendingAccount(tester, auth, status);
      expect(status.reads, hasLength(1));
      for (var i = 0; i < 3; i++) {
        auth.changes.add(
          AuthSession(userId: 'parent-1', email: 'parent$i@example.test'),
        );
        await tester.pump();
        await tester.pump();
      }
      expect(status.reads, hasLength(1));
      status.reads.single.complete(null);
      await tester.pumpAndSettle();
      expect(find.text('今日任务'), findsOneWidget);
      auth.currentSession = const AuthSession(userId: 'parent-2');
      auth.changes.add(auth.currentSession);
      await tester.pump();
      await tester.pump();
      expect(status.reads, hasLength(2));
      expect(find.text('今日任务'), findsNothing);
      status.reads.last.complete(null);
      await tester.pumpAndSettle();
      expect(find.text('今日任务'), findsOneWidget);
    },
  );

  testWidgets(
    'family rejection hides database payload and retry restores home',
    (tester) async {
      final h = _Harness()..family.error = _denied;
      await h.mount(tester);
      _expectNoRawFailure();
      expect(find.text('家庭资料暂时无法读取'), findsOneWidget);
      expect(find.text('今日任务'), findsNothing);
      expect(find.text('重新登录后继续'), findsNothing);
      h.family.error = null;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('今日任务'), findsOneWidget);
      expect(h.family.loads, 2);
      expect(h.auth.exits, 0);
    },
  );

  testWidgets('failed login state can resubscribe without signing out', (
    tester,
  ) async {
    final h = _Harness()
      ..auth.error = AuthRetryableFetchException(message: _private);
    await h.mount(tester);
    _expectNoRawFailure();
    expect(find.text('暂时无法连接服务'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    h.auth.error = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('今日任务'), findsOneWidget);
    expect(h.auth.subscriptions, 2);
    expect(h.auth.exits, 0);
    expect(h.auth.currentSession?.userId, 'parent-1');
  });

  testWidgets(
    'family retry allows one pending read and recovers after timeout',
    (tester) async {
      final h = _Harness()..family.error = const SocketException(_private);
      await h.mount(tester);
      expect(find.text('暂时无法连接服务'), findsOneWidget);
      h.family.error = null;
      h.family.waiting = Completer<List<Family>>();
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(h.family.loads, 2);
      final retry = find.widgetWithText(FilledButton, '正在重试…');
      expect(tester.widget<FilledButton>(retry).onPressed, isNull);
      await tester.tap(retry);
      await tester.pump();
      expect(h.family.loads, 2);
      h.family.waiting!.completeError(TimeoutException(_private));
      await tester.pumpAndSettle();
      _expectNoRawFailure();
      h.family.waiting = null;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('今日任务'), findsOneWidget);
      expect(h.family.loads, 3);
      expect(h.auth.exits, 0);
    },
  );

  testWidgets(
    'invalid session has a safe exit and closes parent authorization',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      h.container.read(parentModeProvider.notifier).state = true;
      h.container.read(parentFamilyIdProvider.notifier).state = 'family-1';
      h.container.read(parentAuthorizedUntilProvider.notifier).state =
          DateTime.now().add(const Duration(minutes: 10));
      h.auth.changes.addError(
        const AuthException(
          _private,
          code: 'refresh_token_not_found',
          statusCode: '400',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('请重新登录'), findsOneWidget);
      _expectNoRawFailure();
      final before = h.notifications.clears;
      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();
      expect(find.text('登录学习星球'), findsOneWidget);
      expect(h.notifications.clears, greaterThan(before));
      expect(h.container.read(activeParentFamilyProvider), isNull);
      expect(h.auth.exits, 1);
    },
  );

  testWidgets(
    'transient auth stream failure can recover through the next event',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      h.auth.changes.addError(AuthRetryableFetchException(message: _private));
      await tester.pumpAndSettle();
      expect(find.text('暂时无法连接服务'), findsOneWidget);
      h.auth.changes.add(h.auth.currentSession);
      await tester.pumpAndSettle();
      expect(find.text('今日任务'), findsOneWidget);
      expect(h.auth.exits, 0);
      expect(h.auth.subscriptions, 1);
    },
  );

  testWidgets(
    'unknown account status cannot be bypassed and retries its check',
    (tester) async {
      final h = _Harness()..accountError = _denied;
      await h.mount(tester);
      expect(find.text('账号状态暂时无法确认'), findsOneWidget);
      _expectNoRawFailure();
      expect(h.family.loads, 0);
      h.accountError = null;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(h.accountReads, 2);
      expect(find.text('今日任务'), findsOneWidget);
    },
  );

  testWidgets(
    'cleanup failure keeps recovery actions and never bypasses logout',
    (tester) async {
      final h = _Harness()..family.error = _denied;
      await h.mount(tester);
      h.notifications.waiting = Completer<void>();
      await tester.tap(find.text('退出登录'));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '重试'))
            .onPressed,
        isNull,
      );
      expect(h.auth.exits, 0);
      h.notifications.waiting!.completeError(StateError(_private));
      await tester.pumpAndSettle();
      _expectNoRawFailure();
      expect(find.text('退出未完成，本机家长权限已关闭。请重试。'), findsOneWidget);
      expect(h.auth.exits, 0);
      h.notifications.waiting = null;
      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();
      expect(find.text('登录学习星球'), findsOneWidget);
    },
  );

  for (final scope in ['auth', 'family', 'account']) {
    testWidgets(
      '$scope failure remains usable at double text with safe insets',
      (tester) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 32, bottom: 24);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final h = _Harness();
        if (scope == 'auth') {
          h.auth.error = AuthSessionMissingException(_private);
        }
        if (scope == 'family') h.family.error = _denied;
        if (scope == 'account') h.accountError = _denied;
        await h.mount(tester);
        _expectNoRawFailure();
        final exit = find.widgetWithText(TextButton, '退出登录');
        await tester.ensureVisible(exit);
        await tester.pumpAndSettle();
        expect(tester.getRect(exit).bottom, lessThanOrEqualTo(616));
        expect(tester.getRect(exit).top, greaterThanOrEqualTo(32));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
