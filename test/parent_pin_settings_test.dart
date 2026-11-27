import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:learning_planet/features/auth_family/application/auth_providers.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/domain/auth_session.dart';
import 'package:learning_planet/features/auth_family/domain/family.dart';
import 'package:learning_planet/features/auth_family/presentation/family_management_screen.dart';
import 'widget_test.dart' as fixture;

class _Auth extends fixture.FakeAuthRepository {
  AuthSession? session = const AuthSession(userId: 'parent-1');
  @override
  AuthSession? get currentSession => session;
}

class _Family extends fixture.FakeFamilyRepository {
  _Family() : super.withChild();
  Completer<void>? save;
  Completer<ParentPinVerification>? verification;
  int saves = 0, verifies = 0;
  Object? saveError, verifyError;
  @override
  Future<void> setParentPin({
    required String familyId,
    required String pin,
  }) async {
    saves++;
    expect(familyId, 'family-1');
    expect(pin, '2468');
    if (saveError != null) throw saveError!;
    await save?.future;
  }

  @override
  Future<ParentPinVerification> verifyParentPin({
    required String familyId,
    required String pin,
  }) async {
    verifies++;
    expect(familyId, 'family-1');
    expect(pin, '2468');
    if (verifyError != null) throw verifyError!;
    return verification == null ? verified() : await verification!.future;
  }
}

ParentPinVerification verified() => ParentPinVerification(
  verified: true,
  remainingAttempts: 5,
  authorizedUntil: DateTime.now().add(const Duration(minutes: 10)),
);

