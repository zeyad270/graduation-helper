import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'image_service.dart';

class OcrServiceException implements Exception {
  final String message;
  final int? statusCode;

  const OcrServiceException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

class OcrService {
  static const List<String> _allKeys = [
    'title',
    'students',
    'supervisor',
    'year',
    'abstract',
    'technologies',
    'description',
    'keywords',
    'category',
    'problem',
    'solution',
    'objectives',
  ];

  static final Map<String, String> _preprocessedCache = {};

  static Uri _endpoint(String path) {
    final rawBaseUrl =
        dotenv.env['BACKEND_URL']?.trim().replaceAll(RegExp(r'/$'), '') ?? '';

    final baseUrl = rawBaseUrl.isNotEmpty
        ? rawBaseUrl
        : defaultTargetPlatform == TargetPlatform.android
        ? 'http://10.0.2.2:8080'
        : 'http://127.0.0.1:8080';

    return Uri.parse('$baseUrl$path');
  }

  static Future<String> _getPreprocessedPath(String originalPath) async {
    final cached = _preprocessedCache[originalPath];
    if (cached != null && await File(cached).exists()) {
      return cached;
    }

    final processed = await ImageService.preprocessImage(originalPath);
    _preprocessedCache[originalPath] = processed.path;
    return processed.path;
  }

  static Future<List<Map<String, String>>> _encodeImages(
    List<String> imagePaths,
    void Function(String step, double progress)? onProgress,
  ) async {
    final encoded = <Map<String, String>>[];

    if (imagePaths.isEmpty) return encoded;

    for (int i = 0; i < imagePaths.length; i++) {
      onProgress?.call(
        'Preparing page ${i + 1} of ${imagePaths.length}...',
        0.08 + ((i + 1) / imagePaths.length) * 0.22,
      );

      final processedPath = await _getPreprocessedPath(imagePaths[i]);
      final bytes = await File(processedPath).readAsBytes();
      encoded.add({
        'mimeType': 'image/jpeg',
        'data': base64Encode(bytes),
      });
    }

    return encoded;
  }

  static Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> payload,
  ) async {
    http.Response response;

    try {
      response = await http
          .post(
            _endpoint(path),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 360));
    } on SocketException {
      throw const OcrServiceException(
        'Could not reach the backend server. Start backend/server.js and check BACKEND_URL.',
      );
    } on HttpException {
      throw const OcrServiceException(
        'Network error while contacting the backend server.',
      );
    } on TimeoutException {
      throw const OcrServiceException(
        'The backend took too long to respond. Check the server logs and try again.',
      );
    } on FormatException {
      throw const OcrServiceException('Invalid backend URL in BACKEND_URL.');
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw OcrServiceException(
        'Backend returned invalid JSON (${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = data['error']?.toString().trim();
      throw OcrServiceException(
        message?.isNotEmpty == true
            ? message!
            : 'Backend request failed (${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }

    if (data['ok'] == false) {
      throw OcrServiceException(
        data['error']?.toString() ?? 'Backend request failed.',
        statusCode: response.statusCode,
      );
    }

    return data;
  }

  static Future<Map<String, dynamic>> extractFromAll({
    List<String> imagePaths = const [],
    List<String> rawTexts = const [],
    void Function(String step, double progress)? onProgress,
  }) async {
    onProgress?.call('Preparing request...', 0.05);

    final images = await _encodeImages(imagePaths, onProgress);
    onProgress?.call('Sending pages to backend...', 0.38);

    final data = await _postJson('/extract', {
      'images': images,
      'rawTexts': rawTexts,
    });

    onProgress?.call('Done', 1.0);
    return _normalizeFields(data['fields']);
  }

  static Future<Map<String, dynamic>> fillMissingFields({
    required Map<String, String> existingFields,
    List<String> imagePaths = const [],
    void Function(String step, double progress)? onProgress,
  }) async {
    onProgress?.call('Preparing context...', 0.08);
    final images = await _encodeImages(imagePaths, onProgress);
    onProgress?.call('Sending request...', 0.38);

    final data = await _postJson('/fill-missing', {
      'existingFields': existingFields,
      'images': images,
    });

    final filledFields = _normalizeFields(data['filledFields']);
    final summary = data['summary']?.toString() ?? '';

    onProgress?.call('Done', 1.0);
    return {
      'filledFields': filledFields,
      'summary': summary,
    };
  }

  static Future<String> generateFieldFromContext({
    required String fieldName,
    required Map<String, String> allFields,
    List<String> imagePaths = const [],
  }) async {
    final images = await _encodeImages(imagePaths, null);
    final data = await _postJson('/generate-field', {
      'fieldName': fieldName,
      'allFields': allFields,
      'images': images,
    });

    return data['value']?.toString().trim() ?? '';
  }

  static Future<String> generateSummary({
    required Map<String, String> existingFields,
    List<String> imagePaths = const [],
  }) async {
    final images = await _encodeImages(imagePaths, null);
    final data = await _postJson('/generate-summary', {
      'existingFields': existingFields,
      'images': images,
    });

    return data['summary']?.toString().trim() ?? '';
  }

  static Future<String> extractSingleField(
    String fieldName, {
    List<String> imagePaths = const [],
    String fallbackText = '',
  }) async {
    final images = await _encodeImages(imagePaths, null);
    final data = await _postJson('/extract-single-field', {
      'fieldName': fieldName,
      'images': images,
      'fallbackText': fallbackText,
    });

    return data['value']?.toString().trim() ?? '';
  }

  static Future<String> smartScanForField({
    required String fieldName,
    required String imagePath,
  }) async {
    final images = await _encodeImages([imagePath], null);
    final data = await _postJson('/smart-scan-field', {
      'fieldName': fieldName,
      'images': images,
    });

    return data['value']?.toString().trim() ?? '';
  }

  static Future<Map<String, dynamic>> extractFromImage(
    String base64Image, {
    String? fallbackOcrText,
  }) async {
    final data = await _postJson('/extract', {
      'images': [
        {'mimeType': 'image/jpeg', 'data': base64Image},
      ],
      'rawTexts': [
        if (fallbackOcrText != null && fallbackOcrText.trim().isNotEmpty)
          fallbackOcrText,
      ],
    });

    return _normalizeFields(data['fields']);
  }

  static Future<Map<String, dynamic>> processOCR(String rawText) async {
    final data = await _postJson('/extract', {
      'images': const [],
      'rawTexts': [rawText],
    });

    return _normalizeFields(data['fields']);
  }

  static Map<String, dynamic> _normalizeFields(dynamic raw) {
    final map = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final normalized = <String, dynamic>{};

    for (final key in [..._allKeys, 'summary']) {
      final value = map[key];
      if (value is Map) {
        normalized[key] = {
          'value': value['value']?.toString() ?? '',
          'confidence': (value['confidence'] as num?)?.toDouble() ?? 0.0,
        };
      } else {
        normalized[key] = {
          'value': value?.toString() ?? '',
          'confidence': 0.0,
        };
      }
    }

    return normalized;
  }
}
