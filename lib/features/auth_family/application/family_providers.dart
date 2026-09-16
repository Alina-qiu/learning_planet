import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/family_repository.dart';
import '../domain/family.dart' as domain;

final familyRepositoryProvider = Provider<FamilyRepository>(
  (ref) => throw UnimplementedError('FamilyRepository must be overridden.'),
);

final familiesProvider = FutureProvider<List<domain.Family>>((ref) {
  return ref.watch(familyRepositoryProvider).loadFamilies();
});

final selectedChildIdProvider = StateProvider<String?>((ref) => null);

final parentModeProvider = StateProvider<bool>((ref) => false);

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
