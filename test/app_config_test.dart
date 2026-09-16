import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/core/config/app_config.dart';

void main() {
  test('accepts a complete backend configuration', () {
    const config = AppConfig(
      environment: AppEnvironment.staging,
      supabaseUrl: 'https://example.supabase.co',
      supabaseAnonKey: 'anon-key',
    );

    expect(config.hasBackendConfig, isTrue);
    expect(config.validate, returnsNormally);
  });

  test('rejects a partial backend configuration', () {
    const config = AppConfig(
      environment: AppEnvironment.development,
      supabaseUrl: '',
      supabaseAnonKey: 'anon-key',
    );

    expect(config.hasBackendConfig, isFalse);
    expect(config.validate, throwsStateError);
  });

  test('rejects a non-HTTPS backend URL', () {
    const config = AppConfig(
      environment: AppEnvironment.production,
      supabaseUrl: 'http://example.supabase.co',
      supabaseAnonKey: 'anon-key',
    );

    expect(config.validate, throwsStateError);
  });
}
