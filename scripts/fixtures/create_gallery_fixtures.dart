import 'dart:io';
import '../../integration_test/support/gallery_fixture.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError('Provide the fixture output directory');
  }
  final destination = await Directory(args.single).create(recursive: true);
  for (final index in [1, 2]) {
    await File(
      '${destination.path}/LP_IMPORT_$index.png',
    ).writeAsBytes(galleryFixture(index));
  }
}
