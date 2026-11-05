import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;

import 'app/app.dart';
import 'app/startup_gate.dart';
import 'core/config/app_config.dart';
import 'core/diagnostics/diagnostic_http_client.dart';
import 'core/diagnostics/runtime_diagnostics.dart';
import 'core/diagnostics/native_diagnostics.dart';
import 'core/diagnostics/runtime_error_handlers.dart';
import 'core/diagnostics/startup_timings.dart';
import 'core/offline/offline_store.dart';
import 'core/security/device_secrets.dart';
import 'core/security/secure_auth_storage.dart';
import 'features/auth_family/data/offline_family_repository.dart';
import 'features/auth_family/data/family_access_repository.dart';
import 'features/tasks/data/offline_task_repository.dart';
import 'features/tasks/data/task_sync_remote.dart';
import 'features/auth_family/data/auth_repository.dart';
import 'features/auth_family/data/email_otp.dart';
import 'features/auth_family/data/family_repository.dart';
import 'features/tasks/data/task_repository.dart';
import 'features/tasks/data/notification_scheduler.dart';
import 'features/notifications/data/remote_parent_push.dart';

Future<void> main() async {
  startStartupMeasurement();
  measureStartupSync(
    StartupPhase.binding,
    WidgetsFlutterBinding.ensureInitialized,
  );
  if (startupMeasurementEnabled) {
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => recordStartupFirstFrame(),
    );
  }
  installRuntimeErrorHandlers(runtimeDiagnostics);
  runApp(
    RuntimeDiagnosticsLifecycle(
      diagnostics: runtimeDiagnostics,
      child: StartupGate(
        load: () => measureStartup(StartupPhase.initialization, initializeApp),
        onFailure: (error) => runtimeDiagnostics.record(
          DiagnosticOperation.startup,
          error: error,
        ),
      ),
    ),
  );
}

NativeDiagnostics? _nativeDiagnostics;

