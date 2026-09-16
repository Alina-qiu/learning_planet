import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'core/config/app_config.dart';
import 'features/auth_family/data/auth_repository.dart';
import 'features/auth_family/data/family_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();
  final AuthRepository authRepository;
  final FamilyRepository familyRepository;

  if (config.hasAnyBackendConfig) {
    config.validate();
    await Supabase.initialize(
      url: config.supabaseUrl,
      publishableKey: config.supabaseAnonKey,
    );
    authRepository = SupabaseAuthRepository(Supabase.instance.client);
    familyRepository = SupabaseFamilyRepository(Supabase.instance.client);
  } else {
    authRepository = const UnconfiguredAuthRepository();
    familyRepository = const UnconfiguredFamilyRepository();
  }

  runApp(
    LearningPlanetApp(
      authRepository: authRepository,
      familyRepository: familyRepository,
    ),
  );
}
