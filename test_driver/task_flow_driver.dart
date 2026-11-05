import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  const destination = 'build/integration_results';
  await integrationDriver(
    writeResponseOnFailure: true,
    onScreenshot: (name, bytes, [args]) async {
      await Directory(destination).create(recursive: true);
      await File('$destination/$name.png').writeAsBytes(bytes, flush: true);
      return true;
    },
    responseDataCallback: (data) => writeResponseData(
      // Screenshots are saved as PNGs, not duplicated as giant JSON arrays.
      data == null ? null : ({...data}..remove('screenshots')),
      destinationDirectory: destination,
      testOutputFilename: 'task_flow',
    ),
  );
}
