import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'core/config/app_config.dart';
import 'features/auth_family/data/auth_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();
  final AuthRepository authRepository;

  if (config.hasAnyBackendConfig) {
    config.validate();
    await Supabase.initialize(
      url: config.supabaseUrl,
      publishableKey: config.supabaseAnonKey,
    );
    authRepository = SupabaseAuthRepository(Supabase.instance.client);
  } else {
    authRepository = const UnconfiguredAuthRepository();
  }

  runApp(LearningPlanetApp(authRepository: authRepository));
}
