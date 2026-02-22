import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;

/// Completely vision-first OCR service.
/// Sends images directly to Gemini Vision — no ML Kit text extraction needed.
/// ML Kit is only used for the thumbnail preview, not for data extraction.
class OcrService {
  static const String _apiKey = 'AIzaSyBoqaKosaqDPS4ZglNfLtuyPlAXdEmr1x8';
  static const String _url =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=';

  // ═══════════════════════════════════════════════════════════════════════════
  // MAIN ENTRY POINT — called from home_page.dart
  // ═══════════════════════════════════════════════════════════════════════════

  /// Send ALL document images + any pasted text to Gemini in one call.
  /// Gemini sees the actual images so it reads clean text, not garbled OCR.
  static Future<Map<String, dynamic>> extractFromAll({
    List<String> imagePaths = const [],
    List<String> rawTexts = const [],
    void Function(String step, double progress)? onProgress,
  }) async {
    onProgress?.call('Preparing pages...', 0.1);

    // Build image parts
    final List<Map<String, dynamic>> parts = [];

    for (int i = 0; i < imagePaths.length; i++) {
      onProgress?.call('Reading page ${i + 1} of ${imagePaths.length}...', 0.1 + (i / imagePaths.length) * 0.3);
      try {
        final bytes = await File(imagePaths[i]).readAsBytes();
        final b64 = base64Encode(bytes);
        parts.add({
          'inline_data': {'mime_type': 'image/jpeg', 'data': b64}
        });
        print('[OCR] Added image ${i + 1}: ${bytes.length} bytes');
      } catch (e) {
        print('[OCR] Failed to read image ${imagePaths[i]}: $e');
      }
    }

    // Add any pasted text as additional context
    if (rawTexts.isNotEmpty) {
      final combined = rawTexts.join('\n\n--- Next Page ---\n\n');
      parts.add({'text': 'Additional text from document:\n$combined'});
    }

    if (parts.isEmpty) {
      print('[OCR] No content to send');
      return _emptyResult();
    }

    // Add the extraction prompt last
    parts.add({'text': _prompt});

    onProgress?.call('Analyzing with Gemini Vision...', 0.5);
    print('[OCR] Sending ${imagePaths.length} image(s) + ${rawTexts.length} text(s) to Gemini Vision');

    final result = await _callGemini(parts);

    onProgress?.call('Done', 1.0);
    return result;
  }

  /// Legacy: called when only base64 image available (from old code paths)
  static Future<Map<String, dynamic>> extractFromImage(
    String base64Image, {
    String? fallbackOcrText,
  }) async {
    final parts = <Map<String, dynamic>>[
      {'inline_data': {'mime_type': 'image/jpeg', 'data': base64Image}},
      {'text': _prompt},
    ];
    return await _callGemini(parts);
  }

  /// Legacy: text-only fallback when no images at all
  static Future<Map<String, dynamic>> processOCR(String rawText) async {
    print('[OCR] Text-only mode (no images available)');
    final parts = <Map<String, dynamic>>[
      {'text': 'Document text:\n$rawText\n\n$_prompt'},
    ];
    return await _callGemini(parts);
  }

