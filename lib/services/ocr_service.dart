import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;

class OcrService {
  // ⚠️ REPLACE THIS WITH YOUR ACTUAL GEMINI API KEY
  // Get your key from: https://aistudio.google.com/app/apikey
  static const String GEMINI_API_KEY =
      'AIzaSyBoqaKosaqDPS4ZglNfLtuyPlAXdEmr1x8';

  // ============================
  // MAIN PUBLIC API - Use this in your app
  // ============================

  /// Complete OCR pipeline: Image → Text Extraction → Data Extraction
  /// This is the main method to use in your app
  ///
  /// @param base64Image - Base64 encoded image string
  /// @param fallbackOcrText - Optional: If you have text from another OCR engine, pass it as fallback
  /// @return Map with extracted fields (title, students, supervisor, year, etc.)
  static Future<Map<String, dynamic>> extractFromImage(
    String base64Image, {
    String? fallbackOcrText,
  }) async {
    print('[OCR] ===== Starting Image OCR Processing =====');

    // Step 1: Extract text using Gemini Vision (best quality)
    String extractedText = await _performGeminiVisionOCR(base64Image);

    // Step 2: Fallback to provided OCR text if Gemini Vision failed
    if (extractedText.isEmpty &&
        fallbackOcrText != null &&
        fallbackOcrText.isNotEmpty) {
      print('[OCR] Using fallback OCR text');
      extractedText = fallbackOcrText;
    }

    // Step 3: If we still don't have text, return empty result
    if (extractedText.isEmpty) {
      print('[OCR] ERROR: No text could be extracted from image');
      return _createEmptyResult();
    }

    // Step 4: Process the extracted text to get structured data
    return await processOCR(extractedText);
  }

