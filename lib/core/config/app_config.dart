import 'package:flutter/foundation.dart';

enum AppEnvironment { development, staging, production }

class AppConfig {
  const AppConfig({
    required this.environment,
    required this.supabaseUrl,
    required this.supabaseAnonKey,
    this.parentRemotePush = false,
    this.taskRemotePush = false,
    this.localBackend = false,
  });

  final AppEnvironment environment;
  final String supabaseUrl;
  final String supabaseAnonKey;
  final bool parentRemotePush;
  final bool taskRemotePush;
  final bool localBackend;

  static AppConfig fromEnvironment() {
    const environmentName = String.fromEnvironment(
      'APP_ENV',
      defaultValue: 'development',
    );
    const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
    const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

    return AppConfig(
      environment: _parseEnvironment(environmentName),
      supabaseUrl: supabaseUrl,
      supabaseAnonKey: supabaseAnonKey,
      parentRemotePush: const bool.fromEnvironment('PARENT_REMOTE_PUSH'),
      taskRemotePush: const bool.fromEnvironment('TASK_REMOTE_PUSH'),
      localBackend: const bool.fromEnvironment('LOCAL_BACKEND'),
    );
  }

  bool get hasBackendConfig =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  bool get hasAnyBackendConfig =>
      supabaseUrl.isNotEmpty || supabaseAnonKey.isNotEmpty;

  void validate() {
    if (supabaseUrl.isEmpty || supabaseAnonKey.isEmpty) {
      throw StateError(
        'SUPABASE_URL and SUPABASE_ANON_KEY must both be configured.',
      );
    }
    final uri = Uri.tryParse(supabaseUrl);
    if (localBackend) {
      if (!kDebugMode ||
          environment != AppEnvironment.development ||
          uri == null ||
          uri.scheme != 'http' ||
          uri.host != '127.0.0.1' ||
          !uri.hasPort ||
          uri.port < 1024 ||
          uri.port > 65535 ||
          uri.userInfo.isNotEmpty ||
          (uri.path.isNotEmpty && uri.path != '/') ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw StateError(
          'LOCAL_BACKEND requires a debug development build and an explicit '
          'http://127.0.0.1:port origin.',
        );
      }
      return;
    }
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw StateError('SUPABASE_URL must be a valid HTTPS URL.');
    }
  }

  static AppEnvironment _parseEnvironment(String value) {
    return switch (value) {
      'development' => AppEnvironment.development,
      'staging' => AppEnvironment.staging,
      'production' => AppEnvironment.production,
      _ => throw StateError(
        'APP_ENV must be development, staging, or production.',
      ),
    };
  }
}
