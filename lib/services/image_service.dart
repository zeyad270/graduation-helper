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

      if (image.width > 3000) {
        image = img.copyResize(image, width: 3000);
      } else if (image.width < 1000) {
        image = img.copyResize(image, width: 1500);
      }

      final directory = await getTemporaryDirectory();
      final processedPath = '${directory.path}/processed_${DateTime.now().millisecondsSinceEpoch}.jpg';
      // In preprocessImage, change quality from 95 to 75
      final processedFile = File(processedPath)
        ..writeAsBytesSync(img.encodeJpg(image, quality: 75));

      // Also tighten the resize — lower the max width
      if (image.width > 1800) {
        image = img.copyResize(image, width: 1800);
      } else if (image.width < 1000) {
        image = img.copyResize(image, width: 1200);
      }
      
      return processedFile;
    } catch (e) {
      debugPrint('Preprocessing error: $e');
      return File(imagePath);
    }
  }
}