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
