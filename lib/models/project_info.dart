// lib/models/project_info.dart

class ProjectInfo {
  final int? id;
  final String title;
  final String abstractText;
  final String description;
  final String category;
  final List<String> technologies;
  final List<String> extractedKeywords;
  final List<String> studentNames;
  final String supervisorName;
  final String year;
  final String rawOcrText;
  final bool isSynced;
  // ── New fields ──────────────────────────────────────────────────────────────
  final String problem;
  final String solution;
  final String objectives;

  ProjectInfo({
    this.id,
    required this.title,
    required this.abstractText,
    required this.description,
    required this.category,
    required this.technologies,
    required this.extractedKeywords,
    required this.studentNames,
    required this.supervisorName,
    required this.year,
    required this.rawOcrText,
    this.isSynced = false,
    this.problem = '',
    this.solution = '',
    this.objectives = '',
  });

  ProjectInfo copyWith({
    int? id,
    String? title,
    String? abstractText,
    String? description,
    String? category,
    List<String>? technologies,
    List<String>? extractedKeywords,
    List<String>? studentNames,
    String? supervisorName,
    String? year,
    String? rawOcrText,
    bool? isSynced,
    String? problem,
    String? solution,
    String? objectives,
  }) {
    return ProjectInfo(
      id: id ?? this.id,
      title: title ?? this.title,
      abstractText: abstractText ?? this.abstractText,
      description: description ?? this.description,
      category: category ?? this.category,
      technologies: technologies ?? this.technologies,
      extractedKeywords: extractedKeywords ?? this.extractedKeywords,
      studentNames: studentNames ?? this.studentNames,
      supervisorName: supervisorName ?? this.supervisorName,
      year: year ?? this.year,
      rawOcrText: rawOcrText ?? this.rawOcrText,
      isSynced: isSynced ?? this.isSynced,
      problem: problem ?? this.problem,
      solution: solution ?? this.solution,
      objectives: objectives ?? this.objectives,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'abstractText': abstractText,
      'description': description,
      'category': category,
      'technologies': technologies.join(','),
      'extractedKeywords': extractedKeywords.join(','),
      'studentNames': studentNames.join('|'),
      'supervisorName': supervisorName,
      'year': year,
      'rawOcrText': rawOcrText,
      'isSynced': isSynced,
      'problem': problem,
      'solution': solution,
      'objectives': objectives,
    };
  }

  factory ProjectInfo.fromMap(int key, Map<dynamic, dynamic> raw) {
    final map = Map<String, dynamic>.from(raw);
    return ProjectInfo(
      id: key,
      title: (map['title'] as String?) ?? '',
      abstractText: (map['abstractText'] as String?) ?? '',
      description: (map['description'] as String?) ?? '',
      category: (map['category'] as String?) ?? '',
      technologies: (map['technologies'] as String?)
              ?.split(',')
              .where((e) => e.isNotEmpty)
              .toList() ??
          [],
      extractedKeywords: (map['extractedKeywords'] as String?)
              ?.split(',')
              .where((e) => e.isNotEmpty)
              .toList() ??
          [],
      studentNames: (map['studentNames'] as String?)
              ?.split('|')
              .where((e) => e.isNotEmpty)
              .toList() ??
          [],
      supervisorName: (map['supervisorName'] as String?) ?? '',
      year: (map['year'] as String?) ?? '',
      rawOcrText: (map['rawOcrText'] as String?) ?? '',
      isSynced: (map['isSynced'] as bool?) ?? false,
      problem: (map['problem'] as String?) ?? '',
      solution: (map['solution'] as String?) ?? '',
      objectives: (map['objectives'] as String?) ?? '',
    );
  }
}