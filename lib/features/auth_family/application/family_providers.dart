import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show Session, AuthRetryableFetchException;

import '../data/family_repository.dart';
import '../data/family_creation_repository.dart';
import '../data/family_members_repository.dart';
import '../data/offline_family_repository.dart';
import 'auth_providers.dart';
import '../domain/family.dart' as domain;
import '../domain/parent_authorization_clock.dart';

final familyRepositoryProvider = Provider<FamilyRepository>(
  (ref) => throw UnimplementedError('FamilyRepository must be overridden.'),
);

final familyCreationRepositoryProvider = Provider<FamilyCreationRepository?>((
  ref,
) {
  final repository = ref.watch(familyRepositoryProvider);
  return repository is FamilyCreationAccess
      ? (repository as FamilyCreationAccess).creations
      : null;
});

final familyMembersRepositoryProvider = Provider<FamilyMembersRepository?>((
  ref,
) {
  final repository = ref.watch(familyRepositoryProvider);
  if (repository is! OfflineFamilyRepository) return null;
  return FamilyMembersRepository(
    store: repository.store,
    remote: repository.membersRemote,
    accountId: repository.accountId,
    isAuthorized: (family) =>
        !ref.read(signingOutProvider) &&
        ref.read(activeParentFamilyProvider) == family &&
        (ref
                .read(parentAuthorizedUntilProvider)
                ?.isAfter(ref.read(parentAuthorizationNowProvider)()) ??
            false),
    authorizationRevision: () => ref.read(parentAuthorizationRevisionProvider),
  );
});

final familiesProvider = FutureProvider<List<domain.Family>>((ref) {
  final repository = ref.watch(familyRepositoryProvider);
  if (repository is OfflineFamilyRepository) {
    final entry = ref.read(familyEntryRefreshProvider);
    final failure = entry.takeFailure(repository.currentSession);
    return repository.loadFamilies(entryRefreshFailure: failure);
  }
  return repository.loadFamilies();
});

// A failed refresh is shared only by the two consecutive cold-entry checks.
// Refreshing the family list explicitly always makes a fresh request.
final familyEntryRefreshProvider = Provider((_) => FamilyEntryRefresh());

class FamilyEntryRefresh {
  ({Session session, AuthRetryableFetchException error})? _failure;
  String? _waitingForConnection;

  void record(Session session, AuthRetryableFetchException error) {
    _failure = (session: session, error: error);
  }

  void clearFailure() => _failure = null;

  AuthRetryableFetchException? takeFailure(Session? session) {
    final failure = _failure;
    clearFailure();
    if (failure == null || !identical(session, failure.session)) return null;
    _waitingForConnection = failure.session.user.id;
    return failure.error;
  }

  bool needsFamilyRefresh(String owner) {
    final refresh = _waitingForConnection == owner;
    _waitingForConnection = null;
    return refresh;
  }
}

final selectedChildIdProvider = StateProvider<String?>((ref) => null);

final parentModeProvider = StateProvider<bool>((ref) => false);
final parentAuthorizationRevisionProvider = StateProvider<int>((ref) => 0);

final parentFamilyIdProvider = StateProvider<String?>((ref) => null);

final parentAuthorizationNowProvider = Provider<DateTime Function()>(
  (ref) => ParentAuthorizationClock.device.now,
);

final parentAuthorizedUntilProvider = StateProvider<DateTime?>((ref) => null);
final authorizationClockProvider = StreamProvider<DateTime>((ref) async* {
  yield DateTime.now();
  yield* Stream.periodic(const Duration(seconds: 1), (_) => DateTime.now());
});
final activeParentFamilyProvider = Provider<String?>((ref) {
  final until = ref.watch(parentAuthorizedUntilProvider);
  if (!ref.watch(parentModeProvider) || until == null) return null;
  if (!until.isAfter(ref.watch(parentAuthorizationNowProvider)())) return null;
  return ref.watch(parentFamilyIdProvider);
});
