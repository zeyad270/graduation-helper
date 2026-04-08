import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:grad_ocr_hive/services/image_service.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Vision-first OCR service with full reliability stack:
/// - Rotating API keys (up to 6) to maximize free quota
/// - Auto-retry with exponential backoff (up to 3 attempts)
/// - Enhanced prompt on retry if too few fields extracted
/// - JSON repair for truncated responses
/// - Regex salvage as last resort
/// - Per-field confidence scoring
/// - Smart semantic field scanning
/// - Fill-missing-fields from context
/// - Per-field AI generation from context
/// - Summary generation
class OcrService {

  // ═══════════════════════════════════════════════════════════════════════════
  // ✏️  PUT YOUR API KEYS HERE
  // ═══════════════════════════════════════════════════════════════════════════
  static List<String> get _apiKeys => [
    dotenv.env['GEMINI_KEY_1'] ?? '',
    dotenv.env['GEMINI_KEY_2'] ?? '',
    dotenv.env['GEMINI_KEY_3'] ?? '',
  ].where((k) => k.isNotEmpty).toList();
  // Add to OcrService class:
  static final Map<String, String> _preprocessedCache = {};

  static Future<String> _getPreprocessedPath(String originalPath) async {
    if (_preprocessedCache.containsKey(originalPath)) {
      final cached = _preprocessedCache[originalPath]!;
      if (await File(cached).exists()) return cached;
    }
    final processed = await ImageService.preprocessImage(originalPath);
    _preprocessedCache[originalPath] = processed.path;
    return processed.path;
  }
  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=';

  static const int _maxRetries  = 1;
  static const int _timeoutSecs = 45; // was 60
  static const int _maxTokens   = 4096; // was 8192

  static int _currentKeyIndex = 0;

  static String get _currentKey {
    for (int i = 0; i < _apiKeys.length; i++) {
      final idx = (_currentKeyIndex + i) % _apiKeys.length;
      if (!_apiKeys[idx].startsWith('YOUR_API_KEY')) {
        _currentKeyIndex = idx;
        return _apiKeys[idx];
      }
    }
    return _apiKeys[_currentKeyIndex];
  }

