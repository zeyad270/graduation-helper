import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

class ImageService {
  static Future<File> preprocessImage(String imagePath) async {
    try {
      final imageFile = File(imagePath);
      final bytes = await imageFile.readAsBytes();

      img.Image? image = img.decodeImage(bytes);
      if (image == null) return imageFile;

      // Fix camera rotation
      image = img.bakeOrientation(image);

      // Strip alpha channel (PNG fix)
      if (image.numChannels == 4) {
        image = image.convert(numChannels: 3);
      }

      // Only DOWNSCALE — never upscale small images
      if (image.width > 1200) {
        image = img.copyResize(
          image,
          width: 1200,
          interpolation: img.Interpolation.linear,
        );
      }
      // Removed the upscale-to-800 block — it was inflating small images

      // Enhance for OCR
      image = img.grayscale(image);
      image = img.adjustColor(image, contrast: 1.3, brightness: 1.1);

      final directory = await getTemporaryDirectory();
      final processedPath =
          '${directory.path}/processed_${DateTime.now().millisecondsSinceEpoch}.jpg';

      final processedFile = File(processedPath)
        ..writeAsBytesSync(
          img.encodeJpg(image, quality: 40),
        ); // 40 instead of 55

      final originalKb = bytes.length / 1024;
      final processedKb = processedFile.lengthSync() / 1024;

      debugPrint(
        '[ImageService] ${imagePath.split('/').last} → '
        '${originalKb.toStringAsFixed(0)} KB → '
        '${processedKb.toStringAsFixed(0)} KB',
      );

      // If processing made it bigger somehow, just use lower quality encode
      if (processedFile.lengthSync() > bytes.length) {  
        final fallback = File(processedPath)
          ..writeAsBytesSync(img.encodeJpg(image, quality: 25));
        debugPrint(
          '[ImageService] Used fallback quality, '
          'final: ${(fallback.lengthSync() / 1024).toStringAsFixed(0)} KB',
        );
        return fallback;
      }

      return processedFile;
    } catch (e) {
      debugPrint('[ImageService] Preprocessing error: $e');
      return File(imagePath);
    }
  }
}
