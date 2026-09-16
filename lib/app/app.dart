import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth_family/application/auth_providers.dart';
import '../features/auth_family/application/family_providers.dart';
import '../features/auth_family/data/auth_repository.dart';
import '../features/auth_family/data/family_repository.dart';
import '../features/auth_family/presentation/auth_gate.dart';
import 'theme.dart';

class LearningPlanetApp extends StatelessWidget {
  const LearningPlanetApp({
    required this.authRepository,
    required this.familyRepository,
    super.key,
  });

  final AuthRepository authRepository;
  final FamilyRepository familyRepository;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        authRepositoryProvider.overrideWithValue(authRepository),
        familyRepositoryProvider.overrideWithValue(familyRepository),
      ],
      child: MaterialApp(
        title: '学习星球',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: const AuthGate(),
      ),
    );
  }
}
