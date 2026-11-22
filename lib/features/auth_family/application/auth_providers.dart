import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/auth_repository.dart';
import '../domain/auth_session.dart';

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => throw UnimplementedError('AuthRepository must be overridden.'),
);

final authSessionProvider = StreamProvider<AuthSession?>((ref) {
  return ref.watch(authRepositoryProvider).watchSession();
});

// An RPC can refresh the token that it uses. Account-scoped reads must survive
// that event while still discarding results from a previous account.
final authAccountIdProvider = Provider<String?>((ref) {
  return ref.watch(authSessionProvider).asData?.value?.userId;
});

final signingOutProvider = StateProvider<bool>((ref) => false);
