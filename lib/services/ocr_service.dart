import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;

/// Vision-first OCR service with full reliability stack:
/// - Rotating API keys (up to 6) to maximize free quota
/// - Auto-retry with exponential backoff (up to 3 attempts)
/// - Enhanced prompt on retry if too few fields extracted
/// - JSON repair for truncated responses
/// - Regex salvage as last resort
/// - Per-field confidence scoring
/// - Smart semantic field scanning
class OcrService {

  // ═══════════════════════════════════════════════════════════════════════════
  // ✏️  PUT YOUR API KEYS HERE
  // Get free keys from: https://aistudio.google.com → "Get API Key"
  // You can add 1 to 6 keys. Each gives 20 free requests/day.
  // 6 keys = 120 requests/day = ~60-120 projects/day
  // ═══════════════════════════════════════════════════════════════════════════
  static const List<String> _apiKeys = [
    'AIzaSyBoqaKosaqDPS4ZglNfLtuyPlAXdEmr1x8',   // ← Replace with your first key
    'AIzaSyDUnS-PQ0tN5S9aOGXsk4KPY9CqRdIUrSE',   // ← Replace with your second key
    'AIzaSyBoqaKosaqDPS4ZglNfLtuyPlAXdEmr1x8',   // ← Replace with your third key
    'AIzaSyDTVoQJEt9K4NCjyizW8E1r__RvDPbKTCg',   // ← Replace with your fourth key
    'AIzaSyDZm5_Ex_erY6lPhsAHFShlLjdClOovm2U',   // ← Replace with your fifth key
    'AIzaSyDwbfwEA3eb-SOnQ7kNXe7o6lySNP4LbTo',   // ← Replace with your sixth key
  ];
  // ═══════════════════════════════════════════════════════════════════════════

  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=';

  static const int _maxRetries  = 1; // Reduced from 3 to save quota
  static const int _timeoutSecs = 60;
  static const int _maxTokens   = 8192;

  // Tracks which key to use next
  static int _currentKeyIndex = 0;

