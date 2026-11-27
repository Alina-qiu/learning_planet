import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Family;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/app/app.dart';
import 'package:learning_planet/core/security/device_secrets.dart';
import 'package:learning_planet/core/security/secure_auth_storage.dart';
import 'package:learning_planet/features/auth_family/application/auth_providers.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/data/auth_repository.dart';
import 'package:learning_planet/features/auth_family/domain/family.dart';
import 'package:learning_planet/features/auth_family/presentation/app_sign_out.dart';
import 'package:learning_planet/features/auth_family/presentation/auth_gate.dart';
import 'package:learning_planet/features/auth_family/presentation/parent_mode_prompt.dart';
import 'package:learning_planet/features/data_management/data/account_deletion_repository.dart';
import 'package:learning_planet/features/tasks/data/notification_scheduler.dart';
import 'package:learning_planet/features/tasks/application/task_providers.dart';

import 'support/mock_supabase.dart';
import 'widget_test.dart' as fixture;

class _Secrets implements DeviceSecrets {
  final values = <String, String>{};
  bool fail = false;
  Future<void> Function(String, String)? intercept;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (fail) throw const LocalDataException('device storage unavailable');
    await intercept?.call(key, value);
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _BrokenPkce extends GotrueAsyncStorage {
  @override
  Future<String?> getItem({required String key}) async => null;
  @override
  Future<void> setItem({required String key, required String value}) async {}
  @override
  Future<void> removeItem({required String key}) async =>
      throw StateError('redundant delete failed');
}

class _Harness {
  _Harness({GotrueAsyncStorage? pkce})
    : backend = MockSupabase(pkceStorage: pkce) {
    values = SecureAuthValues(
      secrets: secrets,
      backendUrl: 'https://project.supabase.co',
    );
    storage = SecureSessionStorage(
      values,
      isCurrentSession: (encoded) =>
          (jsonDecode(encoded) as Map)['access_token'] ==
          backend.client.auth.currentSession?.accessToken,
    );
    repository = SupabaseAuthRepository(
      backend.client,
      sessionStorage: storage,
      revocationWait: const Duration(milliseconds: 30),
    );
  }
  final MockSupabase backend;
  final secrets = _Secrets();
  late final SecureAuthValues values;
  late final SecureSessionStorage storage;
  late final SupabaseAuthRepository repository;
  StreamSubscription<AuthState>? subscription;
  String get encoded =>
      jsonEncode(backend.client.auth.currentSession!.toJson());
  Future<void> start() async {
    await storage.initialize();
    await backend.signIn();
    await storage.persistSession(encoded);
    await values.write(SecureAuthValues.pkceKey, 'old-code-verifier');
    subscription = backend.client.auth.onAuthStateChange.listen((state) {
      if (state.event == AuthChangeEvent.signedOut) {
        unawaited(storage.removePersistedSession());
      } else if (state.session != null) {
        unawaited(storage.persistSession(jsonEncode(state.session!.toJson())));
      }
    });
  }

  Future<void> close() async {
    await subscription?.cancel();
    await repository.dispose();
    await backend.close();
  }
}

class _Scheduler implements NotificationScheduler {
  bool fail = false;
  int clears = 0;
  Completer<void>? waiting;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> setScope(String? scope) async {
    if (scope == null) clears++;
    if (fail) throw StateError('private native error');
    await waiting?.future;
  }

  @override
  Future<void> synchronize(
    String childId,
    List<Map<String, dynamic>> reminders,
  ) async {}
}

class _OfflineFamily extends fixture.FakeFamilyRepository {
  _OfflineFamily({bool child = true}) {
    if (child) {
      families.add(fixture.FakeFamilyRepository.withChild().families.single);
    }
  }
  int revocations = 0;
  bool failLoad = false;
  Completer<List<Family>>? loading;
  Completer<ParentPinVerification>? verification;
  @override
  Future<void> revokeParentAuthorization() async {
    revocations++;
    throw const SocketException('offline');
  }

  @override
  Future<List<Family>> loadFamilies() async {
    if (failLoad) throw const SocketException('offline');
    if (loading != null) return loading!.future;
    return super.loadFamilies();
  }

