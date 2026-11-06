import 'dart:async';
import 'package:http/http.dart' as http;
import 'runtime_diagnostics.dart';

/// Measures through the end of response streaming, without reading or storing
/// headers, query strings, request/response bodies or private Storage paths.
class DiagnosticHttpClient extends http.BaseClient {
  DiagnosticHttpClient(this.inner, this.backend, this.diagnostics);
  final http.Client inner;
  final Uri backend;
  final RuntimeDiagnostics diagnostics;

  DiagnosticOperation? _operation(Uri uri) {
    if (uri.origin != backend.origin) return null;
    final path = uri.path;
    if (path == '/rest/v1/rpc/record_runtime_diagnostics') return null;
    if (path.startsWith('/rest/v1/')) return DiagnosticOperation.database;
    if (path.startsWith('/auth/v1/')) return DiagnosticOperation.auth;
    if (path.startsWith('/storage/v1/')) return DiagnosticOperation.storage;
    if (path.startsWith('/functions/v1/')) return DiagnosticOperation.edge;
    return null;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final operation = _operation(request.url);
    if (operation == null) return inner.send(request);
    final scope = diagnostics.capture(), watch = Stopwatch()..start();
    var recorded = false;
    void record(DiagnosticOutcome outcome, [Object? error]) {
      if (recorded) return;
      recorded = true;
      diagnostics.record(
        operation,
        outcome: outcome,
        error: error,
        elapsed: watch.elapsed,
        scope: scope,
      );
    }

    try {
      final response = await inner.send(request);
      final outcome = response.statusCode >= 500
          ? DiagnosticOutcome.serverError
          : response.statusCode == 401 || response.statusCode == 403
          ? DiagnosticOutcome.authorization
          : response.statusCode >= 400
          ? DiagnosticOutcome.clientError
          : DiagnosticOutcome.ok;
      StreamSubscription<List<int>>? subscription;
      late final StreamController<List<int>> measured;
      measured = StreamController<List<int>>(
        sync: true,
        onListen: () {
          subscription = response.stream.listen(
            measured.add,
            onError: (Object error, StackTrace stack) {
              // Record before forwarding: consumers may cancel on the first error.
              record(diagnosticFailure(error), error);
              measured.addError(error, stack);
            },
            onDone: () {
              record(outcome);
              unawaited(measured.close());
            },
          );
        },
        onPause: () => subscription?.pause(),
        onResume: () => subscription?.resume(),
        onCancel: () async {
          if (!recorded) record(DiagnosticOutcome.cancelled);
          await subscription?.cancel();
        },
      );

      return http.StreamedResponse(
        measured.stream,
        response.statusCode,
        headers: response.headers,
        contentLength: response.contentLength,
        request: response.request,
        reasonPhrase: response.reasonPhrase,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
      );
    } catch (error) {
      record(diagnosticFailure(error), error);
      rethrow;
    }
  }

  @override
  void close() => inner.close();
}
