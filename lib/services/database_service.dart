import 'package:hive_flutter/hive_flutter.dart';
import '../models/project_info.dart';

class DatabaseService {
  static const _boxName = 'projectsBox';
  static Box<Map>? _box;

  static Future<Box<Map>> _openBox() async {
    if (_box != null && _box!.isOpen) return _box!;
    _box = await Hive.openBox<Map>(_boxName);
    return _box!;
  }

  static Future<List<ProjectInfo>> getAllProjects() async {
    final box = await _openBox();
    final List<ProjectInfo> result = [];
    for (int i = 0; i < box.length; i++) {
      final key = box.keyAt(i);
      final value = box.getAt(i);
      if (value != null && key is int) {
        result.add(ProjectInfo.fromMap(key, value));
      }
    }
    result.sort((a, b) => (b.id ?? 0).compareTo(a.id ?? 0));
    return result;
  }

  static Future<int> insertProject(ProjectInfo project) async {
    final box = await _openBox();
    return await box.add(project.toMap());
  }

  static Future<void> updateProject(ProjectInfo project) async {
    if (project.id == null) return;
    final box = await _openBox();
    await box.put(project.id, project.toMap());
  }

  static Future<void> deleteProject(int id) async {
    final box = await _openBox();
    await box.delete(id);
  }

  static Future<void> clearAll() async {
    final box = await _openBox();
    await box.clear();
  }
}