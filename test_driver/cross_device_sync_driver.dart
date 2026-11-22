import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    // The coordinator writes Android's report after validating the device POST.
    if (data?['device'] != 'ios') return;
    await writeResponseData(
      data,
      destinationDirectory: 'build/integration_results',
      testOutputFilename: data?['reader_pass'] == 'initial'
          ? 'cross_device_sync_ios_initial'
          : 'cross_device_sync_ios',
    );
  },
);