Future<Widget> initializeApp() async {
  await _nativeDiagnostics?.dispose();
  _nativeDiagnostics = null;
  runtimeDiagnostics.detach();
  final config = AppConfig.fromEnvironment();
  final AuthRepository authRepository;
  final FamilyRepository familyRepository;
  final TaskRepository taskRepository;
  const nativePush = MethodChannelParentPush();
  RemoteParentPush? remotePush;
  final notifications = LocalNotificationScheduler(
    onScopeChanged: (scope) =>
        remotePush?.setScope(scope) ?? Future<void>.value(),
  );
  // Clear the previous process's local alerts before restoring credentials or
  // opening a family. This also applies to an unconfigured debug installation.
  // Do this before acquiring backend/database resources so a failed clear can
  // safely retry through StartupGate.
  await measureStartup(
    StartupPhase.notifications,
    () => notifications.setScope(null),
  );

  if (config.hasAnyBackendConfig) {
    config.validate();
    final store = await measureStartup(
      StartupPhase.database,
      OfflineStore.open,
    );
    final authValues = SecureAuthValues(
      secrets: const NativeDeviceSecrets(),
      backendUrl: config.supabaseUrl,
    );
    final sessionStorage = SecureSessionStorage(
      authValues,
      isCurrentSession: (encoded) =>
          (jsonDecode(encoded) as Map)['access_token'] ==
          Supabase.instance.client.auth.currentSession?.accessToken,
    );
    // Preflight migration before the SDK starts session refresh or deep links.
    try {
      await measureStartup(StartupPhase.credentials, authValues.initialize);
    } catch (_) {
      await store.close();
      rethrow;
    }
    final transport = DiagnosticHttpClient(
      http.Client(),
      Uri.parse(config.supabaseUrl),
      runtimeDiagnostics,
    );
    try {
      await measureStartup(
        StartupPhase.supabase,
        () => Supabase.initialize(
          url: config.supabaseUrl,
          publishableKey: config.supabaseAnonKey,
          debug: false,
          httpClient: transport,
          authOptions: FlutterAuthClientOptions(
            localStorage: sessionStorage,
            pkceAsyncStorage: SecurePkceStorage(authValues),
          ),
        ),
      );
    } catch (_) {
      // The SDK sets its singleton before awaiting auth storage. Dispose a
      // partially initialized client so Retry performs a complete initialization.
      try {
        await Supabase.instance.dispose();
      } catch (_) {}
      transport.close();
      await store.close();
      rethrow;
    }
    final client = Supabase.instance.client;
    String? accountId() => client.auth.currentUser?.id;
    remotePush = RemoteParentPush(
      native: nativePush,
      remote: SupabaseParentPushRemote(
        client,
        SupabaseClient(
          config.supabaseUrl,
          config.supabaseAnonKey,
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      ),
      secrets: const NativeDeviceSecrets(),
      backendUrl: config.supabaseUrl,
      accountId: accountId,
      privacyGeneration: () => store.privacyGeneration,
      configured: config.parentRemotePush,
    );
    try {
      await measureStartup(StartupPhase.push, remotePush.initialize);
    } catch (_) {
      await Supabase.instance.dispose();
      transport.close();
      await store.close();
      rethrow;
    }
    authRepository = SupabaseAuthRepository(
      client,
      sessionStorage: sessionStorage,
      beforeSignOut: remotePush.disable,
      emailOtp: EmailOtpTransport(
        () => GoTrueClient(
          url: '${config.supabaseUrl}/auth/v1',
          headers: {'apikey': config.supabaseAnonKey},
          httpClient: transport,
          autoRefreshToken: false,
          flowType: AuthFlowType.implicit,
        ),
      ),
    );
    final nativeDiagnostics = _nativeDiagnostics = NativeDiagnostics(
      store: store,
      owner: accountId,
      diagnostics: runtimeDiagnostics,
    );
    runtimeDiagnostics.attach(
      store: store,
      owner: accountId,
      collectNative: nativeDiagnostics.synchronize,
      send: (events) async => Map<String, dynamic>.from(
        await client.rpc(
              'record_runtime_diagnostics',
              params: {'events': events},
            )
            as Map,
      ),
    );
    final access = FamilyAccessRepository(
      store: store,
      accountId: accountId,
      load: () => FamilyAccessRepository.fetch(client),
      cancelNotifications: (change) async {
        if (accountId() != change.owner) return;
        await notifications.cancelFamilyAccess(
          change.owner,
          change.familyId,
          change.childIds,
        );
        if (accountId() != change.owner) return;
        await remotePush?.disableFamilyAccess(change.owner, change.familyId);
      },
    );
    familyRepository = OfflineFamilyRepository(
      client,
      store,
      accountId,
      access: access,
    );
    final offline = OfflineTaskRepository(
      store: store,
      remote: SupabaseTaskSyncRemote(client),
      live: SupabaseTaskRepository(client),
      accountId: accountId,
      refreshFamilyAccess: access.refresh,
    );
    client.auth.onAuthStateChange.listen((_) {
      offline.scopeChanged();
      runtimeDiagnostics.scopeChanged();
      unawaited(nativeDiagnostics.synchronize());
    });
    unawaited(nativeDiagnostics.synchronize());
    taskRepository = offline;
  } else {
    unawaited(
      const MethodChannelNativeDiagnostics()
          .read(null)
          .then<void>((_) {}, onError: (Object _) {}),
    );
    await measureStartup(StartupPhase.push, nativePush.disable);
    authRepository = const UnconfiguredAuthRepository();
    familyRepository = const UnconfiguredFamilyRepository();
    taskRepository = const UnconfiguredTaskRepository();
  }

  return LearningPlanetApp(
    authRepository: authRepository,
    familyRepository: familyRepository,
    taskRepository: taskRepository,
    notificationScheduler: notifications,
    remotePush: remotePush,
  );
}
