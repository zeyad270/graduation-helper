// lib/services/google_sheets_service.dart

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/project_info.dart';

class GoogleSheetsService {
  static const String _scriptUrl = "https://script.google.com/macros/s/AKfycbw9abjo0SvN1tQcoAYY0F3KVBEAeddlgMTC4JjDAxPbWsOoywtpta-UGCHnuwFUOkCB/exec"; 

  static Future<bool> uploadProject(ProjectInfo project) async {
    try {
      final response = await http.post(
        Uri.parse(_scriptUrl),
        body: jsonEncode({
          'title': project.title,
          
          // CHANGE THIS LINE: Join with comma and space
          'studentNames': project.studentNames.join(', '), 
          
          'supervisorName': project.supervisorName,
          'year': project.year,
          'category': project.category,
          'technologies': project.technologies.join(', '), 
          'keywords': project.extractedKeywords.join(', '),
          'abstractText': project.abstractText,
          'description': project.description,
          'rawOcrText': project.rawOcrText,
        }),
      );
      
      return response.statusCode == 200 || response.statusCode == 302;
    } catch (e) {
      print("Upload failed: $e");
      return false;
    }
  }
}