Future<ProviderContainer> _showSettings(
  WidgetTester tester,
  _Family family,
  _Auth auth,
) async {
  final container = ProviderContainer(
    overrides: [
      familyRepositoryProvider.overrideWithValue(family),
      authRepositoryProvider.overrideWithValue(auth),
      authorizationClockProvider.overrideWith(
        (ref) => Stream.value(DateTime.now()),
      ),
    ],
  );
  container.read(parentFamilyIdProvider.notifier).state = 'family-1';
  container.read(parentModeProvider.notifier).state = true;
  container.read(parentAuthorizedUntilProvider.notifier).state = DateTime.now()
      .add(const Duration(minutes: 5));
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: FamilyManagementScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> submitPin(WidgetTester tester) async {
  await tester.tap(find.text('家长 PIN'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(EditableText).first, '2468');
  expect(find.byType(EditableText), findsNWidgets(2));
  await tester.enterText(find.byType(EditableText).last, '2468');
  await tester.tap(find.text('保存'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('PIN update validates both entries and cancel makes no request', (
    tester,
  ) async {
    final family = _Family();
    await _showSettings(tester, family, _Auth());
    await tester.tap(find.text('家长 PIN'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, '12x');
    await tester.enterText(find.byType(EditableText).last, '2468');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请输入4至6位数字'), findsOneWidget);
    expect(find.text('两次 PIN 不一致'), findsOneWidget);
    expect(family.saves, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(family.verifies, 0);
    expect(find.text('家长 PIN'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'one pending change disables duplicate submission and valid verification renews the same family',
    (tester) async {
      final family = _Family()..save = Completer<void>();
      final container = await _showSettings(tester, family, _Auth());
      final oldUntil = container.read(parentAuthorizedUntilProvider)!;
      await submitPin(tester);
      await tester.tap(find.text('PIN 设置中…'));
      await tester.pumpAndSettle();
      expect(family.saves, 1);
      expect(family.verifies, 0);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'PIN 设置中…'),
            )
            .onPressed,
        isNull,
      );
      family.save!.complete();
      await tester.pumpAndSettle();
      expect(family.verifies, 1);
      expect(container.read(activeParentFamilyProvider), 'family-1');
      expect(
        container.read(parentAuthorizedUntilProvider)!.isAfter(oldUntil),
        true,
      );
      expect(find.text('家长 PIN 已更新'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'an expired authorization while the PIN dialog is open sends no mutation',
    (tester) async {
      final family = _Family();
      final container = await _showSettings(tester, family, _Auth());
      await tester.tap(find.text('家长 PIN'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).first, '2468');
      await tester.enterText(find.byType(EditableText).last, '2468');
      container.read(parentAuthorizedUntilProvider.notifier).state = DateTime(
        2000,
      );
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(family.saves, 0);
      expect(family.verifies, 0);
      expect(container.read(activeParentFamilyProvider), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a changed login after PIN save starts no follow-up verification', (
    tester,
  ) async {
    final family = _Family()..save = Completer<void>();
    final auth = _Auth();
    final container = await _showSettings(tester, family, auth);
    final before = container.read(parentAuthorizedUntilProvider);
    await submitPin(tester);
    // Even before AuthGate has processed its stream event, owner identity guards
    // the follow-up RPC against being sent with a different login.
    auth.session = const AuthSession(userId: 'parent-2');
    family.save!.complete();
    await tester.pumpAndSettle();
    expect(family.verifies, 0);
    expect(container.read(parentAuthorizedUntilProvider), before);
    expect(find.text('家长 PIN 已更新'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'PIN settings cannot restore authorization after local revocation',
    (tester) async {
      final family = _Family()
        ..verification = Completer<ParentPinVerification>();
      final container = await _showSettings(tester, family, _Auth());
      await submitPin(tester);
      expect(family.verifies, 1);
      container.read(parentAuthorizationRevisionProvider.notifier).state++;
      container.read(parentModeProvider.notifier).state = false;
      container.read(parentFamilyIdProvider.notifier).state = null;
      container.read(parentAuthorizedUntilProvider.notifier).state = null;
      await tester.pump();
      family.verification!.complete(verified());
      await tester.pumpAndSettle();
      expect(container.read(parentModeProvider), false);
      expect(container.read(parentAuthorizedUntilProvider), isNull);
      expect(find.text('家长 PIN 已更新'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a late verification failure cannot revoke a newly authorized family',
    (tester) async {
      final family = _Family()
        ..verification = Completer<ParentPinVerification>();
      final container = await _showSettings(tester, family, _Auth());
      await submitPin(tester);
      container.read(parentAuthorizationRevisionProvider.notifier).state++;
      container.read(parentFamilyIdProvider.notifier).state = 'family-2';
      final currentUntil = DateTime.now().add(const Duration(minutes: 7));
      container.read(parentAuthorizedUntilProvider.notifier).state =
          currentUntil;
      await tester.pump();
      family.verification!.completeError(StateError('private server detail'));
      await tester.pumpAndSettle();
      expect(container.read(activeParentFamilyProvider), 'family-2');
      expect(container.read(parentAuthorizedUntilProvider), currentUntil);
      expect(find.textContaining('private server detail'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final result in [
    const ParentPinVerification(verified: false, remainingAttempts: 0),
    const ParentPinVerification(verified: true, remainingAttempts: 5),
    ParentPinVerification(
      verified: true,
      remainingAttempts: 5,
      authorizedUntil: DateTime(2000),
    ),
  ].indexed) {
    testWidgets(
      'invalid PIN authorization result ${result.$1} cannot display success',
      (tester) async {
        final family = _Family()
          ..verification = (Completer<ParentPinVerification>()
            ..complete(result.$2));
        final container = await _showSettings(tester, family, _Auth());
        await submitPin(tester);
        expect(container.read(activeParentFamilyProvider), isNull);
        expect(container.read(parentModeProvider), false);
        expect(container.read(parentAuthorizedUntilProvider), isNull);
        expect(find.textContaining('PIN 已保存，但未取得有效家长授权'), findsOneWidget);
        expect(find.text('家长 PIN 已更新'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final failsDuringSave in [true, false]) {
    testWidgets(
      'PIN ${failsDuringSave ? 'save' : 'verification'} error is actionable without echoing credentials or retrying',
      (tester) async {
        final family = _Family();
        if (failsDuringSave) {
          family.saveError = StateError('private 2468 response');
        } else {
          family.verifyError = StateError('private 2468 response');
        }
        final container = await _showSettings(tester, family, _Auth());
        await submitPin(tester);
        expect(family.saves, 1);
        expect(family.verifies, failsDuringSave ? 0 : 1);
        expect(container.read(activeParentFamilyProvider), isNull);
        expect(
          find.textContaining(
            failsDuringSave ? '尚未确认 PIN 是否保存' : 'PIN 已保存，但重新验证未完成',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('private 2468'), findsNothing);
        expect(find.text('家长 PIN 已更新'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'a server rejection is distinguished from an unknown save result',
    (tester) async {
      final family = _Family()
        ..saveError = const PostgrestException(
          message: 'private permission detail',
          code: '42501',
        );
      final container = await _showSettings(tester, family, _Auth());
      await submitPin(tester);
      expect(family.saves, 1);
      expect(family.verifies, 0);
      expect(container.read(activeParentFamilyProvider), isNull);
      expect(find.textContaining('PIN 修改未被服务端接受'), findsOneWidget);
      expect(find.textContaining('尚未确认 PIN 是否保存'), findsNothing);
      expect(find.textContaining('private permission'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'leaving settings while saving prevents a later verification RPC',
    (tester) async {
      final family = _Family()..save = Completer<void>();
      await _showSettings(tester, family, _Auth());
      await submitPin(tester);
      await tester.pumpWidget(const SizedBox());
      family.save!.complete();
      await tester.pumpAndSettle();
      expect(family.verifies, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an HTTP gateway error wrapped by Postgrest still has an unknown save result',
    (tester) async {
      final family = _Family()
        ..saveError = const PostgrestException(
          message: '<html>private 2468 gateway detail</html>',
          code: '503',
        );
      final container = await _showSettings(tester, family, _Auth());
      await submitPin(tester);
      expect(family.saves, 1);
      expect(family.verifies, 0);
      expect(container.read(activeParentFamilyProvider), isNull);
      expect(find.textContaining('尚未确认 PIN 是否保存'), findsOneWidget);
      expect(find.textContaining('PIN 修改未被服务端接受'), findsNothing);
      expect(find.textContaining('private 2468'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'family settings and PIN fields remain reachable at 360px and double text size',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final family = _Family();
      await _showSettings(tester, family, _Auth());
      final addChild = find.widgetWithText(FilledButton, '添加孩子');
      await tester.ensureVisible(addChild);
      expect(addChild.hitTestable(), findsOneWidget);
      expect(
        tester.getRect(addChild).bottom <=
            tester.getRect(find.byType(Card).first).top,
        true,
      );
      await tester.ensureVisible(find.text('家长 PIN'));
      await tester.tap(find.text('家长 PIN'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(EditableText).first);
      await tester.enterText(find.byType(EditableText).first, '2468');
      await tester.ensureVisible(find.byType(EditableText).last);
      await tester.enterText(find.byType(EditableText).last, '2468');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(family.saves, 1);
      expect(find.text('家长 PIN 已更新'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
