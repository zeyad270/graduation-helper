// lib/services/google_sheets_service.dart

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/project_info.dart';

class GoogleSheetsService {
  static const String _scriptUrl =
      "https://script.google.com/macros/s/AKfycbwonCEp1PQPOtv7SnyvjQaf5-Zo-B_SGL8XNvI1GaTLryuuFgwzmFShCx_pHe-6SUpD/exec";

  static Future<bool> uploadProject(ProjectInfo project) async {
    try {
      final response = await http.post(
        Uri.parse(_scriptUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'title': project.title,
          'studentNames': project.studentNames.join(', '),
          'supervisorName': project.supervisorName,
          'year': project.year,
          'category': project.category,
          'technologies': project.technologies.join(', '),
          'keywords': project.extractedKeywords.join(', '),
          'abstractText': project.abstractText,
          'description': project.description,
          'problem': project.problem,
          'solution': project.solution,
          'objectives': project.objectives,
          'aiSummary': project.aiSummary,
          'rawOcrText': project.rawOcrText,
        }),
      );

      print('[Sync] Response status: \${response.statusCode}');
      print('[Sync] Response body: \${response.body}');
      return response.statusCode == 200 || response.statusCode == 302;
    } catch (e) {
      print('[Sync] Upload failed: \$e');
      return false;
    }
  }
}