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

  test(
    'explicit local development configuration accepts only a loopback origin',
    () {
      const config = AppConfig(
        environment: AppEnvironment.development,
        supabaseUrl: 'http://127.0.0.1:54321',
        supabaseAnonKey: 'local-anon',
        localBackend: true,
      );
      expect(config.validate, returnsNormally);
    },
  );

  test(
    'local HTTP still requires explicit opt-in and a development environment',
    () {
      for (final environment in AppEnvironment.values) {
        for (final enabled in [false, true]) {
          if (environment == AppEnvironment.development && enabled) continue;
          final config = AppConfig(
            environment: environment,
            supabaseUrl: 'http://127.0.0.1:54321',
            supabaseAnonKey: 'local-anon',
            localBackend: enabled,
          );
          expect(config.validate, throwsStateError);
        }
      }
    },
  );

  test(
    'local mode rejects external hosts, URL credentials and non-origin URLs',
    () {
      for (final url in [
        'http://example.com:54321',
        'http://127.0.0.1.example.com:54321',
        'http://192.168.1.1:54321',
        'http://0.0.0.0:54321',
        'http://127.0.0.1',
        'http://127.0.0.1:80',
        'http://user:password@127.0.0.1:54321',
        'http://127.0.0.1:54321/redirect',
        'http://127.0.0.1:54321?host=other',
        'http://127.0.0.1:54321#other',
        'https://example.supabase.co',
      ]) {
        final config = AppConfig(
          environment: AppEnvironment.development,
          supabaseUrl: url,
          supabaseAnonKey: 'local-anon',
          localBackend: true,
        );
        expect(config.validate, throwsStateError, reason: url);
      }
    },
  );
}