  /// Extracts a single specific field from OCR text using a focused Gemini call
  static Future<String> extractSingleField(
    String rawText,
    String fieldName,
  ) async {
    try {
      if (GEMINI_API_KEY == 'YOUR_API_KEY_HERE' || GEMINI_API_KEY.isEmpty) {
        return '';
      }

      final url = Uri.parse(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$GEMINI_API_KEY",
      );

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

      final response = await http
          .post(
            url,
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({
              "contents": [
                {
                  "parts": [
                    {"text": prompt},
                  ],
                },
              ],
              "generationConfig": {"temperature": 0.1, "maxOutputTokens": 2048},
            }),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);

        if (decoded["candidates"] == null || decoded["candidates"].isEmpty) {
          return '';
        }

        final text =
            decoded["candidates"][0]["content"]["parts"][0]["text"] as String;

        if (text.trim() == 'NOT_FOUND') {
          print('[OCR] Field $fieldName not found in text');
          return '';
        }

        print(
          '[OCR] Extracted $fieldName: "${text.substring(0, text.length.clamp(0, 100))}..."',
        );
        return text.trim();
      } else {
        print('[OCR] Single field extraction error: ${response.statusCode}');
        return '';
      }
    } catch (e) {
      print('[OCR] extractSingleField error: $e');
      return '';
    }
  }

  /// Process OCR text (legacy method for backward compatibility)
  /// Use extractFromImage() for new implementations
  static Future<Map<String, dynamic>> processOCR(String rawText) async {
    print('[OCR] ===== Starting OCR Processing =====');

    // Preprocess OCR text to fix common issues
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
      return regexData; // fallback
    }

    return _mergeHybrid(regexData, aiData);
  }

  // ============================
  // GEMINI VISION OCR
  // ============================

  /// Enhanced OCR using Gemini's vision capabilities
  /// This provides MUCH better quality than traditional OCR engines
  static Future<String> _performGeminiVisionOCR(String base64Image) async {
    try {
      if (GEMINI_API_KEY == 'YOUR_API_KEY_HERE' || GEMINI_API_KEY.isEmpty) {
        print('[OCR] ⚠️ Gemini API key not configured');
        return '';
      }

      final url = Uri.parse(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent?key=$GEMINI_API_KEY",
      );

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

      final response = await http
          .post(
            url,
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({
              "contents": [
                {
                  "parts": [
                    {"text": prompt},
                    {
                      "inline_data": {
                        "mime_type": "image/jpeg",
                        "data": base64Image,
                      },
                    },
                  ],
                },
              ],
              "generationConfig": {"temperature": 0.1, "maxOutputTokens": 4096},
            }),
          )
          .timeout(const Duration(seconds: 30));

      print('[OCR] Gemini Vision Status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);

        if (decoded["candidates"] == null || decoded["candidates"].isEmpty) {
          print('[OCR] No candidates in Gemini Vision response');
          return '';
        }

        final text = decoded["candidates"][0]["content"]["parts"][0]["text"];
        print('[OCR] ===== GEMINI VISION EXTRACTED TEXT =====');
        print(text);
        print('[OCR] ===== END EXTRACTED TEXT (${text.length} chars) =====');

        return text;
      } else {
        print(
          '[OCR] Gemini Vision Error: ${response.statusCode} - ${response.body}',
        );
      }
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
      if (GEMINI_API_KEY == 'YOUR_API_KEY_HERE' || GEMINI_API_KEY.isEmpty) {
        print(
          '[OCR] ⚠️ Gemini API key not configured - using regex fallback only',
        );
        return {};
      }

      final url = Uri.parse(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$GEMINI_API_KEY",
      );

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
- abstract: Extract ONLY the abstract content text. Remove the word "Abstract" if it appears at the start. Remove page numbers (e.g., "Page 4", "P. 87", "Page 4 87") from the end. Remove any headers or labels. Return ONLY the clean abstract text content.
- technologies: Extract technology stack if explicitly mentioned (e.g., "Java, Python, MySQL")
- description: Extract ONLY the description content text. Remove the word "Description" if it appears at the start. Remove page numbers (e.g., "Page 4", "P. 87") from the end. Remove any headers or labels. Return ONLY the clean description text content.
- keywords: Extract keywords ONLY if explicitly listed with "Keywords:" label, otherwise return "". Remove the "Keywords:" label itself from the output.
- category: Choose ONE from: Medical, Education, Finance, E-Commerce, Social Media, Entertainment, Transportation, Smart Agriculture, IoT/Smart Home, Manufacturing, Other

REQUIRED JSON FORMAT - EXAMPLE:
{"title": "Smart Healthcare System", "students": "Ahmed Hassan Mohamed Ali, Sara Ibrahim Khalil, Omar Mahmoud Youssef", "supervisor": "Dr. Ahmed Shalaby", "year": "2024", "abstract": "This project addresses critical gaps in current project management approaches while maintaining scalability and user-friendly interfaces.", "technologies": "Java, Spring Boot, MySQL", "description": "A comprehensive system designed to improve healthcare management efficiency through AI-powered analytics and automated workflows.", "keywords": "healthcare, management, AI, automation", "category": "Medical"}

CRITICAL CLEANING RULES:
1. Remove label words: "Abstract:", "Description:", "Keywords:", "Title:" from the beginning
2. Remove page references: "Page 4 87", "Page 4", "P. 87", "pg. 12" from the end
3. Return ONLY the clean content text
4. Example: "Abstract: This is the text. Page 4 87" → "This is the text."

CRITICAL REMINDERS:
1. Extract COMPLETE student names - do not shorten or abbreviate
2. DO NOT extract abstract or description - return empty strings
3. Ensure JSON is COMPLETE with all closing quotes and braces
4. All values must be on single lines (no line breaks)

OCR Text:
$rawText

RETURN ONLY THE COMPLETE, VALID JSON OBJECT.
""";

      // Retry logic (max 2 attempts)
      for (int attempt = 0; attempt < 2; attempt++) {
        try {
          final response = await http
              .post(
                url,
                headers: {"Content-Type": "application/json"},
                body: jsonEncode({
                  "contents": [
                    {
                      "parts": [
                        {"text": prompt},
                      ],
                    },
                  ],
                  "generationConfig": {
                    "temperature": 0.0,
                    "maxOutputTokens": 2048,
                    "topP": 0.95,
                  },
                }),
              )
              .timeout(const Duration(seconds: 20));

          print('[OCR] Gemini Extraction Status: ${response.statusCode}');

          if (response.statusCode == 200) {
            final decoded = jsonDecode(response.body);

            if (decoded["candidates"] == null ||
                decoded["candidates"].isEmpty) {
              print('[OCR] No candidates in response');
              return {};
            }

            // Handle blocked content
            if (decoded["candidates"][0].containsKey("finishReason")) {
              final reason = decoded["candidates"][0]["finishReason"];
              if (reason == "SAFETY" || reason == "RECITATION") {
                print('[OCR] Content blocked: $reason');
                return {};
              }
            }

            final text =
                decoded["candidates"][0]["content"]["parts"][0]["text"];
            print('[OCR] ===== GEMINI EXTRACTION RESPONSE =====');
            print(text);
            print('[OCR] ===== END RESPONSE =====');

            return _validateAndSanitize(text, rawText);
          } else {
            print(
              '[OCR] Gemini Error: ${response.statusCode} - ${response.body}',
            );
          }
        } catch (e) {
          print('[OCR] Attempt ${attempt + 1} failed: $e');
          if (attempt < 1) {
            await Future.delayed(const Duration(seconds: 2));
          }
        }
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

  /// Preprocess OCR text to fix common OCR errors before extraction
  static String _preprocessOcrText(String text) {
    // Apply smart character-level fixes
    return _fixCommonOcrPatterns(text);
  }

  /// Smart OCR pattern fixing based on common character confusions
  static String _fixCommonOcrPatterns(String text) {
    StringBuffer result = StringBuffer();

    for (int i = 0; i < text.length; i++) {
      String current = text[i];
      String next = i + 1 < text.length ? text[i + 1] : '';
      String prev = i > 0 ? text[i - 1] : '';

      // Fix 'rn' that should be 'm' (common OCR mistake)
      // Only in middle of words (not at boundaries)
      if (current == 'r' &&
          next == 'n' &&
          _isLetter(prev) &&
          i + 2 < text.length &&
          _isLetter(text[i + 2])) {
        result.write('m');
        i++; // Skip the 'n'
        continue;
      }

      // Fix 'l' at start of common words that should be 'I'
      if (current == 'l' &&
          (prev == '' || prev == ' ') &&
          next != '' &&
          next.toLowerCase() == next) {
        // Likely should be capital I (like Ibrahim, Intelligence, Islam)
        result.write('I');
        continue;
      }

      // Fix '0' (zero) in names - should be 'o' or 'O'
      if (current == '0' && _isLetter(prev) && _isLetter(next)) {
        result.write(prev == prev.toUpperCase() ? 'O' : 'o');
        continue;
      }

      // Fix '1' (one) in names - should be 'l' or 'I'
      if (current == '1' && _isLetter(prev) && _isLetter(next)) {
        result.write(prev == prev.toUpperCase() ? 'I' : 'l');
        continue;
      }

      result.write(current);
    }

    return result.toString();
  }

  /// Clean abstract or description by removing labels and page numbers
  static String _cleanAbstractOrDescription(String text) {
    if (text.isEmpty) return text;

    String cleaned = text.trim();

    // Remove label at the beginning (case-insensitive)
    cleaned = cleaned.replaceAll(
      RegExp(r'^abstract\s*:?\s*', caseSensitive: false),
      '',
    );
    cleaned = cleaned.replaceAll(
      RegExp(r'^description\s*:?\s*', caseSensitive: false),
      '',
    );

    // Remove page numbers at the end
    // Patterns: "Page 4 87", "Page 4", "P. 87", "pg. 12", "page 87", etc.
    cleaned = cleaned.replaceAll(
      RegExp(r'\s*(?:page|pg?\.?)\s*\d+(?:\s+\d+)?\s*$', caseSensitive: false),
      '',
    );

    // Remove standalone numbers at the end that look like page numbers (2-3 digits)
    cleaned = cleaned.replaceAll(RegExp(r'\s+\d{1,3}\s*$'), '');

    // Remove common OCR artifacts at the end
    cleaned = cleaned.replaceAll(
      RegExp(r'\s*[|]\s*\d+\s*$'),
      '',
    ); // "text | 87"

    // Clean up extra whitespace
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();

    return cleaned;
  }

  /// Clean keywords by removing the "Keywords:" label
  static String _cleanKeywords(String text) {
    if (text.isEmpty) return text;

    String cleaned = text.trim();

    // Remove "Keywords:" label at the beginning
    cleaned = cleaned.replaceAll(
      RegExp(r'^keywords?\s*:?\s*', caseSensitive: false),
      '',
    );

    // Clean up extra whitespace
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
      "title",
      "students",
      "supervisor",
      "year",
      "abstract",
      "technologies",
      "description",
      "keywords",
      "category",
    ]) {
      String regexValue = regexData[key]?['value'] ?? "";
      double regexConfidence = regexData[key]?['confidence'] ?? 0.0;

      String aiValue = aiData[key] ?? "";
      double aiConfidence = _calculateAIConfidence(aiValue);

      String finalValue;

      // Special handling for students - prefer AI if it has content
      if (key == "students") {
        if (aiValue.isNotEmpty) {
          finalValue = aiValue;
          print('[OCR] Using AI students (preferred): "$finalValue"');
        } else if (regexValue.isNotEmpty) {
          finalValue = regexValue;
          print('[OCR] Using regex students (fallback): "$finalValue"');
        } else {
          finalValue = "";
          print('[OCR] WARNING: No students found by either method!');
        }
      }
      // NEVER extract abstract or description - always empty
      else if (key == "abstract" || key == "description") {
        finalValue = "";
        aiConfidence = 0.0;
        regexConfidence = 0.0;
      }
      // For other fields, prefer AI if it has content and higher confidence
      else if (aiValue.isNotEmpty && aiConfidence >= regexConfidence) {
        finalValue = aiValue;
      } else if (regexValue.isNotEmpty) {
        finalValue = regexValue;
      } else {
        finalValue = "";
      }

      // Combined confidence for transparency
      double combinedConfidence = _combineConfidence(
        regexScore: regexConfidence,
        aiScore: aiConfidence,
      );

      finalData[key] = {"value": finalValue, "confidence": combinedConfidence};

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
    // FIRST: Try to extract students from incomplete/broken JSON
    String preExtractedStudents = _preExtractStudents(rawJson);
    if (preExtractedStudents.isNotEmpty) {
      print(
        '[OCR] Pre-extracted students from raw response: "$preExtractedStudents"',
      );
    }

    try {
      // Clean up markdown code blocks and whitespace
      String cleaned = rawJson
          .replaceAll("```json", "")
          .replaceAll("```", "")
          .trim();

      // CRITICAL FIX: Fix incomplete JSON by adding missing closing quotes/braces
      cleaned = _fixIncompleteJson(cleaned);

      // CRITICAL FIX: Remove newlines inside JSON strings
      cleaned = _fixMultilineJsonStrings(cleaned);

      // Try to extract JSON if there's extra text
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

      // Normalize original text for better matching
      String normalizedOriginal = originalText
          .toLowerCase()
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

      for (var key in [
        "title",
        "students",
        "supervisor",
        "year",
        "abstract",
        "technologies",
        "description",
        "keywords",
        "category",
      ]) {
        // Force abstract and description to always be empty
        if (key == "abstract" || key == "description") {
          safe[key] = "";
          continue;
        }

        // Special handling for students if it comes as a list
        dynamic rawValue = decoded[key];
        String value = "";

        if (rawValue != null) {
          if (rawValue is List) {
            value = rawValue.map((e) => e.toString()).join(', ').trim();
            print('[OCR] Students was array, converted to: "$value"');
          } else {
            value = rawValue.toString().trim();
          }
        }

        // Use pre-extracted students if JSON decoding didn't get it or got empty
        if (key == "students" &&
            (value.isEmpty || value.length < 3) &&
            preExtractedStudents.isNotEmpty) {
          value = preExtractedStudents;
          print('[OCR] Using pre-extracted students: "$value"');
        }

        if (value.isEmpty) {
          safe[key] = "";
          continue;
        }

        // Clean up abstract and description fields
        if (key == "abstract" || key == "description") {
          value = _cleanAbstractOrDescription(value);
          print('[OCR] Cleaned $key: "$value"');
        }

        // Clean up keywords field
        if (key == "keywords") {
          value = _cleanKeywords(value);
          print('[OCR] Cleaned keywords: "$value"');
        }

        // Skip validation for students since names can be fragmented across OCR lines
        if (key == "students") {
          safe[key] = value;
          print('[OCR] Students accepted without validation: "$value"');
          continue;
        }

        // Apply OCR corrections to supervisor names
        if (key == "supervisor" && value.isNotEmpty) {
          value = _correctOcrErrors(value);
          print('[OCR] Supervisor after OCR correction: "$value"');
        }

        // Relaxed validation - check if key parts exist in original
        bool isValid = _validateExtraction(value, normalizedOriginal, key);

        safe[key] = isValid ? value : "";

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

      // Comprehensive fallback extraction
      final fallbackData = _extractFieldsWithRegex(rawJson, originalText);

      // Use pre-extracted students if fallback didn't find any
      if ((fallbackData['students'] == null ||
              fallbackData['students']!.isEmpty) &&
          preExtractedStudents.isNotEmpty) {
        fallbackData['students'] = preExtractedStudents;
        print(
          '[OCR] Using pre-extracted students in fallback: "$preExtractedStudents"',
        );
      }

      print('[OCR] Fallback extraction results:');
      fallbackData.forEach((key, value) {
        print('[OCR]   $key: "$value"');
      });

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
      print('[OCR] Fixing unclosed string');
      json = json + '"';
    }

    while (closeBraces < openBraces) {
      print('[OCR] Adding missing closing brace');
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

    return "";
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
        extracted[key] = "";
      }
    }

    extracted['abstract'] = "";
    extracted['description'] = "";

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
      String extracted = match.group(1)!.trim().replaceAll(RegExp(r'\s+'), ' ');
      return extracted;
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

    String heuristic = _extractStudents(originalText);
    if (heuristic.isNotEmpty) {
      return heuristic;
    }

    return "";
  }

  static bool _validateExtraction(
    String value,
    String originalText,
    String field,
  ) {
    if (field == "year") {
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

    _addField(data, "year", _extractYear(text));
    _addField(data, "supervisor", _extractSupervisor(text));
    _addField(data, "technologies", _extractTechnologies(text));
    _addField(data, "abstract", "");
    _addField(data, "title", _guessTitle(text));
    _addField(data, "students", _extractStudents(text));
    _addField(data, "category", _guessCategory(text));
    _addField(data, "description", "");
    _addField(data, "keywords", "");

    return data;
  }

  static void _addField(Map<String, dynamic> map, String key, String value) {
    map[key] = {"value": value, "confidence": _calculateRegexConfidence(value)};
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
      final titlePattern = RegExp(
        r'(?:dr\.|prof\.|mr\.|ms\.|mrs\.)\s+[a-z]+(?:\s+[a-z]+)?',
        caseSensitive: false,
      );

      final match = titlePattern.firstMatch(fullText);
      if (match != null) {
        supervisorName = match.group(0)!.trim();
      }
    }

    if (supervisorName.isNotEmpty) {
      supervisorName = _correctOcrErrors(supervisorName);
    }

    return supervisorName;
  }

  /// Smart OCR error correction using pattern analysis
  static String _correctOcrErrors(String text) {
    if (text.isEmpty) return text;

    String corrected = _fixCommonOcrPatterns(text);

    List<String> words = corrected.split(' ');
    List<String> correctedWords = [];

    for (var word in words) {
      if (word.isEmpty) continue;

      String cleanWord = word.toLowerCase().replaceAll('.', '');

      if (cleanWord == 'dr' ||
          cleanWord == 'prof' ||
          cleanWord == 'mr' ||
          cleanWord == 'ms' ||
          cleanWord == 'mrs') {
        correctedWords.add(_capitalizeTitle(cleanWord));
        continue;
      }

      String correctedWord = _smartCorrectWord(word);
      correctedWords.add(correctedWord);
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

      if (monthPattern.hasMatch(beforeText)) {
        continue;
      }

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
      if (count > 0) {
        scores[entry.key] = count;
      }
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
    print('[OCR] Found ${matches.length} numbered patterns in text');

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
