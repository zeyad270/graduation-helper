import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  const workspace = 'D:/helper_app/Graduation-GPRR-Helper';
  const sourcePath =
      'C:/Users/DELL 3520/.codex/generated_images/019dbadf-1cb3-7242-8e58-4c2fa449ad74/ig_0cc24eefc5dc5a190169eb5dc3a4f481918d33fa2b43c59578.png';

  final sourceFile = File(sourcePath);
  if (!sourceFile.existsSync()) {
    stderr.writeln('Source logo not found: $sourcePath');
    exit(1);
  }

  final decoded = img.decodeImage(sourceFile.readAsBytesSync());
  if (decoded == null) {
    stderr.writeln('Could not decode source logo.');
    exit(1);
  }

  final brandingDir = Directory('$workspace/assets/branding');
  brandingDir.createSync(recursive: true);

  final transparentLogo = _prepareLogo(decoded);
  _writePng('$workspace/assets/branding/app_logo_master.png', transparentLogo);

  final splashCanvas = _createSplashCanvas(transparentLogo, 1200, 0xFFF7F8FF);
  _writePng('$workspace/assets/branding/splash.png', splashCanvas);
  _writePng(
    '$workspace/android/app/src/main/res/drawable-nodpi/launch_brand.png',
    splashCanvas,
  );

  const androidIcons = {
    'mipmap-mdpi/ic_launcher.png': 48,
    'mipmap-hdpi/ic_launcher.png': 72,
    'mipmap-xhdpi/ic_launcher.png': 96,
    'mipmap-xxhdpi/ic_launcher.png': 144,
    'mipmap-xxxhdpi/ic_launcher.png': 192,
  };

  for (final entry in androidIcons.entries) {
    final icon = _createIconCanvas(transparentLogo, entry.value);
    _writePng('$workspace/android/app/src/main/res/${entry.key}', icon);
  }

  const iosIcons = {
    'Icon-App-20x20@1x.png': 20,
    'Icon-App-20x20@2x.png': 40,
    'Icon-App-20x20@3x.png': 60,
    'Icon-App-29x29@1x.png': 29,
    'Icon-App-29x29@2x.png': 58,
    'Icon-App-29x29@3x.png': 87,
    'Icon-App-40x40@1x.png': 40,
    'Icon-App-40x40@2x.png': 80,
    'Icon-App-40x40@3x.png': 120,
    'Icon-App-60x60@2x.png': 120,
    'Icon-App-60x60@3x.png': 180,
    'Icon-App-76x76@1x.png': 76,
    'Icon-App-76x76@2x.png': 152,
    'Icon-App-83.5x83.5@2x.png': 167,
    'Icon-App-1024x1024@1x.png': 1024,
  };

  for (final entry in iosIcons.entries) {
    final icon = _createIconCanvas(transparentLogo, entry.value);
    _writePng(
      '$workspace/ios/Runner/Assets.xcassets/AppIcon.appiconset/${entry.key}',
      icon,
    );
  }

  final iosLaunch1x = _createSplashCanvas(transparentLogo, 220, 0xFFF7F8FF);
  final iosLaunch2x = _createSplashCanvas(transparentLogo, 440, 0xFFF7F8FF);
  final iosLaunch3x = _createSplashCanvas(transparentLogo, 660, 0xFFF7F8FF);
  _writePng(
    '$workspace/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage.png',
    iosLaunch1x,
  );
  _writePng(
    '$workspace/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@2x.png',
    iosLaunch2x,
  );
  _writePng(
    '$workspace/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png',
    iosLaunch3x,
  );

  const webIcons = {
    'favicon.png': 64,
    'icons/Icon-192.png': 192,
    'icons/Icon-512.png': 512,
    'icons/Icon-maskable-192.png': 192,
    'icons/Icon-maskable-512.png': 512,
  };

  for (final entry in webIcons.entries) {
    final icon = _createIconCanvas(transparentLogo, entry.value);
    _writePng('$workspace/web/${entry.key}', icon);
  }
}

img.Image _prepareLogo(img.Image source) {
  final square = img.copyResizeCropSquare(source, size: 1024);
  final trimmed = img.trim(square);
  final content = trimmed ?? square;
  return img.copyResize(
    content,
    width: 860,
    interpolation: img.Interpolation.average,
  );
}

img.Image _createIconCanvas(img.Image logo, int size) {
  final canvas = img.Image(width: size, height: size);
  img.fill(canvas, color: img.ColorRgb8(247, 248, 255));

  final logoSize = (size * 0.8).round();
  final scaled = img.copyResize(
    logo,
    width: logoSize,
    height: logoSize,
    interpolation: img.Interpolation.average,
  );

  final x = ((size - scaled.width) / 2).round();
  final y = ((size - scaled.height) / 2).round();
  img.compositeImage(canvas, scaled, dstX: x, dstY: y);
  return canvas;
}

img.Image _createSplashCanvas(img.Image logo, int size, int backgroundHex) {
  final canvas = img.Image(width: size, height: size);
  img.fill(canvas, color: _hex(backgroundHex));

  final logoSize = (size * 0.42).round();
  final scaled = img.copyResize(
    logo,
    width: logoSize,
    interpolation: img.Interpolation.average,
  );
  final x = ((size - scaled.width) / 2).round();
  final y = ((size - scaled.height) / 2).round();
  img.compositeImage(canvas, scaled, dstX: x, dstY: y);
  return canvas;
}

img.Color _hex(int hex) => img.ColorRgb8(
  (hex >> 16) & 0xFF,
  (hex >> 8) & 0xFF,
  hex & 0xFF,
);

void _writePng(String path, img.Image image) {
  final file = File(path)..parent.createSync(recursive: true);
  file.writeAsBytesSync(img.encodePng(image));
}