  static void _rotateKey() {
    _currentKeyIndex = (_currentKeyIndex + 1) % _apiKeys.length;
    print('[OCR] Rotated to key ${_currentKeyIndex + 1}/${_apiKeys.length}');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PUBLIC API
  // ═══════════════════════════════════════════════════════════════════════════

  /// Main extraction — sends all images to Gemini Vision in one call.
  /// Also generates a project summary in the same request.
  /// Returns extracted fields + a 'summary' key.
  static Future<Map<String, dynamic>> extractFromAll({
    List<String> imagePaths = const [],
    List<String> rawTexts   = const [],
    void Function(String step, double progress)? onProgress,
  }) async {
    onProgress?.call('Preparing pages...', 0.1);

    final parts = <Map<String, dynamic>>[];

    for (int i = 0; i < imagePaths.length; i++) {
      onProgress?.call(
        'Reading page ${i + 1} of ${imagePaths.length}...',
        0.1 + (i / imagePaths.length) * 0.3,
      );
      try {
        final processed = await ImageService.preprocessImage(imagePaths[i]);
        final bytes = await processed.readAsBytes(); // added this to get size after preprocessing
        if (bytes.length < 5000) {
          print('[OCR] Warning: page ${i+1} is very small — may be low quality');
        }
        parts.add({
          'inline_data': {'mime_type': 'image/jpeg', 'data': base64Encode(bytes)}
        });
        print('[OCR] Page ${i+1}: ${(bytes.length / 1024).toStringAsFixed(0)} KB');
      } catch (e) {
        print('[OCR] Failed to read image ${imagePaths[i]}: $e');
      }
    }

    if (rawTexts.isNotEmpty) {
      parts.add({'text': 'Additional text:\n${rawTexts.join('\n\n---\n\n')}'});
    }

    if (parts.isEmpty) {
      print('[OCR] No content to process');
      return _emptyResult();
    }

    String currentPrompt = _mainPromptWithSummary;
    Map<String, dynamic> bestResult = _emptyResult();
    int bestFilledCount = 0;

    for (int attempt = 1; attempt <= _maxRetries; attempt++) {
      if (attempt > 1) {
        final waitSecs = attempt * 2;
        print('[OCR] Retry $attempt/$_maxRetries — waiting ${waitSecs}s');
        onProgress?.call('Retrying extraction (attempt $attempt)...', 0.5 + attempt * 0.05);
        await Future.delayed(Duration(seconds: waitSecs));
        currentPrompt = _enhancedPromptWithSummary;
      } else {
        onProgress?.call('Analyzing with Gemini Vision...', 0.5);
      }

      final promptParts = [...parts, {'text': currentPrompt}];
      final raw = await _callGemini(promptParts);
      if (raw == null) continue;

      final result      = _parseResponse(raw);
      final filledCount = _allKeys
          .where((k) => (result[k]?['value'] as String? ?? '').isNotEmpty)
          .length;

      print('[OCR] Attempt $attempt: $filledCount/${_allKeys.length} fields filled');

      if (filledCount > bestFilledCount) {
        bestResult      = result;
        bestFilledCount = filledCount;
      }

      if (filledCount >= 4) break;
    }

    print('[OCR] Final result: $bestFilledCount fields extracted');
    onProgress?.call('Done', 1.0);
    return bestResult;
  }

  /// Fill missing fields + regenerate summary using existing field context + images.
  /// Only fills fields where the current value is empty or below threshold.
  /// Returns a full result map including a new 'summary'.
  static Future<Map<String, dynamic>> fillMissingFields({
    required Map<String, String> existingFields,
    List<String> imagePaths = const [],
    void Function(String step, double progress)? onProgress,
  }) async {
    onProgress?.call('Building context from existing fields...', 0.1);

    final parts = <Map<String, dynamic>>[];

    // Add images if available
    for (int i = 0; i < imagePaths.length; i++) {
      onProgress?.call('Loading page ${i + 1}...', 0.1 + (i / imagePaths.length) * 0.25);
      try {
        final processed = await ImageService.preprocessImage(imagePaths[i]);
        final bytes = await processed.readAsBytes();
        parts.add({
          'inline_data': {'mime_type': 'image/jpeg', 'data': base64Encode(bytes)}
        });
      } catch (e) {
        print('[OCR] Could not read $e');
      }
    }

    // Build a context summary of existing fields
    final contextLines = <String>[];
    existingFields.forEach((key, value) {
      if (value.isNotEmpty) {
        contextLines.add('$key: $value');
      }
    });

    // Identify missing fields
    final missingKeys = _allKeys
        .where((k) => (existingFields[k] ?? '').isEmpty)
        .toList();

    if (missingKeys.isEmpty) {
      // All fields present — just generate summary
      onProgress?.call('Generating summary...', 0.5);
      final summary = await generateSummary(existingFields: existingFields);
      onProgress?.call('Done', 1.0);
      return {'summary': summary, 'filledFields': {}};
    }

    onProgress?.call('Asking AI to fill ${missingKeys.length} missing fields...', 0.4);

    final contextText = contextLines.join('\n');
    final missingList = missingKeys.join(', ');

    final prompt = '''
You are analyzing a graduation project. Here is the known information about this project:

$contextText

${parts.isEmpty ? '' : 'Additional document pages are also provided above.'}

TASK: Based on ALL available context above, intelligently generate content for ONLY these missing fields: $missingList

For each missing field, infer or generate appropriate content:
- If the document pages show the content, COPY it verbatim
- If it can be inferred from other fields, generate it logically
- Use academic/professional tone appropriate for a graduation project
- For "category": pick ONE of: Medical, Education, Finance, E-Commerce, Social Media, Entertainment, Transportation, Smart Agriculture, IoT/Smart Home, Manufacturing, Other
- For "year": use current year if not found: ${DateTime.now().year}
- For long fields (abstract, description, problem, solution, objectives): write 2-4 professional sentences minimum if not found in document

Also generate a "summary" field: a 3-5 sentence executive summary of the entire project based on ALL known information. Make it professional, highlight the problem solved and key technologies.

Return a single valid JSON object with ONLY these keys: ${missingKeys.join(', ')}, summary
Use "" for any field you truly cannot determine even from context.
All values on ONE LINE. Return ONLY the JSON, no markdown, no backticks.
''';

    parts.add({'text': prompt});

    final raw = await _callGemini(parts, maxTokens: 4096, timeoutSecs: 60);
    if (raw == null) {
      onProgress?.call('Failed', 1.0);
      return {'summary': '', 'filledFields': {}};
    }

    onProgress?.call('Parsing results...', 0.85);

    // Parse the response
    try {
      String cleaned = raw.replaceAll('```json', '').replaceAll('```', '').trim();
      final first = cleaned.indexOf('{');
      final last  = cleaned.lastIndexOf('}');
      if (first == -1 || last == -1) return {'summary': '', 'filledFields': {}};
      cleaned = cleaned.substring(first, last + 1);
      cleaned = _repairJson(cleaned);
      final decoded = jsonDecode(cleaned) as Map<String, dynamic>;

      final filledFields = <String, Map<String, dynamic>>{};
      for (final key in missingKeys) {
        final val = decoded[key]?.toString().trim() ?? '';
        if (val.isNotEmpty) {
          filledFields[key] = {'value': val, 'confidence': _score(val, key)};
          print('[OCR] fillMissing + $key: "${val.substring(0, val.length.clamp(0, 60))}..."');
        }
      }

      final summary = decoded['summary']?.toString().trim() ?? '';
      onProgress?.call('Done', 1.0);
      return {'summary': summary, 'filledFields': filledFields};
    } catch (e) {
      print('[OCR] fillMissing parse error: $e');
      onProgress?.call('Done', 1.0);
      return {'summary': '', 'filledFields': {}};
    }
  }

  /// Generate content for a SINGLE field based on full project context.
  /// Used when user taps ✨ on an individual field.
  static Future<String> generateFieldFromContext({
    required String fieldName,
    required Map<String, String> allFields,
    List<String> imagePaths = const [],
  }) async {
    final parts = <Map<String, dynamic>>[];

    for (final path in imagePaths) {
      try {
        final bytes = await File(path).readAsBytes();
        parts.add({
          'inline_data': {'mime_type': 'image/jpeg', 'data': base64Encode(bytes)}
        });
      } catch (e) {
        print('[OCR] Could not read $path: $e');
      }
    }

    final contextLines = <String>[];
    allFields.forEach((key, value) {
      if (value.isNotEmpty && key != fieldName) {
        contextLines.add('$key: $value');
      }
    });

    final context = contextLines.join('\n');
    final fieldContext = _fieldContext[fieldName] ?? 'Content for $fieldName';
    final fieldInstruction = _fieldInstructions[fieldName] ?? 'Generate the $fieldName.';

    final prompt = '''
You are writing content for a graduation project field.

PROJECT CONTEXT:
$context

FIELD TO GENERATE: "$fieldName"
WHAT IT SHOULD CONTAIN: $fieldContext
INSTRUCTION: $fieldInstruction

RULES:
- If document images show the content verbatim, COPY it word-for-word
- Otherwise, infer and write professional academic content based on the project context
- Do NOT include section headings or labels in your output
- Write in a professional academic tone
- Be specific to this project, not generic
- For "category": return ONLY ONE of: Medical, Education, Finance, E-Commerce, Social Media, Entertainment, Transportation, Smart Agriculture, IoT/Smart Home, Manufacturing, Other
- For "year": return ONLY the 4-digit year
- Return ONLY the content — no labels, no JSON, no markdown
- If you truly cannot determine it: return NOT_FOUND
''';

    parts.add({'text': prompt});

    final raw = await _callGemini(parts, maxTokens: 2048, timeoutSecs: 40);
    if (raw == null) return '';
    final text = raw.trim();
    return text == 'NOT_FOUND' ? '' : text;
  }

  /// Generate a project summary from all available fields.
  /// Returns a plain-text summary string.
  static Future<String> generateSummary({
    required Map<String, String> existingFields,
    List<String> imagePaths = const [],
  }) async {
    final parts = <Map<String, dynamic>>[];

    for (final path in imagePaths) {
      try {
        final bytes = await File(path).readAsBytes();
        parts.add({
          'inline_data': {'mime_type': 'image/jpeg', 'data': base64Encode(bytes)}
        });
      } catch (e) {}
    }

    final contextLines = <String>[];
    existingFields.forEach((key, value) {
      if (value.isNotEmpty) contextLines.add('$key: $value');
    });

    parts.add({
      'text': '''
Based on this graduation project information:

${contextLines.join('\n')}

Write a professional 4-6 sentence executive summary of this project that:
1. Starts with what the project is and the problem it solves
2. Mentions the key technologies used
3. Highlights the main features or objectives
4. Mentions the team/supervisor if known
5. Ends with the project's impact or value

Write in a polished, academic tone. Return ONLY the summary text, no headings, no labels.
'''
    });

    final raw = await _callGemini(parts, maxTokens: 1024, timeoutSecs: 40);
    return raw?.trim() ?? '';
  }

  /// Re-extract a single field from already-scanned pages.
  static Future<String> extractSingleField(
    String fieldName, {
    List<String> imagePaths = const [],
    String fallbackText     = '',
  }) async {
    final instruction = _fieldInstructions[fieldName];
    if (instruction == null) return '';

    final parts = <Map<String, dynamic>>[];

    for (final path in imagePaths) {
      try {
        final bytes = await File(path).readAsBytes();
        parts.add({
          'inline_data': {'mime_type': 'image/jpeg', 'data': base64Encode(bytes)}
        });
      } catch (e) {
        print('[OCR] Could not read $path: $e');
      }
    }

    if (fallbackText.isNotEmpty) {
      parts.add({'text': 'Document text:\n$fallbackText'});
    }

    if (parts.isEmpty) return '';

    parts.add({
      'text': '$instruction\n\nReturn ONLY the extracted text. No labels. No JSON.\nIf not found: NOT_FOUND'
    });

    final raw = await _callGemini(parts, maxTokens: 2048, timeoutSecs: 40);
    if (raw == null) return '';

    final text = raw.trim();
    print('[OCR] extractSingleField ($fieldName): "${text.substring(0, text.length.clamp(0, 80))}..."');
    return text == 'NOT_FOUND' ? '' : text;
  }

  /// Smart override — reads any image, understands content semantically.
  static Future<String> smartScanForField({
    required String fieldName,
    required String imagePath,
  }) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final b64   = base64Encode(bytes);

      final context = _fieldContext[fieldName] ?? 'The $fieldName content.';

      final prompt =
          'You are reading a page from an Egyptian university graduation project.\n\n'
          'TASK: Extract content for the "$fieldName" field.\n\n'
          'WHAT TO LOOK FOR: $context\n\n'
          'RULES:\n'
          '- The section may use a DIFFERENT label — understand meaning, not just label\n'
          '- Remove ALL headings/labels from your output\n'
          '- COPY text EXACTLY word-for-word — do NOT paraphrase or summarize\n'
          '- Return COMPLETE text without truncating\n'
          '- Extract ONLY content from the visible section — do NOT pull from other sections\n'
          '- If page has no relevant content, return: NOT_FOUND\n\n'
          'Return ONLY the clean verbatim text. Nothing else.';

      final raw = await _callGemini([
        {'inline_data': {'mime_type': 'image/jpeg', 'data': b64}},
        {'text': prompt},
      ], maxTokens: 2048, timeoutSecs: 40);

      if (raw == null) return '';
      final text = raw.trim();
      print('[OCR] smartScan ($fieldName): "${text.substring(0, text.length.clamp(0, 80))}..."');
      return text == 'NOT_FOUND' ? '' : text;
    } catch (e) {
      print('[OCR] smartScanForField error: $e');
      return '';
    }
  }

  // Legacy compatibility
  static Future<Map<String, dynamic>> extractFromImage(
    String base64Image, {String? fallbackOcrText}) async {
    final raw = await _callGemini([
      {'inline_data': {'mime_type': 'image/jpeg', 'data': base64Image}},
      {'text': _mainPromptWithSummary},
    ]);
    return raw != null ? _parseResponse(raw) : _emptyResult();
  }

  static Future<Map<String, dynamic>> processOCR(String rawText) async {
    final raw = await _callGemini([
      {'text': 'Document text:\n$rawText\n\n$_mainPromptWithSummary'},
    ]);
    return raw != null ? _parseResponse(raw) : _emptyResult();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // GEMINI API CALL — with key rotation on 429
  // ═══════════════════════════════════════════════════════════════════════════

  static Future<String?> _callGemini(
    List<Map<String, dynamic>> parts, {
    int maxTokens   = _maxTokens,
    int timeoutSecs = _timeoutSecs,
  }) async {
    for (int keyAttempt = 0; keyAttempt < _apiKeys.length; keyAttempt++) {
      final key = _currentKey;
      try {
        final response = await http.post(
          Uri.parse('$_baseUrl$key'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [{'parts': parts}],
            'generationConfig': {
              'temperature': 0.1,
              'maxOutputTokens': maxTokens,
              'topP': 0.95,
            },
          }),
        ).timeout(Duration(seconds: timeoutSecs));

        print('[OCR] Status: ${response.statusCode} (key ${_currentKeyIndex + 1}/${_apiKeys.length})');

        if (response.statusCode == 429) {
          print('[OCR] Key ${_currentKeyIndex + 1} rate limited — rotating to next key');
          _rotateKey();
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }

        if (response.statusCode != 200) {
          final body = response.body;
          print('[OCR] Error: ${body.substring(0, body.length.clamp(0, 300))}');
          return null;
        }

        final decoded      = jsonDecode(response.body);
        final finishReason = decoded['candidates']?[0]?['finishReason'] as String?;

        if (finishReason == 'SAFETY' || finishReason == 'RECITATION') {
          print('[OCR] Blocked: $finishReason');
          return null;
        }

        if (finishReason == 'MAX_TOKENS') {
          print('[OCR] WARNING: Response truncated at $maxTokens tokens');
        }

        final text = decoded['candidates']?[0]?['content']?['parts']?[0]?['text'] as String?;
        if (text == null || text.isEmpty) {
          print('[OCR] Empty response');
          return null;
        }

        print('[OCR] Response: ${text.length} chars');
        return text;

      } on TimeoutException {
        print('[OCR] Timeout after ${timeoutSecs}s');
        return null;
      } catch (e) {
        print('[OCR] Call error: $e');
        return null;
      }
    }

    print('[OCR] All API keys exhausted or rate limited');
    return null;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // RESPONSE PARSING
  // ═══════════════════════════════════════════════════════════════════════════

  static Map<String, dynamic> _parseResponse(String raw) {
    try {
      String cleaned = raw
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();

      final first = cleaned.indexOf('{');
      final last  = cleaned.lastIndexOf('}');

      if (first == -1 || last == -1 || last <= first) {
        print('[OCR] No JSON object found — regex salvage');
        return _regexSalvage(raw);
      }

      cleaned = cleaned.substring(first, last + 1);
      cleaned = _repairJson(cleaned);

      final decoded = jsonDecode(cleaned) as Map<String, dynamic>;
      final result  = <String, dynamic>{};

      // Extract normal fields
      for (final key in _allKeys) {
        final val = decoded[key]?.toString().trim() ?? '';
        result[key] = {
          'value':      val,
          'confidence': _score(val, key),
        };
        if (val.isNotEmpty) {
          print('[OCR] + $key: "${val.substring(0, val.length.clamp(0, 55))}..."');
        }
      }

      // Extract summary if present
      final summaryVal = decoded['summary']?.toString().trim() ?? '';
      result['summary'] = {
        'value':      summaryVal,
        'confidence': summaryVal.isNotEmpty ? 0.95 : 0.0,
      };

      return result;
    } catch (e) {
      print('[OCR] Parse error: $e');
      return _regexSalvage(raw);
    }
  }

  static String _repairJson(String json) {
    try {
      jsonDecode(json);
      return json;
    } catch (_) {}

    String r      = json.trimRight();
    final quotes  = r.split('"').length - 1;
    if (quotes % 2 != 0) r += '"';

    int open = 0;
    for (final ch in r.runes) {
      if (ch == 123) open++;
      if (ch == 125) open--;
    }
    r += '}' * open.clamp(0, 5);

    try {
      jsonDecode(r);
      print('[OCR] Repaired truncated JSON');
      return r;
    } catch (_) {
      return json;
    }
  }

  static Map<String, dynamic> _regexSalvage(String raw) {
    print('[OCR] Regex salvage mode');
    final result = <String, dynamic>{};

    for (final key in [..._allKeys, 'summary']) {
      final match = RegExp('"$key"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"').firstMatch(raw);
      final value = match?.group(1)?.trim() ?? '';
      result[key] = {'value': value, 'confidence': value.isNotEmpty ? 0.6 : 0.0};
    }

    return result;
  }

  static double _score(String value, String key) {
    if (value.isEmpty) return 0.0;
    if (key == 'year')     return RegExp(r'^\d{4}$').hasMatch(value) ? 0.97 : 0.4;
    if (key == 'category') return 0.92;

    final isLong = ['abstract', 'description', 'problem', 'solution', 'objectives'].contains(key);
    if (isLong) {
      double score = 0.0;

      if (value.length > 500)      score += 0.35;
      else if (value.length > 300) score += 0.25;
      else if (value.length > 100) score += 0.15;
      else                         score += 0.05;

      final trimmed = value.trimRight();
      if (trimmed.endsWith('.') || trimmed.endsWith('?') ||
          trimmed.endsWith('!') || trimmed.endsWith(':')) {
        score += 0.25;
      } else if (trimmed.endsWith(',') || trimmed.endsWith(';')) {
        score += 0.05;
      }

      if (RegExp(r'(\d+[\.\)]|\•|\-)\s').hasMatch(value)) score += 0.20;

      final aiPhrases = [
        'in summary', 'to summarize', 'in conclusion',
        'the document states', 'according to the document',
        'the text mentions', 'as mentioned',
      ];
      final lower = value.toLowerCase();
      if (aiPhrases.any((p) => lower.contains(p))) score -= 0.30;

      if (value.length < 80) score -= 0.20;

      return score.clamp(0.0, 1.0);
    }

    return value.length > 5 ? 0.88 : 0.55;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PROMPTS & METADATA
  // ═══════════════════════════════════════════════════════════════════════════

  static const String _mainPromptWithSummary = '''
You are analyzing a graduation project document from an Egyptian university.
Formats vary widely. Use visual intelligence to find and extract each field.

Return a single valid JSON object. Use "" for missing fields.

FIELDS:
- title: Specific project name. NOT university/faculty/department. Usually prominent text.
- students: ALL student full names comma-separated. Look near "Project Team", "Prepared by", "By".
- supervisor: Supervisor with title (Dr./Prof./Eng.). Near "Supervisor"/"Supervised by". One name only.
- year: 4-digit year e.g. "2026".
- category: ONE of: Medical, Education, Finance, E-Commerce, Social Media, Entertainment, Transportation, Smart Agriculture, IoT/Smart Home, Manufacturing, Other
- technologies: Comma-separated tools/languages/frameworks. "" if not found.
- keywords: Only if explicit "Keywords:" section. "" otherwise.
- abstract: COPY word-for-word from the Abstract section ONLY. Every sentence. Do NOT truncate. Do NOT include any other section.
- description: COPY word-for-word from the first Overview or Introduction section ONLY. Stop at the next subheading. Do NOT combine multiple sections.
- problem: COPY word-for-word from the Problem section ONLY. Every sentence and numbered point. Do NOT truncate.
- solution: COPY word-for-word from the Solution/Methodology section ONLY. Every sentence. Do NOT truncate.
- objectives: COPY word-for-word from the Objectives section ONLY. Every bullet and number. Do NOT include Project Overview or any other section.
- summary: Write a 3-5 sentence professional executive summary of the entire project. Highlight the problem, solution, technologies, and value. If too few fields are extracted, write "" for this.

RULES:
1. Return ONLY the JSON — no markdown, no backticks, no extra text
2. All values on ONE LINE — replace line breaks with space
3. Escape double quotes inside values with backslash
4. NEVER invent data — use "" if not found
5. NEVER merge content from different sections into one field
6. Remove section labels from the start of values
7. COPY text exactly — do NOT paraphrase or summarize (except for summary field)
''';

  static const String _enhancedPromptWithSummary = '''
CAREFUL EXTRACTION REQUIRED — previous attempt missed many fields.

Look thoroughly through the entire document. These sections may use alternative names:
- "abstract" = Summary, Executive Summary (NOT Overview or Introduction chapters)
- "description" = Chapter 1 Overview or Introduction section 1.1 ONLY — stop at next subheading
- "problem" = Problem Definition, Challenges, Motivation, Issues, Background
- "solution" = Approach, Methodology, Proposed System, System Design, Our Solution
- "objectives" = Goals, Aims, Targets, Project Goals, Key Objectives — NOT Project Overview
- "supervisor" = Under Supervision of, Advisor, Instructor, Project Advisor

Return a single valid JSON with ALL of these keys:
title, students, supervisor, year, category, technologies, keywords, abstract, description, problem, solution, objectives, summary

For the "summary" field: write a 3-5 sentence professional executive summary based on all extracted content.

STRICT RULES:
1. Return ONLY valid JSON — no markdown, no backticks
2. All values on ONE LINE (replace newlines with space)
3. COPY text EXACTLY word-for-word for all fields except summary
4. NEVER merge two different sections into one field
5. Each field must contain content from ONE section only
6. Remove section heading labels from values
7. Use "" only if the field truly cannot be found anywhere
''';

  static const Map<String, String> _fieldInstructions = {
    'title':        'Extract ONLY the specific project title. NOT university or faculty name.',
    'students':     'Extract ALL student full names as comma-separated list.',
    'supervisor':   'Extract supervisor full name with title (Dr./Prof./Eng.).',
    'year':         'Extract the 4-digit submission year only.',
    'category':     'Pick ONE: Medical, Education, Finance, E-Commerce, Social Media, Entertainment, Transportation, Smart Agriculture, IoT/Smart Home, Manufacturing, Other',
    'technologies': 'List all technologies, frameworks, programming languages mentioned.',
    'keywords':     'Extract keywords from explicit Keywords section only. Comma-separated.',
    'abstract':     'Extract the COMPLETE abstract. Copy every sentence word-for-word. Remove the label. Do NOT include any other section.',
    'description':  'Extract the first Overview or Introduction section ONLY. Copy word-for-word. Stop at the next subheading. Do NOT combine with Project Overview or other sections.',
    'problem':      'Extract the COMPLETE problem statement. Copy every sentence and numbered point word-for-word.',
    'solution':     'Extract the COMPLETE proposed solution. Copy every sentence word-for-word.',
    'objectives':   'Extract the COMPLETE objectives section ONLY. Copy every bullet and numbered item word-for-word. Do NOT include Project Overview.',
  };

  static const Map<String, String> _fieldContext = {
    'abstract':     'Abstract or executive summary — labeled: Abstract, Summary, Executive Summary. NOT a chapter introduction.',
    'description':  'The FIRST overview/introduction section only (e.g. 1.1 Overview). Copy word-for-word. Stop at the next subheading. Do NOT include 1.4 Project Overview or similar later sections.',
    'problem':      'Problem statement — labeled: Problem, Problem Statement, Problem Definition, Challenges, Issues, Motivation.',
    'solution':     'Proposed solution — labeled: Solution, Proposed Solution, Approach, Methodology, System Design.',
    'objectives':   'Objectives/goals section ONLY — labeled: Objectives, Goals, Aims, Targets. Include ALL numbered/bulleted items. Do NOT include Project Overview section.',
    'technologies': 'Technology stack — tools, languages, frameworks, databases.',
    'keywords':     'Keywords listed explicitly under a Keywords label.',
    'title':        'The main project title.',
    'supervisor':   'Supervisor or advisor with title Dr./Prof./Eng.',
    'students':     'All student names.',
    'year':         'Submission or academic year.',
    'category':     'Project category or domain.',
  };

  static const List<String> _allKeys = [
    'title', 'students', 'supervisor', 'year', 'abstract',
    'technologies', 'description', 'keywords', 'category',
    'problem', 'solution', 'objectives',
  ];

  static Map<String, dynamic> _emptyResult() => {
    for (final k in [..._allKeys, 'summary']) k: {'value': '', 'confidence': 0.0}
  };
}