import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;

class OcrService {
  // ============================
  // MULTI-KEY ROTATION SYSTEM
  // ============================

  /// Add as many API keys as you want here.
  /// When one hits its rate limit (429), the next one is tried automatically.
  static const List<String> _apiKeys = [
    'AIzaSyDUnS-PQ0tN5S9aOGXsk4KPY9CqRdIUrSE',
    'AIzaSyBoqaKosaqDPS4ZglNfLtuyPlAXdEmr1x8',
    'AIzaSyDTVoQJEt9K4NCjyizW8E1r__RvDPbKTCg',
    'AIzaSyDZm5_Ex_erY6lPhsAHFShlLjdClOovm2U',
    // Add more keys here...
  ];

  /// Tracks which keys are temporarily blocked (rate-limited) and when they expire.
  /// Key = API key string, Value = DateTime when the cooldown ends.
  static final Map<String, DateTime> _rateLimitedUntil = {};

  /// Returns the next available (non-rate-limited) API key, or null if all are blocked.
  static String? _getAvailableKey() {
    final now = DateTime.now();
    for (final key in _apiKeys) {
      final blockedUntil = _rateLimitedUntil[key];
      if (blockedUntil == null || now.isAfter(blockedUntil)) {
        // Clear expired cooldown
        _rateLimitedUntil.remove(key);
        return key;
      }
    }
    return null; // All keys are rate-limited
  }

  /// Marks a key as rate-limited for [cooldownMinutes] minutes.
  static void _markRateLimited(String key, {int cooldownMinutes = 1}) {
    _rateLimitedUntil[key] = DateTime.now().add(
      Duration(minutes: cooldownMinutes),
    );
    print(
      '[OCR] Key ending in ...${key.substring(key.length - 6)} rate-limited for $cooldownMinutes min.',
    );
  }