  @override
  Future<ParentPinVerification> verifyParentPin({
    required String familyId,
    required String pin,
  }) =>
      verification?.future ??
      super.verifyParentPin(familyId: familyId, pin: pin);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'offline PIN revoke and failed HTTP logout still clear session and PKCE durably',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      await h.start();
      h.backend.handle = (_) => throw const SocketException('offline');
      h.backend.logout = (_) => throw const SocketException('offline');
      final states = <String?>[];
      final sub = h.repository.watchSession().listen(
        (s) => states.add(s?.userId),
      );
      addTearDown(sub.cancel);
      await h.repository.signOut();
      await Future<void>.delayed(Duration.zero);
      expect(h.repository.currentSession, isNull);
      expect(await h.storage.accessToken(), isNull);
      expect(await h.values.read(SecureAuthValues.pkceKey), isNull);
      expect(states.last, isNull);
      expect(
        h.backend.logoutCalls.single.url.queryParameters['scope'],
        'local',
      );
      final restarted = SecureSessionStorage(
        SecureAuthValues(
          secrets: h.secrets,
          backendUrl: 'https://project.supabase.co',
        ),
      );
      expect(await restarted.hasAccessToken(), false);
    },
  );

  test(
    'a hanging PIN revoke is bounded and a hanging logout does not delay local completion',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      await h.start();
      final pin = Completer<void>(), logout = Completer<void>();
      h.backend.handle = (r) async {
        await pin.future;
        return MockSupabase.json(r, null);
      };
      h.backend.logout = (r) async {
        await logout.future;
        return MockSupabase.json(r, {});
      };
      await h.repository.signOut().timeout(const Duration(seconds: 1));
      expect(h.repository.currentSession, isNull);
      expect(await h.storage.hasAccessToken(), false);
      pin.complete();
      logout.complete();
    },
  );

  test(
    'late logout error cannot clear a later login or its persisted credentials',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      await h.start();
      final release = Completer<void>();
      h.backend.logout = (r) async {
        await release.future;
        return MockSupabase.json(r, {'message': 'failed'}, status: 500);
      };
      await h.repository.signOut();
      await h.backend.signIn(MockSupabase.secondUser);
      await h.storage.persistSession(h.encoded);
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 45));
      expect(h.repository.currentSession!.userId, MockSupabase.secondUser);
      expect(
        (jsonDecode((await h.storage.accessToken())!) as Map)['access_token'],
        h.backend.client.auth.currentSession!.accessToken,
      );
    },
  );

  test(
    'new login during preflight aborts old logout and resumes persistence for the new account',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      await h.start();
      final entered = Completer<void>(), release = Completer<void>();
      h.backend.handle = (r) async {
        entered.complete();
        await release.future;
        return MockSupabase.json(r, null);
      };
      final old = expectLater(h.repository.signOut(), throwsStateError);
      await entered.future;
      await h.backend.signIn(MockSupabase.secondUser);
      release.complete();
      await old;
      expect(h.repository.currentSession!.userId, MockSupabase.secondUser);
      expect(h.backend.logoutCalls, isEmpty);
      expect(
        (jsonDecode((await h.storage.accessToken())!) as Map)['access_token'],
        h.backend.client.auth.currentSession!.accessToken,
      );
    },
  );

  test(
    'secure storage failure leaves the live session available for retry',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      await h.start();
      final saved = await h.storage.accessToken();
      h.secrets.fail = true;
      await expectLater(
        h.repository.signOut(),
        throwsA(isA<LocalDataException>()),
      );
      expect(h.repository.currentSession!.userId, MockSupabase.firstUser);
      expect(h.backend.logoutCalls, isEmpty);
      h.secrets.fail = false;
      expect(await h.storage.accessToken(), saved);
      await h.repository.signOut();
      expect(await h.storage.hasAccessToken(), false);
    },
  );

  test(
    'an SDK PKCE cleanup error after preflight still emits a local signed-out state',
    () async {
      final h = _Harness(pkce: _BrokenPkce());
      addTearDown(h.close);
      await h.start();
      final states = <String?>[];
      final sub = h.repository.watchSession().listen(
        (s) => states.add(s?.userId),
      );
      addTearDown(sub.cancel);
      await h.repository.signOut();
      await Future<void>.delayed(Duration.zero);
      expect(h.repository.currentSession, isNull);
      expect(states.last, isNull);
      expect(await h.storage.hasAccessToken(), false);
      expect(await h.values.read(SecureAuthValues.pkceKey), isNull);
    },
  );

  test(
    'queued session persistence cannot overwrite the logout tombstone',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      await h.start();
      final entered = Completer<void>(), release = Completer<void>();
      final old = h.encoded;
      var first = true;
      h.secrets.intercept = (key, value) async {
        if (first && key.endsWith(h.values.sessionKey)) {
          first = false;
          entered.complete();
          await release.future;
        }
      };
      final running = h.storage.persistSession(old);
      await entered.future;
      final queued = h.storage.persistSession(old);
      final logout = h.repository.signOut();
      release.complete();
      await running;
      await queued;
      await logout;
      expect(await h.storage.hasAccessToken(), false);
      expect(await h.values.read(SecureAuthValues.pkceKey), isNull);
    },
  );

  test(
    'duplicate sign-out calls share a single preflight and SDK request',
    () async {
      final h = _Harness();
      addTearDown(h.close);
      await h.start();
      final logoutInvoked = Completer<void>();
      h.backend.logout = (request) {
        logoutInvoked.complete();
        return MockSupabase.json(request, {});
      };
      await Future.wait([h.repository.signOut(), h.repository.signOut()]);
      await logoutInvoked.future.timeout(const Duration(seconds: 1));
      expect(
        h.backend.calls
            .where((r) => r.url.path.endsWith('revoke_parent_authorization'))
            .length,
        1,
      );
      expect(h.backend.logoutCalls.length, 1);
    },
  );

  for (final route in [
    'home',
    'empty-family',
    'onboarding',
    'family-error',
    'family-loading',
  ]) {
    testWidgets(
      '$route exit works without a successful parent authorization revoke',
      (tester) async {
        final auth = fixture.SwitchingAuthRepository();
        final family = _OfflineFamily(child: route == 'home')
          ..failLoad = route == 'family-error';
        if (route == 'family-loading') {
          family.loading = Completer<List<Family>>();
        }
        if (route == 'empty-family') {
          family.families.add(
            const Family(
              id: 'family-1',
              name: 'empty',
              timezone: 'Asia/Shanghai',
              children: [],
            ),
          );
        }
        final scheduler = _Scheduler();
        await tester.pumpWidget(
          LearningPlanetApp(
            authRepository: auth,
            familyRepository: family,
            taskRepository: fixture.FakeTaskRepository(),
            notificationScheduler: scheduler,
          ),
        );
        if (route.endsWith('-loading')) {
          await tester.pump();
          await tester.pump();
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
        } else {
          await tester.pumpAndSettle();
        }
        if (route == 'home') {
          await tester.tap(find.byTooltip('更多'));
          await tester.pumpAndSettle();
        }
        final before = scheduler.clears;
        await tester.tap(find.text('退出登录'));
        await tester.pumpAndSettle();
        expect(find.text('登录学习星球'), findsOneWidget);
        expect(scheduler.clears, greaterThan(before));
        expect(family.revocations, 0);
        // Late results for the old account cannot reopen its protected route.
        family.loading?.complete(
          fixture.FakeFamilyRepository.withChild().families,
        );
        await tester.pumpAndSettle();
        expect(find.text('登录学习星球'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await auth.changes.close();
      },
    );
  }

  testWidgets('exit during account status loading ignores late status', (
    tester,
  ) async {
    final auth = fixture.SwitchingAuthRepository();
    final status = Completer<Map<String, dynamic>?>();
    final scheduler = _Scheduler();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(auth),
          familyRepositoryProvider.overrideWithValue(_OfflineFamily()),
          taskRepositoryProvider.overrideWithValue(
            fixture.FakeTaskRepository(),
          ),
          notificationSchedulerProvider.overrideWithValue(scheduler),
          accountDeletionStatusProvider.overrideWith((ref) => status.future),
        ],
        child: const MaterialApp(home: AuthGate()),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    expect(find.text('登录学习星球'), findsOneWidget);
    status.complete({'id': 'old-request', 'status': 'processing'});
    await tester.pumpAndSettle();
    expect(find.text('登录学习星球'), findsOneWidget);
    expect(scheduler.clears, greaterThan(0));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await auth.changes.close();
  });

  testWidgets(
    'offline SDK logout through the real app reaches login with credentials cleared',
    (tester) async {
      final h = _Harness();
      await h.start();
      final network = Completer<void>();
      h.backend.handle = (_) => throw const SocketException('offline');
      h.backend.logout = (r) async {
        await network.future;
        return MockSupabase.json(r, {});
      };
      final scheduler = _Scheduler();
      await tester.pumpWidget(
        LearningPlanetApp(
          authRepository: h.repository,
          familyRepository: _OfflineFamily(),
          taskRepository: fixture.FakeTaskRepository(),
          notificationScheduler: scheduler,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();
      expect(find.text('登录学习星球'), findsOneWidget);
      expect(await h.storage.hasAccessToken(), false);
      expect(await h.values.read(SecureAuthValues.pkceKey), isNull);
      expect(h.repository.currentSession, isNull);
      expect(find.text('退出未完成，本机家长权限已关闭。请重试。'), findsNothing);
      network.complete();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      // Drain fake-time listeners and the SDK's real isolate during disposal.
      var closed = false;
      final closing = h.close().then((_) => closed = true);
      for (var i = 0; i < 50 && !closed; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
      }
      expect(closed, true);
      await closing;
    },
  );

  testWidgets(
    'parent-mode exit locks locally even when the server is unreachable',
    (tester) async {
      final auth = fixture.SwitchingAuthRepository(), family = _OfflineFamily();
      await tester.pumpWidget(
        LearningPlanetApp(
          authRepository: auth,
          familyRepository: family,
          taskRepository: fixture.FakeTaskRepository(),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.text('今日任务')),
      );
      container.read(parentModeProvider.notifier).state = true;
      container.read(parentFamilyIdProvider.notifier).state = 'family-1';
      container.read(parentAuthorizedUntilProvider.notifier).state =
          DateTime.now().add(const Duration(minutes: 5));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('退出家长模式'));
      await tester.pumpAndSettle();
      expect(container.read(activeParentFamilyProvider), isNull);
      expect(container.read(parentModeProvider), false);
      expect(family.revocations, 1);
      expect(find.text('本机已退出家长模式。再次进入时请联网验证 PIN。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await auth.changes.close();
    },
  );

  testWidgets(
    'pending native cleanup blocks further interaction until logout settles',
    (tester) async {
      final auth = fixture.SwitchingAuthRepository(), scheduler = _Scheduler();
      await tester.pumpWidget(
        LearningPlanetApp(
          authRepository: auth,
          familyRepository: _OfflineFamily(),
          taskRepository: fixture.FakeTaskRepository(),
          notificationScheduler: scheduler,
        ),
      );
      await tester.pumpAndSettle();
      final waiting = scheduler.waiting = Completer<void>();
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('退出登录'));
      await tester.pump();
      expect(find.bySemanticsLabel('正在安全退出登录'), findsOneWidget);
      expect(find.byType(ModalBarrier), findsWidgets);
      waiting.complete();
      scheduler.waiting = null;
      await tester.pumpAndSettle();
      expect(find.text('登录学习星球'), findsOneWidget);
      expect(find.bySemanticsLabel('正在安全退出登录'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await auth.changes.close();
    },
  );

  testWidgets(
    'notification cleanup failure is handled and leaves local parent mode locked',
    (tester) async {
      final auth = fixture.SwitchingAuthRepository(), scheduler = _Scheduler();
      await tester.pumpWidget(
        LearningPlanetApp(
          authRepository: auth,
          familyRepository: _OfflineFamily(),
          taskRepository: fixture.FakeTaskRepository(),
          notificationScheduler: scheduler,
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.text('今日任务')),
      );
      container.read(parentModeProvider.notifier).state = true;
      container.read(parentFamilyIdProvider.notifier).state = 'family-1';
      container.read(parentAuthorizedUntilProvider.notifier).state =
          DateTime.now().add(const Duration(minutes: 5));
      scheduler.fail = true;
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();
      expect(container.read(activeParentFamilyProvider), isNull);
      expect(container.read(signingOutProvider), false);
      expect(find.text('退出未完成，本机家长权限已关闭。请重试。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      scheduler.fail = false;
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();
      expect(find.text('登录学习星球'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await auth.changes.close();
    },
  );

  testWidgets(
    'late PIN verification cannot restore locally revoked parent mode',
    (tester) async {
      final family = _OfflineFamily()
        ..verification = Completer<ParentPinVerification>();
      final container = ProviderContainer(
        overrides: [familyRepositoryProvider.overrideWithValue(family)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: Column(
                  children: [
                    TextButton(
                      onPressed: () =>
                          enterParentMode(context, ref, 'family-1'),
                      child: const Text('enter'),
                    ),
                    TextButton(
                      onPressed: () => clearLocalParentAuthorization(ref),
                      child: const Text('lock'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('enter'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '1234');
      await tester.tap(find.text('验证'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('lock'));
      await tester.pump();
      family.verification!.complete(
        ParentPinVerification(
          verified: true,
          remainingAttempts: 5,
          authorizedUntil: DateTime.now().add(const Duration(minutes: 10)),
        ),
      );
      await tester.pumpAndSettle();
      expect(container.read(parentModeProvider), false);
      expect(container.read(parentAuthorizedUntilProvider), isNull);
      expect(find.text('已进入家长模式'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
