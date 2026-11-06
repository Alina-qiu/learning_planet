import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/family_repository.dart';
import '../data/family_creation_repository.dart';
import '../data/family_members_repository.dart';
import '../data/offline_family_repository.dart';
import 'auth_providers.dart';
import '../domain/family.dart' as domain;

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
        (ref.read(parentAuthorizedUntilProvider)?.isAfter(DateTime.now()) ??
            false),
    authorizationRevision: () => ref.read(parentAuthorizationRevisionProvider),
  );
});

final familiesProvider = FutureProvider<List<domain.Family>>((ref) {
  return ref.watch(familyRepositoryProvider).loadFamilies();
});

final selectedChildIdProvider = StateProvider<String?>((ref) => null);

final parentModeProvider = StateProvider<bool>((ref) => false);
final parentAuthorizationRevisionProvider = StateProvider<int>((ref) => 0);

final parentFamilyIdProvider = StateProvider<String?>((ref) => null);

final parentAuthorizedUntilProvider = StateProvider<DateTime?>((ref) => null);
final authorizationClockProvider = StreamProvider<DateTime>((ref) async* {
  yield DateTime.now();
  yield* Stream.periodic(const Duration(seconds: 1), (_) => DateTime.now());
});
final activeParentFamilyProvider = Provider<String?>((ref) {
  final now = ref.watch(authorizationClockProvider).value ?? DateTime.now();
  final until = ref.watch(parentAuthorizedUntilProvider);
  return ref.watch(parentModeProvider) && until != null && now.isBefore(until)
      ? ref.watch(parentFamilyIdProvider)
      : null;
});
