import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) => writeResponseData(
    data,
    destinationDirectory: 'build/integration_results',
    testOutputFilename: data?['reader_pass'] == 'initial'
        ? 'cross_device_sync_ios_initial'
        : 'cross_device_sync_${data?['device'] ?? 'unknown'}',
  ),
);
