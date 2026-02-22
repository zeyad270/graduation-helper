import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/project_info.dart';
import '../services/database_service.dart';
import '../services/google_sheets_service.dart';
import '../services/ocr_service.dart';

// ─── Design Tokens ────────────────────────────────────────────────────────────
class _AppColors {
  static const bg = Color(0xFFF0F2F8);
  static const surface = Colors.white;
  static const primary = Color(0xFF1A1A2E);
  static const accent = Color(0xFF4F46E5);
  static const accentLight = Color(0xFFEEF2FF);
  static const success = Color(0xFF059669);
  static const successLight = Color(0xFFECFDF5);
  static const warning = Color(0xFFD97706);
  static const warningLight = Color(0xFFFFFBEB);
  static const danger = Color(0xFFDC2626);
  static const textPrimary = Color(0xFF111827);
  static const textSecondary = Color(0xFF6B7280);
  static const border = Color(0xFFE5E7EB);
  static const cardShadow = Color(0x0A000000);
}

class OCRHomePage extends StatefulWidget {
  const OCRHomePage({super.key});

  @override
  State<OCRHomePage> createState() => _OCRHomePageState();
}

class _OCRHomePageState extends State<OCRHomePage>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  // ── Navigation ──────────────────────────────────────────────────────────────
  late TabController _tabController;
  int _currentIndex = 0;

  // ── State ───────────────────────────────────────────────────────────────────
  final ImagePicker _picker = ImagePicker();
  final List<Map<String, dynamic>> _scannedDocs = [];

  bool _isProcessing = false;
  String _processingStep = '';
  double _processingProgress = 0.0;

  List<ProjectInfo> _projects = [];
  int? _editingProjectId;
  Map<String, dynamic> _lastExtracted = {}; // stores last extraction result for summary

  // ── Form Controllers ────────────────────────────────────────────────────────
  final _titleCtrl        = TextEditingController();
  final _abstractCtrl     = TextEditingController();
  final _descCtrl         = TextEditingController();
  final _categoryCtrl     = TextEditingController();
  final _techCtrl         = TextEditingController();
  final _supervisorCtrl   = TextEditingController();
  final _yearCtrl         = TextEditingController(text: DateTime.now().year.toString());
  final _keywordsCtrl     = TextEditingController();
  final _problemCtrl      = TextEditingController();   // NEW
  final _solutionCtrl     = TextEditingController();   // NEW
  final _objectivesCtrl   = TextEditingController();   // NEW
  final _studentEntryCtrl = TextEditingController();
  List<String> _studentNames = [];

  // ── Lifecycle ────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) {
        setState(() => _currentIndex = _tabController.index);
      }
    });
    _loadProjects();
    _restoreDraft();

    for (final ctrl in [
      _titleCtrl, _abstractCtrl, _descCtrl, _categoryCtrl,
      _techCtrl, _supervisorCtrl, _keywordsCtrl,
      _problemCtrl, _solutionCtrl, _objectivesCtrl,
    ]) {
      ctrl.addListener(_saveDraft);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    for (final ctrl in [
      _titleCtrl, _abstractCtrl, _descCtrl, _categoryCtrl,
      _techCtrl, _supervisorCtrl, _yearCtrl, _keywordsCtrl,
      _problemCtrl, _solutionCtrl, _objectivesCtrl,
      _studentEntryCtrl,
    ]) {
      ctrl.dispose();
    }
    super.dispose();
  }

  // ── Data ─────────────────────────────────────────────────────────────────────
  Future<void> _loadProjects() async {
    final list = await DatabaseService.getAllProjects();
    if (mounted) setState(() => _projects = list);
  }

  Future<void> _saveDraft() async {
    if (_editingProjectId != null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('draft_form', jsonEncode({
      'title':      _titleCtrl.text,
      'abstract':   _abstractCtrl.text,
      'desc':       _descCtrl.text,
      'cat':        _categoryCtrl.text,
      'tech':       _techCtrl.text,
      'sup':        _supervisorCtrl.text,
      'key':        _keywordsCtrl.text,
      'problem':    _problemCtrl.text,
      'solution':   _solutionCtrl.text,
      'objectives': _objectivesCtrl.text,
      'students':   _studentNames,
      'docs':       _scannedDocs.map((d) => d['rawText'] as String).toList(),
    }));
  }

  Future<void> _restoreDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString('draft_form');
    if (s == null) return;
    try {
      final d = jsonDecode(s);
      setState(() {
        _titleCtrl.text      = d['title']      ?? '';
        _abstractCtrl.text   = d['abstract']   ?? '';
        _descCtrl.text       = d['desc']        ?? '';
        _categoryCtrl.text   = d['cat']         ?? '';
        _techCtrl.text       = d['tech']        ?? '';
        _supervisorCtrl.text = d['sup']         ?? '';
        _keywordsCtrl.text   = d['key']         ?? '';
        _problemCtrl.text    = d['problem']     ?? '';
        _solutionCtrl.text   = d['solution']    ?? '';
        _objectivesCtrl.text = d['objectives']  ?? '';
        if (d['students'] != null) _studentNames = List<String>.from(d['students']);
        if (d['docs'] != null) {
          for (final raw in List<String>.from(d['docs'])) {
            if (raw.isNotEmpty) {
              _scannedDocs.add({'image': null, 'rawText': raw, 'label': 'Restored doc', 'isLoading': false});
            }
          }
        }
      });
      if (_titleCtrl.text.isNotEmpty) _showSnack('Draft restored', type: SnackType.success);
    } catch (_) {}
  }

  Future<void> _clearDraft() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('draft_form');
  }

  // ── Image Picking ────────────────────────────────────────────────────────────
  Future<void> _pickAndAddDocument(ImageSource source) async {
    try {
      if (source == ImageSource.gallery) {
        final images = await _picker.pickMultiImage();
        if (images.isEmpty) return;
        for (final img in images) await _processAndAddImage(img);
      } else {
        final img = await _picker.pickImage(source: ImageSource.camera);
        if (img == null) return;
        await _processAndAddImage(img);
      }
    } catch (e) {
      _showSnack('Error picking image: $e', type: SnackType.error);
    }
  }

  Future<void> _processAndAddImage(XFile img) async {
    // Gemini Vision reads images directly — no ML Kit OCR needed.
    setState(() {
      _scannedDocs.add({
        'image':     img,
        'rawText':   '',
        'label':     'Page \${_scannedDocs.length + 1}',
        'isLoading': false,
      });
    });
    _saveDraft();
  }



  void _removeDoc(int index) {
    setState(() => _scannedDocs.removeAt(index));
    _saveDraft();
  }

  // ── AI EXTRACT ALL ────────────────────────────────────────────────────────────
  Future<void> _aiExtractAll() async {
    if (_scannedDocs.isEmpty) {
      _showSnack('Add at least one document or image first', type: SnackType.error);
      return;
    }
    setState(() { _isProcessing = true; _processingStep = 'Preparing documents...'; _processingProgress = 0.1; });
    try {
      final imagePaths = _scannedDocs
          .where((d) => d['image'] != null)
          .map((d) => (d['image'] as XFile).path)
          .toList();
      final rawTexts = _scannedDocs
          .map((d) => d['rawText'] as String)
          .where((t) => t.isNotEmpty)
          .toList();

      if (imagePaths.isEmpty && rawTexts.isEmpty) {
        _showSnack('No text or images to process', type: SnackType.error);
        return;
      }

      // Single intelligent call — vision if images exist, text fallback otherwise
      final fields = await OcrService.extractFromAll(
        imagePaths: imagePaths,
        rawTexts: rawTexts,
        onProgress: (step, progress) {
          if (mounted) setState(() { _processingStep = step; _processingProgress = progress; });
        },
      );

      setState(() { _processingStep = 'Filling form...'; _processingProgress = 0.95; });
      await Future.delayed(const Duration(milliseconds: 200));
      _fillFormFromFields(fields);
      _showSnack('All fields extracted!', type: SnackType.success);
    } catch (e) {
      _showSnack('Extraction error: $e', type: SnackType.error);
    } finally {
      if (mounted) setState(() { _isProcessing = false; _processingStep = ''; _processingProgress = 0.0; });
    }
  }

  void _fillFormFromFields(Map<String, dynamic> fields) {
    String get(String key) {
      final v = fields[key];
      if (v == null) return '';
      if (v is String) return v;
      if (v is Map && v.containsKey('value')) return v['value']?.toString() ?? '';
      return '';
    }
    setState(() {
      _titleCtrl.text      = get('title');
      _abstractCtrl.text   = get('abstract');
      _descCtrl.text       = get('description');
      _supervisorCtrl.text = get('supervisor');
      _yearCtrl.text       = get('year').isNotEmpty ? get('year') : DateTime.now().year.toString();
      _techCtrl.text       = get('technologies');
      _keywordsCtrl.text   = get('keywords');
      _categoryCtrl.text   = get('category');
      _problemCtrl.text    = get('problem');
      _solutionCtrl.text   = get('solution');
      _objectivesCtrl.text = get('objectives');
      final studentsRaw    = get('students');
      if (studentsRaw.isNotEmpty) {
        _studentNames = studentsRaw.split(RegExp(r'[,;|]')).map((e) => e.trim()).where((e) => e.length > 2).toList();
      }
    });
    _lastExtracted = fields;
    _saveDraft();
  }

  // ── Single-field re-extract ───────────────────────────────────────────────────
  Future<void> _reExtractField(TextEditingController ctrl, String fieldName) async {
    final imagePaths = _scannedDocs
        .where((d) => d['image'] != null)
        .map((d) => (d['image'] as XFile).path)
        .toList();
    final allText = _scannedDocs
        .map((d) => d['rawText'] as String)
        .where((t) => t.isNotEmpty)
        .join('\n\n');

    if (imagePaths.isEmpty && allText.isEmpty) {
      _showSnack('Add document pages first', type: SnackType.error);
      return;
    }

    _showSnack('Re-extracting $fieldName...', type: SnackType.info);

    final value = await OcrService.extractSingleField(
      fieldName,
      imagePaths: imagePaths,
      fallbackText: allText,
    );

    if (value.isNotEmpty) {
      setState(() => ctrl.text = value);
      _saveDraft();
      _showSnack('$fieldName updated!', type: SnackType.success);
    } else {
      _showSnack('Could not extract $fieldName — try Extract All instead', type: SnackType.warning);
    }
  }

  // ── Save / Edit ───────────────────────────────────────────────────────────────
  void _startEditing(ProjectInfo project) {
    setState(() {
      _editingProjectId    = project.id;
      _titleCtrl.text      = project.title;
      _abstractCtrl.text   = project.abstractText;
      _descCtrl.text       = project.description;
      _categoryCtrl.text   = project.category;
      _techCtrl.text       = project.technologies.join(', ');
      _keywordsCtrl.text   = project.extractedKeywords.join(', ');
      _studentNames        = List.from(project.studentNames);
      _supervisorCtrl.text = project.supervisorName;
      _yearCtrl.text       = project.year;
      _problemCtrl.text    = project.problem;
      _solutionCtrl.text   = project.solution;
      _objectivesCtrl.text = project.objectives;
      _scannedDocs.clear();
      if (project.rawOcrText.isNotEmpty) {
        _scannedDocs.add({'image': null, 'rawText': project.rawOcrText, 'label': 'Original text', 'isLoading': false});
      }
      _tabController.animateTo(0);
    });
  }

  void _cancelEditing() => _clearForm();

  Future<void> _saveLocal() async {
    if (_titleCtrl.text.trim().isEmpty) { _showSnack('Project Title is required', type: SnackType.error); return; }
    final combinedRaw = _scannedDocs.map((d) => d['rawText'] as String).join('\n\n--- Page Break ---\n\n');

    final project = ProjectInfo(
      id:                _editingProjectId,
      title:             _titleCtrl.text.trim(),
      abstractText:      _abstractCtrl.text.trim(),
      description:       _descCtrl.text.trim(),
      category:          _categoryCtrl.text.trim(),
      technologies:      _techCtrl.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
      extractedKeywords: _keywordsCtrl.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
      studentNames:      _studentNames,
      supervisorName:    _supervisorCtrl.text.trim(),
      year:              _yearCtrl.text.trim(),
      rawOcrText:        combinedRaw,
      isSynced:          false,
      problem:           _problemCtrl.text.trim(),
      solution:          _solutionCtrl.text.trim(),
      objectives:        _objectivesCtrl.text.trim(),
    );

    if (_editingProjectId != null) {
      await DatabaseService.updateProject(project);
      _showSnack('Project updated!', type: SnackType.success);
    } else {
      await DatabaseService.insertProject(project);
      _showSnack('Project saved!', type: SnackType.success);
    }
    _clearForm();
    _loadProjects();
    _tabController.animateTo(2);
  }

  void _clearForm() {
    _clearDraft();
    setState(() {
      _editingProjectId = null;
      _scannedDocs.clear();
      for (final c in [
        _titleCtrl, _abstractCtrl, _descCtrl, _categoryCtrl,
        _techCtrl, _supervisorCtrl, _keywordsCtrl,
        _problemCtrl, _solutionCtrl, _objectivesCtrl,
        _studentEntryCtrl,
      ]) { c.clear(); }
      _studentNames.clear();
      _lastExtracted = {};
      _yearCtrl.text = DateTime.now().year.toString();
    });
  }

  // ── Sync ─────────────────────────────────────────────────────────────────────
  Future<void> _syncAll() async {
    final unsynced = _projects.where((p) => !p.isSynced).toList();
    if (unsynced.isEmpty) return;
    _showSnack('Syncing ${unsynced.length} projects...', type: SnackType.info);
    int count = 0;
    for (final p in unsynced) {
      if (await GoogleSheetsService.uploadProject(p)) {
        await DatabaseService.updateProject(p.copyWith(isSynced: true));
        count++;
      }
    }
    _loadProjects();
    _showSnack('Synced $count / ${unsynced.length}',
        type: count == unsynced.length ? SnackType.success : SnackType.warning);
  }

  void _uploadSingle(ProjectInfo p) async {
    _showSnack('Syncing...', type: SnackType.info);
    if (await GoogleSheetsService.uploadProject(p)) {
      await DatabaseService.updateProject(p.copyWith(isSynced: true));
      _loadProjects();
      _showSnack('Synced!', type: SnackType.success);
    } else {
      _showSnack('Sync failed', type: SnackType.error);
    }
  }

  // ── Snackbar ──────────────────────────────────────────────────────────────────
  void _showSnack(String msg, {required SnackType type}) {
    final colors = {SnackType.success: _AppColors.success, SnackType.error: _AppColors.danger, SnackType.warning: _AppColors.warning, SnackType.info: _AppColors.accent};
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(color: Colors.white)),
      backgroundColor: colors[type],
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      duration: const Duration(seconds: 3),
      margin: const EdgeInsets.all(12),
    ));
  }

  Future<bool> _confirm(String title, String body) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text(title),
            content: Text(body),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: _AppColors.danger, foregroundColor: Colors.white),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Confirm'),
              ),
            ],
          ),
        ) ?? false;
  }

  // ─── BUILD ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isEditing     = _editingProjectId != null;
    final unsyncedCount = _projects.where((p) => !p.isSynced).length;

    return Scaffold(
      backgroundColor: _AppColors.bg,
      appBar: _buildAppBar(isEditing, unsyncedCount),
      body: TabBarView(
        controller: _tabController,
        children: [_buildFormTab(isEditing), _buildRawTab(), _buildProjectsTab()],
      ),
      floatingActionButton: _currentIndex == 2 ? _buildSyncFab(unsyncedCount) : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  PreferredSizeWidget _buildAppBar(bool isEditing, int unsyncedCount) {
    return AppBar(
      elevation: 0,
      backgroundColor: _AppColors.primary,
      title: Text(isEditing ? 'Edit Project' : 'GradOCR',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 22, letterSpacing: -0.5)),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(48),
        child: Container(
          color: _AppColors.primary,
          child: TabBar(
            controller: _tabController,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white38,
            indicatorColor: _AppColors.accent,
            indicatorWeight: 3,
            labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            tabs: [
              const Tab(icon: Icon(Icons.edit_document, size: 18), text: 'Form'),
              Tab(icon: Stack(clipBehavior: Clip.none, children: [
                const Icon(Icons.description_outlined, size: 18),
                if (_scannedDocs.isNotEmpty)
                  Positioned(right: -6, top: -4, child: Container(
                    width: 14, height: 14,
                    decoration: BoxDecoration(color: _AppColors.accent, borderRadius: BorderRadius.circular(7)),
                    child: Center(child: Text('${_scannedDocs.length}', style: const TextStyle(fontSize: 9, color: Colors.white))),
                  )),
              ]), text: 'Documents'),
              Tab(icon: Stack(clipBehavior: Clip.none, children: [
                const Icon(Icons.folder_outlined, size: 18),
                if (_projects.isNotEmpty)
                  Positioned(right: -6, top: -4, child: Container(
                    width: 14, height: 14,
                    decoration: BoxDecoration(color: Colors.orange, borderRadius: BorderRadius.circular(7)),
                    child: Center(child: Text('${_projects.length}', style: const TextStyle(fontSize: 9, color: Colors.white))),
                  )),
              ]), text: 'Projects'),
            ],
          ),
        ),
      ),
      actions: [
        if (isEditing)
          IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: _cancelEditing, tooltip: 'Cancel Edit')
        else if (_currentIndex == 0)
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white54),
            onPressed: () async {
              if (await _confirm('Clear Form', 'Reset all fields and documents?')) {
                _clearForm();
                _showSnack('Form cleared', type: SnackType.success);
              }
            },
            tooltip: 'Clear Form',
          ),
        if (_currentIndex == 2)
          IconButton(
            icon: const Icon(Icons.delete_forever, color: Colors.white54),
            onPressed: () async {
              if (await _confirm('Delete All', 'Permanently delete all saved projects?')) {
                for (final p in _projects) if (p.id != null) await DatabaseService.deleteProject(p.id!);
                _loadProjects();
                _showSnack('All deleted', type: SnackType.success);
              }
            },
            tooltip: 'Delete All',
          ),
      ],
    );
  }

  // ─── TAB 1: FORM ───────────────────────────────────────────────────────────
  Widget _buildFormTab(bool isEditing) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isEditing) _buildEditBanner(),

          if (!isEditing) ...[
            _buildSectionLabel('DOCUMENTS', Icons.document_scanner),
            _buildDocumentsPanel(),
            const SizedBox(height: 12),
            _buildExtractAllButton(),
            if (_lastExtracted.isNotEmpty) ...[
              const SizedBox(height: 14),
              _buildExtractionSummary(),
            ],
            const SizedBox(height: 24),
          ],

          // ── Project Details ──────────────────────────────────────────────
          _buildSectionLabel('PROJECT DETAILS', Icons.info_outline),
          _buildField(_titleCtrl, 'Project Title', Icons.title),
          const SizedBox(height: 12),
          _buildStudentSection(),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _buildField(_yearCtrl, 'Year', Icons.calendar_today, keyboardType: TextInputType.number)),
            const SizedBox(width: 12),
            Expanded(child: _buildField(_categoryCtrl, 'Category', Icons.category)),
          ]),
          const SizedBox(height: 12),
          _buildField(_supervisorCtrl, 'Supervisor', Icons.person_outline),
          const SizedBox(height: 12),
          _buildField(_techCtrl, 'Technologies', Icons.code, reExtractKey: 'technologies'),
          const SizedBox(height: 12),
          _buildField(_keywordsCtrl, 'Keywords', Icons.tag, reExtractKey: 'keywords'),
          const SizedBox(height: 12),
          _buildField(_abstractCtrl, 'Abstract', Icons.article_outlined, maxLines: 5, reExtractKey: 'abstract'),
          const SizedBox(height: 12),
          _buildField(_descCtrl, 'Description', Icons.notes, maxLines: 5, reExtractKey: 'description'),

          // ── Problem, Solution & Objectives ───────────────────────────────
          const SizedBox(height: 20),
          _buildSectionLabel('PROBLEM, SOLUTION & OBJECTIVES', Icons.lightbulb_outline),
          _buildField(_problemCtrl, 'Problem Statement', Icons.report_problem_outlined,
              maxLines: 4, reExtractKey: 'problem'),
          const SizedBox(height: 12),
          _buildField(_solutionCtrl, 'Proposed Solution', Icons.check_circle_outline,
              maxLines: 4, reExtractKey: 'solution'),
          const SizedBox(height: 12),
          _buildField(_objectivesCtrl, 'Project Objectives', Icons.flag_outlined,
              maxLines: 4, reExtractKey: 'objectives'),

          const SizedBox(height: 28),
          _buildSaveButton(isEditing),
        ],
      ),
    );
  }

  Widget _buildEditBanner() => Container(
        margin: const EdgeInsets.only(bottom: 20),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: _AppColors.warningLight,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _AppColors.warning.withOpacity(0.3)),
        ),
        child: Row(children: [
          Icon(Icons.edit, color: _AppColors.warning, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text('Editing: ${_titleCtrl.text}',
              style: TextStyle(color: _AppColors.warning, fontWeight: FontWeight.w600))),
          TextButton(
            onPressed: _cancelEditing,
            style: TextButton.styleFrom(foregroundColor: _AppColors.warning, padding: EdgeInsets.zero, minimumSize: const Size(0, 0)),
            child: const Text('Cancel'),
          ),
        ]),
      );

  // ─── DOCUMENTS PANEL ────────────────────────────────────────────────────────

  Widget _buildDocumentsPanel() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // ── Add buttons: Camera + Gallery only ──────────────────────────────
      Row(children: [
        Expanded(child: _buildAddDocButton(
          Icons.camera_alt_rounded, 'Camera',
          () => _pickAndAddDocument(ImageSource.camera),
          _AppColors.accent,
        )),
        const SizedBox(width: 12),
        Expanded(child: _buildAddDocButton(
          Icons.photo_library_rounded, 'Gallery',
          () => _pickAndAddDocument(ImageSource.gallery),
          const Color(0xFF7C3AED),
        )),
      ]),

      // ── Image grid ──────────────────────────────────────────────────────
      if (_scannedDocs.isNotEmpty) ...[
        const SizedBox(height: 14),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 0.75,
          ),
          itemCount: _scannedDocs.length,
          itemBuilder: (ctx, i) {
            final doc = _scannedDocs[i];
            final img = doc['image'] as XFile?;
            return _buildImageTile(i, doc, img);
          },
        ),
      ] else
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Center(child: Column(children: [
            Icon(Icons.add_photo_alternate_outlined, size: 40, color: _AppColors.border),
            const SizedBox(height: 8),
            Text('Add document pages', style: TextStyle(color: _AppColors.textSecondary, fontSize: 13)),
          ])),
        ),
    ]);
  }

  Widget _buildAddDocButton(IconData icon, String label, VoidCallback onTap, Color color) {
    return Material(
      color: color.withOpacity(0.07),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withOpacity(0.25)),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(
              width: 34, height: 34,
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 10),
            Text(label, style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    );
  }

  Widget _buildImageTile(int index, Map<String, dynamic> doc, XFile? img) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Image / placeholder
        GestureDetector(
          onTap: img != null ? () => _previewImage(img, index) : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: img != null
                ? Image.file(File(img.path), fit: BoxFit.cover)
                : Container(
                    decoration: BoxDecoration(
                      color: _AppColors.accentLight,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.description_outlined, color: _AppColors.accent, size: 32),
                  ),
          ),
        ),
        // Page label bottom
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 5),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.black.withOpacity(0.6), Colors.transparent],
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                ),
              ),
              child: Text(
                doc['label'] as String,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
        // Delete button top-right
        Positioned(
          top: 4, right: 4,
          child: GestureDetector(
            onTap: () => _removeDoc(index),
            child: Container(
              width: 22, height: 22,
              decoration: BoxDecoration(
                color: _AppColors.danger,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 4)],
              ),
              child: const Icon(Icons.close, color: Colors.white, size: 13),
            ),
          ),
        ),
        // Tap to preview overlay icon bottom-right (only for images)
        if (img != null)
          Positioned(
            bottom: 24, right: 4,
            child: Container(
              width: 22, height: 22,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.5),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.zoom_in, color: Colors.white, size: 13),
            ),
          ),
      ],
    );
  }

  void _previewImage(XFile img, int index) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(children: [
          // Full image
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: InteractiveViewer(
              minScale: 0.8,
              maxScale: 5.0,
              child: Image.file(File(img.path), fit: BoxFit.contain),
            ),
          ),
          // Close button
          Positioned(
            top: 8, right: 8,
            child: GestureDetector(
              onTap: () => Navigator.pop(ctx),
              child: Container(
                width: 32, height: 32,
                decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                child: const Icon(Icons.close, color: Colors.white, size: 18),
              ),
            ),
          ),
          // Page label + delete
          Positioned(
            bottom: 8, left: 8, right: 8,
            child: Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                child: Text('Page ${index + 1}', style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () { Navigator.pop(ctx); _removeDoc(index); },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(color: _AppColors.danger.withOpacity(0.85), borderRadius: BorderRadius.circular(20)),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.delete_outline, color: Colors.white, size: 14),
                    SizedBox(width: 4),
                    Text('Remove', style: TextStyle(color: Colors.white, fontSize: 12)),
                  ]),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _buildExtractAllButton() {
    final imgCount   = _scannedDocs.where((d) => d['image'] != null).length;
    final hasContent = imgCount > 0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      decoration: BoxDecoration(
        gradient: hasContent
            ? const LinearGradient(
                colors: [Color(0xFF4F46E5), Color(0xFF7C3AED)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: hasContent ? null : _AppColors.border,
        borderRadius: BorderRadius.circular(18),
        boxShadow: hasContent
            ? [BoxShadow(color: const Color(0xFF4F46E5).withOpacity(0.4), blurRadius: 20, offset: const Offset(0, 8))]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: (!hasContent || _isProcessing) ? null : _aiExtractAll,
          borderRadius: BorderRadius.circular(18),
          splashColor: Colors.white12,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            child: _isProcessing
                ? Column(children: [
                    Row(children: [
                      const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)),
                      const SizedBox(width: 14),
                      Expanded(child: Text(_processingStep,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
                          overflow: TextOverflow.ellipsis)),
                      Text('${(_processingProgress * 100).round()}%',
                          style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
                    ]),
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: _processingProgress,
                        backgroundColor: Colors.white24,
                        valueColor: const AlwaysStoppedAnimation(Colors.white),
                        minHeight: 4,
                      ),
                    ),
                  ])
                : Row(children: [
                    Container(
                      width: 42, height: 42,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(hasContent ? 0.2 : 0.0),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.auto_awesome_rounded,
                          color: hasContent ? Colors.white : _AppColors.textSecondary, size: 22),
                    ),
                    const SizedBox(width: 14),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Extract All Fields',
                          style: TextStyle(
                            color: hasContent ? Colors.white : _AppColors.textSecondary,
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            letterSpacing: -0.3,
                          )),
                      const SizedBox(height: 2),
                      Text(
                        hasContent
                            ? '$imgCount page${imgCount != 1 ? "s" : ""} ready · powered by Gemini'
                            : 'Add pages above first',
                        style: TextStyle(
                          color: hasContent ? Colors.white.withOpacity(0.75) : _AppColors.textSecondary.withOpacity(0.6),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ])),
                    if (hasContent)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: const Text('GO', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1)),
                      ),
                  ]),
          ),
        ),
      ),
    );
  }

  Widget _buildExtractionSummary() {
    if (_lastExtracted.isEmpty) return const SizedBox.shrink();

    String getValue(String key) {
      final v = _lastExtracted[key];
      if (v == null) return '';
      if (v is String) return v;
      if (v is Map) return v['value']?.toString() ?? '';
      return '';
    }

    final fields = [
      ('title',        'Title',      Icons.title),
      ('students',     'Students',   Icons.people_outline),
      ('supervisor',   'Supervisor', Icons.person_outline),
      ('year',         'Year',       Icons.calendar_today),
      ('abstract',     'Abstract',   Icons.article_outlined),
      ('description',  'Description',Icons.notes),
      ('problem',      'Problem',    Icons.report_problem_outlined),
      ('solution',     'Solution',   Icons.check_circle_outline),
      ('objectives',   'Objectives', Icons.flag_outlined),
      ('technologies', 'Technologies',Icons.code),
      ('keywords',     'Keywords',   Icons.tag),
      ('category',     'Category',   Icons.category_outlined),
    ];

    final found    = fields.where((f) => getValue(f.$1).isNotEmpty).toList();
    final notFound = fields.where((f) => getValue(f.$1).isEmpty).toList();

    return Container(
      decoration: BoxDecoration(
        color: _AppColors.successLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _AppColors.success.withOpacity(0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Row(children: [
            Container(
              width: 28, height: 28,
              decoration: BoxDecoration(color: _AppColors.success, shape: BoxShape.circle),
              child: const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 15),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(
              'Gemini extracted ${found.length} of ${fields.length} fields',
              style: TextStyle(color: _AppColors.success, fontWeight: FontWeight.w700, fontSize: 13),
            )),
            Text('${found.length}/${fields.length}',
                style: TextStyle(color: _AppColors.success, fontWeight: FontWeight.w800, fontSize: 13)),
          ]),
        ),
        const Divider(height: 1, indent: 14, endIndent: 14),
        // Fields grid
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ...found.map((f) => _buildFieldChip(
                f.$2,
                getValue(f.$1),
                f.$3,
                found: true,
              )),
              ...notFound.map((f) => _buildFieldChip(
                f.$2,
                '',
                f.$3,
                found: false,
              )),
            ],
          ),
        ),
        // Preview of key extracted values
        if (getValue('title').isNotEmpty || getValue('abstract').isNotEmpty) ...[
          const Divider(height: 1, indent: 14, endIndent: 14),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (getValue('title').isNotEmpty) ...[
                _buildPreviewRow('Title', getValue('title'), Icons.title),
                const SizedBox(height: 6),
              ],
              if (getValue('supervisor').isNotEmpty) ...[
                _buildPreviewRow('Supervisor', getValue('supervisor'), Icons.person_outline),
                const SizedBox(height: 6),
              ],
              if (getValue('abstract').isNotEmpty)
                _buildPreviewRow('Abstract', getValue('abstract'), Icons.article_outlined, maxChars: 120),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _buildFieldChip(String label, String value, IconData icon, {required bool found}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: found ? _AppColors.success.withOpacity(0.12) : _AppColors.border.withOpacity(0.5),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: found ? _AppColors.success.withOpacity(0.3) : _AppColors.border,
        ),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(
          found ? Icons.check_circle : Icons.radio_button_unchecked,
          size: 11,
          color: found ? _AppColors.success : _AppColors.textSecondary.withOpacity(0.5),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: found ? _AppColors.success : _AppColors.textSecondary.withOpacity(0.5),
          ),
        ),
      ]),
    );
  }

  Widget _buildPreviewRow(String label, String value, IconData icon, {int maxChars = 60}) {
    final display = value.length > maxChars ? '${value.substring(0, maxChars)}...' : value;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 13, color: _AppColors.success.withOpacity(0.7)),
      const SizedBox(width: 6),
      Expanded(child: RichText(text: TextSpan(children: [
        TextSpan(text: '$label: ', style: TextStyle(
          fontSize: 12, fontWeight: FontWeight.w700,
          color: _AppColors.success.withOpacity(0.8),
        )),
        TextSpan(text: display, style: TextStyle(
          fontSize: 12, color: _AppColors.textPrimary.withOpacity(0.75),
        )),
      ]))),
    ]);
  }

  Widget _buildStudentSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: TextField(
          controller: _studentEntryCtrl,
          decoration: InputDecoration(
            labelText: 'Add Student Name',
            labelStyle: TextStyle(color: _AppColors.textSecondary),
            prefixIcon: Icon(Icons.person_add_outlined, size: 20, color: _AppColors.textSecondary),
            filled: true, fillColor: _AppColors.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _AppColors.border)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _AppColors.border)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _AppColors.accent, width: 1.5)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          ),
          onSubmitted: (_) => _addStudent(),
        )),
        const SizedBox(width: 8),
        _buildIconBtn(icon: Icons.add, color: _AppColors.accent, onTap: _addStudent),
      ]),
      if (_studentNames.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Wrap(spacing: 8, runSpacing: 6, children: _studentNames.map((name) => Chip(
            label: Text(name, style: const TextStyle(fontSize: 12)),
            deleteIcon: const Icon(Icons.close, size: 14),
            onDeleted: () => setState(() { _studentNames.remove(name); _saveDraft(); }),
            backgroundColor: _AppColors.accentLight,
            side: BorderSide(color: _AppColors.accent.withOpacity(0.2)),
            labelStyle: TextStyle(color: _AppColors.accent),
            deleteIconColor: _AppColors.accent,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          )).toList()),
        ),
    ]);
  }

  void _addStudent() {
    final name = _studentEntryCtrl.text.trim();
    if (name.isNotEmpty && !_studentNames.contains(name)) {
      setState(() { _studentNames.add(name); _studentEntryCtrl.clear(); });
      _saveDraft();
    }
  }

  Widget _buildIconBtn({required IconData icon, required Color color, required VoidCallback onTap}) {
    return Material(
      color: color, borderRadius: BorderRadius.circular(12),
      child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(12),
        child: Container(width: 46, height: 46, alignment: Alignment.center, child: Icon(icon, color: Colors.white, size: 22)),
      ),
    );
  }

  Widget _buildField(TextEditingController ctrl, String label, IconData icon, {
    int maxLines = 1, TextInputType keyboardType = TextInputType.text, String? reExtractKey,
  }) {
    return TextField(
      controller: ctrl, maxLines: maxLines, keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: _AppColors.textSecondary),
        prefixIcon: Icon(icon, size: 20, color: _AppColors.textSecondary),
        suffixIcon: reExtractKey != null
            ? Row(mainAxisSize: MainAxisSize.min, children: [
                // ✨ re-extract from already-scanned pages
                IconButton(
                  icon: Icon(Icons.auto_awesome, size: 18, color: _AppColors.accent),
                  tooltip: 'Re-extract from scanned pages',
                  onPressed: () => _reExtractField(ctrl, reExtractKey),
                ),
                // 📷 scan a new photo just for this field
                IconButton(
                  icon: Icon(Icons.add_a_photo_outlined, size: 18, color: const Color(0xFF7C3AED)),
                  tooltip: 'Scan a photo for this field',
                  onPressed: () => _showFieldScanPicker(ctrl, reExtractKey),
                ),
              ])
            : null,
        filled: true, fillColor: _AppColors.surface,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _AppColors.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _AppColors.border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _AppColors.accent, width: 1.5)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    );
  }

  void _showFieldScanPicker(TextEditingController ctrl, String fieldName) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 36, height: 4, decoration: BoxDecoration(color: _AppColors.border, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 16),
          Text('Scan for $fieldName', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(child: _buildScanFieldButton(
              icon: Icons.camera_alt_rounded,
              label: 'Camera',
              color: _AppColors.accent,
              onTap: () { Navigator.pop(ctx); _scanFieldFromImage(ctrl, fieldName, ImageSource.camera); },
            )),
            const SizedBox(width: 12),
            Expanded(child: _buildScanFieldButton(
              icon: Icons.photo_library_rounded,
              label: 'Gallery',
              color: const Color(0xFF7C3AED),
              onTap: () { Navigator.pop(ctx); _scanFieldFromImage(ctrl, fieldName, ImageSource.gallery); },
            )),
          ]),
        ]),
      ),
    );
  }

  Widget _buildScanFieldButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: color.withOpacity(0.06),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withOpacity(0.2)),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
          ]),
        ),
      ),
    );
  }

  Future<void> _scanFieldFromImage(
    TextEditingController ctrl,
    String fieldName,
    ImageSource source,
  ) async {
    try {
      final XFile? picked = source == ImageSource.gallery
          ? (await _picker.pickMultiImage()).firstOrNull
          : await _picker.pickImage(source: ImageSource.camera);

      if (picked == null) return;

      _showSnack('Analyzing image...', type: SnackType.info);

      // Use smart override — Gemini reads whatever is on the page,
      // understands the content regardless of how it is labeled,
      // cleans it, and returns it ready to insert.
      final value = await OcrService.smartScanForField(
        fieldName: fieldName,
        imagePath: picked.path,
      );

      if (value.isNotEmpty) {
        setState(() => ctrl.text = value);
        _saveDraft();
        _showSnack('$fieldName filled!', type: SnackType.success);
      } else {
        _showSnack('Nothing useful found in that image', type: SnackType.warning);
      }
    } catch (e) {
      _showSnack('Error: $e', type: SnackType.error);
    }
  }

  Widget _buildSectionLabel(String text, IconData icon) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(children: [
          Icon(icon, size: 14, color: _AppColors.textSecondary),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _AppColors.textSecondary, letterSpacing: 1.2)),
        ]),
      );

  Widget _buildSaveButton(bool isEditing) => SizedBox(
        height: 54,
        child: ElevatedButton.icon(
          onPressed: _saveLocal,
          style: ElevatedButton.styleFrom(
            backgroundColor: isEditing ? _AppColors.warning : _AppColors.success,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            elevation: 0,
          ),
          icon: Icon(isEditing ? Icons.update : Icons.save_outlined, size: 20),
          label: Text(isEditing ? 'Update Project' : 'Save Project',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ),
      );

  // ─── TAB 2: DOCUMENTS / RAW TEXT ───────────────────────────────────────────
  Widget _buildRawTab() {
    if (_scannedDocs.isEmpty) {
      return _buildEmptyState(
        Icons.document_scanner_outlined,
        'No pages yet',
        'Add images from the Form tab',
      );
    }

    // Fields to show in the extracted summary
    final extractedFields = [
      ('title',        'Title',       Icons.title),
      ('students',     'Students',    Icons.people_outline),
      ('supervisor',   'Supervisor',  Icons.person_outline),
      ('year',         'Year',        Icons.calendar_today),
      ('abstract',     'Abstract',    Icons.article_outlined),
      ('description',  'Description', Icons.notes),
      ('problem',      'Problem',     Icons.report_problem_outlined),
      ('solution',     'Solution',    Icons.check_circle_outline),
      ('objectives',   'Objectives',  Icons.flag_outlined),
      ('technologies', 'Technologies',Icons.code),
      ('keywords',     'Keywords',    Icons.tag),
      ('category',     'Category',    Icons.category_outlined),
    ];

    String getVal(String key) {
      final v = _lastExtracted[key];
      if (v == null) return '';
      if (v is String) return v;
      if (v is Map) return v['value']?.toString() ?? '';
      return '';
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

        // ── Page images row ──────────────────────────────────────────────
        Text('PAGES (${_scannedDocs.length})',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800,
                color: _AppColors.textSecondary, letterSpacing: 1.2)),
        const SizedBox(height: 10),
        SizedBox(
          height: 160,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _scannedDocs.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (ctx, i) {
              final doc = _scannedDocs[i];
              final img = doc['image'] as XFile?;
              return GestureDetector(
                onTap: img != null ? () => _previewImage(img, i) : null,
                child: Stack(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: img != null
                        ? Image.file(File(img.path),
                            width: 110, height: 160, fit: BoxFit.cover)
                        : Container(
                            width: 110, height: 160,
                            decoration: BoxDecoration(
                              color: _AppColors.accentLight,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(Icons.description_outlined,
                                color: _AppColors.accent, size: 32),
                          ),
                  ),
                  // Page label
                  Positioned(
                    bottom: 0, left: 0, right: 0,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Colors.black.withOpacity(0.65), Colors.transparent],
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                          ),
                        ),
                        child: Text('Page \${i + 1}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ),
                  // Zoom icon
                  if (img != null)
                    Positioned(
                      top: 6, right: 6,
                      child: Container(
                        width: 22, height: 22,
                        decoration: BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                        child: const Icon(Icons.zoom_in, color: Colors.white, size: 13),
                      ),
                    ),
                ]),
              );
            },
          ),
        ),

        const SizedBox(height: 24),

        // ── Extracted data ───────────────────────────────────────────────
        Row(children: [
          Text('EXTRACTED DATA',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800,
                  color: _AppColors.textSecondary, letterSpacing: 1.2)),
          const Spacer(),
          if (_lastExtracted.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _AppColors.warningLight,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('Not extracted yet',
                  style: TextStyle(fontSize: 11, color: _AppColors.warning, fontWeight: FontWeight.w600)),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _AppColors.successLight,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '\${extractedFields.where((f) => getVal(f.\$1).isNotEmpty).length}/\${extractedFields.length} fields',
                style: TextStyle(fontSize: 11, color: _AppColors.success, fontWeight: FontWeight.w600),
              ),
            ),
        ]),
        const SizedBox(height: 10),

        if (_lastExtracted.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _AppColors.border),
            ),
            child: Column(children: [
              Icon(Icons.auto_awesome_outlined, size: 36, color: _AppColors.border),
              const SizedBox(height: 10),
              Text('Tap "Extract All Fields" in the Form tab',
                  style: TextStyle(color: _AppColors.textSecondary, fontSize: 13),
                  textAlign: TextAlign.center),
            ]),
          )
        else
          Column(
            children: extractedFields.map((f) {
              final value = getVal(f.$1);
              if (value.isEmpty) return const SizedBox.shrink();
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: _AppColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _AppColors.border),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // Field header
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                    child: Row(children: [
                      Container(
                        width: 28, height: 28,
                        decoration: BoxDecoration(
                          color: _AppColors.accentLight,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(f.$3, size: 15, color: _AppColors.accent),
                      ),
                      const SizedBox(width: 10),
                      Text(f.$2,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                      const Spacer(),
                      GestureDetector(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: value));
                          _showSnack('Copied ${f.$2}!', type: SnackType.success);
                        },
                        child: Icon(Icons.copy_outlined, size: 16, color: _AppColors.textSecondary),
                      ),
                    ]),
                  ),
                  const Divider(height: 1),
                  // Field value
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                    child: SelectableText(
                      value,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.6,
                        color: _AppColors.textPrimary,
                      ),
                    ),
                  ),
                ]),
              );
            }).toList(),
          ),

        const SizedBox(height: 80),
      ]),
    );
  }

  // ─── TAB 3: PROJECTS ───────────────────────────────────────────────────────
  Widget _buildProjectsTab() {
    if (_projects.isEmpty) {
      return _buildEmptyState(Icons.folder_copy_outlined, 'No saved projects', 'Fill in the form and tap Save to add projects');
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      itemCount: _projects.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (ctx, i) {
        final p = _projects[i];
        return Dismissible(
          key: Key('proj_${p.id}'),
          direction: DismissDirection.endToStart,
          background: Container(
            decoration: BoxDecoration(color: _AppColors.danger, borderRadius: BorderRadius.circular(16)),
            alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          confirmDismiss: (_) => _confirm('Delete Project?', 'Cannot be undone.'),
          onDismissed: (_) async { await DatabaseService.deleteProject(p.id!); _loadProjects(); },
          child: _buildProjectCard(p),
        );
      },
    );
  }

  Widget _buildProjectCard(ProjectInfo p) => Container(
        decoration: BoxDecoration(
          color: _AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _AppColors.border),
          boxShadow: [BoxShadow(color: _AppColors.cardShadow, blurRadius: 8, offset: const Offset(0, 2))],
        ),
        child: InkWell(
          onTap: () => _startEditing(p),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: p.isSynced ? _AppColors.successLight : _AppColors.warningLight,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(p.isSynced ? Icons.check_circle : Icons.cloud_off, size: 12, color: p.isSynced ? _AppColors.success : _AppColors.warning),
                    const SizedBox(width: 4),
                    Text(p.isSynced ? 'Synced' : 'Local',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: p.isSynced ? _AppColors.success : _AppColors.warning)),
                  ]),
                ),
                if (p.year.isNotEmpty) ...[const SizedBox(width: 8), Text(p.year, style: TextStyle(color: _AppColors.textSecondary, fontSize: 12))],
                const Spacer(),
                PopupMenuButton<String>(
                  padding: EdgeInsets.zero,
                  icon: Icon(Icons.more_vert, color: _AppColors.textSecondary, size: 20),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  onSelected: (val) {
                    if (val == 'edit') _startEditing(p);
                    if (val == 'sync') _uploadSingle(p);
                    if (val == 'delete') { DatabaseService.deleteProject(p.id!); _loadProjects(); }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: Text('Edit')),
                    if (!p.isSynced) const PopupMenuItem(value: 'sync', child: Text('Sync to Sheets')),
                    PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: _AppColors.danger))),
                  ],
                ),
              ]),
              const SizedBox(height: 10),
              Text(p.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, height: 1.3)),
              if (p.supervisorName.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(children: [Icon(Icons.person_outline, size: 14, color: _AppColors.textSecondary), const SizedBox(width: 4), Text(p.supervisorName, style: TextStyle(color: _AppColors.textSecondary, fontSize: 13))]),
              ],
              if (p.category.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(children: [Icon(Icons.category_outlined, size: 14, color: _AppColors.textSecondary), const SizedBox(width: 4), Text(p.category, style: TextStyle(color: _AppColors.textSecondary, fontSize: 13))]),
              ],
              // Problem snippet in card
              if (p.problem.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.report_problem_outlined, size: 13, color: _AppColors.warning),
                  const SizedBox(width: 4),
                  Expanded(child: Text(
                    p.problem.length > 80 ? '${p.problem.substring(0, 80)}...' : p.problem,
                    style: TextStyle(color: _AppColors.textSecondary, fontSize: 12),
                  )),
                ]),
              ],
              if (p.studentNames.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(spacing: 6, runSpacing: 4, children: p.studentNames.take(3).map((s) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: _AppColors.bg, borderRadius: BorderRadius.circular(6), border: Border.all(color: _AppColors.border)),
                  child: Text(s, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
                )).toList()),
              ],
            ]),
          ),
        ),
      );

  Widget _buildSyncFab(int unsyncedCount) {
    return FloatingActionButton.extended(
      onPressed: unsyncedCount > 0 ? _syncAll : null,
      backgroundColor: unsyncedCount > 0 ? _AppColors.accent : _AppColors.success,
      foregroundColor: Colors.white,
      elevation: 4,
      icon: Icon(unsyncedCount > 0 ? Icons.cloud_upload_outlined : Icons.check_circle),
      label: Text(unsyncedCount > 0 ? 'Sync All ($unsyncedCount)' : 'All Synced',
          style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }

  Widget _buildEmptyState(IconData icon, String title, String subtitle) {
    return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(
        width: 80, height: 80,
        decoration: BoxDecoration(color: _AppColors.accentLight, borderRadius: BorderRadius.circular(20)),
        child: Icon(icon, size: 36, color: _AppColors.accent),
      ),
      const SizedBox(height: 16),
      Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _AppColors.textPrimary)),
      const SizedBox(height: 6),
      Text(subtitle, style: TextStyle(color: _AppColors.textSecondary, fontSize: 13), textAlign: TextAlign.center),
    ]));
  }
}

enum SnackType { success, error, warning, info }