  static String get _currentKey {
    // Skip any placeholder keys
    for (int i = 0; i < _apiKeys.length; i++) {
      final idx = (_currentKeyIndex + i) % _apiKeys.length;
      if (!_apiKeys[idx].startsWith('YOUR_API_KEY')) {
        _currentKeyIndex = idx;
        return _apiKeys[idx];
      }
    }
    // fallback if all are placeholders
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
  /// Retries up to _maxRetries times with exponential backoff.
  /// Uses enhanced prompt on retry. Rotates API keys on rate limit.
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
        final bytes = await File(imagePaths[i]).readAsBytes();
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

    String currentPrompt = _mainPrompt;
    Map<String, dynamic> bestResult = _emptyResult();
    int bestFilledCount = 0;

    for (int attempt = 1; attempt <= _maxRetries; attempt++) {
      if (attempt > 1) {
        final waitSecs = attempt * 2;
        print('[OCR] Retry $attempt/$_maxRetries — waiting ${waitSecs}s');
        onProgress?.call('Retrying extraction (attempt $attempt)...', 0.5 + attempt * 0.05);
        await Future.delayed(Duration(seconds: waitSecs));
        currentPrompt = _enhancedPrompt;
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

      // 4+ fields is acceptable — stop retrying
      if (filledCount >= 4) break;
    }

    print('[OCR] Final result: $bestFilledCount fields extracted');
    onProgress?.call('Done', 1.0);
    return bestResult;
  }

  /// Re-extract a single field from already-scanned pages.
  /// Appends to existing value rather than replacing.
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

  /// Smart override — reads any image, understands content semantically,
  /// fills the target field regardless of how sections are labeled in the doc.
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
      {'text': _mainPrompt},
    ]);
    return raw != null ? _parseResponse(raw) : _emptyResult();
  }

  static Future<Map<String, dynamic>> processOCR(String rawText) async {
    final raw = await _callGemini([
      {'text': 'Document text:\n$rawText\n\n$_mainPrompt'},
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
    // Try every available key before giving up
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
          continue; // try next key
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

    for (final key in _allKeys) {
      final match = RegExp('"$key"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"').firstMatch(raw);
      final value = match?.group(1)?.trim() ?? '';
      result[key] = {'value': value, 'confidence': value.isNotEmpty ? 0.6 : 0.0};
    }

    return result;
  }

  /// Improved confidence scoring — checks quality signals, not just length
  static double _score(String value, String key) {
    if (value.isEmpty) return 0.0;
    if (key == 'year')     return RegExp(r'^\d{4}$').hasMatch(value) ? 0.97 : 0.4;
    if (key == 'category') return 0.92;

    final isLong = ['abstract', 'description', 'problem', 'solution', 'objectives'].contains(key);
    if (isLong) {
      double score = 0.0;

      // Length check
      if (value.length > 500)      score += 0.35;
      else if (value.length > 300) score += 0.25;
      else if (value.length > 100) score += 0.15;
      else                         score += 0.05;

      // Ends properly (not mid-sentence)
      final trimmed = value.trimRight();
      if (trimmed.endsWith('.') || trimmed.endsWith('?') ||
          trimmed.endsWith('!') || trimmed.endsWith(':')) {
        score += 0.25;
      } else if (trimmed.endsWith(',') || trimmed.endsWith(';')) {
        score += 0.05; // likely truncated
      }

      // Contains structured content (numbered/bulleted lists)
      if (RegExp(r'(\d+[\.\)]|\•|\-)\s').hasMatch(value)) score += 0.20;

      // Penalize AI summary phrases — means it paraphrased instead of copying
      final aiPhrases = [
        'in summary', 'to summarize', 'in conclusion',
        'the document states', 'according to the document',
        'the text mentions', 'as mentioned',
      ];
      final lower = value.toLowerCase();
      if (aiPhrases.any((p) => lower.contains(p))) score -= 0.30;

      // Penalize suspiciously short long fields
      if (value.length < 80) score -= 0.20;

      return score.clamp(0.0, 1.0);
    }

    return value.length > 5 ? 0.88 : 0.55;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PROMPTS & METADATA
  // ═══════════════════════════════════════════════════════════════════════════

  static const String _mainPrompt = '''
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

RULES:
1. Return ONLY the JSON — no markdown, no backticks, no extra text
2. All values on ONE LINE — replace line breaks with space
3. Escape double quotes inside values with backslash
4. NEVER invent data — use "" if not found
5. NEVER merge content from different sections into one field
6. Remove section labels from the start of values
7. COPY text exactly — do NOT paraphrase or summarize
''';

  static const String _enhancedPrompt = '''
CAREFUL EXTRACTION REQUIRED — previous attempt missed many fields.

Look thoroughly through the entire document. These sections may use alternative names:
- "abstract" = Summary, Executive Summary (NOT Overview or Introduction chapters)
- "description" = Chapter 1 Overview or Introduction section 1.1 ONLY — stop at next subheading
- "problem" = Problem Definition, Challenges, Motivation, Issues, Background
- "solution" = Approach, Methodology, Proposed System, System Design, Our Solution
- "objectives" = Goals, Aims, Targets, Project Goals, Key Objectives — NOT Project Overview
- "supervisor" = Under Supervision of, Advisor, Instructor, Project Advisor

Return a single valid JSON with ALL of these keys:
title, students, supervisor, year, category, technologies, keywords, abstract, description, problem, solution, objectives

STRICT RULES:
1. Return ONLY valid JSON — no markdown, no backticks
2. All values on ONE LINE (replace newlines with space)
3. COPY text EXACTLY word-for-word — do NOT paraphrase
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
    for (final k in _allKeys) k: {'value': '', 'confidence': 0.0}
  };
}