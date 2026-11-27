import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/features/auth_family/application/family_providers.dart';
import 'package:learning_planet/features/auth_family/domain/parent_authorization_clock.dart';
import 'package:learning_planet/features/data_management/data/account_deletion_repository.dart';
import 'package:learning_planet/features/data_management/presentation/account_deletion_gate.dart';

void main() {
  test(
    'an authorization expires across network delay and device sleep even if the phone clock changes',
    () {
      final server = DateTime.utc(2026, 11, 23, 12);
      var wall = server.add(const Duration(hours: 3));
      var elapsed = const Duration(hours: 9);
      final clock = ParentAuthorizationClock(() => elapsed, wall: () => wall);
      final started = clock.now();
      final deadline = ParentAuthorizationClock.deadline(started, {
        'server_now': server.toIso8601String(),
        'authorized_until': server
            .add(const Duration(minutes: 10))
            .toIso8601String(),
      });
      elapsed += const Duration(minutes: 2); // Verification response arrives.
      final container = ProviderContainer(
        overrides: [
          parentAuthorizationNowProvider.overrideWithValue(clock.now),
          authorizationClockProvider.overrideWith((_) => const Stream.empty()),
        ],
      );
      addTearDown(container.dispose);
      container.read(parentFamilyIdProvider.notifier).state = 'family';
      container.read(parentAuthorizedUntilProvider.notifier).state = deadline;
      container.read(parentModeProvider.notifier).state = true;
      expect(container.read(activeParentFamilyProvider), 'family');
      wall = server.subtract(const Duration(days: 2));
      expect(deadline.difference(clock.now()), const Duration(minutes: 8));
      elapsed += const Duration(minutes: 8); // The device slept.
      container.invalidate(activeParentFamilyProvider); // Foreground resume.
      expect(container.read(activeParentFamilyProvider), isNull);
      expect(
        () => ParentAuthorizationClock.deadline(started, {
          'authorized_until': server.toIso8601String(),
        }),
        throwsStateError,
      );
    },
  );
  testWidgets('the app expires a grant in the foreground and on resume', (
    tester,
  ) async {
    var now = DateTime.utc(2033);
    final container = ProviderContainer(
      overrides: [
        parentAuthorizationNowProvider.overrideWithValue(() => now),
        authorizationClockProvider.overrideWith((_) => const Stream.empty()),
        accountDeletionRepositoryProvider.overrideWithValue(null),
        accountDeletionStatusProvider.overrideWith(
          (_) async => {'id': 'job', 'status': 'completed'},
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(parentFamilyIdProvider.notifier).state = 'family';
    container.read(parentModeProvider.notifier).state = true;
    void authorize() =>
        container.read(parentAuthorizedUntilProvider.notifier).state = now.add(
          const Duration(minutes: 10),
        );
    authorize();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AccountDeletionGate()),
      ),
    );
    expect(container.read(activeParentFamilyProvider), 'family');
    now = now.add(const Duration(minutes: 10));
    await tester.pump(const Duration(minutes: 10));
    expect(container.read(activeParentFamilyProvider), isNull);
    authorize();
    expect(container.read(activeParentFamilyProvider), 'family');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 11));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(container.read(activeParentFamilyProvider), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
