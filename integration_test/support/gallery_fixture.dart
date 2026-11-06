import 'dart:typed_data';
import 'package:image/image.dart' as image;

/// Synthetic album images; no captured photos, metadata, or child information.
Uint8List galleryFixture(int index) {
  final pixels = image.Image(width: 240, height: 160);
  image.fill(pixels, color: image.ColorRgb8(255, 255, 255));
  image.drawString(
    pixels,
    'LP IMPORT $index',
    font: image.arial24,
    x: 12,
    y: 50,
    color: image.ColorRgb8(0, 0, 0),
  );
  return Uint8List.fromList(image.encodePng(pixels));
}
