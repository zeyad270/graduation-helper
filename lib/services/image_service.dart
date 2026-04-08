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

      image = img.grayscale(image);
      image = img.adjustColor(image, contrast: 1.3, brightness: 1.1);

      // Resize BEFORE encoding (your current code does this after — a bug)
      if (image.width > 1200) {
        image = img.copyResize(image, width: 1200);
      } else if (image.width < 800) {
        image = img.copyResize(image, width: 800);
      }

      final directory = await getTemporaryDirectory();
      final processedPath =
          '${directory.path}/processed_${DateTime.now().millisecondsSinceEpoch}.jpg';

      // Lower quality: 55 instead of 75 — still readable for OCR
      final processedFile = File(processedPath)
        ..writeAsBytesSync(img.encodeJpg(image, quality: 55));

      return processedFile;
    } catch (e) {
      debugPrint('Preprocessing error: $e');
      return File(imagePath);
    }
  }
}