  /// Makes a Gemini API POST request with automatic key rotation on 429 errors.
  /// [modelPath] = e.g. "models/gemini-2.0-flash-exp"
  /// [body] = the full request body map (without the key)
  /// [timeoutSeconds] = request timeout
  /// Returns the decoded response body, or null on total failure.
  static Future<Map<String, dynamic>?> _geminiRequest({
    required String modelPath,
    required Map<String, dynamic> body,
    int timeoutSeconds = 30,
  }) async {
    // Try each available key in order
    for (int attempt = 0; attempt < _apiKeys.length; attempt++) {
      final key = _getAvailableKey();

      if (key == null) {
        print('[OCR] ⚠️ All API keys are currently rate-limited. Waiting...');
        // Wait for the shortest cooldown to expire
        final soonestExpiry = _rateLimitedUntil.values.reduce(
          (a, b) => a.isBefore(b) ? a : b,
        );
        final waitMs =
            soonestExpiry.difference(DateTime.now()).inMilliseconds + 100;
        if (waitMs > 0 && waitMs < 120000) {
          await Future.delayed(Duration(milliseconds: waitMs));
        }
        continue;
      }

      final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/$modelPath:generateContent?key=$key',
      );

      try {
        final response = await http
            .post(
              url,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body),
            )
            .timeout(Duration(seconds: timeoutSeconds));

        if (response.statusCode == 200) {
          return jsonDecode(response.body) as Map<String, dynamic>;
        } else if (response.statusCode == 429) {
          print(
            '[OCR] Rate limit hit for key ...${key.substring(key.length - 6)}, trying next key...',
          );
          _markRateLimited(key);
          // Continue loop to try next key
          continue;
        } else if (response.statusCode == 503 || response.statusCode == 500) {
          print(
            '[OCR] Server error ${response.statusCode}, retrying with next key...',
          );
          continue;
        } else {
          print(
            '[OCR] Gemini error: ${response.statusCode} - ${response.body}',
          );
          return null;
        }
      } catch (e) {
        print(
          '[OCR] Request error with key ...${key.substring(key.length - 6)}: $e',
        );
        // Don't rate-limit on timeout/network errors, just try next key
        continue;
      }
    }

    print('[OCR] ❌ All API keys failed or exhausted.');
    return null;
  }

  // ============================
  // MAIN PUBLIC API
  // ============================

  static Future<Map<String, dynamic>> extractFromImage(
    String base64Image, {
    String? fallbackOcrText,
  }) async {
    print('[OCR] ===== Starting Image OCR Processing =====');

    String extractedText = await _performGeminiVisionOCR(base64Image);

    if (extractedText.isEmpty &&
        fallbackOcrText != null &&
        fallbackOcrText.isNotEmpty) {
      print('[OCR] Using fallback OCR text');
      extractedText = fallbackOcrText;
    }

    if (extractedText.isEmpty) {
      print('[OCR] ERROR: No text could be extracted from image');
      return _createEmptyResult();
    }

    return await processOCR(extractedText);
  }

  static Future<String> extractSingleField(
    String rawText,
    String fieldName,
  ) async {
    try {
      final fieldInstructions = {
        'abstract': '''
Extract the ABSTRACT section from this document.
- Find the section labeled "Abstract" or "Abstract:"
- Extract ALL of its content completely
- Remove the word "Abstract" or "Abstract:" from the start
- Remove any page numbers from the end
- Return only the clean abstract text
''',
        'description': '''
Extract the DESCRIPTION or PROJECT DESCRIPTION section from this document.
- Find the section labeled "Description", "Project Description", or "Overview"
- Extract ALL of its content completely
- Remove the label word from the start
- Remove any page numbers from the end
- Return only the clean description text
''',
        'technologies': '''
Extract the TECHNOLOGIES or TOOLS used in this project.
- Look for labels like "Technologies:", "Tools:", "Tech Stack:", "Built with:"
- Return as a comma-separated list
- Example: "Flutter, Firebase, Python, TensorFlow"
- Return only the technology names, nothing else
''',
        'keywords': '''
Extract the KEYWORDS from this document.
- Look for a section labeled "Keywords:", "Key Words:", or "Index Terms:"
- Return as a comma-separated list
- Remove the "Keywords:" label itself
- Return only the keyword terms
''',
      };

      final instruction =
          fieldInstructions[fieldName] ??
          'Extract the $fieldName field from this document.';

      final prompt =
          '''
$instruction

RULES:
- Return ONLY the extracted text content, nothing else
- No explanations, no labels, no JSON
- If the section is not found, return exactly: NOT_FOUND
- Be thorough and extract the COMPLETE content of the section

Document text:
$rawText
''';

      print('[OCR] Extracting single field: $fieldName');

      final decoded = await _geminiRequest(
        modelPath: 'models/gemini-2.5-flash',
        body: {
          'contents': [
            {
              'parts': [
                {'text': prompt},
              ],
            },
          ],
          'generationConfig': {'temperature': 0.1, 'maxOutputTokens': 2048},
        },
        timeoutSeconds: 20,
      );

      if (decoded == null) return '';

      if (decoded['candidates'] == null || decoded['candidates'].isEmpty) {
        return '';
      }

      final text =
          decoded['candidates'][0]['content']['parts'][0]['text'] as String;

      if (text.trim() == 'NOT_FOUND') {
        print('[OCR] Field $fieldName not found in text');
        return '';
      }

      print(
        '[OCR] Extracted $fieldName: "${text.substring(0, text.length.clamp(0, 100))}..."',
      );
      return text.trim();
    } catch (e) {
      print('[OCR] extractSingleField error: $e');
      return '';
    }
  }

  // ============================
  // BATCH EXTRACTION (1 request = all fields)
  // ============================

  /// Extracts ALL fields in ONE single API call.
  /// Use this to fill the entire form with one request instead of one per field button.
  /// Returns a Map<String, String> with keys:
  ///   title, students, supervisor, year, category, technologies, keywords, abstract, description
  static Future<Map<String, String>> extractAllFields(String rawText) async {
    try {
      final prompt =
          '''
Extract the following sections from this document text and return ONLY valid JSON.

SECTIONS TO EXTRACT:
1. abstract    - Full abstract section. Remove "Abstract:" label and page numbers from end.
2. description - Full description/project description section. Remove label and page numbers.
3. technologies - Technologies/tools used, comma-separated list.
4. keywords    - Keywords if explicitly listed with "Keywords:" label, else "". Remove the label.
5. title       - Project title. Remove any "Title:" prefix.
6. supervisor  - Supervisor full name with title (Dr., Prof., etc.)
7. year        - 4-digit submission/project year only (e.g. "2024")
8. students    - ALL student full names, comma-separated. Look for numbered lists like "1- Full Name". Include complete names.
9. category    - ONE of: Medical, Education, Finance, E-Commerce, Social Media, Entertainment, Transportation, Smart Agriculture, IoT/Smart Home, Manufacturing, Other

RULES:
- Return ONLY the JSON object — no markdown, no backticks, no extra text
- All string values must be on a single line (no line breaks inside strings)
- Close all quotes and braces — JSON must be complete and valid
- If a section is not found, use ""
- Do NOT invent or hallucinate data
- Remove label words from the START of values (Abstract:, Description:, Title:, etc.)
- Remove page references from the END of values (Page 4, pg. 87, etc.)

EXAMPLE OUTPUT:
{"title":"Smart Healthcare System","students":"Ahmed Hassan Ali, Sara Ibrahim Khalil","supervisor":"Dr. Ahmed Shalaby","year":"2024","category":"Medical","technologies":"Flutter, Firebase","keywords":"healthcare, AI","abstract":"This project addresses critical gaps...","description":"A comprehensive system designed to..."}

Document text:
$rawText

RETURN ONLY THE COMPLETE JSON OBJECT.
''';

      print('[OCR] 🚀 Batch extracting ALL fields in one request...');

      final decoded = await _geminiRequest(
        modelPath: 'models/gemini-2.5-flash',
        body: {
          'contents': [
            {
              'parts': [
                {'text': prompt},
              ],
            },
          ],
          'generationConfig': {
            'temperature': 0.0,
            'maxOutputTokens': 4096,
            'topP': 0.95,
          },
        },
        timeoutSeconds: 30,
      );

      if (decoded == null) {
        print('[OCR] Batch extraction failed - no response');
        return {};
      }

      if (decoded['candidates'] == null || decoded['candidates'].isEmpty) {
        print('[OCR] Batch extraction - no candidates');
        return {};
      }

      final text =
          decoded['candidates'][0]['content']['parts'][0]['text'] as String;
      print('[OCR] ===== BATCH EXTRACTION RESPONSE =====');
      print(text);
      print('[OCR] ===== END BATCH RESPONSE =====');

      String cleaned = text
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();

      cleaned = _fixIncompleteJson(cleaned);
      cleaned = _fixMultilineJsonStrings(cleaned);

      final jsonMatch = RegExp(
        r'\{[\s\S]*\}',
        dotAll: true,
      ).firstMatch(cleaned);
      if (jsonMatch != null) cleaned = jsonMatch.group(0)!;

      final Map<String, dynamic> jsonData = jsonDecode(cleaned);
      final Map<String, String> result = {};

      const fieldKeys = [
        'title',
        'students',
        'supervisor',
        'year',
        'category',
        'technologies',
        'keywords',
        'abstract',
        'description',
      ];

      for (final key in fieldKeys) {
        dynamic raw = jsonData[key];
        String value = '';

        if (raw != null) {
          value = raw is List
              ? raw.map((e) => e.toString()).join(', ').trim()
              : raw.toString().trim();
        }

        if (key == 'abstract' || key == 'description') {
          value = _cleanAbstractOrDescription(value);
        }
        if (key == 'keywords') {
          value = _cleanKeywords(value);
        }

        result[key] = value;
        print(
          '[OCR] Batch [$key]: "${value.length > 80 ? "${value.substring(0, 80)}..." : value}"',
        );
      }

      print(
        '[OCR] ✅ Batch extraction complete — ${result.length} fields filled',
      );
      return result;
    } catch (e) {
      print('[OCR] Batch extraction error: $e');
      return {};
    }
  }

  static Future<Map<String, dynamic>> processOCR(String rawText) async {
    print('[OCR] ===== Starting OCR Processing =====');

    String cleanedText = _preprocessOcrText(rawText);
    print('[OCR] Text preprocessing complete');

    final regexData = _extractHeuristically(cleanedText);
    print(
      '[OCR] Heuristic students found: "${regexData['students']?['value'] ?? ""}"',
    );

    final aiData = await _extractWithGemini(cleanedText);
    print('[OCR] AI students found: "${aiData['students'] ?? ""}"');

    if (aiData.isEmpty) {
      print('[OCR] AI extraction failed, using heuristic data only');
      return regexData;
    }

    return _mergeHybrid(regexData, aiData);
  }

  // ============================
  // GEMINI VISION OCR
  // ============================

  static Future<String> _performGeminiVisionOCR(String base64Image) async {
    try {
      final prompt = """
Extract ALL text from this document image with perfect accuracy.

CRITICAL INSTRUCTIONS:
1. Extract text EXACTLY as it appears - character by character
2. Preserve line breaks and formatting
3. Pay special attention to:
   - Student names in numbered lists (e.g., "1- Yahia Mohammed Hassan", "2- Ahmed Ali")
   - Supervisor/advisor names (with titles like Dr., Prof.)
   - Project title
   - Year/date
   - University/institution names
4. Extract the text EXACTLY - do NOT:
   - Fix spelling errors
   - Correct formatting
   - Add or remove content
   - Interpret or summarize
5. Include ALL visible text from the image

Return ONLY the raw extracted text with original line breaks, nothing else.
""";

      print('[OCR] Calling Gemini Vision API...');

      final decoded = await _geminiRequest(
        modelPath: 'models/gemini-2.0-flash-exp',
        body: {
          'contents': [
            {
              'parts': [
                {'text': prompt},
                {
                  'inline_data': {
                    'mime_type': 'image/jpeg',
                    'data': base64Image,
                  },
                },
              ],
            },
          ],
          'generationConfig': {'temperature': 0.1, 'maxOutputTokens': 4096},
        },
        timeoutSeconds: 30,
      );

      if (decoded == null) return '';

      if (decoded['candidates'] == null || decoded['candidates'].isEmpty) {
        print('[OCR] No candidates in Gemini Vision response');
        return '';
      }

      final text = decoded['candidates'][0]['content']['parts'][0]['text'];
      print('[OCR] ===== GEMINI VISION EXTRACTED TEXT =====');
      print(text);
      print('[OCR] ===== END EXTRACTED TEXT (${text.length} chars) =====');

      return text;
    } catch (e) {
      print('[OCR] Gemini Vision exception: $e');
    }

    return '';
  }

  // ============================
  // GEMINI DATA EXTRACTION
  // ============================

  static Future<Map<String, dynamic>> _extractWithGemini(String rawText) async {
    try {
      final prompt =
          """
Extract information from this OCR text and return ONLY valid, parseable JSON.

CRITICAL JSON FORMATTING RULES (MUST FOLLOW EXACTLY):
1. Return ONLY the JSON object - no markdown, no extra text, no backticks
2. All field values MUST be on a single line (no line breaks allowed inside string values)
3. IMPORTANT: Make sure to CLOSE all quotes and braces - the JSON must be complete and valid
4. Never use \\n, \\r, or actual newlines inside JSON string values
5. Escape any double quotes inside values with a backslash: \"

Extraction rules:
- Only extract data that clearly appears in the OCR text
- If a field is not found or not present, use empty string value ""
- Clean up extracted text (remove extra spaces, trim)
- Do NOT invent or hallucinate data
- Do NOT extract abstracts, descriptions, or long text content

FIELD-SPECIFIC INSTRUCTIONS:
- title: Extract the project title (the main heading/title of the project). Remove any prefix like "Title:" or "Project Title:". Clean output only.
- students: **MOST CRITICAL FIELD** - Extract ALL student FULL NAMES exactly as they appear. Look for numbered lists like "1- Full Name" or "1. Full Name". Include ALL parts of each name (first, middle, last names). Return as comma-separated list. Example: "Yahia Mohammed Mansour Hassan Hamza, Mohammed Sabry Mahmoud Shehabeldin, Hadi Rabee Kamel Alam Heikal". DO NOT abbreviate names - use complete names.
- supervisor: Extract supervisor name with title (e.g., "Dr. Ahmed Shalaby", "Prof. John Smith")
- year: Extract project/submission year ONLY (e.g., "2024") - NOT dates from abstract
- abstract: Extract ONLY the abstract content text. Remove the word "Abstract" if it appears at the start. Remove page numbers from the end. Return ONLY the clean abstract text content.
- technologies: Extract technology stack if explicitly mentioned (e.g., "Java, Python, MySQL")
- description: Extract ONLY the description content text. Remove the word "Description" if it appears at the start. Remove page numbers from the end. Return ONLY the clean description text content.
- keywords: Extract keywords ONLY if explicitly listed with "Keywords:" label, otherwise return "". Remove the "Keywords:" label itself from the output.
- category: Choose ONE from: Medical, Education, Finance, E-Commerce, Social Media, Entertainment, Transportation, Smart Agriculture, IoT/Smart Home, Manufacturing, Other

REQUIRED JSON FORMAT - EXAMPLE:
{"title": "Smart Healthcare System", "students": "Ahmed Hassan Mohamed Ali, Sara Ibrahim Khalil, Omar Mahmoud Youssef", "supervisor": "Dr. Ahmed Shalaby", "year": "2024", "abstract": "This project addresses critical gaps in current project management approaches.", "technologies": "Java, Spring Boot, MySQL", "description": "A comprehensive system designed to improve healthcare management efficiency.", "keywords": "healthcare, management, AI, automation", "category": "Medical"}

CRITICAL CLEANING RULES:
1. Remove label words: "Abstract:", "Description:", "Keywords:", "Title:" from the beginning
2. Remove page references: "Page 4 87", "Page 4", "P. 87", "pg. 12" from the end
3. Return ONLY the clean content text

OCR Text:
$rawText

RETURN ONLY THE COMPLETE, VALID JSON OBJECT.
""";

      // Retry up to 2 times (across available keys)
      for (int attempt = 0; attempt < 2; attempt++) {
        final decoded = await _geminiRequest(
          modelPath: 'models/gemini-2.5-flash',
          body: {
            'contents': [
              {
                'parts': [
                  {'text': prompt},
                ],
              },
            ],
            'generationConfig': {
              'temperature': 0.0,
              'maxOutputTokens': 2048,
              'topP': 0.95,
            },
          },
          timeoutSeconds: 20,
        );

        if (decoded == null) {
          if (attempt < 1) await Future.delayed(const Duration(seconds: 2));
          continue;
        }

        if (decoded['candidates'] == null || decoded['candidates'].isEmpty) {
          print('[OCR] No candidates in response');
          continue;
        }

        // Handle blocked content
        if (decoded['candidates'][0].containsKey('finishReason')) {
          final reason = decoded['candidates'][0]['finishReason'];
          if (reason == 'SAFETY' || reason == 'RECITATION') {
            print('[OCR] Content blocked: $reason');
            return {};
          }
        }

        final text = decoded['candidates'][0]['content']['parts'][0]['text'];
        print('[OCR] ===== GEMINI EXTRACTION RESPONSE =====');
        print(text);
        print('[OCR] ===== END RESPONSE =====');

        return _validateAndSanitize(text, rawText);
      }

      return {};
    } catch (e) {
      print('[OCR] Gemini extraction error: $e');
      return {};
    }
  }

  // ============================
  // HELPER METHODS
  // ============================

  static Map<String, dynamic> _createEmptyResult() {
    Map<String, dynamic> empty = {};
    for (var key in [
      'title',
      'students',
      'supervisor',
      'year',
      'abstract',
      'technologies',
      'description',
      'keywords',
      'category',
    ]) {
      empty[key] = {'value': '', 'confidence': 0.0};
    }
    return empty;
  }

  static String _preprocessOcrText(String text) {
    return _fixCommonOcrPatterns(text);
  }

  static String _fixCommonOcrPatterns(String text) {
    StringBuffer result = StringBuffer();

    for (int i = 0; i < text.length; i++) {
      String current = text[i];
      String next = i + 1 < text.length ? text[i + 1] : '';
      String prev = i > 0 ? text[i - 1] : '';

      if (current == 'r' &&
          next == 'n' &&
          _isLetter(prev) &&
          i + 2 < text.length &&
          _isLetter(text[i + 2])) {
        result.write('m');
        i++;
        continue;
      }

      if (current == 'l' &&
          (prev == '' || prev == ' ') &&
          next != '' &&
          next.toLowerCase() == next) {
        result.write('I');
        continue;
      }

      if (current == '0' && _isLetter(prev) && _isLetter(next)) {
        result.write(prev == prev.toUpperCase() ? 'O' : 'o');
        continue;
      }

      if (current == '1' && _isLetter(prev) && _isLetter(next)) {
        result.write(prev == prev.toUpperCase() ? 'I' : 'l');
        continue;
      }

      result.write(current);
    }

    return result.toString();
  }

  static String _cleanAbstractOrDescription(String text) {
    if (text.isEmpty) return text;

    String cleaned = text.trim();

    cleaned = cleaned.replaceAll(
      RegExp(r'^abstract\s*:?\s*', caseSensitive: false),
      '',
    );
    cleaned = cleaned.replaceAll(
      RegExp(r'^description\s*:?\s*', caseSensitive: false),
      '',
    );

    cleaned = cleaned.replaceAll(
      RegExp(r'\s*(?:page|pg?\.?)\s*\d+(?:\s+\d+)?\s*$', caseSensitive: false),
      '',
    );

    cleaned = cleaned.replaceAll(RegExp(r'\s+\d{1,3}\s*$'), '');
    cleaned = cleaned.replaceAll(RegExp(r'\s*[|]\s*\d+\s*$'), '');
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();

    return cleaned;
  }

  static String _cleanKeywords(String text) {
    if (text.isEmpty) return text;

    String cleaned = text.trim();
    cleaned = cleaned.replaceAll(
      RegExp(r'^keywords?\s*:?\s*', caseSensitive: false),
      '',
    );
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();

    return cleaned;
  }

  static bool _isLetter(String char) {
    if (char.isEmpty) return false;
    return RegExp(r'[a-zA-Z]').hasMatch(char);
  }

  // ============================
  // HYBRID MERGE + CONFIDENCE
  // ============================

  static Map<String, dynamic> _mergeHybrid(
    Map<String, dynamic> regexData,
    Map<String, dynamic> aiData,
  ) {
    Map<String, dynamic> finalData = {};

    for (var key in [
      'title',
      'students',
      'supervisor',
      'year',
      'abstract',
      'technologies',
      'description',
      'keywords',
      'category',
    ]) {
      String regexValue = regexData[key]?['value'] ?? '';
      double regexConfidence = regexData[key]?['confidence'] ?? 0.0;

      String aiValue = aiData[key] ?? '';
      double aiConfidence = _calculateAIConfidence(aiValue);

      String finalValue;

      if (key == 'students') {
        if (aiValue.isNotEmpty) {
          finalValue = aiValue;
          print('[OCR] Using AI students (preferred): "$finalValue"');
        } else if (regexValue.isNotEmpty) {
          finalValue = regexValue;
          print('[OCR] Using regex students (fallback): "$finalValue"');
        } else {
          finalValue = '';
          print('[OCR] WARNING: No students found by either method!');
        }
      } else if (key == 'abstract' || key == 'description') {
        finalValue = '';
        aiConfidence = 0.0;
        regexConfidence = 0.0;
      } else if (aiValue.isNotEmpty && aiConfidence >= regexConfidence) {
        finalValue = aiValue;
      } else if (regexValue.isNotEmpty) {
        finalValue = regexValue;
      } else {
        finalValue = '';
      }

      double combinedConfidence = _combineConfidence(
        regexScore: regexConfidence,
        aiScore: aiConfidence,
      );

      finalData[key] = {'value': finalValue, 'confidence': combinedConfidence};

      print(
        '[OCR] $key: "${finalValue.length > 50 ? finalValue.substring(0, 50) + "..." : finalValue}" (AI: $aiConfidence, Regex: $regexConfidence, Final: $combinedConfidence)',
      );
    }

    return finalData;
  }

  static double _combineConfidence({
    required double regexScore,
    required double aiScore,
    double regexWeight = 0.3,
    double aiWeight = 0.7,
  }) {
    return ((regexScore * regexWeight) + (aiScore * aiWeight)).clamp(0.0, 1.0);
  }

  static double _calculateAIConfidence(String value) {
    if (value.isEmpty) return 0.0;
    if (value.length < 3) return 0.3;
    if (value.length < 10) return 0.6;
    if (value.length < 30) return 0.8;
    return 0.95;
  }

  // ============================
  // VALIDATION
  // ============================

  static Map<String, dynamic> _validateAndSanitize(
    String rawJson,
    String originalText,
  ) {
    String preExtractedStudents = _preExtractStudents(rawJson);
    if (preExtractedStudents.isNotEmpty) {
      print(
        '[OCR] Pre-extracted students from raw response: "$preExtractedStudents"',
      );
    }

    try {
      String cleaned = rawJson
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();

      cleaned = _fixIncompleteJson(cleaned);
      cleaned = _fixMultilineJsonStrings(cleaned);

      final jsonMatch = RegExp(
        r'\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}',
        dotAll: true,
      ).firstMatch(cleaned);
      if (jsonMatch != null) {
        cleaned = jsonMatch.group(0)!;
      }

      print('[OCR] Attempting to parse cleaned JSON...');

      final decoded = jsonDecode(cleaned);

      Map<String, dynamic> safe = {};

      String normalizedOriginal = originalText
          .toLowerCase()
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

      for (var key in [
        'title',
        'students',
        'supervisor',
        'year',
        'abstract',
        'technologies',
        'description',
        'keywords',
        'category',
      ]) {
        if (key == 'abstract' || key == 'description') {
          safe[key] = '';
          continue;
        }

        dynamic rawValue = decoded[key];
        String value = '';

        if (rawValue != null) {
          if (rawValue is List) {
            value = rawValue.map((e) => e.toString()).join(', ').trim();
            print('[OCR] Students was array, converted to: "$value"');
          } else {
            value = rawValue.toString().trim();
          }
        }

        if (key == 'students' &&
            (value.isEmpty || value.length < 3) &&
            preExtractedStudents.isNotEmpty) {
          value = preExtractedStudents;
          print('[OCR] Using pre-extracted students: "$value"');
        }

        if (value.isEmpty) {
          safe[key] = '';
          continue;
        }

        if (key == 'abstract' || key == 'description') {
          value = _cleanAbstractOrDescription(value);
        }

        if (key == 'keywords') {
          value = _cleanKeywords(value);
        }

        if (key == 'students') {
          safe[key] = value;
          print('[OCR] Students accepted without validation: "$value"');
          continue;
        }

        if (key == 'supervisor' && value.isNotEmpty) {
          value = _correctOcrErrors(value);
        }

        bool isValid = _validateExtraction(value, normalizedOriginal, key);
        safe[key] = isValid ? value : '';

        if (!isValid) {
          print(
            '[OCR] Rejected AI value for $key: "$value" (not found in original)',
          );
        }
      }

      return safe;
    } catch (e) {
      print('[OCR] JSON parse error: $e');
      print('[OCR] Attempting comprehensive fallback extraction...');

      final fallbackData = _extractFieldsWithRegex(rawJson, originalText);

      if ((fallbackData['students'] == null ||
              fallbackData['students']!.isEmpty) &&
          preExtractedStudents.isNotEmpty) {
        fallbackData['students'] = preExtractedStudents;
      }

      return fallbackData;
    }
  }

  static String _fixIncompleteJson(String json) {
    int openBraces = '{'.allMatches(json).length;
    int closeBraces = '}'.allMatches(json).length;

    int quoteCount = 0;
    bool escaped = false;
    for (int i = 0; i < json.length; i++) {
      if (escaped) {
        escaped = false;
        continue;
      }
      if (json[i] == '\\') {
        escaped = true;
        continue;
      }
      if (json[i] == '"') {
        quoteCount++;
      }
    }

    if (quoteCount % 2 == 1) {
      json = json + '"';
    }

    while (closeBraces < openBraces) {
      json = json + '}';
      closeBraces++;
    }

    return json;
  }

  static String _preExtractStudents(String rawResponse) {
    var match = RegExp(
      r'"students"\s*:\s*"([^"]*)',
      dotAll: true,
    ).firstMatch(rawResponse);
    if (match != null) {
      String extracted = match
          .group(1)!
          .replaceAll(RegExp(r'[\n\r]+'), ', ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (extracted.isNotEmpty && extracted.length > 3) {
        return extracted;
      }
    }

    match = RegExp(
      r'"students"\s*:\s*\[([\s\S]*?)(?:\]|$)',
      dotAll: true,
    ).firstMatch(rawResponse);
    if (match != null) {
      String arrayContent = match.group(1)!;
      String extracted = arrayContent
          .replaceAll('"', '')
          .replaceAll(RegExp(r'[\n\r]+'), ', ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (extracted.isNotEmpty) {
        return extracted;
      }
    }

    return '';
  }

  static String _fixMultilineJsonStrings(String json) {
    StringBuffer result = StringBuffer();
    bool inString = false;
    bool escaped = false;

    for (int i = 0; i < json.length; i++) {
      String char = json[i];
      String nextChar = i + 1 < json.length ? json[i + 1] : '';

      if (escaped) {
        result.write(char);
        escaped = false;
        continue;
      }

      if (char == '\\') {
        escaped = true;
        result.write(char);
        continue;
      }

      if (char == '"') {
        inString = !inString;
        result.write(char);
        continue;
      }

      if (inString && (char == '\n' || char == '\r')) {
        result.write(' ');
        if (char == '\r' && nextChar == '\n') {
          i++;
        }
        continue;
      }

      result.write(char);
    }

    return result.toString();
  }

  static Map<String, dynamic> _extractFieldsWithRegex(
    String rawResponse,
    String originalText,
  ) {
    Map<String, dynamic> extracted = {};

    final patterns = {
      'title': r'"title"\s*:\s*"([^"]+)"',
      'supervisor': r'"supervisor"\s*:\s*"([^"]+)"',
      'year': r'"year"\s*:\s*"([^"]+)"',
      'technologies': r'"technologies"\s*:\s*"([^"]+)"',
      'keywords': r'"keywords"\s*:\s*"([^"]+)"',
      'category': r'"category"\s*:\s*"([^"]+)"',
    };

    for (var entry in patterns.entries) {
      final key = entry.key;
      final pattern = entry.value;
      var match = RegExp(pattern).firstMatch(rawResponse);

      if (match != null) {
        extracted[key] = match.group(1)!.trim();
      } else {
        extracted[key] = '';
      }
    }

    extracted['abstract'] = '';
    extracted['description'] = '';

    String students = _extractStudentsFromRawResponse(
      rawResponse,
      originalText,
    );
    extracted['students'] = students;

    return extracted;
  }

  static String _extractStudentsFromRawResponse(
    String rawResponse,
    String originalText,
  ) {
    var match = RegExp(
      r'"students"\s*:\s*"([^"]*)',
      dotAll: true,
    ).firstMatch(rawResponse);
    if (match != null && match.group(1)!.trim().isNotEmpty) {
      return match.group(1)!.trim().replaceAll(RegExp(r'\s+'), ' ');
    }

    match = RegExp(
      r'"students"\s*:\s*\[([\s\S]*?)(?:\]|$)',
      dotAll: true,
    ).firstMatch(rawResponse);
    if (match != null) {
      String arrayContent = match.group(1)!;
      String extracted = arrayContent
          .replaceAll('"', '')
          .replaceAll(RegExp(r'[\n\r]+'), ', ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (extracted.isNotEmpty) {
        return extracted;
      }
    }

    return _extractStudents(originalText);
  }

  static bool _validateExtraction(
    String value,
    String originalText,
    String field,
  ) {
    if (field == 'year') {
      return RegExp(r'^20\d{2}$').hasMatch(value);
    }

    String normalizedValue = value
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (normalizedValue.length < 15) {
      return originalText.contains(normalizedValue);
    }

    List<String> words = normalizedValue
        .split(' ')
        .where((w) => w.length > 3)
        .toList();

    if (words.isEmpty) return originalText.contains(normalizedValue);

    int matchCount = words.where((word) => originalText.contains(word)).length;
    double matchRatio = matchCount / words.length;

    return matchRatio >= 0.6;
  }

  // ============================
  // REGEX FALLBACK
  // ============================

  static Map<String, dynamic> _extractHeuristically(String rawText) {
    Map<String, dynamic> data = {};
    String text = rawText.replaceAll('\r\n', '\n');

    _addField(data, 'year', _extractYear(text));
    _addField(data, 'supervisor', _extractSupervisor(text));
    _addField(data, 'technologies', _extractTechnologies(text));
    _addField(data, 'abstract', '');
    _addField(data, 'title', _guessTitle(text));
    _addField(data, 'students', _extractStudents(text));
    _addField(data, 'category', _guessCategory(text));
    _addField(data, 'description', '');
    _addField(data, 'keywords', '');

    return data;
  }

  static void _addField(Map<String, dynamic> map, String key, String value) {
    map[key] = {'value': value, 'confidence': _calculateRegexConfidence(value)};
  }

  static double _calculateRegexConfidence(String value) {
    if (value.isEmpty) return 0.0;
    if (value.length < 3) return 0.3;
    if (value.length < 10) return 0.5;
    if (value.length < 30) return 0.7;
    return 0.85;
  }

  static String _extractSupervisor(String fullText) {
    String supervisorName = '';

    final supervisionMatch = RegExp(
      r'under\s+supervision\s+of\s+((?:dr|prof|mr|ms|mrs)\.?\s+[a-z]+(?:\s+[a-z]+)?)',
      caseSensitive: false,
    ).firstMatch(fullText);

    if (supervisionMatch != null) {
      supervisorName = supervisionMatch.group(1)!.trim();
    }

    if (supervisorName.isEmpty) {
      final labelMatch = RegExp(
        r'supervis(?:or|ion)\s*:?\s*((?:dr|prof|mr|ms|mrs)\.?\s+[a-z]+(?:\s+[a-z]+)?)',
        caseSensitive: false,
      ).firstMatch(fullText);

      if (labelMatch != null) {
        supervisorName = labelMatch.group(1)!.trim();
      }
    }

    if (supervisorName.isEmpty) {
      final match = RegExp(
        r'(?:dr\.|prof\.|mr\.|ms\.|mrs\.)\s+[a-z]+(?:\s+[a-z]+)?',
        caseSensitive: false,
      ).firstMatch(fullText);
      if (match != null) {
        supervisorName = match.group(0)!.trim();
      }
    }

    if (supervisorName.isNotEmpty) {
      supervisorName = _correctOcrErrors(supervisorName);
    }

    return supervisorName;
  }

  static String _correctOcrErrors(String text) {
    if (text.isEmpty) return text;

    String corrected = _fixCommonOcrPatterns(text);

    List<String> words = corrected.split(' ');
    List<String> correctedWords = [];

    for (var word in words) {
      if (word.isEmpty) continue;

      String cleanWord = word.toLowerCase().replaceAll('.', '');

      if (['dr', 'prof', 'mr', 'ms', 'mrs'].contains(cleanWord)) {
        correctedWords.add(_capitalizeTitle(cleanWord));
        continue;
      }

      correctedWords.add(_smartCorrectWord(word));
    }

    return correctedWords.join(' ');
  }

  static String _smartCorrectWord(String word) {
    if (word.isEmpty) return word;

    String lower = word.toLowerCase();
    String corrected = lower;

    if (corrected.endsWith('mn') && corrected.length > 4) {
      corrected = corrected.substring(0, corrected.length - 1);
    }

    corrected = corrected.replaceAllMapped(
      RegExp(r'([a-z])rn([a-z])'),
      (match) => '${match.group(1)}m${match.group(2)}',
    );

    if (corrected.endsWith('nar') && corrected.length > 4) {
      corrected = corrected.replaceAll(RegExp(r'nar$'), 'mar');
    }

    if (corrected.endsWith('ml') && corrected.length > 3) {
      corrected = corrected.replaceAll(RegExp(r'ml$'), 'mal');
    }
    if (corrected.endsWith('rnal') && corrected.length > 5) {
      corrected = corrected.replaceAll(RegExp(r'rnal$'), 'mal');
    }

    corrected = corrected.replaceAll('ei', 'e');

    corrected = corrected.replaceAllMapped(
      RegExp(r'([b-df-hj-np-tv-z])\1+'),
      (match) => match.group(1)!,
    );

    if (corrected.isNotEmpty) {
      corrected = corrected[0].toUpperCase() + corrected.substring(1);
    }

    return corrected;
  }

  static String _capitalizeTitle(String title) {
    switch (title.toLowerCase()) {
      case 'dr':
        return 'Dr.';
      case 'prof':
        return 'Prof.';
      case 'mr':
        return 'Mr.';
      case 'ms':
        return 'Ms.';
      case 'mrs':
        return 'Mrs.';
      default:
        return title;
    }
  }

  static String _extractTechnologies(String fullText) {
    final match = RegExp(
      r'(?:technolog|tools|stack)(?:ies|y)?\s*:?\s*(.+?)(?:\n|$)',
      caseSensitive: false,
    ).firstMatch(fullText);

    if (match != null) {
      String tech = match.group(1)!.trim();
      if (tech.isNotEmpty && tech.length < 200) {
        return tech;
      }
    }

    return '';
  }

  static String _extractYear(String text) {
    final labelMatch = RegExp(
      r'(?:year|academic year)\s*:?\s*(20\d{2})',
      caseSensitive: false,
    ).firstMatch(text);
    if (labelMatch != null) {
      return labelMatch.group(1)!;
    }

    final monthPattern = RegExp(
      r'(?:january|february|march|april|may|june|july|august|september|october|november|december)',
      caseSensitive: false,
    );

    final allMatches = RegExp(r'\b(20\d{2})\b').allMatches(text);

    if (allMatches.isEmpty) return '';

    String lastValidYear = '';
    for (var match in allMatches) {
      int startPos = match.start;
      String beforeText = startPos > 50
          ? text.substring(startPos - 50, startPos)
          : text.substring(0, startPos);

      if (monthPattern.hasMatch(beforeText)) continue;

      lastValidYear = match.group(1)!;
    }

    return lastValidYear;
  }

  static String _guessTitle(String fullText) {
    List<String> lines = fullText.split('\n');

    for (var line in lines) {
      String clean = line.trim();
      if (clean.isEmpty) continue;

      String lower = clean.toLowerCase();

      if (lower.contains('faculty') ||
          lower.contains('university') ||
          lower.contains('department') ||
          lower.contains('college') ||
          lower.contains('project team') ||
          lower.contains('supervision')) {
        continue;
      }

      if (RegExp(r'^\d+\s*[-–]').hasMatch(clean)) continue;
      if (clean.length < 15) continue;

      if (clean.length >= 20 && clean.length < 150) {
        if (clean != clean.toUpperCase()) {
          return clean;
        }
      }
    }

    return '';
  }

  static String _guessCategory(String fullText) {
    String lower = fullText.toLowerCase();

    final categories = {
      'Medical': [
        'medical',
        'hospital',
        'patient',
        'doctor',
        'clinic',
        'healthcare',
        'disease',
        'diagnosis',
        'treatment',
        'medicine',
        'health',
        'nursing',
        'pharma',
        'pharmaceutical',
      ],
      'Education': [
        'education',
        'school',
        'student',
        'learning',
        'course',
        'university',
        'training',
        'academic',
        'classroom',
        'teacher',
        'exam',
        'grade',
        'assessment',
        'online learning',
        'e-learning',
      ],
      'Finance': [
        'bank',
        'finance',
        'payment',
        'transaction',
        'investment',
        'crypto',
        'stock',
        'trading',
        'financial',
        'accounting',
        'wallet',
        'billing',
        'invoice',
        'loan',
      ],
      'E-Commerce': [
        'ecommerce',
        'e-commerce',
        'shopping',
        'store',
        'product',
        'cart',
        'checkout',
        'vendor',
        'seller',
        'buyer',
        'marketplace',
        'commerce',
        'shop',
        'retail',
      ],
      'Social Media': [
        'social',
        'network',
        'chat',
        'messaging',
        'post',
        'feed',
        'like',
        'comment',
        'share',
        'friend',
        'follower',
        'community',
        'interaction',
        'profile',
      ],
      'Entertainment': [
        'entertainment',
        'movie',
        'music',
        'game',
        'video',
        'streaming',
        'audio',
        'content',
        'media',
        'podcast',
        'cinema',
        'play',
        'film',
        'show',
      ],
      'Transportation': [
        'transport',
        'taxi',
        'ride',
        'delivery',
        'logistics',
        'shipping',
        'car',
        'driver',
        'route',
        'tracking',
        'fleet',
        'vehicle',
        'cargo',
        'courier',
      ],
      'Smart Agriculture': [
        'agriculture',
        'farm',
        'farming',
        'crop',
        'soil',
        'irrigation',
        'weather',
        'farmer',
        'harvest',
        'greenhouse',
        'agricultural',
        'smart farming',
      ],
      'IoT/Smart Home': [
        'smart home',
        'iot',
        'sensor',
        'automation',
        'smart',
        'arduino',
        'raspberry',
        'embedded',
        'device',
        'connected',
        'internet of things',
        'home automation',
      ],
      'Manufacturing': [
        'manufacturing',
        'factory',
        'production',
        'industrial',
        'machinery',
        'process',
        'quality',
        'supply chain',
        'warehouse',
        'inventory',
        'automation',
      ],
    };

    Map<String, int> scores = {};
    for (var entry in categories.entries) {
      int count = 0;
      for (var keyword in entry.value) {
        if (lower.contains(keyword)) count++;
      }
      if (count > 0) scores[entry.key] = count;
    }

    if (scores.isNotEmpty) {
      var best = scores.entries.reduce((a, b) => a.value > b.value ? a : b);
      return best.key;
    }

    return 'Other';
  }

  static String _extractStudents(String fullText) {
    print('[OCR] === Starting heuristic student extraction ===');

    List<String> names = [];

    final numberedPattern = RegExp(
      r'(\d+)\s*[-–.]\s*([a-z]+(?:\s+[a-z]+){1,6})',
      caseSensitive: false,
    );

    final matches = numberedPattern.allMatches(fullText);

    for (var match in matches) {
      String number = match.group(1)!;
      String name = match.group(2)!.trim();

      if (name.length < 5 || name.length > 150) continue;
      if (name.toLowerCase().contains(
        RegExp(
          r'chapter|section|page|abstract|project|supervision|university|faculty|benha|feb|january|february|march|april|may|june|july|august|september|october|november|december|submitted|requirements|degree|bachelor|computer|science|department|team',
        ),
      ))
        continue;

      name = name.replaceAll(RegExp(r'\s+'), ' ').trim();

      List<String> words = name.split(' ');
      if (words.length >= 2 && words.length <= 7) {
        bool looksLikeName = words.every(
          (w) => w.isNotEmpty && w[0].toUpperCase() == w[0] && w.length > 1,
        );

        if (looksLikeName) {
          name = _correctOcrErrors(name);
          names.add(name);
          print('[OCR] Found student #$number: "$name"');
        }
      }
    }

    if (names.isNotEmpty) {
      List<String> uniqueNames = [];
      Set<String> seen = {};
      for (var name in names) {
        String normalized = name.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
        if (!seen.contains(normalized)) {
          uniqueNames.add(name);
          seen.add(normalized);
        }
      }
      names = uniqueNames;
    }

    String result = names.join(', ');
    print('[OCR] === Total students extracted: ${names.length} ===');
    print('[OCR] === Final student list: "$result" ===');
    return result;
  }
}