  /// Re-extract a single field — used by the ✨ button on each field
  /// Sends images directly to Gemini Vision for best accuracy
  static Future<String> extractSingleField(
    String fieldName, {
    List<String> imagePaths = const [],
    String fallbackText = '',
  }) async {
    final instruction = _fieldInstructions[fieldName];
    if (instruction == null) return '';

    final parts = <Map<String, dynamic>>[];

    // Add images if available — Vision is more accurate than raw text
    for (final path in imagePaths) {
      try {
        final bytes = await File(path).readAsBytes();
        parts.add({'inline_data': {'mime_type': 'image/jpeg', 'data': base64Encode(bytes)}});
      } catch (e) {
        print('[OCR] Could not read image $path: $e');
      }
    }

    // Add fallback text if provided
    if (fallbackText.isNotEmpty) {
      parts.add({'text': 'Document text:\n$fallbackText'});
    }

    if (parts.isEmpty) return '';

    // Add the focused prompt
    parts.add({'text': '''
$instruction

RULES:
- Return ONLY the extracted text, nothing else
- No explanation, no labels, no JSON
- Extract the COMPLETE text, do not truncate
- If not found anywhere in the document, return exactly: NOT_FOUND
'''});

    try {
      final response = await http.post(
        Uri.parse('$_url$_apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'contents': [{'parts': parts}],
          'generationConfig': {'temperature': 0.1, 'maxOutputTokens': 2048},
        }),
      ).timeout(const Duration(seconds: 40));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        final text = (decoded['candidates']?[0]?['content']?['parts']?[0]?['text'] as String? ?? '').trim();
        print('[OCR] extractSingleField ($fieldName): "${text.substring(0, text.length.clamp(0, 80))}..."');
        return text == 'NOT_FOUND' ? '' : text;
      } else {
        print('[OCR] extractSingleField error: \${response.statusCode} \${response.body}');
      }
    } catch (e) {
      print('[OCR] extractSingleField error: $e');
    }
    return '';
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // GEMINI API CALL
  // ═══════════════════════════════════════════════════════════════════════════

  static Future<Map<String, dynamic>> _callGemini(
    List<Map<String, dynamic>> parts,
  ) async {
    try {
      final body = jsonEncode({
        'contents': [{'parts': parts}],
        'generationConfig': {
          'temperature': 0.1,
          'maxOutputTokens': 8192,  // Large enough for full abstract + all fields
          'topP': 0.95,
        },
      });

      print('[OCR] Calling Gemini API...');
      final response = await http.post(
        Uri.parse('$_url$_apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: body,
      ).timeout(const Duration(seconds: 60));

      print('[OCR] Response status: ${response.statusCode}');

      if (response.statusCode != 200) {
        print('[OCR] API error: ${response.body}');
        return _emptyResult();
      }

      final decoded = jsonDecode(response.body);

      // Check for blocked content
      final finishReason = decoded['candidates']?[0]?['finishReason'];
      if (finishReason == 'SAFETY' || finishReason == 'RECITATION') {
        print('[OCR] Content blocked: $finishReason');
        return _emptyResult();
      }

      if (finishReason == 'MAX_TOKENS') {
        print('[OCR] WARNING: Response was cut off — maxOutputTokens reached');
      }

      final rawText = decoded['candidates']?[0]?['content']?['parts']?[0]?['text'] as String? ?? '';

      print('[OCR] ===== GEMINI RESPONSE =====');
      print(rawText);
      print('[OCR] ===== END RESPONSE =====');

      if (rawText.isEmpty) {
        print('[OCR] Empty response from Gemini');
        return _emptyResult();
      }

      return _parseResponse(rawText);
    } catch (e) {
      print('[OCR] Gemini call error: $e');
      return _emptyResult();
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PARSE RESPONSE
  // ═══════════════════════════════════════════════════════════════════════════

  static Map<String, dynamic> _parseResponse(String raw) {
    try {
      // Strip markdown fences
      String cleaned = raw
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();

      // Find outermost { } — handles any length
      final first = cleaned.indexOf('{');
      final last = cleaned.lastIndexOf('}');

      if (first == -1 || last == -1 || last <= first) {
        print('[OCR] No JSON object found in response');
        return _emptyResult();
      }

      cleaned = cleaned.substring(first, last + 1);

      // Fix truncated JSON — if abstract or any field got cut off
      cleaned = _repairJson(cleaned);

      final decoded = jsonDecode(cleaned) as Map<String, dynamic>;

      // Wrap each value in {value, confidence} format
      final result = <String, dynamic>{};
      for (final key in _allKeys) {
        final val = decoded[key];
        final str = val?.toString().trim() ?? '';
        result[key] = {
          'value': str,
          'confidence': str.length > 10 ? 0.95 : (str.isEmpty ? 0.0 : 0.6),
        };
        if (str.isNotEmpty) {
          print('[OCR] $key: "${str.substring(0, str.length.clamp(0, 60))}${str.length > 60 ? "..." : ""}"');
        }
      }

      return result;
    } catch (e) {
      print('[OCR] Parse error: $e');
      // Try to salvage what we can with regex
      return _regexFallback(raw);
    }
  }

  /// Attempt to repair truncated JSON by closing any open string and braces
  static String _repairJson(String json) {
    try {
      jsonDecode(json); // If it parses fine, return as-is
      return json;
    } catch (_) {}

    // Count open braces
    String repaired = json.trimRight();

    // Close any unclosed string
    final quoteCount = repaired.split('"').length - 1;
    if (quoteCount % 2 != 0) {
      repaired += '"';
    }

    // Close any unclosed brace
    int openBraces = 0;
    for (final ch in repaired.runes) {
      if (ch == '{'.codeUnitAt(0)) openBraces++;
      if (ch == '}'.codeUnitAt(0)) openBraces--;
    }
    for (int i = 0; i < openBraces; i++) {
      repaired += '}';
    }

    try {
      jsonDecode(repaired);
      print('[OCR] Repaired truncated JSON successfully');
      return repaired;
    } catch (_) {
      return json; // Return original, let caller handle error
    }
  }

  /// Last resort: pull values from raw text using regex
  static Map<String, dynamic> _regexFallback(String raw) {
    print('[OCR] Using regex fallback parser');
    final result = <String, dynamic>{};

    for (final key in _allKeys) {
      final pattern = RegExp('"$key"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"');
      final match = pattern.firstMatch(raw);
      final value = match?.group(1)?.trim() ?? '';
      result[key] = {'value': value, 'confidence': value.isNotEmpty ? 0.7 : 0.0};
      if (value.isNotEmpty) {
        print('[OCR] Regex salvaged $key: "${value.substring(0, value.length.clamp(0, 60))}..."');
      }
    }

    return result;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // THE PROMPT
  // ═══════════════════════════════════════════════════════════════════════════

  static const String _prompt = '''
You are analyzing a graduation project document from an Egyptian university.
These documents vary in layout and format. Use your visual intelligence to find and extract each field.

Return a single JSON object with these exact keys. For missing fields use "".

EXTRACTION INSTRUCTIONS:
- title: The specific project name. NOT the university/faculty/department. Usually bold or large text. Example: "Fixy" or "Smart Healthcare System".
- students: ALL student full names comma-separated. Look for lists under "Project Team", "Prepared by", "By". Include every name fully.
- supervisor: Supervisor name with title (Dr./Prof./Eng.). Look near "Supervisor", "Supervised by", "Under Supervision of". One name only.
- year: 4-digit year only e.g. "2026".
- category: Pick ONE: Medical, Education, Finance, E-Commerce, Social Media, Entertainment, Transportation, Smart Agriculture, IoT/Smart Home, Manufacturing, Other
- technologies: Comma-separated tools/languages/frameworks if mentioned. Empty if not found.
- keywords: Only if there is an explicit "Keywords:" section. Empty otherwise.
- abstract: The COMPLETE abstract text. Extract every sentence word for word. Do NOT truncate.
- description: The COMPLETE project description section if it exists. Every sentence. Do NOT truncate.
- problem: The COMPLETE problem statement/definition section. Every sentence and numbered point. Do NOT truncate.
- solution: The COMPLETE proposed solution section. Every sentence. Do NOT truncate.
- objectives: The COMPLETE objectives/goals section including ALL bullet points and numbered items. Do NOT truncate.

CRITICAL RULES:
1. Return ONLY the JSON object — no explanation, no markdown, no backticks
2. All string values must be on ONE LINE — replace any line breaks with a space
3. Escape any double quotes inside values with backslash: \\"
4. Extract COMPLETE text for abstract/description/problem/solution/objectives — never cut them short
5. Do NOT invent data — if a field is not in the document use ""
6. Remove section label words from the start of values (e.g. remove "Abstract:" from the abstract value)
''';

  // ═══════════════════════════════════════════════════════════════════════════
  // SINGLE FIELD INSTRUCTIONS
  // ═══════════════════════════════════════════════════════════════════════════

  static const Map<String, String> _fieldInstructions = {
    'title':       'Extract ONLY the specific project title — what was built. NOT the university or faculty name.',
    'students':    'Extract ALL student full names as a comma-separated list. Include every part of each name.',
    'supervisor':  'Extract the supervisor full name with title (Dr./Prof./Eng.). Look near "Supervised by" or "Supervisor".',
    'year':        'Extract the 4-digit submission year.',
    'category':    'Pick ONE: Medical, Education, Finance, E-Commerce, Social Media, Entertainment, Transportation, Smart Agriculture, IoT/Smart Home, Manufacturing, Other',
    'technologies':'List all technologies, frameworks, programming languages mentioned.',
    'keywords':    'Extract keywords from the Keywords section only. Comma-separated.',
    'abstract':    'Extract the COMPLETE abstract section. Every sentence. Remove the "Abstract" label from the start.',
    'description': 'Extract the COMPLETE description section. Every sentence. Remove the "Description" label from the start.',
    'problem':     'Extract the COMPLETE problem statement/definition section. Every sentence and numbered point.',
    'solution':    'Extract the COMPLETE proposed solution section. Every sentence.',
    'objectives':  'Extract the COMPLETE objectives section. Every bullet point and numbered item.',
  };

  static const List<String> _allKeys = [
    'title', 'students', 'supervisor', 'year', 'abstract',
    'technologies', 'description', 'keywords', 'category',
    'problem', 'solution', 'objectives',
  ];

  /// Smart override scan - reads ANY image, understands the content
  /// regardless of how sections are labeled, cleans the text, and returns
  /// it ready to insert into the target field.
  static Future<String> smartScanForField({
    required String fieldName,
    required String imagePath,
  }) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final b64   = base64Encode(bytes);

      final fieldContext = <String, String>{
        'abstract':     'The abstract or executive summary. May be labeled Abstract, Summary, Executive Summary, or Overview.',
        'description':  'The project description - what the system does. May be labeled Description, Project Overview, Overview, Introduction, or About.',
        'problem':      'The problem statement - challenges this project addresses. May be labeled Problem, Problem Statement, Problem Definition, Challenges, Issues, or Motivation.',
        'solution':     'The proposed solution. May be labeled Solution, Proposed Solution, Approach, Methodology, or System Design.',
        'objectives':   'The project objectives or goals. May be labeled Objectives, Goals, Aims, or Targets. Include all numbered or bulleted items.',
        'technologies': 'The technology stack - tools, languages, frameworks, databases used.',
        'keywords':     'Keywords listed explicitly, usually under a Keywords label.',
        'title':        'The main project title.',
        'supervisor':   'The supervisor or advisor name with their title Dr./Prof./Eng.',
        'students':     'All student names involved in the project.',
        'year':         'The submission or academic year.',
        'category':     'The project category or domain.',
      };

      final context = fieldContext[fieldName] ?? 'The $fieldName field content.';

      final prompt = 'You are looking at a page from a graduation project document.\n\n'
          'Your task: Extract and return ONLY the content for the "$fieldName" field.\n\n'
          'What to look for: $context\n\n'
          'RULES:\n'
          '- The section may NOT be labeled exactly as "$fieldName" - use your understanding to find the right content\n'
          '- Remove the section heading from your output - return ONLY the clean content text\n'
          '- Fix any OCR errors and clean up the text\n'
          '- Return the COMPLETE text, do not summarize or truncate\n'
          '- If the page does not contain relevant content, return exactly: NOT_FOUND\n\n'
          'Return ONLY the clean extracted text, nothing else.';

      final response = await http.post(
        Uri.parse('$_url$_apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'contents': [{
            'parts': [
              {'inline_data': {'mime_type': 'image/jpeg', 'data': b64}},
              {'text': prompt},
            ]
          }],
          'generationConfig': {
            'temperature': 0.1,
            'maxOutputTokens': 2048,
          },
        }),
      ).timeout(const Duration(seconds: 40));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        final text = (decoded['candidates']?[0]?['content']?['parts']?[0]?['text'] as String? ?? '').trim();
        print('[OCR] smartScanForField ($fieldName): "${text.substring(0, text.length.clamp(0, 80))}..."');
        return text == 'NOT_FOUND' ? '' : text;
      } else {
        print('[OCR] smartScanForField error: ${response.statusCode}');
      }
    } catch (e) {
      print('[OCR] smartScanForField error: $e');
    }
    return '';
  }

  static Map<String, dynamic> _emptyResult() {
    return {for (final k in _allKeys) k: {'value': '', 'confidence': 0.0}};
  }
}