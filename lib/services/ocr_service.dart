import 'package:flutter/foundation.dart';

class OcrService {
  
  /// The main function that turns raw text into a structured map
  static Map<String, String> extractFields(String rawText) {
    Map<String, String> data = {};
    
    // 1. Clean up the text (unify newlines)
    String text = rawText.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    List<String> lines = text.split('\n');

    // 2. Extract Specific Single-Line Fields (Year, Supervisor, Category)
    data['year'] = _extractYear(text);
    data['supervisor'] = _extractLineByKeywords(lines, ['supervisor', 'supervised by', 'advisor', 'dr.', 'prof.']) ?? '';
    data['category'] = _extractLineByKeywords(lines, ['category', 'domain', 'track', 'field']) ?? '';
    data['technologies'] = _extractLineByKeywords(lines, ['technologies', 'tools', 'tech stack', 'frameworks']) ?? '';
    
    // 3. Extract Block Fields (Abstract, Description) - Handles multi-line text
    data['abstract'] = _extractBlock(text, startKeywords: ['abstract', 'summary'], stopKeywords: ['keywords', 'introduction', 'table of contents', '1.']);
    data['description'] = _extractBlock(text, startKeywords: ['description', 'overview'], stopKeywords: ['features', 'objectives', 'technologies']);
    
    // 4. Extract Keywords (Comma separated)
    String? keywordsLine = _extractLineByKeywords(lines, ['keywords', 'index terms']);
    if (keywordsLine != null) {
      data['extractedKeywords'] = keywordsLine; // We'll parse commas in the UI
    }

    // 5. Smart Title Extraction (Heuristic: First non-empty line that isn't a header)
    data['title'] = _guessTitle(lines);

    // 6. Smart Student Extraction (Look for names or "By:")
    data['students'] = _extractStudents(lines);

    return data;
  }

  // --- Helper Methods ---

  /// Finds a specific line that starts with one of the keywords
  static String? _extractLineByKeywords(List<String> lines, List<String> keywords) {
    for (String line in lines) {
      String lowerLine = line.toLowerCase().trim();
      for (String keyword in keywords) {
        if (lowerLine.startsWith(keyword)) {
          // Return the part AFTER the keyword (e.g. "Supervisor: Dr. Ahmed" -> "Dr. Ahmed")
          return line.substring(line.toLowerCase().indexOf(keyword) + keyword.length).replaceAll(':', '').trim();
        }
      }
    }
    return null;
  }

  /// Extracts a chunk of text between a Header and the Next Header
  static String _extractBlock(String fullText, {required List<String> startKeywords, required List<String> stopKeywords}) {
    String lowerText = fullText.toLowerCase();
    int startIndex = -1;
    String matchedKeyword = '';

    // Find where the block starts
    for (var k in startKeywords) {
      int idx = lowerText.indexOf(k);
      if (idx != -1) {
        startIndex = idx;
        matchedKeyword = k;
        break;
      }
    }

    if (startIndex == -1) return '';

    // Move start index to after the keyword (plus colon/newline)
    int contentStart = startIndex + matchedKeyword.length;
    
    // Find where the block ends (the next section)
    int endIndex = fullText.length;
    for (var k in stopKeywords) {
      int idx = lowerText.indexOf(k, contentStart);
      if (idx != -1 && idx < endIndex) {
        endIndex = idx;
      }
    }

    String extracted = fullText.substring(contentStart, endIndex).trim();
    
    // Clean up leading colons or bullets
    if (extracted.startsWith(':')) extracted = extracted.substring(1).trim();
    
    return extracted;
  }

  /// regex to find a 4-digit year (2018-2029)
  static String _extractYear(String text) {
    final yearRegex = RegExp(r'\b(20[1-2][0-9])\b');
    final match = yearRegex.firstMatch(text);
    return match?.group(0) ?? '';
  }

  /// Guesses the title. Usually the first line, often in ALL CAPS.
  static String _guessTitle(List<String> lines) {
    for (var line in lines) {
      String clean = line.trim();
      if (clean.isEmpty) continue;
      // Skip common header info
      if (clean.toLowerCase().contains('university')) continue;
      if (clean.toLowerCase().contains('faculty')) continue;
      if (clean.toLowerCase().contains('department')) continue;
      if (clean.toLowerCase().contains('graduation project')) continue;
      
      return clean; // Return the first substantial line
    }
    return '';
  }

  /// Tries to find student names
  static String _extractStudents(List<String> lines) {
    List<String> found = [];
    bool isCapturing = false;

    for (var line in lines) {
      String lower = line.toLowerCase().trim();
      
      // Explicit start
      if (lower.startsWith('by:') || lower.startsWith('students:') || lower.startsWith('team:')) {
        String content = line.substring(line.indexOf(':') + 1).trim();
        if (content.isNotEmpty) return content; // If names are on the same line
        isCapturing = true; // Names are on next lines
        continue;
      }

      // Stop capturing
      if (isCapturing) {
        if (lower.startsWith('supervised') || lower.startsWith('abstract') || lower.isEmpty) {
          break;
        }
        found.add(line.trim());
      }
    }
    return found.join(', ');
  }
}
